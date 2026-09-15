#!/usr/bin/env bash
# Renders config templates into ~/.openclaw, pulling secrets from the Keychain.
# The rendered file never enters a repo.
set -euo pipefail

TEMPLATE="${1:-config/openclaw.json.template}"
DEST="${2:-$HOME/.openclaw/openclaw.json}"

kc() { security find-generic-password -a "$USER" -s "$1" -w 2>/dev/null || true; }

TELEGRAM_TOKEN=$(kc brain/telegram-token)
[ -n "$TELEGRAM_TOKEN" ] || { echo "missing keychain item: brain/telegram-token" >&2; exit 1; }
export TELEGRAM_TOKEN

GATEWAY_TOKEN=$(kc brain/gateway-token)
[ -n "$GATEWAY_TOKEN" ] || {
  echo "missing keychain item: brain/gateway-token" >&2
  echo "Create it with: bash scripts/new-gateway-token.sh" >&2
  exit 1
}
export GATEWAY_TOKEN

mkdir -p "$(dirname "$DEST")"

# Two passes:
#   1. Only substitute the vars we explicitly name, so nothing else gets mangled.
#   2. Drop every "// ..." key.
#
# OpenClaw validates its config strictly and rejects unrecognized keys, so the
# documentation keys that make the template readable are exactly what stops the
# rendered file from loading. Stripping them here keeps the notes next to the
# values they explain -- the "/v1 breaks tool calling" warning is worth more in
# the template than in a doc nobody opens -- while the agent receives clean
# JSON. The template stays strict JSON rather than JSON5 comments so it can be
# parsed and checked by the installer before it is handed over.
umask 077
envsubst '${TELEGRAM_TOKEN} ${GATEWAY_TOKEN}' < "$TEMPLATE" | python3 -c '
import json, sys

def strip(node):
    if isinstance(node, dict):
        return {k: strip(v) for k, v in node.items() if not k.startswith("//")}
    if isinstance(node, list):
        return [strip(v) for v in node]
    return node

json.dump(strip(json.load(sys.stdin)), sys.stdout, indent=2)
sys.stdout.write("\n")
' > "$DEST"
chmod 600 "$DEST"
echo "rendered $DEST (mode 600)"
