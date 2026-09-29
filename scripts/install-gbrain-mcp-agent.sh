#!/usr/bin/env bash
#
# Installs gbrain's HTTP MCP server as a launchd agent, running as the owner,
# on loopback only. This is what lets the assistant query GBrain without the
# agent account ever holding a database credential.
#
# What happens when it fails at 3am: KeepAlive restarts it every 10s. If
# Postgres is down the process comes up anyway and /health reports
# db:unreachable; the gateway's tool call then errors and the assistant tells
# the owner it cannot reach memory, which is the honest answer. Nothing else
# depends on it -- pgdump (03:15) and restic (03:45) do not use it -- so a
# night of it being down costs a night of the assistant having no memory, and
# health-check.sh reports the gbrain-mcp row DOWN in the morning.
#
# Usage: bash scripts/install-gbrain-mcp-agent.sh [--dry-run|--status|--uninstall]
set -euo pipefail

LABEL="com.personalbrain.gbrain-mcp"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$REPO/config/paths.env" ] && . "$REPO/config/paths.env"

# No fallback: a guessed log path is how the Ollama agent crash-looped for
# days into a directory nobody looked in (install-ollama-agent.sh).
[ -n "${BRAIN_LOGIC_DIR:-}" ] || {
  echo "BRAIN_LOGIC_DIR is unset -- config/paths.env is missing or incomplete." >&2
  exit 1
}
LOG_DIR="${BRAIN_LOGIC_DIR}/logs"
PORT="${GBRAIN_MCP_PORT:-3131}"
WRAPPER="${REPO}/scripts/gbrain-mcp-serve.sh"
HEALTH="http://127.0.0.1:${PORT}/health"

DRY=0
MODE="install"
case "${1:-}" in
  --dry-run)   DRY=1 ;;
  --status)    MODE="status" ;;
  --uninstall) MODE="uninstall" ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

run() { if [ "$DRY" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

# lsof exits 1 with nothing listening -- a result, not an error, and fatal
# inside $( ) under pipefail without the guard.
port_holder() {
  { lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR==2 {print $2}'
}
port_bind() {
  { lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR==2 {print $9}'
}
agent_pid() {
  { launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null || true; } | awk '/^\tpid = /{print $3; exit}'
}

status() {
  local pid holder bind body
  if [ ! -f "$PLIST" ]; then echo "${LABEL}: not installed"; return 1; fi
  if ! launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
    echo "${LABEL}: installed but not loaded"; return 1
  fi
  pid="$(agent_pid)"; holder="$(port_holder)"; bind="$(port_bind)"
  echo "${LABEL}: loaded, pid ${pid:-none}"
  if [ -n "$holder" ]; then
    echo "  port ${PORT}: held by pid ${holder} on ${bind}"
  else
    echo "  port ${PORT}: nothing listening"
  fi
  body="$({ curl -sS -m 5 "$HEALTH" 2>/dev/null || true; })"
  echo "  health: ${body:-no answer}"
  [ -n "$pid" ] && [ "$holder" = "$pid" ] && [ "${bind%%:*}" = "127.0.0.1" ] && [ "${body#*\"status\":\"ok\"}" != "$body" ]
}

case "$MODE" in
  status) status; exit $? ;;
  uninstall)
    launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST"
    echo "removed ${LABEL}. The assistant's gbrain__search tool will now fail until it is reinstalled."
    exit 0 ;;
esac

[ -x "$WRAPPER" ] || { echo "missing or not executable: $WRAPPER" >&2; exit 1; }
# The wrapper's own preflight, run here as the owner so a missing bun or gbrain
# surfaces now, not as exit 78 in a log at 3am.
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:$PATH"
command -v gbrain >/dev/null 2>&1 || { echo "gbrain is not on PATH; bun's global bin is missing?" >&2; exit 1; }

# Whoever holds the port wins, and the loser respawns forever under KeepAlive.
# A hand-started `gbrain serve --http` from a terminal is the likely holder.
HOLDER="$(port_holder)"
if [ -n "$HOLDER" ] && [ "$HOLDER" != "$(agent_pid)" ]; then
  echo "port ${PORT} is held by pid ${HOLDER}, which is not this agent:" >&2
  { ps -o pid,ppid,user,command -p "$HOLDER" 2>/dev/null || true; } >&2
  echo "Stop it and re-run. Installing now would produce an agent that cannot bind." >&2
  exit 1
fi

run mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"

if [ "$DRY" -eq 1 ]; then
  echo "  [dry-run] would write $PLIST running: /bin/bash $WRAPPER"
  echo "  [dry-run] logs: ${LOG_DIR}/gbrain-mcp.{out,err}.log"
else
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${WRAPPER}</string>
  </array>
  <key>RunAtLoad</key>   <true/>
  <key>KeepAlive</key>   <true/>
  <key>ThrottleInterval</key> <integer>10</integer>
  <key>StandardOutPath</key> <string>${LOG_DIR}/gbrain-mcp.out.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/gbrain-mcp.err.log</string>
</dict>
</plist>
PLIST_EOF
  plutil -lint "$PLIST" >/dev/null || { echo "plist is malformed" >&2; exit 1; }
  echo "==> wrote $PLIST"
fi

echo "==> loading the agent"
run launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
run launchctl bootstrap "$DOMAIN" "$PLIST"
run launchctl enable "${DOMAIN}/${LABEL}"

if [ "$DRY" -eq 0 ]; then
  printf '  waiting for /health'
  for _ in $(seq 1 30); do
    curl -fsS -m 2 "$HEALTH" >/dev/null 2>&1 && break
    printf '.'; sleep 1
  done
  printf '\n'
  if ! status; then
    echo "the agent did not come up healthy -- see ${LOG_DIR}/gbrain-mcp.err.log" >&2
    exit 1
  fi
fi

cat <<EOF2

  Done. gbrain's MCP server runs as a launchd agent (${LABEL}), starting at login,
  on 127.0.0.1:${PORT} only. The gateway reaches it with the token from
  scripts/new-gbrain-token.sh, rendered into the agent's config by
  scripts/install-openclaw-config.sh.

  Status:    bash scripts/install-gbrain-mcp-agent.sh --status
  Logs:      ${LOG_DIR}/gbrain-mcp.{out,err}.log
  Uninstall: bash scripts/install-gbrain-mcp-agent.sh --uninstall

EOF2
