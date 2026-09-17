#!/usr/bin/env bash
#
# One command that answers "is the assistant actually working?"
#
# Every failure during bring-up was silent: a cron job that died inside a
# command substitution, a gateway rejecting its config into a log in another
# user's home, an embedding provider quietly pointed at a cloud API. Each was
# visible in seconds once someone thought to look. This is the thing that looks.
#
# Three states, never two. A check that cannot distinguish "the thing is down"
# from "I could not tell" is worse than no check, because both render as
# failure and you learn to ignore the output:
#
#   OK       Established, by a probe that would have failed if the thing were down.
#   DOWN     Established to be broken. A refused connection on loopback is proof:
#            nothing is bound to that port.
#   UNKNOWN  Not established either way. A timeout is not a death -- a gateway
#            mid-inference and a wedged one look identical from outside. So does
#            anything needing root that this script deliberately will not ask for.
#
# It reads only. No flags for dry-run because there is nothing to dry-run, and
# no sudo prompt: privileged facts (the gateway's launchd state, the owner of
# its socket) are reported when sudo is already cached and reported as UNKNOWN
# when it is not. A health check that blocks on a password cannot run unattended.
#
# Exit: 0 all OK, 1 something is DOWN, 2 nothing DOWN but something UNKNOWN.
#
# Usage: bash scripts/health-check.sh
set -euo pipefail

# Not as root. `sudo bash scripts/health-check.sh` is the natural thing to
# type and it produces two confident wrong answers: launchd's `gui/$(id -u)`
# becomes gui/0, which holds no agents, so the Ollama agent reads as not
# loaded; and Postgres peer auth sees role "root", so the database reads as
# down. Cache the credential and run as yourself -- the script reaches for
# `sudo -n` itself, only for the facts that need it.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  echo "health-check: do not run as root -- launchd and Postgres answer for the wrong user." >&2
  echo "Run:  sudo -v && bash scripts/health-check.sh" >&2
  exit 2
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# config/paths.env assigns unconditionally, so a caller override is otherwise
# silently discarded -- cron/restic-backup.sh documents the opposite, and the
# comment is wrong. Snapshotting here rather than changing shared config: being
# able to aim a check at a path that is *supposed* to fail is the only way the
# DOWN and UNKNOWN branches ever get exercised.
#   BRAIN_BACKUP_DIR=/nope bash scripts/health-check.sh
_OV_BACKUP="${BRAIN_BACKUP_DIR:-}"
_OV_PGHOST="${PGHOST:-}"
_OV_DB="${BRAIN_DB_NAME:-}"
# shellcheck source=/dev/null
[ -f "$REPO/config/paths.env" ] && . "$REPO/config/paths.env"
BRAIN_BACKUP_DIR="${_OV_BACKUP:-${BRAIN_BACKUP_DIR:-}}"
BRAIN_DB_NAME="${_OV_DB:-${BRAIN_DB_NAME:-}}"
export PGHOST="${_OV_PGHOST:-${PGHOST:-/tmp}}"

TEMPLATE="${REPO}/config/openclaw.json.template"
DB="${BRAIN_DB_NAME:-gbrain}"
BACKUP_DIR="${BRAIN_BACKUP_DIR:-$HOME/backups/pgdump}"
AGENT_USER="${OPENCLAW_AGENT_USER:-brain}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
AGENT_WORKSPACE="${OPENCLAW_WORKSPACE:-/Users/${OPENCLAW_AGENT_USER:-brain}/.openclaw/workspace}"
OLLAMA_LABEL="${OLLAMA_AGENT_LABEL:-com.personalbrain.ollama}"
OLLAMA_PORT="${OLLAMA_AGENT_PORT:-11434}"
GATEWAY_LABEL="com.personalbrain.openclaw-gateway"
GATEWAY_PLIST="/Library/LaunchDaemons/${GATEWAY_LABEL}.plist"

# pgdump runs 03:15 daily. 26h leaves room for a late run and for launchd
# firing a missed job on wake, without letting a genuinely skipped night pass.
MAX_DUMP_AGE_H=26

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,30p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0 ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

N_DOWN=0
N_UNKNOWN=0

