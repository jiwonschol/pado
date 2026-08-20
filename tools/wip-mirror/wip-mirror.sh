#!/bin/bash
# pado wip-mirror — copy a repository snapshot to an explicitly approved private remote.
#
# Usage: wip-mirror.sh <repo-path> [remote-name]   (defaults to "origin")
#
# Exit codes: 0 mirrored / 3 precondition stop / 4 secret gate / 1 other error
set -u

umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
REPO_INPUT="${1:?repo path}"
REMOTE="${2:-origin}"

if [ -n "${PADO_LOG:-}" ]; then
  LOG="$PADO_LOG"
  if [ -L "$LOG" ]; then
    printf '%s\n' "pado-wip: refusing symlink log path" >&2
    exit 1
  fi
  : >> "$LOG" || exit 1
  chmod 600 "$LOG" || exit 1
else
  LOG=$(mktemp "${TMPDIR:-/tmp}/pado-wip-mirror.XXXXXX") || exit 1
fi

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG"; }
stop() { log "PRECONDITION FAIL-CLOSED: $1"; exit 3; }

REPO=$(git -C "$REPO_INPUT" rev-parse --show-toplevel 2>/dev/null) || {
  log "ERROR: repository not found"
  exit 1
}

# A remote may have multiple push URLs, and Git writes to every configured
# pushurl. Validate the effective push destinations, never only the fetch URL.
PUSH_URLS=()
while IFS= read -r url; do
  [ -n "$url" ] && PUSH_URLS+=("$url")
done < <(git -C "$REPO" remote get-url --push --all "$REMOTE" 2>/dev/null)

[ "${#PUSH_URLS[@]}" -gt 0 ] || {
  log "ERROR: remote '$REMOTE' not found or has no push URL"
  exit 1
}

contains_control_char() {
  case "$1" in
    *$'\n'*|*$'\r'*) return 0 ;;
    *) return 1 ;;
  esac
}

