#!/usr/bin/env bash
#
# Moves the OpenClaw gateway off the owner account and onto the sandboxed
# agent account, as a LaunchDaemon.
#
# Why a daemon and not an agent in brain's own LaunchAgents directory:
# a user agent is bootstrapped into `gui/<uid>`, which only exists while that
# user has a login session. Nobody logs into the sandbox account, so an agent
# there would never start. A LaunchDaemon with UserName=brain starts at boot
# with no session and no window server -- which is what an unattended gateway
# wants anyway.
#
# What happens when it fails at 3am:
#   - KeepAlive restarts it, throttled to one attempt per 10s so a crash loop
#     does not spin the CPU.
#   - stderr goes to a real file. The agent this replaces sent stderr to
#     /dev/null, so a crash would have left no trace at all; that is the single
#     worst property of the setup being removed here.
#   - If it cannot start at all -- missing config, port already held -- the
#     error lands in gateway.err.log and `--status` reports it as not running.
#     Nothing pages you. Until scripts/health-check.sh exists, this is the one
#     job here whose failure is silent to the user, and it fails safe: the
#     assistant stops answering, which you notice by using it.
#
# Consequences of the move, both accepted:
#   - The gateway loses access to anything gated on a GUI session or on the
#     owner's TCC grants. Telegram is network-only and unaffected. A future
#     iMessage channel would NOT work from here.
#   - The agent account starts with an empty ~/.openclaw workspace and state.
#     Anything paired or approved inside the old owner-side gateway has to be
#     redone once. That is the point of the move, not a side effect: the
#     account reading untrusted input should not inherit the owner's session.
#
# Usage: bash scripts/install-gateway-daemon.sh [--dry-run|--uninstall|--status|--logs]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$REPO/config/paths.env" ] && . "$REPO/config/paths.env"

AGENT_USER="${OPENCLAW_AGENT_USER:-brain}"
AGENT_HOME="/Users/${AGENT_USER}"
CONFIG="${AGENT_HOME}/.openclaw/openclaw.json"
PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

LABEL="com.personalbrain.openclaw-gateway"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
DOMAIN="system"

LOG_DIR="${AGENT_HOME}/Library/Logs/openclaw"

# The agent installed by OpenClaw's own setup, in the owner account. Removed by
# this script: it points at a service-env wrapper that no longer exists, it
# would contend for the same port, and it runs as the wrong user.
OLD_LABEL="ai.openclaw.gateway"
OLD_PLIST="${HOME}/Library/LaunchAgents/${OLD_LABEL}.plist"
OLD_DOMAIN="gui/$(id -u)"

NODE="${OPENCLAW_NODE:-/opt/homebrew/opt/node/bin/node}"
ENTRY="${OPENCLAW_ENTRY:-/opt/homebrew/lib/node_modules/openclaw/dist/index.js}"

DRY=0
MODE="install"
case "${1:-}" in
  --dry-run)   DRY=1 ;;
  --uninstall) MODE="uninstall" ;;
  --status)    MODE="status" ;;
  --logs)      MODE="logs" ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