# Anything not OK is counted here and nowhere else, so the exit code and the
# printed output can never disagree.
result() {
  local name=$1 state=$2; shift 2
  case "$state" in
    DOWN)    N_DOWN=$((N_DOWN + 1)) ;;
    UNKNOWN) N_UNKNOWN=$((N_UNKNOWN + 1)) ;;
  esac
  printf '  %-11s %-8s %s\n' "$name" "$state" "$*"
}

detail() { printf '  %-11s %-8s %s\n' "" "" "$*"; }

# curl's exit status is the whole diagnosis, and `set -e` would throw it away
# before it could be read. An `if` condition suppresses errexit for the command
# inside it, which is the only way to keep both the status and the strict mode.
# HTTP_CODE is set alongside RC; a 401 still proves something is answering.
probe() {
  if HTTP_CODE=$(curl -sS -m "$2" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null); then
    RC=0
  else
    RC=$?
    HTTP_CODE="000"
  fi
}

# Shared reading of a failed probe. Loopback makes ECONNREFUSED conclusive:
# no route, no proxy, no firewall in between -- nothing is bound to that port.
probe_verdict() {
  case "$RC" in
    7)  echo "DOWN|connection refused on ${1} -- nothing is listening" ;;
    28) echo "UNKNOWN|no response within ${2}s -- busy, starting, or wedged" ;;
    *)  echo "UNKNOWN|curl exit ${RC}" ;;
  esac
}

echo
echo "  $(date '+%Y-%m-%d %H:%M:%S')  $(hostname -s)"
echo

# ---- Ollama: the model everything personal runs on ----

check_ollama() {
  local url="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
  if ! command -v curl >/dev/null 2>&1; then
    result ollama UNKNOWN "curl not installed; cannot probe ${url}"
    return
  fi

  probe "${url}/api/tags" 5
  if [ "$RC" -ne 0 ]; then
    IFS='|' read -r state msg <<<"$(probe_verdict "$url" 5)"
    result ollama "$state" "$msg"
    return
  fi
  if [ "${HTTP_CODE:0:1}" != "2" ]; then
    result ollama UNKNOWN "answered HTTP ${HTTP_CODE} on ${url}/api/tags"
    return
  fi

  # Serving is not the same as serving the model the agent asks for. A missing
  # model surfaces as a per-request failure inside the gateway, which is
  # exactly the class of thing that goes unnoticed for weeks.
  local want have
  want=$({ jq -r '.models.providers.ollama.models[0].id // empty' "$TEMPLATE" 2>/dev/null || true; })
  if [ -z "$want" ]; then
    result ollama OK "serving on ${url}; configured model unknown (unreadable template)"
    return
  fi
  have=$({ curl -sS -m 5 "${url}/api/tags" 2>/dev/null || true; } \
    | { jq -r --arg m "$want" '[.models[]?.name] | index($m) // empty' 2>/dev/null || true; })
  if [ -n "$have" ]; then
    result ollama OK "serving ${want}"
  else
    result ollama DOWN "serving on ${url}, but ${want} is not pulled"
    detail "ollama pull ${want}"
  fi
}

# ---- Ollama's service identity: whose server is it? ----
#
# The endpoint check above proves *a* server is answering. It cannot prove it is
# ours, and for three days it was not: Ollama.app's menu-bar server held :11434,
# com.personalbrain.ollama lost every bind and respawned every 10 seconds under
# KeepAlive, and the tuned environment -- context length, keep-alive, KV cache
# type -- was never in effect. Everything looked healthy from outside. This is
# the check that tells the two apart.

