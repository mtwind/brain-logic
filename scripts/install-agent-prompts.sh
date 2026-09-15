#!/usr/bin/env bash
#
# Installs SOUL.md and USER.md into the sandboxed agent account.
#
# The problem this solves: OpenClaw reads these from the agent's workspace at
# the start of EVERY session, and the agent's home is /Users/brain, which
# provably cannot read $BRAIN_DIR -- install-openclaw-config.sh asserts that
# failure as a pass condition on every run. So the repo's old instruction,
#
#     ln -s $BRAIN/personal/SOUL.md ~/.openclaw/SOUL.md
#
# could never work. It was wrong twice: the symlink target is unreadable by the
# account that must read it, and `~/.openclaw/` is the wrong directory anyway --
# these are WORKSPACE files (`~/.openclaw/workspace/`), while `~/.openclaw/`
# holds config, credentials and sessions. Without them the assistant runs with
# no purpose and no user context, and confabulates both.
#
# Same shape as the config problem, same answer: the owner copies, the agent
# never reaches across the boundary.
#
# This script never prints file contents -- only paths, character counts and a
# short hash. That is deliberate: it is run by an assistant that must not read
# the owner's personal writing, and output is the obvious way that leaks.
#
# What happens when it fails at 3am: nothing, it is not a cron job. But a
# MISSING file is silent at runtime -- OpenClaw injects a "missing file" marker
# and carries on with a generic persona. scripts/health-check.sh reports it.
#
# Usage: bash scripts/install-agent-prompts.sh [--dry-run|--verify-only|--uninstall]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$REPO/config/paths.env" ] && . "$REPO/config/paths.env"

AGENT_USER="${OPENCLAW_AGENT_USER:-brain}"
AGENT_HOME="/Users/${AGENT_USER}"
WORKSPACE="${OPENCLAW_WORKSPACE:-${AGENT_HOME}/.openclaw/workspace}"

SRC_DIR="${BRAIN_PROMPTS_DIR:-${BRAIN_DIR:?BRAIN_DIR is unset; config/paths.env is missing}/personal}"

# OpenClaw's injection budgets, from its own docs (concepts/agent-workspace):
#   USER.md  gets a separate, hard 4,000-character budget.
#   Others   fall under agents.defaults.bootstrapMaxChars, default 20,000.
# Oversized files are TRUNCATED at injection, not rejected -- so an over-budget
# USER.md reaches the agent as an arbitrary prefix of itself, cut mid-sentence,
# and nothing anywhere reports that. Enforced here instead.
USER_MAX_CHARS=4000
SOUL_MAX_CHARS=20000

DRY=0
MODE="install"
case "${1:-}" in
  --dry-run)     DRY=1 ;;
  --verify-only) MODE="verify" ;;
  --uninstall)   MODE="uninstall" ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

