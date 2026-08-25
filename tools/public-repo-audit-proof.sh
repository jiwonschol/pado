#!/bin/bash
# Offline regression proof for public-repo-audit.sh.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
AUDIT="$SCRIPT_DIR/public-repo-audit.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pado-public-audit.XXXXXX") || exit 1
trap 'rm -rf -- "$ROOT"' EXIT

PASS=0
FAIL=0

ok() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

init_repo() {
  repo=$1
  git init -q "$repo"
  git -C "$repo" config user.name "pado-test"
  git -C "$repo" config user.email "pado-test@invalid"
  printf 'baseline\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm baseline
}

clone_fixture() {
  name=$1
  repo="$ROOT/$name"
  git clone -q "$BASE_REPO" "$repo"
  git -C "$repo" config user.name "pado-test"
  git -C "$repo" config user.email "pado-test@invalid"
  printf '%s\n' "$repo"
}

expect_pass() {
  label=$1
  repo=$2
  if bash "$AUDIT" "$repo" > "$ROOT/result.log" 2>&1; then
    ok "$label"
  else
    bad "$label"
  fi
}

expect_block() {
  label=$1
  repo=$2
  if bash "$AUDIT" "$repo" > "$ROOT/result.log" 2>&1; then
    bad "$label"
  else
    ok "$label"
  fi
}

TOKEN="ghp_$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)"

# A conventional root test suite is publishable source, not local scratch.
BASE_REPO="$ROOT/base"
init_repo "$BASE_REPO"
SAFE_REPO=$(clone_fixture safe)
mkdir -p "$SAFE_REPO/test"
printf '#!/bin/sh\nexit 0\n' > "$SAFE_REPO/test/future-test.sh"
LEGACY_SCANNER_LITERAL="(/""Users/[^/[:space:]]+|/""home/[^/[:space:]]+)"
printf '%s\n' "$LEGACY_SCANNER_LITERAL" > "$SAFE_REPO/test/scanner-pattern.txt"
git -C "$SAFE_REPO" add test/future-test.sh test/scanner-pattern.txt
git -C "$SAFE_REPO" commit -qm add-test
expect_pass "safe history, scanner literals, and conventional tests accepted" "$SAFE_REPO"

# Enumeration errors must fail closed instead of producing an empty scan set.
ENUM_BIN="$ROOT/enum-bin"
ENUM_MARKER="$ROOT/object-enumeration-failed"
REAL_GIT=$(command -v git)
mkdir -p "$ENUM_BIN"
cat > "$ENUM_BIN/git" <<'STUB'
#!/bin/bash
is_rev_list=0
is_objects=0
for arg in "$@"; do
  [ "$arg" != "rev-list" ] || is_rev_list=1
  [ "$arg" != "--objects" ] || is_objects=1
done
if [ "$is_rev_list" = 1 ] && [ "$is_objects" = 1 ]; then
  : > "$PADO_ENUM_MARKER"
  exit 9
fi
exec "$PADO_REAL_GIT" "$@"
STUB
chmod +x "$ENUM_BIN/git"
if PADO_REAL_GIT="$REAL_GIT" PADO_ENUM_MARKER="$ENUM_MARKER" \
    PATH="$ENUM_BIN:$PATH" bash "$AUDIT" "$BASE_REPO" \
      > "$ROOT/result.log" 2>&1; then
  bad "reachable-object enumeration error failed closed"
elif [ -e "$ENUM_MARKER" ]; then
  ok "reachable-object enumeration error failed closed"
else
  bad "reachable-object enumeration failure fixture did not execute"
fi

# GitHub's current PR merge commit may carry the intentionally public account
# email as author. Only the exact event SHA may receive that narrow allowance.
MERGE_REPO=$(clone_fixture pr-merge)
merge_base=$(git -C "$MERGE_REPO" rev-parse HEAD)
printf 'head content\n' > "$MERGE_REPO/head.txt"
git -C "$MERGE_REPO" add head.txt
git -C "$MERGE_REPO" commit -qm head
merge_head=$(git -C "$MERGE_REPO" rev-parse HEAD)
merge_tree=$(git -C "$MERGE_REPO" rev-parse HEAD^{tree})
PUBLIC_AUTHOR_EMAIL="synthetic-public@""example.test"
merge_sha=$(GIT_AUTHOR_NAME="public-account" \
  GIT_AUTHOR_EMAIL="$PUBLIC_AUTHOR_EMAIL" \
  GIT_COMMITTER_NAME="GitHub" \
  GIT_COMMITTER_EMAIL="noreply@github.com" \
  git -C "$MERGE_REPO" commit-tree "$merge_tree" \
    -p "$merge_head" -p "$merge_base" \
    -m "Merge $merge_head into $merge_base")