run() { if [ "$DRY" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

# lsof exits 1 when nothing is listening. Under `set -e` with pipefail that
# status propagates out of a `who="$(listener)"` assignment and kills the
# script mid-verification with no output at all -- which is exactly what it did
# on the first real run. "Nothing is listening" is a result, not an error.
# Prints the user owning the listener, empty if nothing is listening, or "?"
# when it cannot tell.
#
# lsof only reports sockets owned by OTHER users when it runs as root -- and
# this daemon deliberately runs as someone else. Without sudo the check said
# "nothing listening" while curl and pgrep, sitting right beside it, both
# confirmed the gateway was up. A check that contradicts its neighbours is
# worse than no check: it teaches you to ignore the output.
listener() {
  if sudo -n true 2>/dev/null; then
    { sudo -n lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR==2 {print $3}'
  else
    printf '?'
  fi
}

# Everything worth reading when the daemon will not stay up. launchd reports
# the job's own exit status here: 78 (EX_CONFIG) is the gateway rejecting its
# configuration, not launchd failing to spawn it.
diagnose() {
  echo "  Daemon state:"
  { sudo launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null || true; } \
    | awk '/^\t(state|runs|last exit code) = /{sub(/^\t/,"    "); print}'
  echo
  echo "  ${LOG_DIR}/gateway.err.log:"
  { sudo tail -40 "${LOG_DIR}/gateway.err.log" 2>/dev/null || true; } \
    | sed 's/^/    /' | grep . || echo "    (empty or not created)"
  echo
  echo "  ${LOG_DIR}/gateway.out.log:"
  { sudo tail -40 "${LOG_DIR}/gateway.out.log" 2>/dev/null || true; } \
    | sed 's/^/    /' | grep . || echo "    (empty or not created)"
}

if [ "$MODE" = "logs" ]; then diagnose; exit 0; fi

if [ "$MODE" = "status" ]; then
  if launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
    pid=$({ launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null || true; } | awk '/^\tpid = /{print $3}')
    echo "  ${LABEL}  loaded${pid:+, pid ${pid}}"
  elif [ -f "$PLIST" ]; then
    echo "  ${LABEL}  plist present but NOT loaded"
  else
    echo "  ${LABEL}  not installed"
  fi

  who=$(listener)
  case "$who" in
    "")
      echo "  port ${PORT}  nothing listening" ;;
    "?")
      # No sudo cached. The HTTP probe needs no privileges, so report what can
      # actually be established rather than guessing at the owner.
      if curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null; then
        echo "  port ${PORT}  answering HTTP; owner needs sudo to confirm"
      else
        echo "  port ${PORT}  not answering; owner needs sudo to confirm"
      fi ;;
    "$AGENT_USER")
      echo "  port ${PORT}  listening, owned by ${AGENT_USER}" ;;
    *)
      echo "  port ${PORT}  listening, owned by ${who}"
      echo "                WRONG USER -- expected ${AGENT_USER}" ;;
  esac

  # OpenClaw's own installer rewrites this on some commands. If it comes back,
  # two gateways will race for the port and the owner-side one may win.
  if [ -f "$OLD_PLIST" ]; then
    if [ -f "$PLIST" ]; then
      echo "  WARNING: ${OLD_PLIST} has reappeared."
      echo "           OpenClaw's installer rewrites it. Re-run this script."
    else
      echo "  note: owner-account agent ${OLD_LABEL} is still installed."
      echo "        Running this script without a flag removes it."
    fi
  fi
  exit 0
fi

if [ "$MODE" = "uninstall" ]; then
  run sudo launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
  run sudo rm -f "$PLIST"
  echo "  removed ${LABEL}"
  echo "  note: ${CONFIG} and ${LOG_DIR} are left in place."
  exit 0
fi

# ---- preflight. Fail before touching anything. ----

id "$AGENT_USER" >/dev/null 2>&1 || { echo "no such user: ${AGENT_USER}" >&2; exit 1; }

# Establish sudo up front. Every check below runs through it, and without this
# the first one fails with "brain cannot execute node" when the real cause is
# that sudo had no terminal to prompt from -- a diagnosis pointing at the
# sandbox boundary instead of at the missing password.
if ! sudo -v; then
  echo >&2
  echo "This script needs sudo: it installs a LaunchDaemon and writes into ${AGENT_HOME}." >&2
  echo "Run it from an interactive terminal." >&2
  exit 1
fi

[ -x "$NODE" ]  || { echo "node not found or not executable: ${NODE}" >&2; exit 1; }
[ -f "$ENTRY" ] || { echo "openclaw entrypoint not found: ${ENTRY}" >&2; exit 1; }

