#!/usr/bin/env bash
#
# Renders openclaw.json here (where the template and the Keychain item live)
# and installs it into the sandboxed agent account.
#
# Why this shape: /Users/<you> is mode 750, so the agent account cannot reach
# this repo at all, and Keychain items are per-user so it cannot read the
# Telegram token either. The alternatives were to open up the home directory
# or to store a second copy of the secret in the agent's Keychain. Both widen
# the blast radius to solve a one-file delivery problem. So: render on this
# side, hand over only the rendered file, mode 600 owned by the agent.
#
# Re-run this whenever config/openclaw.json.template changes. The agent account
# has no way to re-render on its own, by design.
#
# Usage: bash scripts/install-openclaw-config.sh [--dry-run|--verify-only]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$REPO/config/paths.env" ] && . "$REPO/config/paths.env"

AGENT_USER="${OPENCLAW_AGENT_USER:-brain}"
AGENT_HOME="/Users/${AGENT_USER}"
DEST="${AGENT_HOME}/.openclaw/openclaw.json"
TEMPLATE="${REPO}/config/openclaw.json.template"
STAGING_DIR=""
STAGING=""

MODE="install"
case "${1:-}" in
  --dry-run)     MODE="dry" ;;
  --verify-only) MODE="verify" ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

id "$AGENT_USER" >/dev/null 2>&1 || { echo "no such user: $AGENT_USER" >&2; exit 1; }

verify() {
  local rc=0
  echo "==> config is present and readable by ${AGENT_USER}"
  sudo -u "$AGENT_USER" test -r "$DEST" \
    && echo "    ok" || { echo "    FAIL: ${AGENT_USER} cannot read $DEST"; rc=1; }

  echo "==> permissions"
  sudo stat -f '    %Sp  %Su:%Sg  %N' "$DEST" 2>/dev/null || rc=1

  # Confirm substitution happened WITHOUT printing the token, and that the
  # settings the gateway refuses to start without are present.
  echo "==> config is startable (token itself never printed)"
  if sudo -u "$AGENT_USER" python3 - "$DEST" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1]))
ok = True

t = cfg.get("channels", {}).get("telegram", {}).get("botToken", "")
if t and "${" not in t and len(t) > 20:
    print("    ok: botToken present, length %d" % len(t))
else:
    print("    FAIL: placeholder not substituted")
    ok = False

h = cfg.get("mcp", {}).get("servers", {}).get("gbrain", {}).get("headers", {}).get("Authorization", "")
if h.startswith("Bearer ") and "${" not in h and len(h) > 27:
    print("    ok: gbrain MCP bearer present, length %d" % (len(h) - 7))
else:
    print("    FAIL: mcp.servers.gbrain Authorization header not substituted")
    ok = False

mode = cfg.get("gateway", {}).get("mode")
if mode in ("local", "remote"):
    print("    ok: gateway.mode=%s" % mode)
else:
    print("    FAIL: gateway.mode is %r -- the gateway exits 78 without it" % mode)
    ok = False

sys.exit(0 if ok else 1)
PY
  then :; else rc=1; fi

  # The boundary tests. These MUST fail -- that is the pass condition.
  echo "==> ${AGENT_USER} still cannot reach the brain repo"
  if sudo -u "$AGENT_USER" test -r "${BRAIN_DIR:?}" 2>/dev/null; then
    echo "    FAIL: ${AGENT_USER} can read ${BRAIN_DIR}"; rc=1
  else
    echo "    ok: refused"
  fi

  echo "==> ${AGENT_USER} still cannot reach Postgres"
  if sudo -u "$AGENT_USER" psql -d "${BRAIN_DB_NAME:-gbrain}" -tAc 'select 1' >/dev/null 2>&1; then
    echo "    FAIL: ${AGENT_USER} connected to the database"; rc=1
  else
    echo "    ok: refused"
  fi

  echo "==> ${AGENT_USER} can reach Ollama (it must)"
  if sudo -u "$AGENT_USER" curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    echo "    ok"
  else
    echo "    FAIL: ${AGENT_USER} cannot reach Ollama on 127.0.0.1:11434"; rc=1
  fi

  # The agent's only route to the brain is gbrain's MCP server on loopback,
  # run as the owner (scripts/install-gbrain-mcp-agent.sh). It must be
  # reachable, and it must refuse a call that carries no token: the boundary
  # is the token, and 401 is what proves it is being checked.
  local mcp_port="${GBRAIN_MCP_PORT:-3131}" code
  echo "==> ${AGENT_USER} can reach the GBrain MCP server on 127.0.0.1:${mcp_port} (it must)"
  if sudo -u "$AGENT_USER" curl -fsS -m 5 "http://127.0.0.1:${mcp_port}/health" >/dev/null 2>&1; then
    echo "    ok"
  else
    echo "    FAIL: ${AGENT_USER} cannot reach /health on 127.0.0.1:${mcp_port}"
    echo "    bash scripts/install-gbrain-mcp-agent.sh --status"; rc=1
  fi
  echo "==> the MCP server refuses ${AGENT_USER} without the token"
  code=$({ sudo -u "$AGENT_USER" curl -sS -m 5 -o /dev/null -w '%{http_code}' \
            -X POST "http://127.0.0.1:${mcp_port}/mcp" -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>/dev/null || true; })
  if [ "$code" = "401" ]; then
    echo "    ok: 401"
  else
    echo "    FAIL: expected 401 without a token, got '${code:-no answer}'"; rc=1
  fi

  return $rc
}

