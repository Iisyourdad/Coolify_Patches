#!/usr/bin/env bash
set -euo pipefail

# Restore Coolify to an official stock install.
# Default behavior preserves runtime data and only removes local patches.
# Set FULL_WIPE=true to remove /data/coolify and Docker volumes first.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

FULL_WIPE="${FULL_WIPE:-false}"
RESET_LOCAL_REPO="${RESET_LOCAL_REPO:-true}"
DISABLE_CUSTOM_COMPOSE="${DISABLE_CUSTOM_COMPOSE:-true}"
CHANNEL="${CHANNEL:-stable}"
BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR/backups/$TIMESTAMP}"
COOLIFY_DATA_DIR="${COOLIFY_DATA_DIR:-/data/coolify}"
COOLIFY_SOURCE_DIR="$COOLIFY_DATA_DIR/source"
COOLIFY_CUSTOM_COMPOSE="$COOLIFY_SOURCE_DIR/docker-compose.custom.yml"
COOLIFY_REPO_DIR="${COOLIFY_REPO_DIR:-}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/coollabsio/coolify.git}"
LOCAL_RESET_REF="${LOCAL_RESET_REF:-}"

log() {
  printf '==> %s\n' "$1"
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

validate_boolean() {
  case "${1,,}" in
    true|1|yes|y|false|0|no|n) ;;
    *) fail "Expected a boolean value, got: $1" ;;
  esac
}

