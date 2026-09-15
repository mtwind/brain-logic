#!/usr/bin/env bash
#
# Generates the gateway auth token and stores it in the Keychain, where
# render-config.sh picks it up like every other secret here.
#
# Why not let the gateway generate its own: it offers to, but only as a runtime
# token that changes on every restart, and persisting it means
# `openclaw config set` -- the agent account rewriting its own config, which is
# the one thing the sandbox design forbids. Rendering it from the owner's
# Keychain keeps the direction of control the same as the Telegram token.
#
# On `ps` exposure: `security` will not read a password from stdin, so the
# value passes through argv and is briefly visible to `ps`. The only other
# account on this machine is the agent, which receives this exact token in its
# config file anyway -- so this leaks it to nobody who does not already hold it.
# That reasoning does not survive a third local account; revisit if one appears.
#
# Usage: bash scripts/new-gateway-token.sh [--force]
set -euo pipefail

SERVICE="brain/gateway-token"
FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

# `|| true` is load-bearing: security exits 1 when the item does not exist, and
# under `set -euo pipefail` that status propagates out of the assignment and
# kills the script silently -- before it can create the item it exists to
# create. The first version printed nothing at all on exactly the machine it
# was written for.
existing_len=$({ security find-generic-password -a "$USER" -s "$SERVICE" -w 2>/dev/null || true; } | tr -d '\n' | wc -c | tr -d ' ')
if [ "${existing_len:-0}" -ge 32 ] && [ "$FORCE" -eq 0 ]; then
  echo "${SERVICE} already exists (length ${existing_len}). Nothing to do."
  echo "Rotate it with: bash scripts/new-gateway-token.sh --force"
  echo "After rotating, re-run: bash scripts/install-openclaw-config.sh"
  exit 0
fi

# 48 chars from urandom. Never printed.
#
# Note the shape: a bounded `head -c` reads FIRST and `cut` finishes the
# pipeline. The obvious spelling -- `tr -dc ... </dev/urandom | head -c 48` --
# makes head exit as soon as it has 48 bytes, tr dies on SIGPIPE, and pipefail
# turns that into a fatal 141. cut consumes its whole input, so nothing gets a
# broken pipe. (The runbook uses the tr|head spelling in an interactive shell,
# where there is no `set -e` to make it fatal.)
token="$(head -c 512 /dev/urandom | LC_ALL=C base64 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c 1-48)"
[ "${#token}" -eq 48 ] || { echo "token generation failed" >&2; exit 1; }

# -U updates in place. A plain add refuses when the item already exists, which
# is how the Telegram item ended up empty once already.
security add-generic-password -a "$USER" -s "$SERVICE" -w "$token" -U
unset token

stored_len=$({ security find-generic-password -a "$USER" -s "$SERVICE" -w 2>/dev/null || true; } | tr -d '\n' | wc -c | tr -d ' ')
[ "${stored_len:-0}" -eq 48 ] || { echo "stored item is ${stored_len:-0} chars, expected 48" >&2; exit 1; }

echo "stored ${SERVICE} (length ${stored_len}, value not printed)"
echo "Next: bash scripts/install-openclaw-config.sh"
