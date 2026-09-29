#!/usr/bin/env bash
#
# Mints the bearer token the assistant uses to query GBrain, straight into the
# Keychain. The value is never printed and never lands in a file.
#
# The token is scoped `read` at mint time. gbrain's HTTP server checks that
# scope on every tools/list and tools/call, so a token minted here cannot
# reach put_page, delete_page, add_timeline_entry or submit_agent even if the
# client asks for them by name. A token minted WITHOUT --scopes is
# "grandfathered" to full access -- which is why this script exists instead
# of a one-liner in the runbook.
#
# Direction of control is the same as the gateway token: the owner mints, the
# agent receives a rendered copy in its config. The agent account has no
# Postgres role and cannot mint or revoke tokens itself.
#
# Usage: bash scripts/new-gbrain-token.sh [--force|--dry-run]
#   --force   revoke every active token of this name and mint a fresh one
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$REPO/config/paths.env" ] && . "$REPO/config/paths.env"   # exports PGHOST

ITEM="brain/gbrain-token"
# The token's name inside gbrain (`gbrain auth list`). Says what it is for.
NAME="${GBRAIN_TOKEN_NAME:-openclaw-search}"

DRY=0
FORCE=0
case "${1:-}" in
  --force)   FORCE=1 ;;
  --dry-run) DRY=1 ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

command -v gbrain >/dev/null 2>&1 || { echo "gbrain is not on PATH" >&2; exit 1; }

# Length, never the value. An empty item is what Enter at the prompt creates.
kc_len() {
  { security find-generic-password -a "$USER" -s "$ITEM" -w 2>/dev/null || true; } \
    | tr -d '\n' | wc -c | tr -d ' '
}

# Active rows of this name in the database. `gbrain auth list` prints a table
# with a Status column; anything not "revoked" is live.
db_active() {
  { gbrain auth list 2>/dev/null || true; } \
    | { grep -E "^[0-9a-f-]{36}  ${NAME} " || true; } \
    | { grep -vc revoked || true; }
}

have_len="$(kc_len)"
have_db="$(db_active)"

if [ "$FORCE" -eq 0 ]; then
  if [ "${have_len:-0}" -ge 20 ] && [ "${have_db:-0}" -ge 1 ]; then
    echo "Keychain item ${ITEM} exists (length ${have_len}) and gbrain has an active token named \"${NAME}\"."
    echo "Nothing to do. Use --force to revoke and re-mint."
    exit 0
  fi
  if [ "${have_db:-0}" -ge 1 ]; then
    echo "gbrain has an active token named \"${NAME}\" but the Keychain item ${ITEM} is missing or empty." >&2
    echo "The plaintext is gone -- it prints once at mint time. Re-run with --force to revoke and re-mint." >&2
    exit 1
  fi
  if [ "${have_len:-0}" -ge 20 ]; then
    echo "Keychain item ${ITEM} exists (length ${have_len}) but gbrain has no active token named \"${NAME}\"." >&2
    echo "The stored value is orphaned. Re-run with --force to mint a fresh one." >&2
    exit 1
  fi
fi

if [ "$DRY" -eq 1 ]; then
  cat <<MSG
  [dry-run] gbrain auth revoke "${NAME}"           (only with --force; ${have_db:-0} active now)
  [dry-run] gbrain auth create "${NAME}" --scopes read
  [dry-run] security add-generic-password -a "\$USER" -s ${ITEM} -w <token> -U
  [dry-run] then: bash scripts/install-openclaw-config.sh  (renders it into the agent's config)
MSG
  exit 0
fi

if [ "$FORCE" -eq 1 ] && [ "${have_db:-0}" -ge 1 ]; then
  echo "==> revoking ${have_db} active token(s) named \"${NAME}\""
  gbrain auth revoke "$NAME" >/dev/null
fi

echo "==> minting \"${NAME}\" with scope: read"
# stdout carries the token on its own indented line, once. Captured, parsed,
# stored; never echoed. `sed -n 1p` reads to EOF, unlike head, so the producer
# cannot die on SIGPIPE under pipefail.
out="$(gbrain auth create "$NAME" --scopes read 2>&1)" || {
  printf '%s\n' "$out" | sed -E 's/gbrain_[A-Za-z0-9_-]+/<token>/g' >&2
  exit 1
}
token="$(printf '%s\n' "$out" | { grep -E '^  gbrain_[A-Za-z0-9_-]+$' || true; } | sed -n '1p' | tr -d ' ')"
if [ -z "$token" ]; then
  echo "could not find the token in gbrain's output; nothing stored. Output (redacted):" >&2
  printf '%s\n' "$out" | sed -E 's/gbrain_[A-Za-z0-9_-]+/<token>/g' >&2
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'scopes=\["read"\]'; then
  echo "gbrain did not confirm scopes=[\"read\"]; revoking what was just minted." >&2
  gbrain auth revoke "$NAME" >/dev/null || true
  exit 1
fi

# -U overwrites in place; plain add refuses when the item exists. The value
# passes through argv and is briefly visible to `ps` -- same accepted trade as
# the gateway token (decision log, 2026-09-05): the only other account here is
# the agent, which receives this same token in its config.
security add-generic-password -a "$USER" -s "$ITEM" -w "$token" -U
unset token out

new_len="$(kc_len)"
[ "${new_len:-0}" -ge 20 ] || { echo "Keychain write failed (length ${new_len:-0})" >&2; exit 1; }

cat <<MSG

  Stored ${ITEM} in the login Keychain (length ${new_len}); gbrain token "${NAME}", scope read.

  It does nothing until it is rendered into the agent's config:
    bash scripts/install-openclaw-config.sh
    bash scripts/install-gateway-daemon.sh

  Rotate:  bash scripts/new-gbrain-token.sh --force   (then the two commands above)
  Inspect: gbrain auth list
MSG
