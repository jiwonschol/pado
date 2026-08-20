#!/bin/bash
# Fail when tracked/public Git content contains local-only artifacts or identity leaks.
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

FAIL=0

fail_path() {
  printf 'PUBLIC-AUDIT FAIL: tracked local-only path: %q\n' "$1" >&2
  FAIL=1
}

while IFS= read -r -d '' path; do
  case "$path" in
    PLANS/*|RESEARCH/*|test/*|tools/wip-mirror/run/*|*.log|*.pem|*.key|*.p12|*.mobileprovision|*.xcresult|*/.DS_Store|.DS_Store|.env|.env.*|*/.env|*/.env.*)
      fail_path "$path"
      ;;
  esac
done < <(git ls-files -z)

while IFS= read -r -d '' path; do
  [ "$path" = "tools/public-repo-audit.sh" ] && continue
  if grep -I -qE '(/Users/[^/[:space:]]+|/home/[^/[:space:]]+|[A-Za-z]:\\Users\\[^\\[:space:]]+)' "$path" 2>/dev/null; then
    fail_path "$path"
  fi
done < <(git ls-files -z)

while IFS= read -r -d '' path; do
  case "$path" in
    tools/public-repo-audit.sh|tools/wip-mirror/wip-mirror.sh) continue ;;
  esac
  if grep -I -qE '(AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|AIza[A-Za-z0-9_-]{10,}|xox[baprs]-[A-Za-z0-9-]{10,}|BEGIN [A-Z ]*PRIVATE KEY)' "$path" 2>/dev/null; then
    fail_path "$path"
  fi
done < <(git ls-files -z)

while IFS= read -r -d '' path; do
  [ "$path" = "tools/public-repo-audit.sh" ] && continue
  emails=$(grep -I -Eo '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$path" 2>/dev/null || true)
  for email in $emails; do
    case "$email" in
      git@github.com|*@users.noreply.github.com|noreply@github.com|noreply@anthropic.com) ;;
      *) fail_path "$path" ;;
    esac
  done
done < <(git ls-files -z)

while IFS=$'\t' read -r commit email; do
  case "$email" in
    *@users.noreply.github.com|*@invalid|noreply@github.com|noreply@anthropic.com) ;;
    *)
      printf 'PUBLIC-AUDIT FAIL: commit %s uses a non-noreply author email\n' "${commit%${commit#????????????}}" >&2
      FAIL=1
      ;;
  esac
done < <(git log --format='%H%x09%ae')

while IFS=$'\t' read -r commit email; do
  case "$email" in
    *@users.noreply.github.com|*@invalid|noreply@github.com|noreply@anthropic.com) ;;
    *)
      printf 'PUBLIC-AUDIT FAIL: commit %s uses a non-noreply committer email\n' "${commit%${commit#????????????}}" >&2
      FAIL=1
      ;;
  esac
done < <(git log --format='%H%x09%ce')

for commit in $(git rev-list HEAD); do
  emails=$(git show -s --format='%B' "$commit" \
    | grep -Eo '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' || true)
  for email in $emails; do
    case "$email" in
      *@users.noreply.github.com|*@invalid|noreply@github.com|noreply@anthropic.com) ;;
      *)
        printf 'PUBLIC-AUDIT FAIL: commit %s message contains a non-noreply email\n' "${commit%${commit#????????????}}" >&2
        FAIL=1
        ;;
    esac
  done
done

if [ "$FAIL" = 0 ]; then
  printf 'PUBLIC-AUDIT PASS: tracked files and reachable commit metadata are public-safe\n'
fi

exit "$FAIL"
