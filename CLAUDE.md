# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker container that wraps [`sandreas/m4b-tool`](https://github.com/sandreas/m4b-tool) in a watch-loop daemon. It scans `/input` for subdirectories of audio files, merges each into a single tagged `.m4b` audiobook, and writes the result to `/output`. Designed for Unraid (hence the `unraid-template.xml` and `PUID/PGID` handling).

There is no application code beyond two bash scripts and a Dockerfile. All "logic" lives in `scripts/m4b-audiobook-converter.sh`.

## Architecture

Three-layer container:

1. **`Dockerfile`** — `FROM sandreas/m4b-tool:latest` (Alpine-based). Adds `bash`, `su-exec`, `shadow` for the PUID/PGID dance, creates the `abc` user, and pre-creates `/input`, `/output`, `/config/logs`, `/temp/merge`, `/backup`.
2. **`scripts/entrypoint.sh`** — runs as root. Rewrites `abc`'s UID/GID to match `PUID`/`PGID` env vars, `chown`s the volumes, prints a startup banner, then `su-exec abc:abc` into the worker script. Forwards `SIGTERM`/`SIGINT` to the child.
3. **`scripts/m4b-audiobook-converter.sh`** — the worker loop. Runs as `abc`. Sleeps `SLEEPTIME` between scans.

### Worker loop semantics (important when editing the script)

For each top-level directory under `/input`:

- **Locking**: writes `.processing` inside the book dir. Locks older than 24h are considered stale and removed. Only directories with audio files (`mp3/m4a/m4b/ogg/flac/wma/aac/opus/wav`, `maxdepth 1`) are processed.
- **Working copy**: the source is copied (`cp -a`) into `/temp/merge/<book>` so originals are untouched until success. `/temp` is a `tmpfs` (4G) per `docker-compose.yml` — large books may need this raised.
- **Bitrate**: when `AUDIO_BITRATE=auto`, `ffprobe` reads the first audio file and the result is rounded to kbps. Falls back to `128k`.
- **Chapters**: if `chapters.txt` is present in the book dir it's used; otherwise `--use-filenames-as-chapters` + `--no-chapter-reindexing`. Don't "fix" this by removing the flag — filename chapters are the intended fallback.
- **Success path**: result moves to `/output/<book>/<book>.m4b`, the per-book log is copied alongside, cover art (`cover|folder.{jpg,jpeg,png}`) is copied if present, optional backup to `/backup/<book>`, and **the source is deleted from `/input`**. This deletion is intentional — the container is a one-way pipeline.
- **Failure path**: source is moved to `/output/failed/<book>/source` with `error.log`. Never silently retried.
- **Per-book log**: `/config/logs/<book>.log`, also copied into the output dir.

### Config surface

All runtime knobs are env vars, defaulted in the Dockerfile and surfaced again in `docker-compose.yml` and `unraid-template.xml`. **When adding or renaming an env var, update all three** or the Unraid template will silently drift.

| Var | Default | Notes |
|---|---|---|
| `PUID` / `PGID` | `99` / `100` | Unraid `nobody:users`. Applied at entrypoint via `usermod`/`groupmod`. |
| `SLEEPTIME` | `5m` | Passed straight to `sleep`, so any `sleep`-compatible suffix works. |
| `CPU_CORES` | `0` | `0` ⇒ `nproc`. Passed to `m4b-tool --jobs`. |
| `MAKE_BACKUP` | `N` | Compared case-insensitively against `Y`. |
| `AUDIO_BITRATE` | `auto` | `auto` triggers `ffprobe` detection. |
| `AUDIO_CODEC` | `libfdk_aac` | Whatever `m4b-tool` accepts. |

## Build & run

```bash
# Local build
docker build -t m4b-audiobook-converter:dev .

# Run against a compose file (most common during development)
docker compose up --build

# Tail the worker
docker logs -f m4b-audiobook-converter

# Exec in to poke around
docker exec -it m4b-audiobook-converter bash

# Lint the bash scripts before pushing
shellcheck scripts/entrypoint.sh scripts/m4b-audiobook-converter.sh
```

There are no unit tests. Validation is "build the image, point it at a directory of test files, watch the log."

## Release / CI

`.github/workflows/build-and-push.yml` builds and pushes to `ghcr.io/aidrak/m4b-audiobook-converter` on:

- pushes to `main` → `latest` + `sha-…` tags
- tags matching `v*.*.*` → semver tags (`{{version}}`, `{{major}}.{{minor}}`)

Work happens on `main`; every push ships `latest`. Tag `vX.Y.Z` for a versioned release. The GHCR PAT is not needed locally — CI uses `GITHUB_TOKEN`.

## Things to be careful about

- **Successful conversions delete the source.** If you're testing destructive changes, use a throwaway input dir.
- **`set -euo pipefail` is on in both scripts.** Any unguarded command failure kills the loop. Wrap fallible probes (`ffprobe`, `find`) with `|| true` or explicit `set +e` blocks like the existing `m4b-tool` invocation.
- **The healthcheck `pgrep`s for `m4b-audiobook-converter.sh`.** Don't rename the script without updating the `HEALTHCHECK` line in the Dockerfile.
- **`/temp` is tmpfs.** A book larger than the tmpfs size will fail mid-copy. Surface this in errors rather than swallowing it.