contains_http_userinfo() {
  case "$1" in
    http://*|https://*)
      authority=${1#*://}
      authority=${authority%%/*}
      case "$authority" in *@*) return 0 ;; esac
      ;;
  esac
  return 1
}

github_owner_repo() {
  candidate="$1"
  case "$candidate" in
    https://github.com/*) candidate=${candidate#https://github.com/} ;;
    git@github.com:*) candidate=${candidate#git@github.com:} ;;
    ssh://git@github.com/*) candidate=${candidate#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  candidate=${candidate%.git}
  case "$candidate" in
    */*/*|/*|*/|*\?*|*\#*|*..*) return 1 ;;
  esac
  [ -n "${candidate%%/*}" ] && [ -n "${candidate#*/}" ] || return 1
  printf '%s\n' "$candidate"
}

canonical_directory() {
  [ -d "$1" ] || return 1
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

is_harness_remote() {
  [ "${PADO_TEST_APPROVED_REMOTE:-0}" = "1" ] || return 1
  case "$1" in /*) ;; *) return 1 ;; esac

  run_root=$(canonical_directory "$SCRIPT_DIR/run") || return 1
  remote_path=$(canonical_directory "$1") || return 1
  case "$remote_path" in
    "$run_root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_explicitly_approved() {
  git -C "$REPO" config --get-all pado.approvedRemote 2>/dev/null \
    | grep -qxF -- "$1"
}

for push_url in "${PUSH_URLS[@]}"; do
  contains_control_char "$push_url" \
    && stop "push URL contains unsupported control characters; no snapshot push"
  contains_http_userinfo "$push_url" \
    && stop "credential-bearing HTTP push URLs are unsupported; no snapshot push"

  if is_harness_remote "$push_url"; then
    log "PRECONDITION: approved local proof-harness destination"
    continue
  fi

  owner_repo=$(github_owner_repo "$push_url") \
    || stop "effective push destination is not a supported GitHub URL; no snapshot push"
  command -v gh >/dev/null 2>&1 \
    || stop "GitHub CLI unavailable; destination safety is undetermined; no snapshot push"

  visibility=$(gh api "repos/$owner_repo" --jq '.visibility' 2>/dev/null) \
    || stop "GitHub visibility lookup failed; no snapshot push"
  can_push=$(gh api "repos/$owner_repo" --jq '.permissions.push' 2>/dev/null) \
    || stop "GitHub push-permission lookup failed; no snapshot push"

  [ "$visibility" = "private" ] \
    || stop "effective GitHub push destination is not confirmed private; no snapshot push"
  [ "$can_push" = "true" ] \
    || stop "effective GitHub push destination is not confirmed writable; no snapshot push"
  is_explicitly_approved "$push_url" \
    || stop "effective push URL is not explicitly approved in pado.approvedRemote; no snapshot push"

  log "PRECONDITION: effective GitHub push destination is private, writable, and approved"
done

# Build the exact tree first. The secret gate scans these immutable blobs, so a
# concurrent edit can only wait for the next mirror; it cannot enter unscanned.
TMP_WORK=$(mktemp -d "${TMPDIR:-/tmp}/pado-wip.XXXXXX") || exit 1
TMP_INDEX="$TMP_WORK/index"
trap 'rm -rf -- "$TMP_WORK"' EXIT

if HEAD_SHA=$(git -C "$REPO" rev-parse --verify HEAD 2>/dev/null); then
  GIT_INDEX_FILE="$TMP_INDEX" git -C "$REPO" read-tree "$HEAD_SHA" || exit 1
else
  HEAD_SHA="unborn"
  GIT_INDEX_FILE="$TMP_INDEX" git -C "$REPO" read-tree --empty || exit 1
fi

GIT_INDEX_FILE="$TMP_INDEX" git -C "$REPO" add -A || exit 1
TREE=$(GIT_INDEX_FILE="$TMP_INDEX" git -C "$REPO" write-tree) || exit 1

BLOCKED_FILE=""
BLOCKED_REASON=""
SECRET_PATTERN="(^|[^A-Za-z0-9_])(sk-[A-Za-z0-9_-]{8,}|ghp_[A-Za-z0-9]{20,}|AIza[A-Za-z0-9_-]{10,}|xox[baprs]-)|PRIVATE KEY|(api[_-]?key|secret|token|password)[[:space:]]*[:=][[:space:]]*['\"]?[^[:space:]'\"]{12,}"
while IFS= read -r -d '' entry; do
  metadata=${entry%%$'\t'*}
  path=${entry#*$'\t'}
  set -- $metadata
  object_type=$2
  object_id=$3
  [ "$object_type" = "blob" ] || continue

  case "$path" in
    .env|.env.*|*/.env|*/.env.*|*.pem|*.key|*/id_rsa|*/id_ed25519)
      BLOCKED_FILE="$path"
      BLOCKED_REASON="sensitive-filename"
      break
      ;;
  esac

  if git -C "$REPO" cat-file blob "$object_id" \
      | grep -qE "$SECRET_PATTERN"; then
    BLOCKED_FILE="$path"
    BLOCKED_REASON="content-pattern"
    break
  fi
done < <(git -C "$REPO" ls-tree -r -z "$TREE")

if [ -n "$BLOCKED_FILE" ]; then
  printf -v blocked_file_safe '%q' "$BLOCKED_FILE"
  log "SECRET GATE: snapshot blocked; file=$blocked_file_safe reason=$BLOCKED_REASON (value not recorded)"
  exit 4
fi

synthetic_commit() {
  commit_tree="$1"
  commit_message="$2"
  GIT_AUTHOR_NAME="Pado WIP Mirror" \
  GIT_AUTHOR_EMAIL="pado-wip@invalid" \
  GIT_COMMITTER_NAME="Pado WIP Mirror" \
  GIT_COMMITTER_EMAIL="pado-wip@invalid" \
    git -C "$REPO" commit-tree "$commit_tree" -m "$commit_message"
}

# Probe with a harmless root commit. Never upload local HEAD or its history.
EMPTY_TREE=$(git -C "$REPO" mktree </dev/null) || exit 1
PROBE_COMMIT=$(synthetic_commit "$EMPTY_TREE" "pado-wip write probe") || exit 1
HOST=$(hostname -s 2>/dev/null || printf 'host')
HOST=$(printf '%s' "$HOST" | tr -c 'A-Za-z0-9._-' '-')
[ -n "$HOST" ] || HOST="host"
PROBE="refs/pado-wip/_probe/$HOST/$$-$(date +%s)-${RANDOM:-0}"

if ! git -C "$REPO" push -q "$REMOTE" "$PROBE_COMMIT:$PROBE" 2>/dev/null; then
  stop "custom-ref write probe failed; no snapshot push"
fi
if ! git -C "$REPO" push -q "$REMOTE" ":$PROBE" 2>/dev/null; then
  log "PRECONDITION FAIL-CLOSED: probe cleanup failed; snapshot was not pushed"
  exit 3
fi
log "PRECONDITION: unique write probe succeeded and was removed"

if branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null); then
  :
elif [ "$HEAD_SHA" = "unborn" ]; then
  branch="unborn"
else
  branch="detached-${HEAD_SHA%${HEAD_SHA#????????????}}"
fi
WIP_REF="refs/pado-wip/$HOST/$branch"
git check-ref-format "$WIP_REF" >/dev/null 2>&1 \
  || stop "derived mirror ref is invalid; snapshot was not pushed"

SNAPSHOT_COMMIT=$(synthetic_commit "$TREE" "pado-wip snapshot") || exit 1
if ! git -C "$REPO" push -q -f "$REMOTE" "$SNAPSHOT_COMMIT:$WIP_REF" 2>/dev/null; then
  log "ERROR: snapshot push failed"
  exit 1
fi

log "MIRROR OK: snapshot ref updated"
printf '%s\n' "$SNAPSHOT_COMMIT"
exit 0