# Verify and install both read a mode-600 file owned by brain, so both need
# sudo. Without a cached credential `sudo -u brain test -r` simply fails, and
# the report reads "brain cannot read the config" / "brain cannot reach Ollama"
# -- a diagnosis pointing at the sandbox boundary when the real cause is a
# missing password. Same shape install-gateway-daemon.sh preflights against.
# --dry-run touches nothing and is exempt, so it can run unattended.
need_sudo() {
  if ! sudo -v; then
    echo >&2
    echo "This script needs sudo: it reads and writes ${DEST} inside ${AGENT_HOME}." >&2
    echo "Run it from an interactive terminal." >&2
    exit 1
  fi
}

if [ "$MODE" = "verify" ]; then need_sudo; verify; exit $?; fi

[ -f "$TEMPLATE" ] || { echo "missing template: $TEMPLATE" >&2; exit 1; }
# Presence is not enough. `security add-generic-password` with Enter at the
# prompt creates a real item holding an empty string, and a second attempt to
# add it fails with "item already exists" rather than overwriting -- so it is
# easy to end up with an empty token and no error until render time. Check the
# length, never the value.
_tok_len=$({ security find-generic-password -a "$USER" -s brain/telegram-token -w 2>/dev/null || true; } | tr -d '\n' | wc -c | tr -d ' ')
if [ "${_tok_len:-0}" -lt 20 ]; then
  echo "Keychain item brain/telegram-token is missing or empty (length ${_tok_len:-0})." >&2
  echo "An empty item is what you get from pressing Enter at the password prompt." >&2
  echo "Overwrite it in place -- plain add refuses when the item exists:" >&2
  echo "  security add-generic-password -a \"\$USER\" -s brain/telegram-token -w -U" >&2
  exit 1
fi
unset _tok_len

# Same check for the GBrain token. Without it the render fails later with a
# less helpful message; with an empty one the gateway would connect, get 401
# on every search, and the assistant would loop on a tool that always errors.
_tok_len=$({ security find-generic-password -a "$USER" -s brain/gbrain-token -w 2>/dev/null || true; } | tr -d '\n' | wc -c | tr -d ' ')
if [ "${_tok_len:-0}" -lt 20 ]; then
  echo "Keychain item brain/gbrain-token is missing or empty (length ${_tok_len:-0})." >&2
  echo "Mint it with:  bash scripts/new-gbrain-token.sh" >&2
  exit 1
fi
unset _tok_len

if [ "$MODE" = "dry" ]; then
  cat <<EOF
  [dry-run] render  $TEMPLATE
            ->      a private temp dir (mode 700), never $HOME
  [dry-run] sudo install -d -o $AGENT_USER -g staff -m 700 ${AGENT_HOME}/.openclaw
  [dry-run] sudo install -o $AGENT_USER -g staff -m 600 \$STAGING $DEST
  [dry-run] shred staging file
  [dry-run] then run the verification block
EOF
  exit 0
fi

need_sudo

