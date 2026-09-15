#!/usr/bin/env bash
#
# Wires cron/*.sh into launchd as user agents.
#
# What happens when each fails at 3am -- the question that decides the design:
#
#   brain-commit   A missing or unreadable brain repo used to log and exit 1
#                  with nothing else. launchd does not surface a nonzero exit,
#                  so the brain would quietly stop being committed and you
#                  would notice weeks later. cron/brain-commit.sh now posts a
#                  notification on that path, matching what it already did for
#                  a gitleaks-blocked commit.
#
#   nightly-pgdump Already loud: logs, posts a notification, exits 1. The dump
#                  is the thing you need on restore day, so a silent failure
#                  here is the worst of the three.
#
#   restic-backup  Cannot run at all right now -- restic is not installed and
#                  brain/restic-password is not in the Keychain. Loading it
#                  would produce a guaranteed nightly failure, which trains you
#                  to ignore the notifications that matter. Its plist is
#                  written but deliberately NOT loaded until prerequisites
#                  exist. --status says so every time you ask.
#
# Ordering is not arbitrary: commit the brain, then dump the database, then
# back up both -- restic must run after pgdump or it snapshots yesterday's dump.
#
# If the Mac is asleep at the scheduled time, launchd runs the job once on
# wake. It does not run it once per missed interval.
#
# Usage: bash scripts/install-cron-agents.sh [--dry-run|--uninstall|--status]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$REPO/config/paths.env" ] && . "$REPO/config/paths.env"

LOG_DIR="${BRAIN_LOGIC_DIR:-$HOME/brain-logic}/logs"
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

# label-suffix : script : hour : minute
JOBS=(
  "brain-commit:cron/brain-commit.sh:3:0"
  "pgdump:cron/nightly-pgdump.sh:3:15"
  "restic:cron/restic-backup.sh:3:45"
)

DRY=0
MODE="install"
case "${1:-}" in
  --dry-run)   DRY=1 ;;
  --uninstall) MODE="uninstall" ;;
  --status)    MODE="status" ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

run() { if [ "$DRY" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

# restic cannot work without both of these. Checked rather than assumed.
# All three prerequisites of cron/restic-backup.sh, not two. The job dies at
# its first line without the Keychain item and at `${BRAIN_RESTIC_REPO:?}`
# without the repo -- so a guard that checks only the binary and the password
# loads a job that fails every night at 03:45 on the third one. The repo
# variable belongs in config/paths.env; which backend it names is the owner's
# call. This function is also what --status reports, so keep the message in
# restic_missing() in step with it.
restic_ready() {
  [ -z "$(restic_missing)" ]
}

restic_missing() {
  local missing=()
  command -v restic >/dev/null 2>&1 || missing+=("restic not installed")
  security find-generic-password -a "$USER" -s brain/restic-password -w >/dev/null 2>&1 \
    || missing+=("brain/restic-password absent")
  [ -n "${BRAIN_RESTIC_REPO:-}" ] || missing+=("BRAIN_RESTIC_REPO unset in config/paths.env")
  local out="" m
  for m in "${missing[@]-}"; do
    [ -n "$m" ] || continue
    out="${out:+$out; }$m"
  done
  printf '%s' "$out"
}

if [ "$MODE" = "status" ]; then
  for job in "${JOBS[@]}"; do
    IFS=: read -r name _ hh mm <<<"$job"
    label="com.personalbrain.${name}"
    if launchctl print "${DOMAIN}/${label}" >/dev/null 2>&1; then
      state="loaded, runs $(printf '%02d:%02d' "$hh" "$mm") daily"
    elif [ -f "${AGENTS}/${label}.plist" ]; then
      state="plist present but NOT loaded"
    else
      state="not installed"
    fi
    printf '  %-28s %s\n' "$label" "$state"
  done
  restic_ready || echo "  note: restic prerequisites missing: $(restic_missing)"
  exit 0
fi

if [ "$MODE" = "uninstall" ]; then
  for job in "${JOBS[@]}"; do
    IFS=: read -r name _ _ _ <<<"$job"
    label="com.personalbrain.${name}"
    run launchctl bootout "${DOMAIN}/${label}" 2>/dev/null || true
    run rm -f "${AGENTS}/${label}.plist"
    echo "  removed ${label}"
  done
  exit 0
fi

run mkdir -p "$LOG_DIR" "$AGENTS"

for job in "${JOBS[@]}"; do
  IFS=: read -r name script hh mm <<<"$job"
  label="com.personalbrain.${name}"
  plist="${AGENTS}/${label}.plist"
  target="${REPO}/${script}"
  [ -x "$target" ] || { echo "not executable: $target" >&2; exit 1; }

  echo "==> ${label}  ($(printf '%02d:%02d' "$hh" "$mm") daily)  ${script}"

  if [ "$DRY" -eq 1 ]; then
    echo "  [dry-run] would write $plist"
  else
    # EnvironmentVariables is not a nicety. launchd hands a job a nearly empty
    # environment: no PATH beyond a minimal default, and no USER. PGHOST is
    # required because pg_hba is socket-only (see decision-log), and USER is
    # required because gbrain's client reads the role name from it -- without
    # it Postgres sees user "unknown" and peer auth fails with an error that
    # points at authentication rather than at the missing variable.
    cat > "$plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${target}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>             <string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>             <string>${HOME}</string>
    <key>USER</key>             <string>${USER}</string>
    <key>LOGNAME</key>          <string>${USER}</string>
    <key>PGHOST</key>           <string>${PGHOST:-/tmp}</string>
    <key>BRAIN_DIR</key>        <string>${BRAIN_DIR}</string>
    <key>BRAIN_LOGIC_DIR</key>  <string>${BRAIN_LOGIC_DIR}</string>
    <key>BRAIN_BACKUP_DIR</key> <string>${BRAIN_BACKUP_DIR}</string>
    <key>BRAIN_DB_NAME</key>    <string>${BRAIN_DB_NAME}</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>${hh}</integer>
    <key>Minute</key><integer>${mm}</integer>
  </dict>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key> <string>${LOG_DIR}/${name}.out.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/${name}.err.log</string>
</dict>
</plist>
PLIST_EOF
    plutil -lint "$plist" >/dev/null || { echo "malformed plist: $plist" >&2; exit 1; }
  fi

  if [ "$name" = "restic" ] && ! restic_ready; then
    echo "  plist written, NOT loaded: $(restic_missing)."
    echo "  A job that fails every night trains you to ignore the ones that matter."
    echo "  Re-run this script once all three exist; it loads the job then."
    continue
  fi

  run launchctl bootout "${DOMAIN}/${label}" 2>/dev/null || true
  run launchctl bootstrap "${DOMAIN}" "$plist"
  run launchctl enable "${DOMAIN}/${label}"
  [ "$DRY" -eq 1 ] || echo "  loaded"
done

cat <<EOF

  Done.

  Status:    bash scripts/install-cron-agents.sh --status
  Run now:   launchctl kickstart -p ${DOMAIN}/com.personalbrain.pgdump
  Logs:      ${LOG_DIR}/{brain-commit,pgdump,restic}.{out,err}.log
             plus each script's own log: brain-commit.log, pgdump.log, restic.log
  Uninstall: bash scripts/install-cron-agents.sh --uninstall

EOF
