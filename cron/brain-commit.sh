#!/usr/bin/env bash
# Commits whatever the dream cycle changed in the brain repo.
# Runs unattended, so it must never block on a prompt.
set -euo pipefail

# Load shared paths. Anything already exported wins, so a one-off override
# still works: BRAIN_DIR=/tmp/x bash cron/brain-commit.sh
_PATHS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/paths.env"
# shellcheck source=/dev/null
[ -f "$_PATHS" ] && . "$_PATHS"

BRAIN="${BRAIN_DIR:-$HOME/brain}"
LOG="${BRAIN_LOGIC_DIR:-$HOME/brain-logic}/logs/brain-commit.log"
mkdir -p "$(dirname "$LOG")"

# A missing brain repo is the silent-failure case: nothing to commit, nothing
# to see, and you find out weeks later. Notify like the blocked-commit path
# below rather than only writing to a log nobody is reading at 3am.
if [ ! -d "$BRAIN/.git" ]; then
  echo "$(date -Iseconds) NO BRAIN REPO at $BRAIN" >> "$LOG"
  command -v osascript >/dev/null && osascript -e \
    'display notification "Brain repo missing — nightly commit did nothing" with title "Personal Brain"'
  exit 1
fi
cd "$BRAIN"
if [ -z "$(git status --porcelain)" ]; then
  echo "$(date -Iseconds) no changes" >> "$LOG"
  exit 0
fi

{
  echo "=== $(date -Iseconds) ==="
  git add -A
  # The pre-commit hook runs gitleaks and fails closed. If it blocks, we want
  # to know tonight, not on the day something leaks.
  if git commit -m "dream cycle $(date +%Y-%m-%d)"; then
    git remote | grep -q . && git push || echo "no remote configured — local only"
  else
    echo "COMMIT BLOCKED (likely gitleaks) — leaving working tree dirty"
    command -v osascript >/dev/null && osascript -e \
      'display notification "Brain commit blocked — check hooks.log" with title "Personal Brain"'
    exit 1
  fi
} >> "$LOG" 2>&1