# A private directory, not $HOME: openclaw derives its state root from the
# directory holding the config, so linting a staging file in the home directory
# invites it to reason about paths there. The token never lands in $HOME.
STAGING_DIR="$(mktemp -d)"
chmod 700 "$STAGING_DIR"
STAGING="${STAGING_DIR}/openclaw.json"
trap 'rm -rf "$STAGING_DIR"' EXIT
echo "==> rendering"
( cd "$REPO" && bash scripts/render-config.sh "$TEMPLATE" "$STAGING" ) >/dev/null
chmod 600 "$STAGING"

# Carry forward the keys the RUNTIME owns, not the template.
#
# `openclaw pairing approve` writes commands.ownerAllowFrom into the installed
# config -- so the agent account can modify its own config after all, which the
# 2026-09-02 entry assumed it could not. Re-rendering would silently drop the
# command owner and de-authorize the operator account for privileged commands.
# The template cannot hold it either: it is a Telegram account id, discovered at
# pairing time, and personal data that does not belong in the repo.
if sudo test -f "$DEST"; then
  echo "==> carrying forward runtime-owned keys from the installed config"
  # Both configs go in as arguments. A heredoc already occupies stdin here --
  # `python3 - file <<'PY'` feeds the SCRIPT on stdin, so a piped config never
  # arrives and json.load reads the script text instead.
  sudo cat "$DEST" > "${STAGING_DIR}/installed.json"
  chmod 600 "${STAGING_DIR}/installed.json"
  python3 - "${STAGING_DIR}/installed.json" "$STAGING" <<'PY'
import json, sys

PRESERVE = ("commands",)

installed = json.load(open(sys.argv[1]))
rendered = json.load(open(sys.argv[2]))

kept = []
for key in PRESERVE:
    if key in installed and key not in rendered:
        rendered[key] = installed[key]
        kept.append(key)

with open(sys.argv[2], "w") as fh:
    json.dump(rendered, fh, indent=2)
    fh.write("\n")

print("    kept: %s" % ", ".join(kept) if kept else "    nothing to carry forward")
PY
  rm -f "${STAGING_DIR}/installed.json"
fi

# Validate BEFORE installing. A config the gateway rejects does not produce an
# error you see -- it produces a launchd crash loop with the reason buried in a
# log file in another user's home.
#
# The authority here is openclaw itself. A hand-maintained list of required
# keys is always one release behind, and the first version of this check passed
# a config with three separate schema violations in it: a model-level "think",
# an invented root-level "approval" block, and channels.telegram.token, which
# is spelled botToken. Each would have cost another crash loop to find.
echo "==> validating rendered config"

if command -v openclaw >/dev/null 2>&1; then
  lint="$(OPENCLAW_CONFIG_PATH="$STAGING" openclaw doctor --lint \
            --only core/doctor/gateway-config 2>&1 || true)"
  if ! printf '%s' "$lint" | grep -q '"ok":true'; then
    echo "    FAIL: openclaw rejects this config" >&2
    printf '%s\n' "$lint" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    for f in json.loads(raw).get("findings", []):
        sys.stderr.write("      %s: %s\n" % (f.get("path", "config"), f.get("message", "")))
except Exception:
    sys.stderr.write("      " + raw + "\n")
'
    echo "    Fix config/openclaw.json.template, not the installed file." >&2
    exit 1
  fi
  echo "    ok: openclaw doctor --lint accepts it"
else
  echo "    WARNING: openclaw not on PATH; schema not checked" >&2
fi

# openclaw cannot know whether the token is the real one or an unsubstituted
# placeholder -- both are strings. Checked here, never printed.
python3 - "$STAGING" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1]))
tok = cfg.get("channels", {}).get("telegram", {}).get("botToken", "")
if not tok or "${" in tok or len(tok) <= 20:
    sys.stderr.write("    FAIL: botToken looks unsubstituted\n")
    sys.exit(1)
print("    ok: botToken substituted (length %d), gateway.mode=%s bind=%s" % (
    len(tok), cfg["gateway"]["mode"], cfg["gateway"].get("bind", "(default)")))
PY

echo "==> installing into ${AGENT_HOME}/.openclaw (sudo)"
sudo install -d -o "$AGENT_USER" -g staff -m 700 "${AGENT_HOME}/.openclaw"
sudo install -o "$AGENT_USER" -g staff -m 600 "$STAGING" "$DEST"
rm -f "$STAGING"

echo
verify
