#!/usr/bin/env bash
# Tests docker-updater against a stub docker that logs its calls and returns canned output.
# Uses the real yq if installed, otherwise a stub.
# shellcheck disable=SC2016 # bash -c snippets expand their variables themselves

SCRIPT="$(realpath "$(dirname "$0")/../docker-updater")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() {
	PASS=$((PASS + 1))
	echo "ok   $1"
}

not_ok() {
	FAIL=$((FAIL + 1))
	echo "FAIL $1"
	[[ -n "$2" ]] && echo "${2//$'\n'/$'\n'     }"
}

# check NAME COMMAND...: passes if COMMAND succeeds.
check() {
	local name="$1"
	shift
	if "$@"; then ok "$name"; else not_ok "$name" "$OUT"; fi
}

has() { grep -qE -- "$1" <<<"$2"; }
log_has() { grep -qE -- "$1" "$LOG"; }
log_count() { [[ "$(grep -cE -- "$1" "$LOG")" == "$2" ]]; }

mkdir -p "$WORK/bin"
cat >"$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
# The project is selected by the current directory name:
#   fresh: web uses an old image, registry has a newer one
#   same: nothing changed, registry matches
#   buildfail: build fails
#   nocontainer: db has no container
#   broken: compose config fails
p="$(basename "$PWD")"
echo "docker $* [$p]" >>"$LOG"
file=""
[[ "$1 $2" == "compose -f" ]] && file="$3" && set -- compose "${@:4}"
if [[ "$*" == "compose config" ]]; then
	[[ "$p" == broken ]] && echo "yaml: line 1: did not find expected key" && exit 1
	# Stands in for the merged config: the compose file docker compose would pick.
	for f in "$file" compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
		[[ -n "$f" && -f "$f" ]] && exec cat "$f"
	done
	exit 1
fi
DIG_A="sha256:$(printf 'a%.0s' {1..64})"
DIG_B="sha256:$(printf 'b%.0s' {1..64})"
case "$*" in
"compose config --hash *") echo "web h1"; echo "db h2" ;;
"compose ps -aq") echo c1; [[ "$p" != nocontainer ]] && echo c2 ;;
inspect\ *c1) printf 'web\th1\tnginx\tsha256:old\n' ;;
inspect\ *c2) printf 'db\th2\tpg\tsha256:pg\n' ;;
"image inspect -f {{.Id}} nginx") [[ "$p" == fresh ]] && echo sha256:new || echo sha256:old ;;
"image inspect -f {{.Id}} pg") echo sha256:pg ;;
"compose config --images") echo nginx; echo pg ;;
"image inspect -f {{join .RepoDigests \" \"}} nginx") echo "nginx@$DIG_A" ;;
"image inspect -f {{join .RepoDigests \" \"}} pg") echo "pg@$DIG_A" ;;
"buildx version") ;;
buildx\ imagetools\ *) [[ "$p" == same ]] && echo "{\"digest\":\"$DIG_A\"}" || echo "{\"digest\":\"$DIG_B\"}" ;;
"compose build --pull") [[ "$p" == buildfail ]] && exit 1 ;;
esac
exit 0
EOF
if ! command -v yq &>/dev/null; then
	cat >"$WORK/bin/yq" <<'EOF'
#!/usr/bin/env bash
# Only knows the two expressions docker-updater uses.
in="$(tr '\n' ' ')"
case "$1" in
'.["x-docker-updater"].enabled')
	[[ "$in" =~ x-docker-updater:\ +enabled:\ +(true|false) ]] && echo "${BASH_REMATCH[1]}" || echo null
	;;
.configs.autoupdate) [[ "$in" == *"configs:   autoupdate:"* ]] ;;
*) exit 2 ;;
esac
EOF
fi
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
export LOG="$WORK/log"
unset DOCKER_UPDATER_ROOT NO_COLOR

ROOT="$WORK/root"
AUTO=$'x-docker-updater:\n  enabled: true\nservices: {}\n'
LEGACY=$'configs:\n  autoupdate:\n    external: true\nservices: {}\n'
mkdir -p "$ROOT"/{fresh,same,buildfail,nocontainer,off,disabled,broken,empty}
echo "$AUTO" >"$ROOT/fresh/compose.yaml"
echo "$AUTO" >"$ROOT/fresh/docker-compose.yml"
echo "$AUTO" >"$ROOT/same/compose.yml"
echo "$AUTO" >"$ROOT/buildfail/docker-compose.yaml"
echo "$LEGACY" >"$ROOT/nocontainer/docker-compose.yml"
echo 'services: {}' >"$ROOT/off/compose.yaml"
printf 'x-docker-updater:\n  enabled: false\n%s' "$LEGACY" >"$ROOT/disabled/compose.yaml"
echo "$AUTO" >"$ROOT/broken/compose.yaml"