check_ollama_service() {
  local domain="gui/$(id -u)" print_out agent_pid last_exit holder

  print_out=$({ launchctl print "${domain}/${OLLAMA_LABEL}" 2>/dev/null || true; })
  if [ -z "$print_out" ]; then
    if [ -f "$HOME/Library/LaunchAgents/${OLLAMA_LABEL}.plist" ]; then
      result ollama-svc DOWN "${OLLAMA_LABEL} is installed but not loaded"
    else
      result ollama-svc DOWN "${OLLAMA_LABEL} is not installed"
    fi
    detail "bash scripts/install-ollama-agent.sh"
    return
  fi

  agent_pid=$(printf '%s\n' "$print_out" | awk '/^\tpid = /{print $3; exit}')
  last_exit=$(printf '%s\n' "$print_out" | awk '/^\tlast exit code = /{print $5; exit}')

  # No pid plus a nonzero exit is the crash loop. It is invisible from the
  # endpoint's side, which is why it ran for days.
  if [ -z "$agent_pid" ]; then
    if [ -n "${last_exit:-}" ] && [ "$last_exit" != "0" ]; then
      result ollama-svc DOWN "${OLLAMA_LABEL} is crash-looping (last exit ${last_exit})"
      # The last ERROR, not the last line: the log interleaves INFO from
      # whichever server is winning, so a blind tail reports the wrong thing.
      local why log="${BRAIN_LOGIC_DIR:-.}/logs/ollama.err.log"
      why=$({ grep -aiE '^error|error:|fatal' "$log" 2>/dev/null || true; } | tail -1)
      [ -n "$why" ] && detail "${why}"
    else
      result ollama-svc DOWN "${OLLAMA_LABEL} is loaded but not running"
    fi
    return
  fi

  # Same user as this script, so lsof needs no privileges here -- unlike the
  # gateway's socket, which belongs to brain.
  holder=$({ lsof -nP -iTCP:"${OLLAMA_PORT}" -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR==2 {print $2}')
  if [ -z "$holder" ]; then
    result ollama-svc UNKNOWN "agent is running (pid ${agent_pid}) but nothing holds :${OLLAMA_PORT}"
    return
  fi
  if [ "$holder" != "$agent_pid" ]; then
    result ollama-svc DOWN "port ${OLLAMA_PORT} is served by pid ${holder}, not the agent (pid ${agent_pid})"
    detail "$({ ps -o comm= -p "$holder" 2>/dev/null || true; })"
    detail "the agent's tuned environment is NOT in effect; quit that server and re-run"
    detail "bash scripts/install-ollama-agent.sh"
    return
  fi

  # Report what the live process was actually started with, not what the plist
  # says. Those disagreed for three days.
  local env_out ctx keep
  env_out=$({ ps -Eww -o command= -p "$agent_pid" 2>/dev/null || true; } | tr ' ' '\n')
  ctx=$(printf '%s\n' "$env_out"  | { grep -E '^OLLAMA_CONTEXT_LENGTH=' || true; } | cut -d= -f2)
  keep=$(printf '%s\n' "$env_out" | { grep -E '^OLLAMA_KEEP_ALIVE=' || true; } | cut -d= -f2)
  result ollama-svc OK "agent owns :${OLLAMA_PORT} (pid ${agent_pid})"
  detail "live env: context ${ctx:-unset}, keep-alive ${keep:-unset}"
}

# ---- Postgres: GBrain's store ----

check_postgres() {
  if ! command -v pg_isready >/dev/null 2>&1; then
    result postgres UNKNOWN "pg_isready not on PATH; cannot probe"
    return
  fi

  local host="${PGHOST:-/tmp}" rc=0
  # Socket-only by pg_hba (harden-postgres-auth.sh). Exit 3 means pg_isready
  # never made an attempt -- a wrong socket path, not a dead server.
  pg_isready -q -h "$host" -d "$DB" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) ;;
    1) result postgres DOWN "server on ${host} is rejecting connections";  return ;;
    2) result postgres DOWN "no response from a server on ${host}";        return ;;
    *) result postgres UNKNOWN "pg_isready exit ${rc} -- no connection attempted (PGHOST=${host})"; return ;;
  esac

  # Accepting connections is not the same as this database being usable by
  # this user: peer auth means the OS user is the credential, so a real query
  # is the only thing that proves the pair works.
  if ! command -v psql >/dev/null 2>&1; then
    result postgres UNKNOWN "accepting on ${host}, but psql is missing; cannot query ${DB}"
    return
  fi
  local err
  if psql -d "$DB" -tAc 'select 1' >/dev/null 2>"${TMPDIR:-/tmp}/hc-psql.$$"; then
    result postgres OK "${DB} reachable over ${host} as ${USER}"
  else
    err=$({ sed -n '1p' "${TMPDIR:-/tmp}/hc-psql.$$" 2>/dev/null || true; })
    result postgres DOWN "server up, but ${DB} query failed: ${err:-no error text}"
  fi
  rm -f "${TMPDIR:-/tmp}/hc-psql.$$"
}

# ---- Gateway: the assistant's front door ----