git -C "$MERGE_REPO" update-ref refs/pull/1/merge "$merge_sha"
expect_block "unapproved public commit email blocked" "$MERGE_REPO"
if PADO_GITHUB_PR_MERGE_SHA="$merge_sha" bash "$AUDIT" "$MERGE_REPO" \
    > "$ROOT/result.log" 2>&1; then
  ok "exact GitHub PR merge author email accepted"
else
  bad "exact GitHub PR merge author email was not narrowly accepted"
fi

# A leading-dash filename must never become a grep option.
OPTION_REPO=$(clone_fixture option-name)
OPTION_NAME='--exclude=*'
printf '%s\n' "$TOKEN" > "$OPTION_REPO/$OPTION_NAME"
git -C "$OPTION_REPO" add -- "$OPTION_NAME"
git -C "$OPTION_REPO" commit -qm option-name
expect_block "option-like filename credential blocked" "$OPTION_REPO"

# Scan the symlink target stored in Git, never the checkout target it names.
SYMLINK_REPO=$(clone_fixture symlink)
SYMLINK_TARGET="/$(printf '%s' Users)/synthetic-person/private"
ln -s "$SYMLINK_TARGET" "$SYMLINK_REPO/private-link"
git -C "$SYMLINK_REPO" add private-link
git -C "$SYMLINK_REPO" commit -qm symlink
expect_block "symlink blob local path blocked" "$SYMLINK_REPO"

# NUL bytes must not cause a credential-bearing blob to be skipped.
BINARY_REPO=$(clone_fixture binary)
printf '\0%s\n' "$TOKEN" > "$BINARY_REPO/data.bin"
git -C "$BINARY_REPO" add data.bin
git -C "$BINARY_REPO" commit -qm binary
expect_block "binary blob credential blocked" "$BINARY_REPO"

# Production safety scripts are content, not whole-file exemptions.
EXEMPT_REPO=$(clone_fixture formerly-exempt)
mkdir -p "$EXEMPT_REPO/tools/wip-mirror"
printf '#!/bin/sh\n%s\n' "$TOKEN" > "$EXEMPT_REPO/tools/public-repo-audit.sh"
printf '#!/bin/sh\n%s\n' "$TOKEN" > "$EXEMPT_REPO/tools/wip-mirror/wip-mirror.sh"
git -C "$EXEMPT_REPO" add tools
git -C "$EXEMPT_REPO" commit -qm safety-scripts
expect_block "formerly exempt safety-script credential blocked" "$EXEMPT_REPO"

# Deleting a blob does not remove it from reachable public history.
HISTORY_REPO=$(clone_fixture deleted-history)
printf '%s\n' "$TOKEN" > "$HISTORY_REPO/old-secret.txt"
git -C "$HISTORY_REPO" add old-secret.txt
git -C "$HISTORY_REPO" commit -qm add-old-secret
git -C "$HISTORY_REPO" rm -q old-secret.txt
git -C "$HISTORY_REPO" commit -qm delete-old-secret
expect_block "deleted reachable credential blob blocked" "$HISTORY_REPO"

# Historical sensitive filenames remain public even when their contents are benign.
PATH_HISTORY_REPO=$(clone_fixture deleted-path)
printf 'synthetic fixture\n' > "$PATH_HISTORY_REPO/.env"
git -C "$PATH_HISTORY_REPO" add -f .env
git -C "$PATH_HISTORY_REPO" commit -qm add-sensitive-path
git -C "$PATH_HISTORY_REPO" rm -q .env
git -C "$PATH_HISTORY_REPO" commit -qm delete-sensitive-path
expect_block "deleted reachable sensitive path blocked" "$PATH_HISTORY_REPO"

# A tag can make a tree public without making that tree part of any commit.
TREE_TAG_REPO=$(clone_fixture tree-tag)
tree_blob=$(printf 'synthetic fixture\n' | git -C "$TREE_TAG_REPO" hash-object -w --stdin)
tree_oid=$(printf '100644 blob %s\t.env\0' "$tree_blob" | git -C "$TREE_TAG_REPO" mktree -z)
git -C "$TREE_TAG_REPO" tag tree-only "$tree_oid"
expect_block "tree-only tag sensitive path blocked" "$TREE_TAG_REPO"

printf '\nRESULT: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
