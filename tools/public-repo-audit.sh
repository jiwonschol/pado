#!/bin/bash
# Fail when any reachable public Git object contains local-only artifacts or identity leaks.
set -u

if [ "$#" -gt 1 ]; then
  printf 'usage: %s [repository-directory]\n' "$0" >&2
  exit 2
fi

if [ "$#" -eq 1 ]; then
  START_DIR=$1
else
  SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
  START_DIR=$SCRIPT_DIR
fi

ROOT=$(git -C "$START_DIR" rev-parse --show-toplevel 2>/dev/null) || exit 1
cd "$ROOT" || exit 1

TMP_WORK=$(mktemp -d "${TMPDIR:-/tmp}/pado-public-audit.XXXXXX") || exit 1
trap 'rm -rf -- "$TMP_WORK"' EXIT

FAIL=0
PATH_FAILURE_REPORTED=0
TRUSTED_HISTORY_SHA=

if [ -n "${PADO_GITHUB_TRUSTED_HISTORY_SHA:-}" ]; then
  if ! TRUSTED_HISTORY_SHA=$(git rev-parse --verify \
      "${PADO_GITHUB_TRUSTED_HISTORY_SHA}^{commit}" 2>/dev/null); then
    printf 'PUBLIC-AUDIT FAIL: trusted history boundary is not a commit\n' >&2
    exit 1
  fi
else
  if DEFAULT_REMOTE_REF=$(git symbolic-ref --quiet \
      refs/remotes/origin/HEAD 2>/dev/null); then
    TRUSTED_HISTORY_SHA=$(git rev-parse --verify \
      "${DEFAULT_REMOTE_REF}^{commit}" 2>/dev/null) || TRUSTED_HISTORY_SHA=
  elif git rev-parse --verify refs/heads/main^{commit} >/dev/null 2>&1; then
    TRUSTED_HISTORY_SHA=$(git rev-parse --verify refs/heads/main^{commit}) \
      || TRUSTED_HISTORY_SHA=
  fi
fi

short_oid() {
  printf '%s\n' "${1%${1#????????????}}"
}

fail_object() {
  object_id=$1
  object_type=$2
  rule=$3
  printf 'PUBLIC-AUDIT FAIL: reachable %s %s violates %s (matched value omitted)\n' \
    "$object_type" "$(short_oid "$object_id")" "$rule" >&2
  FAIL=1
}

fail_scan() {
  object_id=$1
  object_type=$2
  printf 'PUBLIC-AUDIT FAIL: could not inspect reachable %s %s\n' \
    "$object_type" "$(short_oid "$object_id")" >&2
  FAIL=1
}

fail_path_once() {
  tree=$1
  if [ "$PATH_FAILURE_REPORTED" = 0 ]; then
    printf 'PUBLIC-AUDIT FAIL: reachable tree %s contains a local-only path (path omitted)\n' \
      "$(short_oid "$tree")" >&2
    PATH_FAILURE_REPORTED=1
  fi
  FAIL=1
}

is_current_github_pr_merge() {
  object_id=$1
  [ -n "${PADO_GITHUB_PR_MERGE_SHA:-}" ] || return 1
  [ "$object_id" = "$PADO_GITHUB_PR_MERGE_SHA" ] || return 1
  [ "$(git show -s --format='%ce' "$object_id" 2>/dev/null)" = "noreply@github.com" ] \
    || return 1
  subject=$(git show -s --format='%s' "$object_id" 2>/dev/null) || return 1
  printf '%s\n' "$subject" \
    | LC_ALL=C grep -qE '^Merge [0-9a-f]{40} into [0-9a-f]{40}$'
}

is_historical_github_pr_merge() {
  object_id=$1
  [ -n "$TRUSTED_HISTORY_SHA" ] || return 1
  git merge-base --is-ancestor "$object_id" "$TRUSTED_HISTORY_SHA" \
    >/dev/null 2>&1 || return 1
  [ "$(git show -s --format='%cn' "$object_id" 2>/dev/null)" = "GitHub" ] \
    || return 1
  [ "$(git show -s --format='%ce' "$object_id" 2>/dev/null)" = "noreply@github.com" ] \
    || return 1
  parents=$(git show -s --format='%P' "$object_id" 2>/dev/null) || return 1
  set -- $parents
  [ "$#" -eq 2 ] || return 1
  subject=$(git show -s --format='%s' "$object_id" 2>/dev/null) || return 1
  printf '%s\n' "$subject" \
    | LC_ALL=C grep -qE '^Merge pull request #[1-9][0-9]* from [^[:space:]]+/[^[:space:]]+$' \
    || return 1
  git cat-file commit "$object_id" 2>/dev/null \
    | LC_ALL=C grep -a -q '^gpgsig -----BEGIN PGP SIGNATURE-----$'
}

is_allowed_github_pr_merge_author() {
  object_id=$1
  is_current_github_pr_merge "$object_id" \
    || is_historical_github_pr_merge "$object_id"
}

