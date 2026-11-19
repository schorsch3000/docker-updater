# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Bash script, `docker-updater` (no extension), that updates Docker Compose services living under `/opt/docker/*/`. There is no build system or package manifest.

## Commands

- Lint: `shellcheck docker-updater tests/run.sh`
- Tests: `bash tests/run.sh`
- Help: `bash docker-updater -h`
- Dry run (changes nothing, checks registries for newer images): `bash docker-updater -n`
- Specific projects: `bash docker-updater [-n] path/to/compose.yaml path/to/project-dir ...`
- Other root: `--root DIR` or `DOCKER_UPDATER_ROOT=DIR` (default `/opt/docker`)

Runtime dependencies: `yq`, `docker compose` v2 (uses `pull --ignore-buildable` and `config --hash`), and `docker buildx` for the dry-run registry check. None are installed in the `.az` sandbox.

`tests/run.sh` puts a stub `docker` first in `PATH`. The stub logs every call and returns canned output chosen by the project directory name (`fresh`, `same`, `buildfail`, `nocontainer`, `broken`). For `compose config` it prints the compose file itself in place of the merged config. It uses the real `yq` if one is installed, otherwise a stub. New docker calls in the script need a matching case in the stub.

## CI

GitHub Actions:
- `.github/workflows/ci.yml` runs shellcheck and the tests on pushes to `main` and on PRs.
- `.github/workflows/release.yml` runs on `v*` tags. It reuses CI, replaces `VERSION="dev"` in the script with the tag name, and creates a GitHub release with `docker-updater` and its `.sha256` attached. Keep the `VERSION="dev"` line exactly as is; the release step greps for it.

## How it works

Everything runs in one process so results can be collected for the summary at the end.

1. **Discovery:** each direct subdirectory of the root (or each argument) becomes a project. The compose file is the first that exists of `compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`, matching docker compose's own precedence, so each directory is handled once. `-f` is passed only when an argument names a non-default file; otherwise `compose.override.*` would stop being picked up.
2. **Opt-in:** a project is updated only if `x-docker-updater.enabled` is `true`. It is read from the merged `docker compose config` output, so overrides, `include` and `.env` apply. If `docker compose config` fails, the project is reported as failed. The old `configs.autoupdate` key in the compose file itself still works, but adds a deprecation note to the summary; an explicit `enabled: false` wins over it. Everything else is reported as skipped.
3. **Update:** `pull --ignore-buildable`, then `build --pull`. If either fails, the project is marked failed and not restarted. `local_changes` then compares each container's config-hash label with `docker compose config --hash '*'`, and its image ID with the current ID of its image tag. It also flags services that have no container. Only if something changed does it run `up -d --remove-orphans`. There is deliberately no `down`.
4. **Dry run:** runs `local_changes` plus `remote_changes`, which compares local `RepoDigests` with the registry digest from `docker buildx imagetools inspect`. Images without a registry digest (built locally) are reported as not checkable.
5. **Prune:** `docker system prune -af` runs once before and once after all projects, to free space on nearly full disks. It is host-wide and removes stopped containers too. That is intended: these are production hosts where every image can be pulled or rebuilt.
6. **Summary:** `record name status reason` collects results. Exit code is 1 if any project or prune failed.

Output colors use the `FC_*`/`BC_*`/`S_*`/`R_*` ANSI variables at the top and need `echo -e` or `printf %b`. They are blanked when stdout is not a terminal or `NO_COLOR` is set.

## Repo layout notes

- `.az/` is the sandboxed dev-container setup (Dockerfile plus apt/pipx package lists), not part of the tool itself.
- `.idea/` is JetBrains project config.