check_gateway() {
  local url="http://127.0.0.1:${GATEWAY_PORT}/"

  probe "$url" 4
  if [ "$RC" -eq 0 ]; then
    result gateway OK "answering HTTP ${HTTP_CODE} on port ${GATEWAY_PORT}"
  else
    IFS='|' read -r state msg <<<"$(probe_verdict "127.0.0.1:${GATEWAY_PORT}" 4)"
    result gateway "$state" "$msg"
    [ -f "$GATEWAY_PLIST" ] || detail "not installed: ${GATEWAY_PLIST} is absent"
  fi

  # Everything below needs root: the daemon lives in the system domain and its
  # socket belongs to another user. Asking for a password would make this
  # script unrunnable unattended, so it reports what it cannot see instead.
  if ! sudo -n true 2>/dev/null; then
    detail "launchd state and socket owner need root: run under sudo to include them"
    return
  fi

  local state_line exit_line owner
  state_line=$({ sudo -n launchctl print "system/${GATEWAY_LABEL}" 2>/dev/null || true; } \
    | awk '/^\tstate = /{print $3; exit}')
  exit_line=$({ sudo -n launchctl print "system/${GATEWAY_LABEL}" 2>/dev/null || true; } \
    | awk '/^\tlast exit code = /{print $5; exit}')
  if [ -z "$state_line" ]; then
    detail "launchd: ${GATEWAY_LABEL} is not loaded"
  else
    # "(never exited)" splits into "(never", which rendered as a truncated
    # fragment. Only a numeric exit code is worth showing.
    case "${exit_line:-}" in
      ''|*[!0-9]*) detail "launchd: ${state_line}" ;;
      *)           detail "launchd: ${state_line}, last exit ${exit_line}" ;;
    esac
    # 78 is EX_CONFIG: the gateway rejected its own config and will crash-loop.
    [ "${exit_line:-}" = "78" ] && detail "exit 78 = config rejected. bash scripts/install-openclaw-config.sh --verify-only"
  fi

  owner=$({ sudo -n lsof -nP -iTCP:"${GATEWAY_PORT}" -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR==2 {print $3}')
  if [ -z "$owner" ]; then
    detail "socket: nothing listening on ${GATEWAY_PORT}"
  elif [ "$owner" = "$AGENT_USER" ]; then
    detail "socket: owned by ${AGENT_USER}"
  else
    detail "socket: owned by ${owner} -- WRONG USER, expected ${AGENT_USER}"
  fi
}

# ---- The agent's purpose: is there a SOUL.md at all? ----
#
# A missing SOUL.md does not fail. OpenClaw injects a "missing file" marker and
# carries on with a generic persona, which is how the assistant spent its first
# days inventing facts about its owner. Nothing in the running system reports
# it, so it gets reported here.

check_prompts() {
  if ! sudo -n true 2>/dev/null; then
    result prompts UNKNOWN "needs root to read ${AGENT_WORKSPACE}"
    return
  fi
  if ! sudo -n test -f "${AGENT_WORKSPACE}/SOUL.md" 2>/dev/null; then
    result prompts DOWN "no SOUL.md in ${AGENT_WORKSPACE}"
    detail "the agent has no purpose or voice configured, and will confabulate"
    detail "bash scripts/install-agent-prompts.sh"
    return
  fi
  local soul user
  # The path goes to wc as an ARGUMENT. With `< file` the shell opens it, as
  # this user, before sudo runs at all -- and these are mode 600 owned by brain,
  # so it printed "Permission denied" and reported "? chars" for a file that was
  # installed correctly. Privilege applies to the command, never to a redirect.
  soul=$({ sudo -n wc -m "${AGENT_WORKSPACE}/SOUL.md" 2>/dev/null || echo '?'; } | awk '{print $1}')
  result prompts OK "SOUL.md installed (${soul} chars)"
  if sudo -n test -f "${AGENT_WORKSPACE}/USER.md" 2>/dev/null; then
    user=$({ sudo -n wc -m "${AGENT_WORKSPACE}/USER.md" 2>/dev/null || echo 0; } | awk '{print $1}')
    # 4,000 is OpenClaw's hard cap; past it the file is silently truncated.
    if [ "$user" -gt 4000 ] 2>/dev/null; then
      detail "USER.md is ${user} chars -- OVER the 4000 budget, truncated every session"
    else
      detail "USER.md installed (${user} chars)"
    fi
  else
    detail "USER.md absent -- optional, but the agent has no context about you"
  fi
}

# ---- Backups: the only check whose failure is invisible until restore day ----

check_backups() {
  if [ ! -d "$BACKUP_DIR" ] || [ ! -r "$BACKUP_DIR" ]; then
    result backups UNKNOWN "${BACKUP_DIR} is missing or unreadable"
    return
  fi

  # `ls | head` is the SIGPIPE shape that kills scripts under pipefail: head
  # exits first and ls dies on the write. sed -n 1p reads to EOF.
  local newest age_h size
  newest=$({ ls -t "${BACKUP_DIR}/${DB}"-*.dump 2>/dev/null || true; } | sed -n '1p')
  if [ -z "$newest" ]; then
    result backups DOWN "no ${DB}-*.dump in ${BACKUP_DIR} -- nothing to restore from"
    return
  fi

  age_h=$(( ( $(date +%s) - $(stat -f %m "$newest") ) / 3600 ))
  size=$(stat -f %z "$newest")
  if [ "$size" -eq 0 ]; then
    result backups DOWN "newest dump is empty: $(basename "$newest")"
  elif [ "$age_h" -gt "$MAX_DUMP_AGE_H" ]; then
    result backups DOWN "newest dump is ${age_h}h old (>${MAX_DUMP_AGE_H}h): $(basename "$newest")"
    detail "logs/pgdump.log, and: launchctl kickstart -p gui/$(id -u)/com.personalbrain.pgdump"
  else
    result backups OK "$(basename "$newest"), ${age_h}h old, $(( size / 1024 ))K"
  fi

  # Off-disk state is reported, not scored. restic is a known, accepted gap;
  # counting it as a failure every single run is how you learn to ignore the
  # runs that mean something.
  local missing=()
  command -v restic >/dev/null 2>&1 || missing+=("restic not installed")
  { security find-generic-password -a "$USER" -s brain/restic-password -w >/dev/null 2>&1; } \
    || missing+=("brain/restic-password absent")
  [ -n "${BRAIN_RESTIC_REPO:-}" ] || missing+=("BRAIN_RESTIC_REPO unset")
  if [ ${#missing[@]} -eq 0 ]; then
    if launchctl print "gui/$(id -u)/com.personalbrain.restic" >/dev/null 2>&1; then
      # The job's own log ends each run with "ok" or "RESTIC FAILED"; the
      # "=== <iso time> ===" header above it says when. Read, never score:
      # a failed offsite run is worth a line here, not a DOWN that hides the
      # on-disk dump being fine.
      local rlog="${REPO}/logs/restic.log" last_hdr="" last_line=""
      if [ -r "$rlog" ]; then
        last_hdr=$({ grep -E '^=== .* ===$' "$rlog" || true; } | tail -1 | tr -d '=' | cut -c2-20)
        last_line=$({ grep -E '^(ok|.*RESTIC FAILED)$' "$rlog" || true; } | tail -1)
      fi
      case "$last_line" in
        ok)         detail "off-disk: restic job loaded; last run ok at ${last_hdr:-?}" ;;
        *FAILED*)   detail "off-disk: restic job loaded; last run FAILED at ${last_hdr:-?} -- see logs/restic.log" ;;
        *)          detail "off-disk: restic job loaded; no completed run in logs/restic.log yet" ;;
      esac
    else
      detail "off-disk: restic is ready but its job is NOT loaded"
    fi
  else
    # Joined by hand: "${a[*]}" uses only the FIRST character of IFS, so a
    # two-character separator silently becomes one.
    local joined="" m
    for m in "${missing[@]}"; do joined="${joined:+${joined}; }${m}"; done
    detail "off-disk: NONE -- ${joined}"
    detail "          these dumps share a disk with the database they came from"
  fi
}

check_ollama
check_ollama_service
check_postgres
check_gateway
check_prompts
check_backups

echo
if [ "$N_DOWN" -gt 0 ]; then
  echo "  ${N_DOWN} down, ${N_UNKNOWN} unknown"
  echo
  exit 1
elif [ "$N_UNKNOWN" -gt 0 ]; then
  echo "  nothing down, ${N_UNKNOWN} could not be established"
  echo
  exit 2
fi
echo "  all ok"
echo