# brain must be able to execute node and read the module tree. Homebrew is
# world-readable by default, but a hardened umask or a chmod -R would break
# this in a way that only shows up as a daemon that will not start.
if ! sudo -u "$AGENT_USER" test -x "$NODE"; then
  echo "${AGENT_USER} cannot execute ${NODE}" >&2; exit 1
fi
if ! sudo -u "$AGENT_USER" test -r "$ENTRY"; then
  echo "${AGENT_USER} cannot read ${ENTRY}" >&2; exit 1
fi

# The config is the whole reason the sandbox account is usable. Without it the
# gateway starts on defaults -- no Ollama baseUrl, no channel, no approval
# policy -- which is worse than not starting.
if ! sudo test -f "$CONFIG"; then
  cat >&2 <<MSG
missing ${CONFIG}

The rendered config is not on the agent's side yet. Install it first:

  bash scripts/install-openclaw-config.sh

Starting the gateway without it would run on defaults: no Ollama baseUrl, no
Telegram channel, and no approval policy.
MSG
  exit 1
fi

echo "==> preflight ok: ${AGENT_USER} can run node, config present at ${CONFIG}"

# ---- remove the owner-side agent ----

if [ -f "$OLD_PLIST" ] || launchctl print "${OLD_DOMAIN}/${OLD_LABEL}" >/dev/null 2>&1; then
  echo "==> removing owner-account gateway (${OLD_LABEL})"
  run launchctl bootout "${OLD_DOMAIN}/${OLD_LABEL}" 2>/dev/null || true
  run rm -f "$OLD_PLIST"
fi

# Stop OUR daemon too, not just the owner-side agent. On a re-install -- which
# is the normal way to apply a config change -- the port is held by the very
# job this script is about to replace, and the wait below would otherwise fail
# with "still held by user brain" and refuse to continue.
if launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
  echo "==> stopping the running ${LABEL}"
  run sudo launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
fi

# bootout is asynchronous and the socket lingers. A daemon that loses the bind
# race gets thrown into KeepAlive restarts and looks like a config problem.
if [ "$DRY" -eq 0 ]; then
  # Wait longer than the job's own ExitTimeOut (20s). bootout is SIGTERM, and
  # launchd allows the full timeout before escalating -- a gateway blocked on an
  # in-flight model call uses most of it. Waiting 10s here failed on a live
  # daemon and reported it as "still held", which reads like a stuck process
  # rather than a script that gave up early.
  waited=0
  while [ -n "$(listener)" ] && [ "$waited" -lt 45 ]; do
    [ "$waited" -eq 5 ] && echo "    waiting for it to release port ${PORT} (up to 45s)..."
    sleep 1
    waited=$((waited + 1))
  done

  holder="$(listener)"
  if [ -n "$holder" ] && [ "$holder" != "?" ]; then
    pid="$({ sudo -n lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR==2 {print $2}')"
    echo "port ${PORT} is still held by user ${holder} after ${waited}s." >&2
    echo "Two gateways cannot share it. Stop it and re-run:" >&2
    echo "  sudo kill ${pid:-<pid>}" >&2
    exit 1
  fi
fi

# ---- install ----

echo "==> log directory ${LOG_DIR}"
run sudo install -d -o "$AGENT_USER" -g staff -m 700 "${AGENT_HOME}/Library/Logs"
run sudo install -d -o "$AGENT_USER" -g staff -m 700 "$LOG_DIR"

echo "==> writing ${PLIST}"
if [ "$DRY" -eq 1 ]; then
  echo "  [dry-run] would write ${PLIST} (root:wheel 0644), UserName=${AGENT_USER}"
