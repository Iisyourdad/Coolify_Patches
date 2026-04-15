# Routing Patch Helper

`apply_routing_patch.sh` applies one or more GitHub PRs or branch URLs into a running Coolify container without rebuilding the image.

It is meant for fast self-hosted testing when you want to layer a patch set on top of an existing Coolify install and validate the result quickly.

`remove_routing_patch.sh` removes the entries listed in `remove_patch.txt` by rebuilding the patched workspace with those entries excluded, then syncing the resulting delta into the container.

The removal script defaults to `upstream/v4.x` as its reset base, so it removes only the patches you list and does not move the workspace to `next`. Override with `BASE_REF=...` if you need a different reset branch.

## What It Does

The apply script now builds one aggregate git workspace instead of copying each PR directly into the container one at a time.

That means it will:

1. Clone the upstream Coolify repo into a temporary workspace.
2. Check out a local work branch from `BASE_REF`.
3. Read every GitHub PR or branch URL from `patches.txt`.
4. Fetch each source ref.
5. Generate that ref's diff against `BASE_REF`.
6. Apply each diff into the same workspace with `git apply --3way`.
7. Stop if patches conflict instead of silently overwriting later files.
8. Compute the final merged file set.
9. Copy changed files into the container and remove deleted files.
10. Clear Laravel caches, optionally run migrations, and optionally restart the container.

This is safer than the older flow because overlapping PRs are now handled as a combined patch set instead of "last file copied wins".

## Supported Patch Sources

Each non-empty, non-comment line in `patches.txt` must be one of these:

- `https://github.com/<owner>/<repo>/pull/<number>`
- `https://github.com/<owner>/<repo>/tree/<branch>`

`remove_patch.txt` uses the same formats, but it is interpreted as the subset of `patches.txt` to remove.

The included `patches.txt` currently points at:

```txt
https://github.com/Iisyourdad/coolify/pull/4
https://github.com/Iisyourdad/coolify/pull/5
```

## Why This Works Better

Compared with the earlier script, this version:

- applies all entries into one shared workspace instead of copying each PR independently
- fails on conflicts instead of silently overwriting previous file copies
- handles deletions and renames when syncing into the container
- supports `DRY_RUN=true` so you can validate the combined patch set without touching Docker
- clears Laravel caches by default after file sync
- can auto-run migrations when files under `database/migrations/` changed
- preserves the temp workspace automatically when the script fails

## Requirements

You need:

- `bash`
- `git`
- `tar`
- `docker` unless you use `DRY_RUN=true`

You also need Docker access on the machine running the script.

If you are not using `DRY_RUN=true`, the target container must already exist.

## How To Run It

From this directory:

```bash
chmod +x apply_routing_patch.sh
./apply_routing_patch.sh
```

To remove selected patches:

```bash
chmod +x remove_routing_patch.sh
./remove_routing_patch.sh
```

By default it reads `patches.txt` from the same directory as the script, patches the `coolify` container, clears caches, runs migrations only when migration files changed, and then restarts the container.

## Common Examples

Preview the combined patch set without touching the container:

```bash
DRY_RUN=true ./apply_routing_patch.sh
```

Patch a different container:

```bash
CONTAINER=my-coolify ./apply_routing_patch.sh
```

Use a different patch list:

```bash
PATCHES_FILE=/path/to/patches.txt ./apply_routing_patch.sh
```

Use a different removal list:

```bash
REMOVE_PATCHES_FILE=/path/to/remove_patch.txt ./remove_routing_patch.sh
```

Use a different base ref:

```bash
BASE_REF=upstream/main ./apply_routing_patch.sh
```

Skip the restart:

```bash
RESTART_CONTAINER=false ./apply_routing_patch.sh
```

Disable cache clear:

```bash
CLEAR_CACHE=false ./apply_routing_patch.sh
```

Always run migrations:

```bash
RUN_MIGRATIONS=true ./apply_routing_patch.sh
```

Never run migrations:

```bash
RUN_MIGRATIONS=false ./apply_routing_patch.sh
```

Run an extra command inside the container after syncing files:

```bash
POST_APPLY_COMMAND='php artisan queue:restart' ./apply_routing_patch.sh
```

Keep the temp workspace even on success:

```bash
KEEP_WORKDIR=true ./apply_routing_patch.sh
```

## Environment Variables

- `UPSTREAM_URL`: upstream repo to clone and compare against
- `BASE_REF`: base ref used for diffs, default `upstream/next`
- `PATCHES_FILE`: patch source list, default is the local `patches.txt`
- `REMOVE_PATCHES_FILE`: removal list used by `remove_routing_patch.sh`, default is the local `remove_patch.txt`
- `CONTAINER`: target Docker container name, default `coolify`
- `DEST_DIR`: destination path inside the container, default `/var/www/html`
- `RESTART_CONTAINER`: `true` or `false`
- `CLEAR_CACHE`: `true` or `false`
- `RUN_MIGRATIONS`: `true`, `false`, or `auto`
- `POST_APPLY_COMMAND`: optional shell command to run inside the container after file sync
- `DRY_RUN`: `true` or `false`
- `KEEP_WORKDIR`: `true` or `false`

`RUN_MIGRATIONS=auto` means migrations only run when the final merged patch set changes files under `database/migrations/`.

## Important Notes

- This script still overlays files directly into a running container. If the container is recreated or Coolify is updated, these changes can be lost.
- The script is safer than the original version, but it still assumes the listed PRs or branches are intended to be combined on top of the same `BASE_REF`.
- If a patch fails to apply cleanly, the script stops and keeps the temp workspace so you can inspect the conflict.
- If your patch set needs extra build or runtime steps beyond cache clear, migrations, or restart, use `POST_APPLY_COMMAND` or handle those manually.