is_true() {
  case "${1,,}" in
    true|1|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_owner_user() {
  if [ -n "${SUDO_USER:-}" ]; then
    printf '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

resolve_owner_home() {
  local owner_user="$1"
  local owner_home

  owner_home="$(getent passwd "$owner_user" | cut -d: -f6)"
  [ -n "$owner_home" ] || fail "Could not determine home for $owner_user"
  printf '%s\n' "$owner_home"
}

run_as_owner() {
  local owner_user="$1"
  shift

  if [ "$(id -u)" -eq 0 ] && [ "$owner_user" != "root" ]; then
    sudo -u "$owner_user" -H "$@"
  else
    "$@"
  fi
}

resolve_repo_dir() {
  local owner_home="$1"
  local candidate

  if [ -n "$COOLIFY_REPO_DIR" ] && [ -d "$COOLIFY_REPO_DIR/.git" ]; then
    printf '%s\n' "$COOLIFY_REPO_DIR"
    return 0
  fi

  for candidate in \
    "$owner_home/Coolify/coolify" \
    "$owner_home/coolify" \
    "$owner_home/Coolify"; do
    if [ -d "$candidate/.git" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

resolve_channel_settings() {
  case "${CHANNEL,,}" in
    stable|beta|production)
      CHANNEL="stable"
      INSTALL_URL="https://cdn.coollabs.io/coolify/install.sh"
      VERSION_KEY=".coolify.v4.version"
      DEFAULT_RESET_REF="upstream/v4.x"
      INSTALLER_ARG=""
      ;;
    nightly|next)
      CHANNEL="nightly"
      INSTALL_URL="https://cdn.coollabs.io/coolify-nightly/install.sh"
      VERSION_KEY=".coolify.nightly.version"
      DEFAULT_RESET_REF="upstream/next"
      INSTALLER_ARG="next"
      ;;
    *)
      fail "Unsupported CHANNEL: $CHANNEL"
      ;;
  esac

  if [ -z "$LOCAL_RESET_REF" ]; then
    LOCAL_RESET_REF="$DEFAULT_RESET_REF"
  fi
}

fetch_latest_version() {
  local versions_json
  versions_json="$(curl -fsSL https://cdn.coollabs.io/coolify/versions.json)"

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$versions_json" | jq -r "$VERSION_KEY"
  else
    if [ "$CHANNEL" = "nightly" ]; then
      printf '%s\n' "$versions_json" | tr -d '\n' | sed -n 's/.*"nightly":[[:space:]]*{"version":[[:space:]]*"\([^"]*\)".*/\1/p'
    else
      printf '%s\n' "$versions_json" | tr -d '\n' | sed -n 's/.*"v4":[[:space:]]*{"version":[[:space:]]*"\([^"]*\)".*/\1/p'
    fi
  fi
}

backup_file_if_present() {
  local path="$1"
  local label="$2"

  [ -f "$path" ] || return 0

  mkdir -p "$BACKUP_ROOT"
  cp -a "$path" "$BACKUP_ROOT/$label"
  log "Backed up $path"
}

disable_custom_compose_if_present() {
  [ -f "$COOLIFY_CUSTOM_COMPOSE" ] || return 0

  mkdir -p "$BACKUP_ROOT"
  mv "$COOLIFY_CUSTOM_COMPOSE" "$BACKUP_ROOT/docker-compose.custom.yml.disabled"
  log "Disabled $COOLIFY_CUSTOM_COMPOSE"
}

backup_repo_state() {
  local owner_user="$1"
  local repo_dir="$2"
  local repo_backup_dir="$BACKUP_ROOT/local-checkout"

  mkdir -p "$repo_backup_dir"
  run_as_owner "$owner_user" git -C "$repo_dir" status --short --branch > "$repo_backup_dir/status.txt"
  run_as_owner "$owner_user" git -C "$repo_dir" diff > "$repo_backup_dir/worktree.diff"
  run_as_owner "$owner_user" git -C "$repo_dir" diff --cached > "$repo_backup_dir/index.diff"
}

reset_local_repo() {
  local owner_user="$1"
  local repo_dir="$2"
  local current_head backup_branch

  log "Resetting local checkout at $repo_dir to $LOCAL_RESET_REF"
  backup_repo_state "$owner_user" "$repo_dir"

  if run_as_owner "$owner_user" git -C "$repo_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
    current_head="$(run_as_owner "$owner_user" git -C "$repo_dir" rev-parse --short HEAD)"
    backup_branch="backup/pre-stock-reset-$TIMESTAMP"
    run_as_owner "$owner_user" git -C "$repo_dir" branch "$backup_branch" >/dev/null 2>&1 || true
    log "Created backup branch $backup_branch at $current_head"
  fi

  if run_as_owner "$owner_user" git -C "$repo_dir" remote get-url upstream >/dev/null 2>&1; then
    run_as_owner "$owner_user" git -C "$repo_dir" remote set-url upstream "$UPSTREAM_URL"
  else
    run_as_owner "$owner_user" git -C "$repo_dir" remote add upstream "$UPSTREAM_URL"
  fi

  run_as_owner "$owner_user" git -C "$repo_dir" fetch --prune upstream
  run_as_owner "$owner_user" git -C "$repo_dir" checkout -B "restore/${CHANNEL}-stock" "$LOCAL_RESET_REF"
  run_as_owner "$owner_user" git -C "$repo_dir" reset --hard "$LOCAL_RESET_REF"
  run_as_owner "$owner_user" git -C "$repo_dir" clean -fd
}

full_wipe_runtime() {
  require_cmd docker

  log "FULL_WIPE=true, removing Coolify runtime state"

  docker stop -t 0 coolify coolify-realtime coolify-db coolify-redis coolify-proxy coolify-sentinel >/dev/null 2>&1 || true
  docker rm coolify coolify-realtime coolify-db coolify-redis coolify-proxy coolify-sentinel >/dev/null 2>&1 || true
  docker volume rm coolify-db coolify-redis >/dev/null 2>&1 || true
  docker network rm coolify >/dev/null 2>&1 || true
  rm -rf "$COOLIFY_DATA_DIR"
}

run_official_installer() {
  local latest_version="$1"
  local installer

  installer="$(mktemp "${TMPDIR:-/tmp}/coolify-install.XXXXXX.sh")"
  trap 'rm -f "$installer"' EXIT

  log "Downloading official installer from $INSTALL_URL"
  curl -fsSL "$INSTALL_URL" -o "$installer"
  chmod +x "$installer"

  log "Running official installer for $CHANNEL ($latest_version)"
  if [ -n "$INSTALLER_ARG" ]; then
    bash "$installer" "$INSTALLER_ARG"
  else
    bash "$installer"
  fi
}

main() {
  local owner_user owner_home repo_dir latest_version

  validate_boolean "$FULL_WIPE"
  validate_boolean "$RESET_LOCAL_REPO"
  validate_boolean "$DISABLE_CUSTOM_COMPOSE"

  require_cmd curl
  require_cmd git
  resolve_channel_settings

  if [ "$(id -u)" -ne 0 ]; then
    require_cmd sudo
    log "Re-running with sudo"
    exec sudo --preserve-env=FULL_WIPE,RESET_LOCAL_REPO,DISABLE_CUSTOM_COMPOSE,CHANNEL,BACKUP_ROOT,COOLIFY_DATA_DIR,COOLIFY_REPO_DIR,UPSTREAM_URL,LOCAL_RESET_REF bash "$0" "$@"
  fi

  owner_user="$(resolve_owner_user)"
  owner_home="$(resolve_owner_home "$owner_user")"
  latest_version="$(fetch_latest_version)"

  [ -n "$latest_version" ] || fail "Could not determine the latest official Coolify version"

  mkdir -p "$BACKUP_ROOT"
  log "Latest official Coolify $CHANNEL version: $latest_version"
  log "Backups: $BACKUP_ROOT"

  backup_file_if_present "$COOLIFY_SOURCE_DIR/.env" "coolify.env.before-reinstall"
  backup_file_if_present "$COOLIFY_CUSTOM_COMPOSE" "docker-compose.custom.yml.before-reinstall"

  if is_true "$DISABLE_CUSTOM_COMPOSE"; then
    disable_custom_compose_if_present
  fi

  if is_true "$RESET_LOCAL_REPO"; then
    if repo_dir="$(resolve_repo_dir "$owner_home")"; then
      reset_local_repo "$owner_user" "$repo_dir"
    else
      log "No local Coolify checkout found under $owner_home; skipping repo reset"
    fi
  fi

  if is_true "$FULL_WIPE"; then
    full_wipe_runtime
  fi

  run_official_installer "$latest_version"

  log "Restore finished."
  log "Installer logs should be under $COOLIFY_SOURCE_DIR"
}

main "$@"