else
  tmp="$(mktemp)"
  cat > "$tmp" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>

  <key>UserName</key><string>${AGENT_USER}</string>
  <key>GroupName</key><string>staff</string>

  <key>ProgramArguments</key>
  <array>
    <string>${NODE}</string>
    <string>--max-old-space-size=8192</string>
    <string>${ENTRY}</string>
    <string>gateway</string>
    <string>--port</string>
    <string>${PORT}</string>
  </array>

  <!-- launchd hands a daemon a near-empty environment. HOME especially:
       without it the process inherits root's and never finds openclaw.json. -->
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>    <string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>    <string>${AGENT_HOME}</string>
    <key>USER</key>    <string>${AGENT_USER}</string>
    <key>LOGNAME</key> <string>${AGENT_USER}</string>
  </dict>

  <key>WorkingDirectory</key><string>${AGENT_HOME}/.openclaw</string>

  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ExitTimeOut</key><integer>20</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>Umask</key><integer>63</integer>

  <key>StandardInPath</key><string>/dev/null</string>
  <key>StandardOutPath</key><string>${LOG_DIR}/gateway.out.log</string>
  <!-- Not /dev/null. The agent this replaces discarded stderr, so a crash
       left nothing behind to read. -->
  <key>StandardErrorPath</key><string>${LOG_DIR}/gateway.err.log</string>
</dict>
</plist>
PLIST_EOF
  plutil -lint "$tmp" >/dev/null || { echo "malformed plist" >&2; rm -f "$tmp"; exit 1; }
  sudo install -o root -g wheel -m 644 "$tmp" "$PLIST"
  rm -f "$tmp"
fi

echo "==> loading"
run sudo launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
run sudo launchctl bootstrap "$DOMAIN" "$PLIST"
run sudo launchctl enable "${DOMAIN}/${LABEL}"

[ "$DRY" -eq 1 ] && exit 0

# ---- verify. The install is not the claim; this is. ----

echo
echo "==> verifying"
rc=0

for _ in $(seq 1 30); do
  [ -n "$(listener)" ] && break
  sleep 1
done

who="$(listener)"
case "$who" in
  "$AGENT_USER") echo "    ok: port ${PORT} listening as ${AGENT_USER}" ;;
  "?")           echo "    SKIPPED: cannot read the socket owner without sudo" ;;
  *)             echo "    FAIL: port ${PORT} listener is '${who:-nothing}', expected ${AGENT_USER}"
                 rc=1 ;;
esac

if curl -fsS -m 5 -o /dev/null "http://127.0.0.1:${PORT}/"; then
  echo "    ok: gateway answers on 127.0.0.1:${PORT}"
else
  echo "    FAIL: no HTTP response on 127.0.0.1:${PORT}"
  rc=1
fi

if pgrep -u "$AGENT_USER" -f 'openclaw.*gateway' >/dev/null 2>&1; then
  echo "    ok: process is owned by ${AGENT_USER}"
else
  echo "    FAIL: no gateway process running as ${AGENT_USER}"
  rc=1
fi

if [ -f "$OLD_PLIST" ]; then
  echo "    FAIL: ${OLD_PLIST} still present"
  rc=1
else
  echo "    ok: owner-account gateway agent is gone"
fi

echo
if [ "$rc" -ne 0 ]; then
  echo "  Verification failed."
  echo
  diagnose
  echo
  echo "  Re-read after a fix:  bash scripts/install-gateway-daemon.sh --logs"
  echo "  Restart:              sudo launchctl kickstart -k ${DOMAIN}/${LABEL}"
  exit 1
fi

cat <<EOF
  Done. The gateway runs as ${AGENT_USER}, from ${CONFIG}.

  Status:    bash scripts/install-gateway-daemon.sh --status
  Logs:      sudo tail -f ${LOG_DIR}/gateway.{out,err}.log
  Restart:   sudo launchctl kickstart -k ${DOMAIN}/${LABEL}
  Uninstall: bash scripts/install-gateway-daemon.sh --uninstall

  Re-run this script after any 'openclaw' command that reinstalls a service --
  it rewrites ${OLD_PLIST}, and two gateways cannot share port ${PORT}.
EOF
