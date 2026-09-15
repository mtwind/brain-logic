#!/usr/bin/env bash
# Switch Postgres to socket-only peer authentication.
#
# Why: the default Homebrew pg_hba trusts every local connection, so any local
# OS user could connect as any role -- including the superuser that owns the
# gbrain database, in a server process running as the desktop user. That makes
# `pg_read_file()` and `COPY ... FROM PROGRAM` reachable from the sandboxed
# agent account, which defeats both the mode-700 brain repo and the sandbox
# itself. See docs/decision-log.md.
#
# After this runs: the OS user IS the credential (peer), there is no password
# to store or leak, and there is no TCP path at all. The agent account has no
# role in this cluster; it reaches the brain only through `gbrain serve`.
#
# Idempotent. Pass --dry-run to see the diff without changing anything.
set -euo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

command -v psql >/dev/null || { echo "psql not found" >&2; exit 1; }
pg_isready -q || { echo "postgres is not accepting connections; start it first" >&2; exit 1; }

HBA=$(psql -d postgres -tAc "show hba_file;")
[ -f "$HBA" ] || { echo "cannot find pg_hba.conf (got: $HBA)" >&2; exit 1; }

read -r -d '' DESIRED <<'CONF' || true
# Managed by scripts/harden-postgres-auth.sh -- do not hand-edit.
# Rationale in docs/decision-log.md, "Postgres: socket-only peer auth".
#
# Local socket only. peer maps the OS user to the role of the same name, so
# identity is enforced by the kernel rather than by a shared secret. TCP is
# rejected explicitly rather than omitted, so a refused connection says
# "pg_hba rejected you" instead of looking like the server is down.
#
# TYPE  DATABASE     USER  ADDRESS         METHOD
local   all          all                   peer
host    all          all   127.0.0.1/32    reject
host    all          all   ::1/128         reject
local   replication  all                   peer
host    replication  all   127.0.0.1/32    reject
host    replication  all   ::1/128         reject
CONF

if diff -q <(printf '%s\n' "$DESIRED") "$HBA" >/dev/null 2>&1; then
  echo "already hardened: $HBA"
  exit 0
fi

echo "==> target: $HBA"
echo "==> diff (current -> desired):"
diff -u "$HBA" <(printf '%s\n' "$DESIRED") || true

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "--dry-run: nothing changed."
  exit 0
fi

# PREFLIGHT. Learned by locking gbrain out with this exact script: a client
# that cannot use a Unix socket loses its database the moment this applies.
#
# gbrain 0.46 had no socket path at all. gbrain 0.48 does, but only via the
# environment -- its client (postgres.js) reads PGHOST and does NOT honour
# ?host= in the URL, which it forwards to the server as a startup option
# ("unrecognized configuration parameter \"host\""). The working combination,
# verified by observing pg_stat_activity.client_addr rather than trusting a
# green check:
#
#   gbrain config set database_url 'postgresql:///gbrain'
#   export PGHOST=/tmp            # config/paths.env exports this
#
# Confirm before running. A connection that merely succeeds proves nothing
# while TCP is still trusted -- it must show as NULL client_addr:
#
#   ( gbrain doctor >/dev/null 2>&1 & )
#   psql -d postgres -tAc "select coalesce(host(client_addr)::text,'NULL-socket')
#        from pg_stat_activity where datname='gbrain';"
#
if [ "${ASSUME_SOCKET_CLIENTS_OK:-0}" != "1" ]; then
  echo >&2
  echo "REFUSING: socket-only auth breaks any client that cannot use a Unix socket." >&2
  echo "gbrain 0.46 is one such client -- see the preflight comment in this script." >&2
  echo "Re-verify, then re-run with ASSUME_SOCKET_CLIENTS_OK=1." >&2
  exit 1
fi

BACKUP="${HBA}.backup-$(date +%Y%m%d-%H%M%S)"
cp "$HBA" "$BACKUP"
echo "==> backed up to $BACKUP"

printf '%s\n' "$DESIRED" > "$HBA"
chmod 600 "$HBA"

echo "==> reloading"
psql -d postgres -tAc "select pg_reload_conf();" >/dev/null

# Verify both directions. A guard you have not watched fire is one you are
# guessing about -- and a failed TCP connect must be distinguishable from the
# server simply being down.
echo "==> verifying socket access still works"
psql "postgresql:///postgres?host=/tmp" -tAc "select 'socket ok as '||current_user;" \
  || { echo "SOCKET ACCESS BROKE -- restoring $BACKUP" >&2; cp "$BACKUP" "$HBA"; psql -d postgres -tAc "select pg_reload_conf();" >/dev/null; exit 1; }

echo "==> verifying TCP is refused by pg_hba (not by the server being down)"
if err=$(psql "postgresql://127.0.0.1:5432/postgres" -tAc "select 1;" 2>&1); then
  echo "TCP STILL ALLOWED -- restoring $BACKUP" >&2
  cp "$BACKUP" "$HBA"; psql -d postgres -tAc "select pg_reload_conf();" >/dev/null
  exit 1
fi
case "$err" in
  *"pg_hba.conf rejects"*) echo "    refused by pg_hba, as intended" ;;
  *) echo "TCP failed, but not via pg_hba -- inconclusive, check manually:" >&2
     echo "$err" >&2; exit 1 ;;
esac

echo "==> no login role for the agent account:"
psql -d postgres -tAc "select coalesce(string_agg(rolname,','),'(none)') from pg_roles where rolcanlogin and rolname <> current_user;"

echo "done."