run() { if [ "$DRY" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

# Never the contents. `wc -c` on a path the shell opens, and a truncated hash
# for change detection -- enough to tell two versions apart, useless for
# reconstructing either.
describe() {
  local f=$1 chars hash
  # -m not -c: the budget is characters, and one em dash is three bytes.
  chars=$({ LC_ALL=en_US.UTF-8 wc -m < "$f" 2>/dev/null || echo 0; } | tr -d ' ')
  hash=$({ shasum -a 256 "$f" 2>/dev/null || true; } | cut -c1-12)
  printf '%s chars, sha %s' "$chars" "${hash:-unknown}"
}

installed_state() {
  local name=$1 dest="${WORKSPACE}/$1"
  if sudo -n test -f "$dest" 2>/dev/null; then
    printf '  %-9s installed (%s chars, mode %s, owner %s)\n' "$name" \
      "$({ sudo -n wc -c < "$dest" 2>/dev/null || echo '?'; } | tr -d ' ')" \
      "$({ sudo -n stat -f '%Lp' "$dest" 2>/dev/null || echo '?'; })" \
      "$({ sudo -n stat -f '%Su' "$dest" 2>/dev/null || echo '?'; })"
  elif sudo -n true 2>/dev/null; then
    printf '  %-9s NOT installed\n' "$name"
  else
    printf '  %-9s cannot tell without root\n' "$name"
  fi
}

if [ "$MODE" = "verify" ]; then
  echo "==> ${WORKSPACE}"
  installed_state SOUL.md
  installed_state USER.md
  exit 0
fi

if [ "$MODE" = "uninstall" ]; then
  sudo -v || { echo "needs sudo: the files live in ${AGENT_HOME}" >&2; exit 1; }
  for f in SOUL.md USER.md; do
    run sudo rm -f "${WORKSPACE}/${f}"
    echo "  removed ${WORKSPACE}/${f}"
  done
  echo "  the agent falls back to a generic persona on its next session."
  exit 0
fi

# ---- preflight ----

id "$AGENT_USER" >/dev/null 2>&1 || { echo "no such user: ${AGENT_USER}" >&2; exit 1; }

[ -f "${SRC_DIR}/SOUL.md" ] || {
  cat >&2 <<MSG
missing ${SRC_DIR}/SOUL.md

SOUL.md is the file that gives the assistant a purpose and a voice. Write it
first -- prompts/SOUL.md.template has the structure -- and keep it in the brain
repo, which is where personal writing belongs.
MSG
  exit 1
}

# USER.md is optional to OpenClaw: absent, it is simply omitted from the
# session rather than marked missing. Installing SOUL.md alone is a supported
# state, not a half-finished one.
HAVE_USER=0
[ -f "${SRC_DIR}/USER.md" ] && HAVE_USER=1

echo "==> sources in ${SRC_DIR}"
echo "    SOUL.md   $(describe "${SRC_DIR}/SOUL.md")"
[ "$HAVE_USER" -eq 1 ] && echo "    USER.md   $(describe "${SRC_DIR}/USER.md")" \
                       || echo "    USER.md   absent (optional; the agent gets no user context)"

# ---- budget enforcement, before anything is copied ----

soul_chars=$({ LC_ALL=en_US.UTF-8 wc -m < "${SRC_DIR}/SOUL.md" 2>/dev/null || echo 0; } | tr -d ' ')
if [ "$soul_chars" -gt "$SOUL_MAX_CHARS" ]; then
  echo "    warning: SOUL.md is ${soul_chars} chars, over the ${SOUL_MAX_CHARS} bootstrap budget." >&2
  echo "             OpenClaw will truncate it at injection. Shorten it, or raise" >&2
  echo "             agents.defaults.bootstrapMaxChars in the config template." >&2
fi

if [ "$HAVE_USER" -eq 1 ]; then
  user_chars=$({ LC_ALL=en_US.UTF-8 wc -m < "${SRC_DIR}/USER.md" 2>/dev/null || echo 0; } | tr -d ' ')
  if [ "$user_chars" -gt "$USER_MAX_CHARS" ]; then
    cat >&2 <<MSG

USER.md is ${user_chars} characters, over OpenClaw's hard ${USER_MAX_CHARS}-character budget
by $(( user_chars - USER_MAX_CHARS )).

Refusing to install it. OpenClaw would not reject this file -- it would inject
the first ${USER_MAX_CHARS} characters of it and drop the rest, cut at whatever character
that lands on, silently, every session. An arbitrary prefix of a dossier is
worse than no dossier: the agent cannot tell that it is missing the rest.

Write a trimmed USER.md for the agent and point this script at it:

  BRAIN_PROMPTS_DIR=<dir holding the trimmed copies> bash scripts/install-agent-prompts.sh

SOUL.md was not installed either. Re-run once USER.md fits, or move it aside to
install SOUL.md alone.
MSG
    exit 1
  fi
fi

if [ "$DRY" -eq 0 ]; then
  sudo -v || {
    echo "This script needs sudo: it writes into ${AGENT_HOME}." >&2
    echo "Run it from an interactive terminal." >&2
    exit 1
  }
fi

# ---- install ----

run sudo mkdir -p "$WORKSPACE"
run sudo chown "${AGENT_USER}" "$WORKSPACE"

install_one() {
  local name=$1 src="${SRC_DIR}/$1" dest="${WORKSPACE}/$1"
  echo "==> ${name} -> ${dest}"
  run sudo cp "$src" "$dest"
  run sudo chown "${AGENT_USER}" "$dest"
  # 600: the agent reads untrusted input from Telegram, and this is personal
  # writing sitting in its account. No other local user needs it.
  run sudo chmod 600 "$dest"
}

install_one SOUL.md
[ "$HAVE_USER" -eq 1 ] && install_one USER.md

[ "$DRY" -eq 1 ] && { echo; echo "  [dry-run] nothing was written."; exit 0; }

# ---- verification, including the boundary that made this script necessary ----

rc=0
echo "==> ${AGENT_USER} can read what was installed (it must)"
for f in SOUL.md $([ "$HAVE_USER" -eq 1 ] && echo USER.md); do
  if sudo -u "$AGENT_USER" test -r "${WORKSPACE}/${f}"; then
    echo "    ok: ${f}"
  else
    echo "    FAIL: ${AGENT_USER} cannot read ${WORKSPACE}/${f}"; rc=1
  fi
done

# The boundary test. This MUST fail -- that is the pass condition. Copying a
# file across it must not have opened a path through it.
echo "==> ${AGENT_USER} still cannot reach the brain repo"
if sudo -u "$AGENT_USER" test -r "${BRAIN_DIR:?}" 2>/dev/null; then
  echo "    FAIL: ${AGENT_USER} can read ${BRAIN_DIR}"; rc=1
else
  echo "    ok: refused"
fi

[ "$rc" -eq 0 ] || { echo; echo "verification failed" >&2; exit 1; }

cat <<EOF

  Done.

  No gateway restart needed: OpenClaw reads workspace files at the start of
  every session, so the next message picks them up.

  Verify:    bash scripts/install-agent-prompts.sh --verify-only
             bash scripts/health-check.sh
  Re-run:    after editing the source files. The agent's copies do not update
             themselves, and a stale copy looks exactly like a fresh one.
  Uninstall: bash scripts/install-agent-prompts.sh --uninstall

EOF