run() {
	: >"$LOG"
	OUT="$(cd "$WORK" && "$@" 2>&1)"
	RC=$?
}

# Full run
run bash "$SCRIPT" --root "$ROOT"
check "full run exits 1 when a project failed" test "$RC" = 1
check "fresh is updated" has 'fresh +updated +web: new image' "$OUT"
check "same is up-to-date" has 'same +up-to-date' "$OUT"
check "buildfail fails" has 'buildfail +failed +build failed' "$OUT"
check "nocontainer is updated" has 'nocontainer +updated +db: no container' "$OUT"
check "off is skipped" has 'off +skipped +autoupdate not configured' "$OUT"
check "legacy configs.autoupdate still works" has 'nocontainer +updated .*\(deprecated configs.autoupdate' "$OUT"
check "x-docker-updater enabled has no deprecation note" bash -c '! grep -q "fresh.*deprecated" <<<"$1"' _ "$OUT"
check "enabled: false wins over legacy" has 'disabled +skipped +disabled in x-docker-updater' "$OUT"
check "broken compose file fails" has 'broken +failed +compose config failed: yaml: line 1' "$OUT"
check "nothing else runs for broken" bash -c '! grep -q "compose pull.*\[broken\]" "$LOG"'
check "dir without compose file is ignored" bash -c '! grep -q "empty" <<<"$1"' _ "$OUT"
check "fresh processed once despite two compose files" log_count 'compose pull .*\[fresh\]' 1
check "up -d only for changed projects" log_count 'compose up -d --remove-orphans' 2
check "no up -d after failed build" bash -c '! grep -q "up -d.*\[buildfail\]" "$LOG"'
check "never runs down" bash -c '! grep -q "compose down" "$LOG"'
check "prune runs twice" log_count 'system prune -af' 2
check "no color codes when piped" bash -c '! grep -q $'"'"'\e'"'"' <<<"$1"' _ "$OUT"

# Dry run
run bash "$SCRIPT" -n --root "$ROOT"
check "dry run exits 1 when a project failed" test "$RC" = 1
check "dry run changes nothing" bash -c '! grep -qE "compose (pull|build|up)|system prune" "$LOG"'
check "dry run: fresh would update" has 'fresh +would update' "$OUT"
check "dry run: same up-to-date" has 'same +up-to-date +all images current' "$OUT"
check "dry run: registry digest compared" has 'buildfail +would update +.*nginx: newer image in registry' "$OUT"

run bash "$SCRIPT" -n "$ROOT/same"
check "dry run exits 0 when nothing failed" test "$RC" = 0

# Root selection
run env DOCKER_UPDATER_ROOT="$ROOT" bash "$SCRIPT" -n
check "root from env var" has 'same +up-to-date' "$OUT"
run env DOCKER_UPDATER_ROOT=/nonexistent bash "$SCRIPT" -n --root "$ROOT"
check "--root wins over env var" has 'same +up-to-date' "$OUT"
run bash "$SCRIPT" -n --root /nonexistent
check "missing root fails" test "$RC" = 1

# Explicit targets
run bash "$SCRIPT" -n "$ROOT/fresh/docker-compose.yml" "$ROOT/same" "$ROOT/empty" nope
check "non-default file gets -f" log_has "compose -f $ROOT/fresh/docker-compose.yml config"
check "default file gets no -f" bash -c '! grep -q "compose -f.*\[same\]" "$LOG"'
check "dir without compose file skipped" has 'empty +skipped +no compose file' "$OUT"
check "missing target fails" has 'nope +failed +not found' "$OUT"

# Options
run bash "$SCRIPT" --help
check "--help exits 0" test "$RC" = 0
run bash "$SCRIPT" --bogus
check "unknown option exits 1" test "$RC" = 1
run bash "$SCRIPT" --version
check "--version prints version" has '^docker-updater ' "$OUT"

echo
echo "$PASS passed, $FAIL failed"
((FAIL == 0))