# Split scanner literals so this script remains subject to its own rules.
MAC_HOME="/""Users/"
LINUX_HOME="/""home/"
WINDOWS_HOME='[A-Za-z]:\\'"Users"'\\'
PERSONAL_PATH_PATTERN="(${MAC_HOME}[^/[:space:][][^/[:space:]]*|${LINUX_HOME}[^/[:space:][][^/[:space:]]*|${WINDOWS_HOME}[^\\[:space:][][^\\[:space:]]*)"

AWS_PREFIX="AK""IA"
GH_PREFIX="gh""p_"
OPENAI_PREFIX="s""k-"
GOOGLE_PREFIX="AI""za"
SLACK_PREFIX="xo""x"
PRIVATE_KEY_WORDS="PRIVATE"" KEY"
CREDENTIAL_PATTERN="(${AWS_PREFIX}[0-9A-Z]{16}|${GH_PREFIX}[A-Za-z0-9]{20,}|${OPENAI_PREFIX}[A-Za-z0-9_-]{20,}|${GOOGLE_PREFIX}[A-Za-z0-9_-]{10,}|${SLACK_PREFIX}[baprs]-[A-Za-z0-9-]{10,}|BEGIN [A-Z ]*${PRIVATE_KEY_WORDS})"
EMAIL_PATTERN='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

OBJECTS="$TMP_WORK/objects"
OBJECTS_UNSORTED="$TMP_WORK/objects-unsorted"
if ! git rev-list --objects --all --no-object-names > "$OBJECTS_UNSORTED"; then
  printf 'PUBLIC-AUDIT FAIL: could not enumerate reachable objects\n' >&2
  exit 1
fi
if ! sort -u "$OBJECTS_UNSORTED" > "$OBJECTS"; then
  printf 'PUBLIC-AUDIT FAIL: could not prepare reachable object list\n' >&2
  exit 1
fi

# Object policy: inspect paths from every reachable tree, including tree-only
# tags, and raw bytes from blobs, commits, and annotated tags.
while IFS= read -r object_id; do
  [ -n "$object_id" ] || continue
  object_type=$(git cat-file -t "$object_id" 2>/dev/null) || {
    fail_scan "$object_id" "object"
    continue
  }
  case "$object_type" in
    tree)
      TREE_FILE="$TMP_WORK/tree"
      if ! git ls-tree -r -z --full-tree "$object_id" > "$TREE_FILE"; then
        fail_scan "$object_id" "$object_type"
        continue
      fi
      while IFS= read -r -d '' entry; do
        path=${entry#*$'\t'}
        case "$path" in
          PLANS/*|RESEARCH/*|.pado-local/*|tools/wip-mirror/run/*|*.log|*.pem|*.key|*.p12|*.mobileprovision|*.xcresult|*/.DS_Store|.DS_Store|.env|.env.*|*/.env|*/.env.*)
            fail_path_once "$object_id"
            ;;
        esac
      done < "$TREE_FILE"
      continue
      ;;
    blob|commit|tag) ;;
    *) continue ;;
  esac

  OBJECT_FILE="$TMP_WORK/object"
  if ! git cat-file "$object_type" "$object_id" > "$OBJECT_FILE"; then
    fail_scan "$object_id" "$object_type"
    continue
  fi

  LC_ALL=C grep -a -qE "$PERSONAL_PATH_PATTERN" "$OBJECT_FILE"
  grep_rc=$?
  case "$grep_rc" in
    0) fail_object "$object_id" "$object_type" "personal-path" ;;
    1) ;;
    *) fail_scan "$object_id" "$object_type" ;;
  esac

  LC_ALL=C grep -a -qE "$CREDENTIAL_PATTERN" "$OBJECT_FILE"
  grep_rc=$?
  case "$grep_rc" in
    0) fail_object "$object_id" "$object_type" "credential-pattern" ;;
    1) ;;
    *) fail_scan "$object_id" "$object_type" ;;
  esac

  EMAIL_FILE="$OBJECT_FILE"
  if [ "$object_type" = "commit" ] \
      && is_allowed_github_pr_merge_author "$object_id"; then
    EMAIL_FILE="$TMP_WORK/email-object"
    if ! LC_ALL=C sed 's/^author .*$/author GitHub PR merge <noreply@github.com>/' \
        "$OBJECT_FILE" > "$EMAIL_FILE"; then
      fail_scan "$object_id" "$object_type"
      continue
    fi
  fi

  emails=$(LC_ALL=C grep -a -Eo "$EMAIL_PATTERN" "$EMAIL_FILE" 2>/dev/null || true)
  for email in $emails; do
    case "$email" in
      git@github.com|*@users.noreply.github.com|noreply@github.com|noreply@anthropic.com) ;;
      *) fail_object "$object_id" "$object_type" "non-noreply-email" ;;
    esac
  done
done < "$OBJECTS"

if [ "$FAIL" = 0 ]; then
  printf 'PUBLIC-AUDIT PASS: all reachable Git paths, objects, and metadata are public-safe\n'
fi

exit "$FAIL"
