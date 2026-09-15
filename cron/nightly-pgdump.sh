#!/usr/bin/env bash
# Nightly Postgres dump. Fails loudly — silent failure in an unattended job is
# worse than a crash, because you find out on restore day.
set -euo pipefail

# Load shared paths. Anything already exported wins, so a one-off override
# still works: BRAIN_DIR=/tmp/x bash cron/brain-commit.sh
_PATHS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/paths.env"
# shellcheck source=/dev/null
[ -f "$_PATHS" ] && . "$_PATHS"

DB="${BRAIN_DB_NAME:-gbrain}"
OUT_DIR="${BRAIN_BACKUP_DIR:-$HOME/backups/pgdump}"
KEEP_DAYS="${BRAIN_DUMP_KEEP_DAYS:-30}"
LOG="${BRAIN_LOGIC_DIR:-$HOME/brain-logic}/logs/pgdump.log"

mkdir -p "$OUT_DIR" "$(dirname "$LOG")"
stamp=$(date +%Y-%m-%d)
out="$OUT_DIR/${DB}-${stamp}.dump"

{
  echo "=== $(date -Iseconds) pg_dump $DB ==="
  pg_dump -Fc -d "$DB" -f "$out"
  echo "wrote $out ($(du -h "$out" | cut -f1))"
  find "$OUT_DIR" -name "${DB}-*.dump" -mtime "+${KEEP_DAYS}" -print -delete
  echo "ok"
} >> "$LOG" 2>&1 || {
  echo "$(date -Iseconds) PGDUMP FAILED — see $LOG" >> "$LOG"
  command -v osascript >/dev/null && osascript -e \
    'display notification "Nightly pg_dump failed" with title "Personal Brain"'
  exit 1
}
