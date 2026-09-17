#!/usr/bin/env bash
# Rehearse the restore. Backups you have never restored are a hypothesis.
# Restores into a scratch directory and a scratch database — touches nothing real.
set -euo pipefail

# Load shared paths. Anything already exported wins, so a one-off override
# still works: BRAIN_DIR=/tmp/x bash cron/brain-commit.sh
_PATHS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/paths.env"
# shellcheck source=/dev/null
[ -f "$_PATHS" ] && . "$_PATHS"

SCRATCH=$(mktemp -d)
DB_TEST="gbrain_restoretest"
trap 'rm -rf "$SCRATCH"; dropdb --if-exists "$DB_TEST" 2>/dev/null || true' EXIT

echo "==> Restoring brain repo into $SCRATCH"
git clone --quiet "${BRAIN_REMOTE:-${BRAIN_DIR:?}}" "$SCRATCH/brain"
pages=$(find "$SCRATCH/brain" -name '*.md' | wc -l | tr -d ' ')
echo "    $pages markdown pages"

echo "==> Restoring latest dump into $DB_TEST"
latest=$(ls -t "${BRAIN_BACKUP_DIR:-$HOME/backups/pgdump}"/*.dump 2>/dev/null | head -1)
[ -n "$latest" ] || { echo "no dump found" >&2; exit 1; }
createdb "$DB_TEST"
pg_restore -d "$DB_TEST" "$latest" >/dev/null 2>&1 || true
rows=$(psql -d "$DB_TEST" -tAc \
  "SELECT COALESCE(sum(n_live_tup),0) FROM pg_stat_user_tables;" 2>/dev/null || echo 0)
echo "    restored from $(basename "$latest"), ~$rows rows"

# Offsite: restore the latest restic snapshot into scratch and count what came
# back. Skipped, not failed, when restic is not configured -- the drill above
# still proves the on-disk path. Nothing restored here is read or printed:
# only counts, and the restic summary line.
if command -v restic >/dev/null 2>&1 && [ -n "${BRAIN_RESTIC_REPO:-}" ] \
   && security find-generic-password -a "$USER" -s brain/restic-password -w >/dev/null 2>&1; then
  echo "==> Restoring latest restic snapshot into $SCRATCH/restic"
  export RESTIC_REPOSITORY="$BRAIN_RESTIC_REPO"
  export RESTIC_PASSWORD_COMMAND="security find-generic-password -a $USER -s brain/restic-password -w"
  restic restore latest --target "$SCRATCH/restic" 2>&1 | grep -E 'restoring|Summary|error' | sed 's/^/    /' || true
  rfiles=$(find "$SCRATCH/restic" -type f | wc -l | tr -d ' ')
  [ "$rfiles" -gt 0 ] || { echo "restic restore produced no files" >&2; exit 1; }
  echo "    $rfiles files restored from $(restic snapshots latest --json 2>/dev/null | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s[-1]["short_id"], s[-1]["time"][:19])' 2>/dev/null || echo 'latest')"
else
  echo "==> restic not configured; offsite restore skipped"
fi

echo
echo "Restore drill passed. Re-run after any change to the backup pipeline."
