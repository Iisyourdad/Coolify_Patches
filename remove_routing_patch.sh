#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep git output non-interactive so the script never drops into a pager.
export GIT_PAGER="${GIT_PAGER:-cat}"

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/coollabsio/coolify.git}"
BASE_REF="${BASE_REF:-upstream/next}"

CONTAINER="${CONTAINER:-coolify}"
DEST_DIR="${DEST_DIR:-/var/www/html}"
PATCHES_FILE="${PATCHES_FILE:-$SCRIPT_DIR/patches.txt}"
REMOVE_PATCHES_FILE="${REMOVE_PATCHES_FILE:-$SCRIPT_DIR/remove_patch.txt}"
RESTART_CONTAINER="${RESTART_CONTAINER:-true}"
CLEAR_CACHE="${CLEAR_CACHE:-true}"
RUN_MIGRATIONS="${RUN_MIGRATIONS:-auto}"
POST_APPLY_COMMAND="${POST_APPLY_COMMAND:-}"
DRY_RUN="${DRY_RUN:-false}"
KEEP_WORKDIR="${KEEP_WORKDIR:-false}"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/remove-routing-patch.XXXXXX")"
BEFORE_REPO="$WORKDIR/repo-before"
AFTER_REPO="$WORKDIR/repo-after"
BEFORE_BRANCH="removed-routing-patches-before"
AFTER_BRANCH="removed-routing-patches-after"

declare -a PATCH_SOURCES=()
declare -a REMOVE_SOURCES=()
declare -a REMAINING_PATCH_SOURCES=()
declare -a COPY_PATHS=()
declare -a DELETE_PATHS=()
declare -A PATCH_SET=()
declare -A REMOVE_SET=()

cleanup() {
  local exit_code=$?

  if [ "$KEEP_WORKDIR" = "true" ] || [ "$exit_code" -ne 0 ]; then
    echo "==> Preserving workspace: $WORKDIR"
    return
  fi

  rm -rf "$WORKDIR"
}
trap cleanup EXIT

require_cmd() {
  local cmd="$1"

  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing required command: $cmd"
    exit 1
  }
}

validate_boolean() {
  case "${1,,}" in
    true|1|yes|y|false|0|no|n) return 0 ;;
    *)
      echo "Expected a boolean value, got: $1"
      exit 1
      ;;
  esac
}

is_true() {
  validate_boolean "$1"

  case "${1,,}" in
    true|1|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_mode() {
  case "${1,,}" in
    true|false|auto) printf '%s\n' "${1,,}" ;;
    *)
      echo "Expected true, false, or auto, got: $1"
      exit 1
      ;;
  esac
}

sanitize_name() {
  printf '%s\n' "$1" | sed 's#[^A-Za-z0-9._-]#_#g'
}

