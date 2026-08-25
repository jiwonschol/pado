#!/bin/bash
# Offline proof harness. All repositories and synthetic fixtures stay under run/.
set -u

cd "$(dirname "$0")" || exit 1
ROOT="$PWD/run"
OUTSIDE_REMOTE="$PWD/run-outside.git"
MIRROR="$PWD/wip-mirror.sh"
PASS=0
FAIL=0

ok() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

rm -rf -- "$ROOT" "$OUTSIDE_REMOTE"
mkdir -p "$ROOT"
trap 'rm -rf -- "$OUTSIDE_REMOTE"' EXIT

export PADO_LOG="$ROOT/mirror.log"
: > "$PADO_LOG"

file_sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

file_mtime() {
  if stat -f %m "$1" >/dev/null 2>&1; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

file_mode() {
  if stat -f %Lp "$1" >/dev/null 2>&1; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

capture() {
  repo="$1"
  output="$2"
  {
    printf 'INDEX_SHA=%s\n' "$(file_sha "$repo/.git/index")"
    printf 'INDEX_MTIME=%s\n' "$(file_mtime "$repo/.git/index")"
    git --no-optional-locks -C "$repo" status --porcelain=v1
    printf 'HEAD=%s\n' "$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" stash list
  } > "$output"
}

snapshot_ref() {
  git -C "$1" for-each-ref --format='%(refname)' refs/pado-wip \
    | grep -v '^refs/pado-wip/_probe/' \
    | head -1
}

probe_ref_count() {
  git -C "$1" for-each-ref --format='%(refname)' refs/pado-wip/_probe \
    | wc -l \
    | tr -d ' '
}

init_committed_repo() {
  repo="$1"
  git init -q "$repo"
  git -C "$repo" config user.name "pado-test"
  git -C "$repo" config user.email "pado-test@invalid"
  printf 'baseline\n' > "$repo/tracked.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -qm baseline
}

# Primary repository: dirty + staged + untracked + ignored + stash.
SRC="$ROOT/src"
BARE="$ROOT/remote.git"
init_committed_repo "$SRC"
printf 'stable\n' > "$SRC/stable.txt"
printf 'node_modules/\nignored.log\n' > "$SRC/.gitignore"
git -C "$SRC" add stable.txt .gitignore
git -C "$SRC" commit -qm fixtures
printf 'stash me\n' >> "$SRC/stable.txt"
git -C "$SRC" stash -q
printf 'dirty\n' >> "$SRC/tracked.txt"
printf 'staged\n' > "$SRC/staged.txt"
git -C "$SRC" add staged.txt
printf 'agent output\n' > "$SRC/untracked.txt"
mkdir -p "$SRC/node_modules/pkg"
printf 'ignored\n' > "$SRC/node_modules/pkg/file.txt"
printf 'ignored\n' > "$SRC/ignored.log"
git init -q --bare "$BARE"
git -C "$SRC" remote add origin "$BARE"

git --no-optional-locks -C "$SRC" status --porcelain=v1 >/dev/null
capture "$SRC" "$ROOT/before.txt"

# 1. Unknown local destination fails closed without any remote write.
unset PADO_TEST_APPROVED_REMOTE 2>/dev/null || true
bash "$MIRROR" "$SRC" origin >/dev/null
rc=$?
ref_count=$(git -C "$BARE" for-each-ref | wc -l | tr -d ' ')
if [ "$rc" = 3 ] && [ "$ref_count" = 0 ]; then
  ok "unknown destination stopped with zero refs"
else
  bad "unknown destination was not fail-closed"
fi

# 2. Test bypass is limited to the bundled run/ directory.
git init -q --bare "$OUTSIDE_REMOTE"
OUTSIDE_SRC="$ROOT/outside-src"
init_committed_repo "$OUTSIDE_SRC"
git -C "$OUTSIDE_SRC" remote add origin "$OUTSIDE_REMOTE"
PADO_TEST_APPROVED_REMOTE=1 bash "$MIRROR" "$OUTSIDE_SRC" origin >/dev/null
rc=$?
outside_refs=$(git -C "$OUTSIDE_REMOTE" for-each-ref | wc -l | tr -d ' ')
if [ "$rc" = 3 ] && [ "$outside_refs" = 0 ]; then
  ok "test bypass rejected a destination outside the harness"
else
  bad "test bypass escaped the harness boundary"
fi

# 3. Successful mirror under the exact local harness boundary.
PADO_TEST_APPROVED_REMOTE=1 bash "$MIRROR" "$SRC" origin >/dev/null
rc=$?
WIP_REF=$(snapshot_ref "$BARE")
if [ "$rc" = 0 ] && [ -n "$WIP_REF" ]; then
  ok "approved harness destination mirrored"
else
  bad "approved harness mirror failed"
fi
MIRROR_SHA=$(git -C "$BARE" rev-parse "$WIP_REF" 2>/dev/null)

# 4. Probe is unique per invocation and removed before snapshot upload.
if [ "$(probe_ref_count "$BARE")" = 0 ]; then
  ok "write probe left no remote ref"
else
  bad "write probe ref remained"
fi

# 5. Snapshot is a root commit, so local HEAD/history was not transferred as a parent.
if ! git -C "$BARE" cat-file -p "$MIRROR_SHA" | grep -q '^parent '; then
  ok "snapshot is a root commit"
else
  bad "snapshot retained local history"
fi

# 6. Original branch, status, stash, and index remain identical.
capture "$SRC" "$ROOT/after.txt"
if diff -u "$ROOT/before.txt" "$ROOT/after.txt" > "$ROOT/invasive.diff"; then
  ok "working tree, HEAD, stash, and index stayed unchanged"
else
  bad "source Git state changed"
fi

# 7. Ignored files stay out while staged and untracked files are included.
TREE_FILES=$(git -C "$BARE" ls-tree -r --name-only "$MIRROR_SHA")
if ! printf '%s\n' "$TREE_FILES" | grep -qE 'node_modules|ignored\.log' \
    && printf '%s\n' "$TREE_FILES" | grep -q 'staged.txt' \
    && printf '%s\n' "$TREE_FILES" | grep -q 'untracked.txt'; then
  ok "gitignore respected and staged/untracked files included"
else
  bad "snapshot file selection was incorrect"
fi

# 8. Restore into an empty repository is byte-identical for mirrored contents.
RESTORE="$ROOT/restore"
git init -q "$RESTORE"
git -C "$RESTORE" fetch -q "$BARE" "$WIP_REF"
git -C "$RESTORE" -c advice.detachedHead=false checkout -qf FETCH_HEAD
if diff -r -x .git -x node_modules -x ignored.log "$SRC" "$RESTORE" > "$ROOT/restore.diff"; then
  ok "restore matched mirrored file contents"
else
  bad "restore content differed"
fi

# 9. Secret scanning reads exact tree blobs and handles unusual filenames.
SECRET_VALUE="s""k-proof-$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)"
WEIRD_FILE="$SRC/odd-$SECRET_VALUE
name-파일.py"
printf 'token = "%s"\n' "$SECRET_VALUE" > "$WEIRD_FILE"
capture "$SRC" "$ROOT/before-secret.txt"
PADO_TEST_APPROVED_REMOTE=1 bash "$MIRROR" "$SRC" origin >/dev/null
rc=$?
after_secret_sha=$(git -C "$BARE" rev-parse "$WIP_REF")
capture "$SRC" "$ROOT/after-secret.txt"
if [ "$rc" = 4 ] && [ "$after_secret_sha" = "$MIRROR_SHA" ]; then
  ok "unusual-filename secret blocked before remote write"
else
  bad "unusual-filename secret was not blocked"
fi
if ! grep -qF "$SECRET_VALUE" "$PADO_LOG" \
    && diff -q "$ROOT/before-secret.txt" "$ROOT/after-secret.txt" >/dev/null; then
  ok "blocked value stayed out of logs and source state stayed unchanged"
else
  bad "blocked path leaked or changed source state"
fi
rm -f -- "$WEIRD_FILE"

# 10. Invoking from a subdirectory still scans the repository top level.
mkdir -p "$SRC/nested/deeper"
printf 'secret = "%s"\n' "$SECRET_VALUE" > "$SRC/root-secret.py"
PADO_TEST_APPROVED_REMOTE=1 bash "$MIRROR" "$SRC/nested/deeper" origin >/dev/null
rc=$?
if [ "$rc" = 4 ] && [ "$(git -C "$BARE" rev-parse "$WIP_REF")" = "$MIRROR_SHA" ]; then
  ok "subdirectory invocation scanned the repository root"
else
  bad "subdirectory invocation skipped a root file"
fi
rm -f -- "$SRC/root-secret.py"

# 11. Benign task identifiers do not false-positive, and repeat mirrors work.
printf 'queue.enqueue("task-1234567890-abcdef")\n' > "$SRC/scheduler.txt"
PADO_TEST_APPROVED_REMOTE=1 bash "$MIRROR" "$SRC" origin >/dev/null
rc=$?
SECOND_SHA=$(git -C "$BARE" rev-parse "$WIP_REF")
if [ "$rc" = 0 ] && [ "$SECOND_SHA" != "$MIRROR_SHA" ] \
    && [ "$(probe_ref_count "$BARE")" = 0 ]; then
  ok "repeat mirror replaced the snapshot without a false positive"
else
  bad "repeat mirror or benign identifier handling failed"
fi
rm -f -- "$SRC/scheduler.txt"

# 12. A deleted secret in local commit history never reaches the remote.
HISTORY_SRC="$ROOT/history-src"
HISTORY_BARE="$ROOT/history-remote.git"
init_committed_repo "$HISTORY_SRC"
printf '%s\n' "$SECRET_VALUE" > "$HISTORY_SRC/old-secret.txt"
git -C "$HISTORY_SRC" add old-secret.txt
git -C "$HISTORY_SRC" commit -qm add-old-file
SECRET_HISTORY_COMMIT=$(git -C "$HISTORY_SRC" rev-parse HEAD)
git -C "$HISTORY_SRC" rm -q old-secret.txt
git -C "$HISTORY_SRC" commit -qm remove-old-file
git init -q --bare "$HISTORY_BARE"
git -C "$HISTORY_SRC" remote add origin "$HISTORY_BARE"
PADO_TEST_APPROVED_REMOTE=1 bash "$MIRROR" "$HISTORY_SRC" origin >/dev/null
rc=$?
if [ "$rc" = 0 ] \
    && ! git -C "$HISTORY_BARE" cat-file -e "$SECRET_HISTORY_COMMIT^{commit}" 2>/dev/null; then
  ok "local commit history was not transferred"
else
  bad "local commit history reached the destination"
fi

# 13. An unborn repository works without user identity configuration.
UNBORN_SRC="$ROOT/unborn-src"
UNBORN_BARE="$ROOT/unborn-remote.git"
git init -q "$UNBORN_SRC"
git -C "$UNBORN_SRC" config user.useConfigOnly true
printf 'first file\n' > "$UNBORN_SRC/first.txt"
git init -q --bare "$UNBORN_BARE"
git -C "$UNBORN_SRC" remote add origin "$UNBORN_BARE"
PADO_TEST_APPROVED_REMOTE=1 bash "$MIRROR" "$UNBORN_SRC" origin >/dev/null
rc=$?
UNBORN_REF=$(snapshot_ref "$UNBORN_BARE")
if [ "$rc" = 0 ] && [ -n "$UNBORN_REF" ]; then
  ok "unborn repository mirrored with synthetic identity"
else
  bad "unborn repository or synthetic identity failed"
fi

# GitHub API behavior is simulated by a local gh stub. No network is used.
mkdir -p "$ROOT/bin"
GH_STUB="$ROOT/bin/gh"
cat > "$GH_STUB" <<'STUB'
#!/bin/bash
host="${GH_HOST:-github.com}"
repo=""
selector=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    api) shift ;;
    --hostname) host="${2:-}"; shift 2 ;;
    --jq) selector="${2:-}"; shift 2 ;;
    repos/*) repo=$1; shift ;;
    *) shift ;;
  esac
done
case "$repo" in
  repos/example/public) visibility=public; writable=true ;;
  repos/example/private) visibility=private; writable=true ;;
  repos/example/readonly) visibility=private; writable=false ;;
  repos/example/host-confusion)
    if [ "$host" = "github.com" ]; then
      visibility=public
    else
      visibility=private
    fi
    writable=true
    ;;
  *) exit 1 ;;
esac
case "$selector" in
  .visibility) printf '%s\n' "$visibility" ;;
  .permissions.push) printf '%s\n' "$writable" ;;
  *visibility*permissions.push*) printf '%s\t%s\n' "$visibility" "$writable" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$GH_STUB"

GITHUB_SRC="$ROOT/github-src"
init_committed_repo "$GITHUB_SRC"
git -C "$GITHUB_SRC" remote add origin "https://github.com/example/public.git"

# 14. Confirmed-public effective push URL is refused.
PATH="$ROOT/bin:$PATH" bash "$MIRROR" "$GITHUB_SRC" origin >/dev/null
rc=$?
if [ "$rc" = 3 ]; then
  ok "confirmed-public GitHub destination refused"
else
  bad "public GitHub destination was not refused"
fi

# 15. Private but unapproved URL is refused.
git -C "$GITHUB_SRC" remote set-url origin "https://github.com/example/private.git"
PATH="$ROOT/bin:$PATH" bash "$MIRROR" "$GITHUB_SRC" origin >/dev/null
rc=$?
if [ "$rc" = 3 ]; then
  ok "private but unapproved GitHub destination refused"
else
  bad "unapproved private destination was accepted"
fi

# 16. Effective pushurl, not fetch URL, controls the safety decision.
git -C "$GITHUB_SRC" remote set-url origin "https://github.com/example/private.git"
git -C "$GITHUB_SRC" remote set-url --push origin "https://github.com/example/public.git"
git -C "$GITHUB_SRC" config --add pado.approvedRemote "https://github.com/example/private.git"
PATH="$ROOT/bin:$PATH" bash "$MIRROR" "$GITHUB_SRC" origin >/dev/null
rc=$?
if [ "$rc" = 3 ]; then
  ok "unsafe pushurl could not hide behind a private fetch URL"
else
  bad "fetch URL was validated instead of pushurl"
fi

# 17. Credential-bearing URL is rejected without writing the credential to logs.
CREDENTIAL="tok""en-proof-private"
GITHUB_HOST="github.com"
git -C "$GITHUB_SRC" remote set-url --delete --push origin "https://github.com/example/public.git" 2>/dev/null || true
git -C "$GITHUB_SRC" remote set-url --push origin "https://user:$CREDENTIAL@$GITHUB_HOST/example/private.git"
PATH="$ROOT/bin:$PATH" bash "$MIRROR" "$GITHUB_SRC" origin >/dev/null
rc=$?
if [ "$rc" = 3 ] && ! grep -qF "$CREDENTIAL" "$PADO_LOG"; then
  ok "URL credentials were rejected and redacted"
else
  bad "URL credential handling was unsafe"
fi

# 18. Probe cleanup failure stops before a snapshot is written.
CLEANUP_SRC="$ROOT/cleanup-src"
CLEANUP_BARE="$ROOT/cleanup-remote.git"
init_committed_repo "$CLEANUP_SRC"
git init -q --bare "$CLEANUP_BARE"
cat > "$CLEANUP_BARE/hooks/update" <<'HOOK'
#!/bin/sh
case "$1:$3" in
  refs/pado-wip/_probe/*:0000000000000000000000000000000000000000) exit 1 ;;
  *) exit 0 ;;
esac
HOOK
chmod +x "$CLEANUP_BARE/hooks/update"
git -C "$CLEANUP_SRC" remote add origin "$CLEANUP_BARE"
PADO_TEST_APPROVED_REMOTE=1 bash "$MIRROR" "$CLEANUP_SRC" origin >/dev/null
rc=$?
if [ "$rc" = 3 ] && [ -z "$(snapshot_ref "$CLEANUP_BARE")" ]; then
  ok "probe cleanup failure stopped before snapshot upload"
else
  bad "snapshot continued after probe cleanup failure"
fi

# 19. GH_HOST cannot redirect the safety lookup away from github.com.
HOST_SRC="$ROOT/host-src"
init_committed_repo "$HOST_SRC"
HOST_URL="https://github.com/example/host-confusion.git"
git -C "$HOST_SRC" remote add origin "$HOST_URL"
git -C "$HOST_SRC" config --add pado.approvedRemote "$HOST_URL"
HOST_BIN="$ROOT/host-bin"
HOST_PUSH_MARKER="$ROOT/host-push-attempted"
REAL_GIT=$(command -v git)
mkdir -p "$HOST_BIN"
cat > "$HOST_BIN/git" <<'STUB'
#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = "push" ]; then
    : > "$PADO_PUSH_MARKER"
    exit 0
  fi
done
exec "$PADO_REAL_GIT" "$@"
STUB
chmod +x "$HOST_BIN/git"
GH_HOST="enterprise.invalid" \
PADO_REAL_GIT="$REAL_GIT" \
PADO_PUSH_MARKER="$HOST_PUSH_MARKER" \
PATH="$HOST_BIN:$ROOT/bin:$PATH" \
  bash "$MIRROR" "$HOST_SRC" origin >/dev/null
rc=$?
if [ "$rc" = 3 ] && [ ! -e "$HOST_PUSH_MARKER" ]; then
  ok "GitHub safety lookup stayed pinned to github.com"
else
  bad "GH_HOST redirected or bypassed the GitHub safety lookup"
fi

# 20. Candidate-path enumeration errors stop before any remote write.
ENUM_BIN="$ROOT/enum-bin"
mkdir -p "$ENUM_BIN"
cat > "$ENUM_BIN/git" <<'STUB'
#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = "$PADO_FAIL_GIT_SUBCOMMAND" ]; then
    exit 9
  fi
done
exec "$PADO_REAL_GIT" "$@"
STUB
chmod +x "$ENUM_BIN/git"

FILES_SRC="$ROOT/files-enum-src"
FILES_BARE="$ROOT/files-enum-remote.git"
init_committed_repo "$FILES_SRC"
git init -q --bare "$FILES_BARE"
git -C "$FILES_SRC" remote add origin "$FILES_BARE"
PADO_FAIL_GIT_SUBCOMMAND="ls-files" \
PADO_REAL_GIT="$REAL_GIT" \
PATH="$ENUM_BIN:$PATH" \
PADO_TEST_APPROVED_REMOTE=1 \
  bash "$MIRROR" "$FILES_SRC" origin >/dev/null
rc=$?
files_enum_refs=$(git -C "$FILES_BARE" for-each-ref | wc -l | tr -d ' ')
if [ "$rc" = 1 ] && [ "$files_enum_refs" = 0 ]; then
  ok "candidate-path enumeration error stopped before remote writes"
else
  bad "candidate-path enumeration error failed open"
fi

# 21. Snapshot-tree enumeration errors stop before any remote write.
TREE_SRC="$ROOT/tree-enum-src"
TREE_BARE="$ROOT/tree-enum-remote.git"
init_committed_repo "$TREE_SRC"
git init -q --bare "$TREE_BARE"
git -C "$TREE_SRC" remote add origin "$TREE_BARE"
PADO_FAIL_GIT_SUBCOMMAND="ls-tree" \
PADO_REAL_GIT="$REAL_GIT" \
PATH="$ENUM_BIN:$PATH" \
PADO_TEST_APPROVED_REMOTE=1 \
  bash "$MIRROR" "$TREE_SRC" origin >/dev/null
rc=$?
tree_enum_refs=$(git -C "$TREE_BARE" for-each-ref | wc -l | tr -d ' ')
if [ "$rc" = 1 ] && [ "$tree_enum_refs" = 0 ]; then
  ok "snapshot-tree enumeration error stopped before remote writes"
else
  bad "snapshot-tree enumeration error failed open"
fi

# 22. External clean filters stop before the filter process or any push.
FILTER_SRC="$ROOT/filter-src"
FILTER_BARE="$ROOT/filter-remote.git"
FILTER_SCRIPT="$ROOT/filter-clean.sh"
FILTER_MARKER="$ROOT/filter-called"
init_committed_repo "$FILTER_SRC"
printf '*.filtered filter=fixture\n' > "$FILTER_SRC/.gitattributes"
git -C "$FILTER_SRC" add .gitattributes
git -C "$FILTER_SRC" commit -qm attributes
cat > "$FILTER_SCRIPT" <<'FILTER'
#!/bin/sh
: > "$PADO_FILTER_MARKER"
cat
FILTER
chmod +x "$FILTER_SCRIPT"
git -C "$FILTER_SRC" config filter.fixture.clean "$FILTER_SCRIPT"
printf 'ordinary content\n' > "$FILTER_SRC/payload.filtered"
git init -q --bare "$FILTER_BARE"
git -C "$FILTER_SRC" remote add origin "$FILTER_BARE"
PADO_FILTER_MARKER="$FILTER_MARKER" \
PADO_TEST_APPROVED_REMOTE=1 \
  bash "$MIRROR" "$FILTER_SRC" origin >/dev/null
rc=$?
filter_refs=$(git -C "$FILTER_BARE" for-each-ref | wc -l | tr -d ' ')
if [ "$rc" = 4 ] && [ "$filter_refs" = 0 ] && [ ! -e "$FILTER_MARKER" ]; then
  ok "external filter stopped before filter execution and remote writes"
else
  bad "external filter executed or reached the outbound snapshot"
fi

# 23. Canonical LFS pointers stop before any hook or remote write.
LFS_SRC="$ROOT/lfs-src"
LFS_BARE="$ROOT/lfs-remote.git"
LFS_HOOK_MARKER="$ROOT/lfs-hook-called"
init_committed_repo "$LFS_SRC"
printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize 42\n' \
  "$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64)" \
  > "$LFS_SRC/large.dat"
git -C "$LFS_SRC" add large.dat
git -C "$LFS_SRC" commit -qm lfs-pointer
git init -q --bare "$LFS_BARE"
git -C "$LFS_SRC" remote add origin "$LFS_BARE"
cat > "$LFS_SRC/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
: > "$PADO_HOOK_MARKER"
HOOK
chmod +x "$LFS_SRC/.git/hooks/pre-push"
PADO_HOOK_MARKER="$LFS_HOOK_MARKER" \
PADO_TEST_APPROVED_REMOTE=1 \
  bash "$MIRROR" "$LFS_SRC" origin >/dev/null
rc=$?
lfs_refs=$(git -C "$LFS_BARE" for-each-ref | wc -l | tr -d ' ')
if [ "$rc" = 4 ] && [ "$lfs_refs" = 0 ] && [ ! -e "$LFS_HOOK_MARKER" ]; then
  ok "LFS pointer stopped before hooks and remote writes"
else
  bad "LFS pointer or pre-push upload channel was accepted"
fi

# 24. A repository hook cannot change the destination between validation and use.
MUTATE_SRC="$ROOT/mutate-src"
MUTATE_SAFE="$ROOT/mutate-safe.git"
MUTATE_UNSAFE="$ROOT/mutate-unsafe.git"
MUTATE_COUNT="$ROOT/mutate-hook-count"
init_committed_repo "$MUTATE_SRC"
git init -q --bare "$MUTATE_SAFE"
git init -q --bare "$MUTATE_UNSAFE"
git -C "$MUTATE_SRC" remote add origin "$MUTATE_SAFE"
cat > "$MUTATE_SRC/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
count=0
[ ! -f "$PADO_HOOK_COUNT" ] || read -r count < "$PADO_HOOK_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$PADO_HOOK_COUNT"
if [ "$count" = 2 ]; then
  "$PADO_REAL_GIT" -C "$PADO_MUTATION_REPO" remote set-url origin "$PADO_UNSAFE_REMOTE"
fi
HOOK
chmod +x "$MUTATE_SRC/.git/hooks/pre-push"
PADO_HOOK_COUNT="$MUTATE_COUNT" \
PADO_REAL_GIT="$REAL_GIT" \
PADO_MUTATION_REPO="$MUTATE_SRC" \
PADO_UNSAFE_REMOTE="$MUTATE_UNSAFE" \
PADO_TEST_APPROVED_REMOTE=1 \
  bash "$MIRROR" "$MUTATE_SRC" origin >/dev/null
rc=$?
mutate_safe_ref=$(snapshot_ref "$MUTATE_SAFE")
mutate_unsafe_refs=$(git -C "$MUTATE_UNSAFE" for-each-ref | wc -l | tr -d ' ')
if [ "$rc" = 0 ] && [ -n "$mutate_safe_ref" ] \
    && [ "$mutate_unsafe_refs" = 0 ] && [ ! -e "$MUTATE_COUNT" ]; then
  ok "validated destination stayed bound through every push"
else
  bad "repository hook changed or observed the outbound push sequence"
fi

# 25. Every validated push URL receives the same synthetic snapshot.
MULTI_SRC="$ROOT/multi-src"
MULTI_ONE="$ROOT/multi-one.git"
MULTI_TWO="$ROOT/multi-two.git"
init_committed_repo "$MULTI_SRC"
git init -q --bare "$MULTI_ONE"
git init -q --bare "$MULTI_TWO"
git -C "$MULTI_SRC" remote add origin "$MULTI_ONE"
git -C "$MULTI_SRC" remote set-url --add --push origin "$MULTI_ONE"
git -C "$MULTI_SRC" remote set-url --add --push origin "$MULTI_TWO"
PADO_TEST_APPROVED_REMOTE=1 bash "$MIRROR" "$MULTI_SRC" origin >/dev/null
rc=$?
multi_one_ref=$(snapshot_ref "$MULTI_ONE")
multi_two_ref=$(snapshot_ref "$MULTI_TWO")
if [ "$rc" = 0 ] && [ -n "$multi_one_ref" ] && [ -n "$multi_two_ref" ]; then
  multi_one_sha=$(git -C "$MULTI_ONE" rev-parse "$multi_one_ref")
  multi_two_sha=$(git -C "$MULTI_TWO" rev-parse "$multi_two_ref")
  if [ "$multi_one_sha" = "$multi_two_sha" ]; then
    ok "all validated push URLs received the same snapshot"
  else
    bad "validated push URLs received different snapshots"
  fi
else
  bad "multiple validated push URLs were not preserved"
fi

# 26. Log is private even when the caller supplies its path.
if [ "$(file_mode "$PADO_LOG")" = 600 ]; then
  ok "log permissions are owner-only"
else
  bad "log permissions are not owner-only"
fi

printf '\nRESULT: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
