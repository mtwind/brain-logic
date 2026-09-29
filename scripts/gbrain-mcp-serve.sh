#!/usr/bin/env bash
#
# What the com.personalbrain.gbrain-mcp LaunchAgent actually runs: gbrain's
# HTTP MCP server, as the owner, on loopback only.
#
# Why a wrapper and not the binary in the plist: gbrain is a bun script and
# needs bun on PATH; it needs PGHOST=/tmp to reach Postgres over the socket
# (config/paths.env is the one place that is defined); and the flags below are
# the security posture, which belongs in a reviewed file, not in a plist that
# the installer regenerates.
#
# Why this runs as the owner and not as `brain`: the agent account has no
# Postgres role, by design (decision log, 2026-09-02). The gateway reaches
# this server over 127.0.0.1 with a read-scoped bearer token; it never
# touches the database.
#
#   --bind 127.0.0.1   loopback only. Also the default since gbrain 0.34.1,
#                      set explicitly so a default change cannot widen it.
#   --surface starter  the ~20-op daily set, the narrowest surface that
#                      contains `search`. Per-token scope narrows further
#                      (read only), and the OpenClaw side exposes one tool.
#   --suppress-bootstrap-token
#                      never print the /admin bootstrap token. With no
#                      GBRAIN_ADMIN_BOOTSTRAP_TOKEN set, a random one is
#                      generated per start and shown to nobody, so the admin
#                      UI is unreachable. That is the intent.
#
# Not for interactive use; run scripts/install-gbrain-mcp-agent.sh instead.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$REPO/config/paths.env"          # exports PGHOST; sets GBRAIN_MCP_PORT

# launchd starts with a bare PATH. bun's global bin holds gbrain; Homebrew
# holds bun and psql.
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

command -v gbrain >/dev/null 2>&1 || { echo "gbrain-mcp-serve: gbrain is not on PATH ($PATH)" >&2; exit 78; }
[ -n "${PGHOST:-}" ] || { echo "gbrain-mcp-serve: PGHOST is unset; refusing to start (would fall back to TCP, which pg_hba rejects)" >&2; exit 78; }

exec gbrain serve --http \
  --port "${GBRAIN_MCP_PORT:-3131}" \
  --bind 127.0.0.1 \
  --surface starter \
  --suppress-bootstrap-token