trim_line() {
  printf '%s\n' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

print_paths() {
  local header="$1"
  shift || true

  [ "$#" -gt 0 ] || return 0

  echo "$header"
  printf '%s\n' "$@" | LC_ALL=C sort
  echo
}

run_in_container() {
  local command_text="$1"

  echo "==> Running in container: $command_text"
  docker exec -e DEST_DIR="$DEST_DIR" "$CONTAINER" sh -lc "cd \"\$DEST_DIR\" && $command_text"
  echo
}

path_list_has_prefix() {
  local prefix="$1"
  local path

  for path in "${COPY_PATHS[@]}" "${DELETE_PATHS[@]}"; do
    [[ "$path" == "$prefix"* ]] && return 0
  done

  return 1
}

prepare_repo() {
  local repo_dir="$1"
  local work_branch="$2"

  echo "==> Preparing workspace: $repo_dir"
  git clone --quiet --origin upstream "$UPSTREAM_URL" "$repo_dir"
  git -C "$repo_dir" fetch --prune upstream
  git -C "$repo_dir" config user.name "Routing Patch Helper"
  git -C "$repo_dir" config user.email "routing-patch-helper@local"
  git -C "$repo_dir" checkout --quiet -B "$work_branch" "$BASE_REF"
  echo
}

ensure_remote() {
  local repo_dir="$1"
  local remote_name="$2"
  local remote_url="$3"

  if git -C "$repo_dir" remote get-url "$remote_name" >/dev/null 2>&1; then
    git -C "$repo_dir" remote set-url "$remote_name" "$remote_url"
  else
    git -C "$repo_dir" remote add "$remote_name" "$remote_url"
  fi
}

apply_remote_ref() {
  local repo_dir="$1"
  local remote_ref="$2"
  local label="$3"
  local safe_label="$4"
  local patch_file="$WORKDIR/$safe_label.patch"

  echo "==> Finding changed files for $label"
  if git -C "$repo_dir" diff --quiet "$BASE_REF...$remote_ref"; then
    echo "==> No changed files found for $label, skipping"
    echo
    return 0
  fi

  git -C "$repo_dir" diff --name-status --find-renames "$BASE_REF...$remote_ref"
  echo

  echo "==> Applying $label into workspace"
  git -C "$repo_dir" diff --binary --find-renames --full-index "$BASE_REF...$remote_ref" > "$patch_file"

  if ! git -C "$repo_dir" apply --3way --index "$patch_file"; then
    echo "Failed to apply $label cleanly."
    echo "Workspace preserved at: $WORKDIR"
    exit 1
  fi

  if git -C "$repo_dir" diff --cached --quiet; then
    echo "==> $label did not introduce any new changes after previous patches"
    echo
    return 0
  fi

  git -C "$repo_dir" commit --quiet -m "Apply $label"
  echo "==> Finished: $label"
  echo
}

apply_branch_url() {
  local repo_dir="$1"
  local owner="$2"
  local repo="$3"
  local branch="$4"

  local fork_url="https://github.com/${owner}/${repo}.git"
  local remote_name
  local safe_branch
  local remote_ref

  remote_name="source_$(sanitize_name "${owner}_${repo}")"
  safe_branch="$(sanitize_name "$branch")"
  remote_ref="refs/patches/$remote_name/branch-$safe_branch"

  echo "=================================================="
  echo "==> Applying branch URL"
  echo "==> Repo:   $fork_url"
  echo "==> Branch: $branch"
  echo "=================================================="

  ensure_remote "$repo_dir" "$remote_name" "$fork_url"
  git -C "$repo_dir" fetch --quiet "$remote_name" "refs/heads/$branch:$remote_ref"
  apply_remote_ref "$repo_dir" "$remote_ref" "branch-$branch" "branch-$safe_branch"
}

apply_pr_url() {
  local repo_dir="$1"
  local owner="$2"
  local repo="$3"
  local pr_number="$4"

  local fork_url="https://github.com/${owner}/${repo}.git"
  local remote_name
  local remote_ref

  remote_name="source_$(sanitize_name "${owner}_${repo}")"
  remote_ref="refs/patches/$remote_name/pr-$pr_number"

  echo "=================================================="
  echo "==> Applying PR URL"
  echo "==> Repo: $fork_url"
  echo "==> PR:   #$pr_number"
  echo "=================================================="

  ensure_remote "$repo_dir" "$remote_name" "$fork_url"
  git -C "$repo_dir" fetch --quiet "$remote_name" "pull/${pr_number}/head:$remote_ref"
  apply_remote_ref "$repo_dir" "$remote_ref" "pr-$pr_number" "pr-$pr_number"
}

read_patch_list() {
  local file="$1"
  local -n out_array="$2"
  local -n out_set="$3"
  local line

  echo "==> Reading patch list from $file"
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(trim_line "$line")"
    line="${line%/}"

    [ -z "$line" ] && continue
    [[ "$line" =~ ^# ]] && continue

    out_array+=("$line")
    out_set["$line"]=1
  done < "$file"

  if [ "${#out_array[@]}" -eq 0 ]; then
    echo "No patch entries found in $file"
    exit 1
  fi

  echo
}

filter_remaining_patches() {
  local entry

  REMAINING_PATCH_SOURCES=()
  for entry in "${PATCH_SOURCES[@]}"; do
    if [ -z "${REMOVE_SET[$entry]+x}" ]; then
      REMAINING_PATCH_SOURCES+=("$entry")
    fi
  done
}

validate_remove_list() {
  local entry
  local missing_entries=()

  for entry in "${REMOVE_SOURCES[@]}"; do
    if [ -z "${PATCH_SET[$entry]+x}" ]; then
      missing_entries+=("$entry")
    fi
  done

  if [ "${#missing_entries[@]}" -gt 0 ]; then
    echo "These remove entries were not found in $PATCHES_FILE:"
    printf '%s\n' "${missing_entries[@]}"
    exit 1
  fi
}

apply_patch_sources() {
  local repo_dir="$1"
  local -n sources="$2"
  local entry

  for entry in "${sources[@]}"; do
    if [[ "$entry" =~ ^https://github\.com/([^/]+)/([^/]+)/tree/(.+)$ ]]; then
      apply_branch_url "$repo_dir" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
      continue
    fi

    if [[ "$entry" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$ ]]; then
      apply_pr_url "$repo_dir" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
      continue
    fi

    echo "Invalid entry in patch list:"
    echo "  $entry"
    echo
    echo "Supported formats:"
    echo "  https://github.com/<owner>/<repo>/tree/<branch>"
    echo "  https://github.com/<owner>/<repo>/pull/<number>"
    exit 1
  done
}

build_sync_manifest() {
  local repo_dir="$1"
  local before_commit="$2"
  local after_commit="$3"
  local status
  local path_a
  local path_b
  declare -A copy_map=()
  declare -A delete_map=()

  while IFS= read -r -d '' status; do
    case "$status" in
      D*)
        IFS= read -r -d '' path_a
        delete_map["$path_a"]=1
        ;;
      R*)
        IFS= read -r -d '' path_a
        IFS= read -r -d '' path_b
        delete_map["$path_a"]=1
        copy_map["$path_b"]=1
        ;;
      C*)
        IFS= read -r -d '' path_a
        IFS= read -r -d '' path_b
        copy_map["$path_b"]=1
        ;;
      *)
        IFS= read -r -d '' path_a
        copy_map["$path_a"]=1
        ;;
    esac
  done < <(git -C "$repo_dir" diff --name-status -z --find-renames "$before_commit" "$after_commit")

  COPY_PATHS=("${!copy_map[@]}")
  DELETE_PATHS=("${!delete_map[@]}")
}

sync_into_container() {
  local source_repo="$1"
  local copy_list="$WORKDIR/copy-paths.txt"
  local rel_path

  echo "==> Preparing changed files"
  print_paths "==> Files to copy" "${COPY_PATHS[@]}"
  print_paths "==> Files to delete" "${DELETE_PATHS[@]}"

  if is_true "$DRY_RUN"; then
    echo "==> Dry run enabled, skipping container sync"
    echo
    return 0
  fi

  echo "==> Applying files into container"
  docker exec "$CONTAINER" mkdir -p "$DEST_DIR"

  for rel_path in "${DELETE_PATHS[@]}"; do
    echo "==> Removing $rel_path"
    docker exec "$CONTAINER" rm -rf -- "$DEST_DIR/$rel_path"
  done

  if [ "${#COPY_PATHS[@]}" -gt 0 ]; then
    printf '%s\0' "${COPY_PATHS[@]}" > "$copy_list"
    tar -C "$source_repo" --null -T "$copy_list" -cf - \
      | docker exec -i "$CONTAINER" tar -C "$DEST_DIR" -xf -
  fi

  echo
}

run_post_apply_steps() {
  local migrations_mode

  if is_true "$DRY_RUN"; then
    echo "==> Dry run enabled, skipping post-apply steps"
    echo
    return 0
  fi

  migrations_mode="$(normalize_mode "$RUN_MIGRATIONS")"

  if is_true "$CLEAR_CACHE"; then
    run_in_container "php artisan optimize:clear"
  fi

  if [ "$migrations_mode" = "true" ] || { [ "$migrations_mode" = "auto" ] && path_list_has_prefix "database/migrations/"; }; then
    run_in_container "php artisan migrate --force"
  fi

  if [ -n "$POST_APPLY_COMMAND" ]; then
    run_in_container "$POST_APPLY_COMMAND"
  fi
}

restart_container_if_needed() {
  if is_true "$DRY_RUN"; then
    echo "==> Dry run enabled, skipping container restart"
    echo
    return 0
  fi

  if is_true "$RESTART_CONTAINER"; then
    echo "==> Restarting container: $CONTAINER"
    docker restart "$CONTAINER"
    echo
  fi
}

require_cmd bash
require_cmd git
require_cmd tar
require_cmd sed

if ! is_true "$DRY_RUN"; then
  require_cmd docker
fi

validate_boolean "$RESTART_CONTAINER"
validate_boolean "$CLEAR_CACHE"
validate_boolean "$DRY_RUN"
validate_boolean "$KEEP_WORKDIR"
normalize_mode "$RUN_MIGRATIONS" >/dev/null

echo "==> Using temporary workspace: $WORKDIR"
echo "==> Upstream:              $UPSTREAM_URL"
echo "==> Base ref:              $BASE_REF"
echo "==> Container:             $CONTAINER"
echo "==> Dest dir:              $DEST_DIR"
echo "==> Patches file:          $PATCHES_FILE"
echo "==> Remove patches file:   $REMOVE_PATCHES_FILE"
echo "==> Restart container:     $RESTART_CONTAINER"
echo "==> Clear cache:           $CLEAR_CACHE"
echo "==> Run migrations:        $RUN_MIGRATIONS"
echo "==> Dry run:               $DRY_RUN"
echo "==> Keep workspace:        $KEEP_WORKDIR"
echo

[ -f "$PATCHES_FILE" ] || {
  echo "Patches file not found: $PATCHES_FILE"
  exit 1
}

[ -f "$REMOVE_PATCHES_FILE" ] || {
  echo "Remove patches file not found: $REMOVE_PATCHES_FILE"
  exit 1
}

if ! is_true "$DRY_RUN"; then
  docker inspect "$CONTAINER" >/dev/null 2>&1 || {
    echo "Container not found: $CONTAINER"
    exit 1
  }
fi

read_patch_list "$PATCHES_FILE" PATCH_SOURCES PATCH_SET
read_patch_list "$REMOVE_PATCHES_FILE" REMOVE_SOURCES REMOVE_SET
validate_remove_list
filter_remaining_patches

echo "==> Full patch entries:      ${#PATCH_SOURCES[@]}"
echo "==> Removal entries:         ${#REMOVE_SOURCES[@]}"
echo "==> Remaining patch entries: ${#REMAINING_PATCH_SOURCES[@]}"
echo

prepare_repo "$BEFORE_REPO" "$BEFORE_BRANCH"
apply_patch_sources "$BEFORE_REPO" PATCH_SOURCES
BEFORE_HEAD="$(git -C "$BEFORE_REPO" rev-parse HEAD)"

prepare_repo "$AFTER_REPO" "$AFTER_BRANCH"
PATCH_SOURCES=("${REMAINING_PATCH_SOURCES[@]}")
apply_patch_sources "$AFTER_REPO" PATCH_SOURCES

git -C "$BEFORE_REPO" fetch --quiet "$AFTER_REPO" "refs/heads/$AFTER_BRANCH:refs/patches/remove-target"
AFTER_FETCHED_HEAD="$(git -C "$BEFORE_REPO" rev-parse FETCH_HEAD)"

build_sync_manifest "$BEFORE_REPO" "$BEFORE_HEAD" "$AFTER_FETCHED_HEAD"

if [ "${#COPY_PATHS[@]}" -eq 0 ] && [ "${#DELETE_PATHS[@]}" -eq 0 ]; then
  echo "==> No cumulative changes to apply"
  exit 0
fi

sync_into_container "$AFTER_REPO"
run_post_apply_steps
restart_container_if_needed

echo "==> Done"
echo "Selected patches from $REMOVE_PATCHES_FILE were removed."
