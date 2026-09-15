#!/usr/bin/env bash
#
# Replaces the Ollama menu-bar app's server with a launchd agent that actually
# honors its environment.
#
# Why: the desktop app ignores `launchctl setenv` (ollama/ollama#16896), so
# context length and keep-alive silently fall back to defaults. A LaunchAgent
# carries its own EnvironmentVariables dict — no ambiguity about what the
# server was started with.
#
# Usage:  bash scripts/install-ollama-agent.sh [--dry-run|--uninstall]
set -euo pipefail

LABEL="com.personalbrain.ollama"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
_P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/paths.env"; [ -f "$_P" ] && . "$_P"

# No fallback. An earlier run of this script defaulted to $HOME/brain-logic when
# paths.env had not yet defined BRAIN_LOGIC_DIR, and wrote that path into the
# plist. The agent then crash-looped for days, logging 646KB of the reason into
# a directory nobody had cause to look in. A wrong log path is not a smaller
# problem than no log path; it is a bigger one.
[ -n "${BRAIN_LOGIC_DIR:-}" ] || {
  echo "BRAIN_LOGIC_DIR is unset -- config/paths.env is missing or incomplete." >&2
  echo "Refusing to guess a log directory; the guess is what broke this before." >&2
  exit 1
}
LOG_DIR="${BRAIN_LOGIC_DIR}/logs"

# Match the installer's tuning; override by exporting before running.
: "${BRAIN_CONTEXT_LENGTH:=16384}"
: "${BRAIN_KV_CACHE_TYPE:=q8_0}"
: "${BRAIN_FLASH_ATTENTION:=1}"
: "${BRAIN_MAX_LOADED_MODELS:=1}"
# 5m, not 30m. The model is 17GB on a 24GB machine, and macOS refuses every
# mlock -- including the 80KB buffer CoreAudio wires to start the speakers --
# once free memory falls below vm.global_no_user_wire_amount (~5.9GB here).
# While the model is resident, free memory sits near 7%, so audio devices fail
# to start for the whole keep-alive window. See docs/decision-log.md 2026-09-07.
: "${BRAIN_KEEP_ALIVE:=5m}"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  --uninstall)
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST"
    echo "removed ${LABEL}. Reopen Ollama.app if you want the menu-bar server back."
    exit 0 ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

