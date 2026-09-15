#!/usr/bin/env bash
# Encrypted offsite backup. restic encrypts client-side, so the storage
# provider holds ciphertext it cannot read.
#
# Repo password comes from the Keychain, never from a file in a repo:
#   security add-generic-password -a "$USER" -s brain/restic-password -w
set -euo pipefail

# Load shared paths. Anything already exported wins, so a one-off override
# still works: BRAIN_DIR=/tmp/x bash cron/brain-commit.sh
_PATHS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/paths.env"
# shellcheck source=/dev/null
[ -f "$_PATHS" ] && . "$_PATHS"

LOG="${BRAIN_LOGIC_DIR:-$HOME/brain-logic}/logs/restic.log"
mkdir -p "$(dirname "$LOG")"

RESTIC_PASSWORD=$(security find-generic-password -a "$USER" -s brain/restic-password -w)
export RESTIC_PASSWORD
export RESTIC_REPOSITORY="${BRAIN_RESTIC_REPO:?set BRAIN_RESTIC_REPO, e.g. b2:bucket:brain}"

{
  echo "=== $(date -Iseconds) ==="
  restic backup \
    "${BRAIN_DIR:?}" \
    "${BRAIN_LOGIC_DIR:?}" \
    "${BRAIN_BACKUP_DIR:?}" \
    --exclude-caches \
    --exclude "${BRAIN_LOGIC_DIR}/logs"
  restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
  echo "ok"
} >> "$LOG" 2>&1 || {
  echo "$(date -Iseconds) RESTIC FAILED" >> "$LOG"
  command -v osascript >/dev/null && osascript -e \
    'display notification "Offsite backup failed" with title "Personal Brain"'
  exit 1
}