run() { if [ "$DRY" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

# Resolve the real binary — the cask ships it inside the app bundle.
OLLAMA_BIN="$(command -v ollama || true)"
[ -n "$OLLAMA_BIN" ] || OLLAMA_BIN=/Applications/Ollama.app/Contents/Resources/ollama
[ -x "$OLLAMA_BIN" ] || { echo "cannot find the ollama binary" >&2; exit 1; }
# Follow symlinks so the agent doesn't depend on a Homebrew shim.
OLLAMA_BIN="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$OLLAMA_BIN")"
echo "==> using $OLLAMA_BIN"

echo "==> stopping the menu-bar app (it would fight for :11434)"
run osascript -e 'quit app "Ollama"' 2>/dev/null || true
[ "$DRY" -eq 0 ] && sleep 2
run pkill -f "Ollama.app" 2>/dev/null || true
[ "$DRY" -eq 0 ] && sleep 1

# Whoever holds :11434 wins, and the loser respawns forever under KeepAlive.
# That is precisely the state this script is being run to repair, so it refuses
# to install an agent that would lose. lsof exits 1 with nothing listening --
# a result, not an error, and fatal inside $( ) under pipefail without the guard.
port_holder() {
  { lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR==2 {print $2}'
}
if [ "$DRY" -eq 0 ]; then
  HOLDER="$(port_holder)"
  if [ -n "$HOLDER" ]; then
    echo "port 11434 is still held by pid ${HOLDER}:" >&2
    { ps -o pid,ppid,comm -p "$HOLDER" 2>/dev/null || true; } >&2
    cat >&2 <<MSG

The menu-bar app did not release the port, or something else is serving.
Installing now would produce an agent that cannot bind and respawns every 10
seconds forever -- the exact failure this run is meant to fix.

Quit Ollama.app from the menu bar and re-run.
MSG
    exit 1
  fi
fi

run mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"

if [ "$DRY" -eq 1 ]; then
  echo "  [dry-run] would write $PLIST"
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
    <string>${OLLAMA_BIN}</string>
    <string>serve</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_CONTEXT_LENGTH</key>    <string>${BRAIN_CONTEXT_LENGTH}</string>
    <key>OLLAMA_KV_CACHE_TYPE</key>     <string>${BRAIN_KV_CACHE_TYPE}</string>
    <key>OLLAMA_FLASH_ATTENTION</key>   <string>${BRAIN_FLASH_ATTENTION}</string>
    <key>OLLAMA_MAX_LOADED_MODELS</key> <string>${BRAIN_MAX_LOADED_MODELS}</string>
    <key>OLLAMA_KEEP_ALIVE</key>        <string>${BRAIN_KEEP_ALIVE}</string>
    <key>OLLAMA_HOST</key>              <string>127.0.0.1:11434</string>
  </dict>
  <key>RunAtLoad</key>   <true/>
  <key>KeepAlive</key>   <true/>
  <key>StandardOutPath</key> <string>${LOG_DIR}/ollama.out.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/ollama.err.log</string>
</dict>
</plist>
PLIST_EOF
  plutil -lint "$PLIST" >/dev/null || { echo "plist is malformed" >&2; exit 1; }
  echo "==> wrote $PLIST"
fi

echo "==> loading the agent"
run launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
run launchctl bootstrap "gui/$(id -u)" "$PLIST"
run launchctl enable "gui/$(id -u)/${LABEL}"

if [ "$DRY" -eq 0 ]; then
  printf '  waiting for the server'
  for _ in $(seq 1 30); do
    curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break
    printf '.'; sleep 1
  done
  printf '\n'
  curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1 \
    || { echo "server did not come up — check ${LOG_DIR}/ollama.err.log" >&2; exit 1; }

  # "A server answered" is not the same as "our server answered". The app can
  # win the race and leave this agent crash-looping behind a working endpoint,
  # which is indistinguishable from success unless the owner is checked.
  AGENT_PID="$({ launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null || true; } | awk '/^\tpid = /{print $3; exit}')"
  HOLDER="$(port_holder)"
  if [ -z "$AGENT_PID" ]; then
    echo "the agent is loaded but not running — check ${LOG_DIR}/ollama.err.log" >&2; exit 1
  fi
  if [ "$HOLDER" != "$AGENT_PID" ]; then
    echo "port 11434 is served by pid ${HOLDER:-none}, not by the agent (pid ${AGENT_PID})." >&2
    echo "The tuned environment below is NOT in effect. Quit Ollama.app and re-run." >&2
    exit 1
  fi
  echo "==> agent (pid ${AGENT_PID}) owns :11434"
  echo "    context ${BRAIN_CONTEXT_LENGTH}, keep-alive ${BRAIN_KEEP_ALIVE}, kv ${BRAIN_KV_CACHE_TYPE}"
fi

cat <<EOF

  Done. Ollama now runs as a launchd agent, starting at login.

  Verify:
    ollama run qwen3.6:27b-q4_K_M --think=false "say hi in five words"
    ollama ps        # CONTEXT ${BRAIN_CONTEXT_LENGTH}, UNTIL ~${BRAIN_KEEP_ALIVE} out

  Do NOT reopen Ollama.app — it would start a second server on the same port,
  win it at the next login, and leave this agent respawning every 10 seconds
  with its environment ignored. That has already happened once.

  Turn OFF "launch at login" in Ollama.app's settings (or System Settings →
  General → Login Items → Ollama). Nothing in this repo can do that for you,
  and nothing here will notice for you except:

    bash scripts/health-check.sh

  Logs:      ${LOG_DIR}/ollama.{out,err}.log
  Uninstall: bash scripts/install-ollama-agent.sh --uninstall

EOF
