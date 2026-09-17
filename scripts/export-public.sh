#!/usr/bin/env bash
#
# Builds the public mirror of this repo: a curated copy with fresh history.
#
# The rule since 2026-08-18 is that this repo is never flipped public in place.
# Its history has carried the owner's username, account ids and machine name,
# and a history is published whole or not at all. So the public repo is a
# THIRD repo: an allowlisted subset of committed files, scanned twice, landing
# as ordinary commits in a repo that has never held anything else. Re-running
# this after changes here adds a commit there; the public history is a series
# of snapshots, never this repo's log.
#
# One thing neither scan can see: GitHub's own push protection matches
# provider secret formats (AWS keys, real PATs) regardless of any allowlist
# here. Synthetic test values in the docs must trip gitleaks and nothing
# upstream -- see RUNBOOK.md step 6.
#
# Two scans, both fatal:
#   1. gitleaks over the staged tree, same rules as the pre-commit hook.
#   2. Identifiers: the owner's username, home path, hostnames, git author
#      name and email, plus any line in config/export-denylist.local
#      (gitignored, because a list of your identifiers is itself one; entries
#      are literal substrings, so a username that is a prefix of something
#      public -- a GitHub handle, say -- needs its context: `user@`, not `user`). These
#      are derived from the machine at run time, so nothing personal is
#      written into this script.
#
# It never pushes. The push is one `gh` command, printed at the end, and it is
# the owner's to run.
#
# Usage: bash scripts/export-public.sh [--dry-run] [--out DIR] [--author "Name <email>"]
#
#   --dry-run   stage and scan in a temp dir, report, write nothing to --out
#   --out       the public repo's working copy (default: $BRAIN_PUBLIC_DIR,
#               else ~/Code/brain-logic-public). Created on first run;
#               synced and committed on later runs.
#   --author    commit identity. Default: your GitHub noreply address via
#               `gh`, so the public history does not carry your real email.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${BRAIN_PUBLIC_DIR:-$HOME/Code/brain-logic-public}"
AUTHOR=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --out)     OUT="${2:?--out needs a directory}"; shift ;;
    --author)  AUTHOR="${2:?--author needs \"Name <email>\"}"; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---- What ships -------------------------------------------------------------
#
# An allowlist, not a denylist: a new file is excluded until someone decides
# otherwise. Only COMMITTED content is staged (git archive HEAD), so an edit
# that has not been reviewed on a branch cannot leak through the working tree.
INCLUDE=(
  CLAUDE.md README.md RUNBOOK.md LICENSE
  .gitignore .gitattributes .gitleaks.toml
  config/paths.env
  config/openclaw.json.template
  config/gbrain.config.template.json
  cron docs prompts scripts githooks
)
# Committed, allowlisted by directory, and still not shipped:
#   HANDOFF.md               state of THIS machine: what is running, who is paired
#   scripts/brain-setup.conf real configuration; brain-setup.conf.example ships
# githooks/ ships whole, pre-push included: a reader building their own
# private copy wants the hook that refuses third-party hosts. The mirror
# itself never activates the hooks (see below), so it can push to GitHub.
EXCLUDE=(
  HANDOFF.md
  scripts/brain-setup.conf
)

# ---- Preflight ----------------------------------------------------------------

cd "$REPO"
for tool in git gitleaks rsync; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool" >&2; exit 1; }
done
if [ -n "$(git status --porcelain)" ]; then
  echo "note: working tree has uncommitted changes; only HEAD is exported." >&2
fi
SRC_SHA="$(git rev-parse --short HEAD)"
SRC_BRANCH="$(git branch --show-current)"

STAGE="$(mktemp -d)"
chmod 700 "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

# ---- Stage ------------------------------------------------------------------------

git archive --format=tar HEAD -- "${INCLUDE[@]}" | tar -x -C "$STAGE"
for f in "${EXCLUDE[@]}"; do rm -f "${STAGE:?}/$f"; done
# git archive materialises empty parents for excluded files; drop them.
find "$STAGE" -type d -empty -delete

echo "==> staged $(find "$STAGE" -type f | wc -l | tr -d ' ') files from ${SRC_BRANCH}@${SRC_SHA}"
( cd "$STAGE" && find . -type f | sort | sed 's|^\./|    |' )
echo "    excluded: ${EXCLUDE[*]}"

# ---- Scan 1: secrets ----------------------------------------------------------------
#
# A whole-tree scan, unlike the pre-commit hook's staged-hunks scan. The
# runbook's synthetic credentials are allowlisted by value in .gitleaks.toml.
echo "==> gitleaks"
if ! ( cd "$STAGE" && gitleaks dir . --no-banner --redact --config .gitleaks.toml ); then
  echo "REFUSED: gitleaks found something in the staged tree." >&2
  exit 1
fi

# ---- Scan 2: identifiers ---------------------------------------------------------------
#
# Derived at run time. Short values (under 4 chars) are skipped: a two-letter
# name would match everything. Matching is case-insensitive and literal.
echo "==> identifiers"
idents=()
add_ident() {
  local v="${1:-}"
  v="${v//$'\n'/}"
  [ "${#v}" -ge 4 ] || return 0
  idents+=("$v")
}
add_ident "$USER"
add_ident "$HOME"
add_ident "$(hostname -s 2>/dev/null || true)"
add_ident "$(hostname 2>/dev/null || true)"
add_ident "$(scutil --get ComputerName 2>/dev/null || true)"
add_ident "$(scutil --get LocalHostName 2>/dev/null || true)"
add_ident "$(git config user.name 2>/dev/null || true)"
add_ident "$(git config user.email 2>/dev/null || true)"
if [ -f "$REPO/config/export-denylist.local" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    add_ident "$line"
  done < "$REPO/config/export-denylist.local"
fi

hits=0
for v in "${idents[@]}"; do
  # grep exits 1 on no match, which is the result we want, not an error.
  found="$( { cd "$STAGE" && grep -rniF -e "$v" . || true; } | cut -c1-160 )"
  if [ -n "$found" ]; then
    echo "    '$v' appears:"
    printf '%s\n' "$found" | sed 's|^\./|      |'
    hits=1
  fi
done
if [ "$hits" -ne 0 ]; then
  echo "REFUSED: the staged tree names the owner or the machine. Fix the source, not the export." >&2
  exit 1
fi
echo "    none of ${#idents[@]} identifiers found"

[ -f "$STAGE/LICENSE" ] || echo "note: no LICENSE file. A public repo without one grants nobody anything; the choice is yours." >&2

if [ "$DRY" -eq 1 ]; then
  echo "[dry-run] would sync the staged tree into $OUT and commit. Nothing written."
  exit 0
fi

# ---- Commit identity --------------------------------------------------------------
#
# The default is the GitHub noreply address, so the public history carries
# the account, not the mailbox. Without gh, fall back to git's identity and
# say so: it is about to become public.
if [ -z "$AUTHOR" ]; then
  name="$(git config user.name 2>/dev/null || true)"
  gh_login="$( { gh api user --jq '.login' 2>/dev/null || true; } | tr -d '\n' )"
  gh_id="$( { gh api user --jq '.id' 2>/dev/null || true; } | tr -d '\n' )"
  if [ -n "$gh_login" ] && [ -n "$gh_id" ]; then
    AUTHOR="${name:-$gh_login} <${gh_id}+${gh_login}@users.noreply.github.com>"
  else
    AUTHOR="${name} <$(git config user.email 2>/dev/null || true)>"
    echo "note: gh is not signed in; commits will carry your git email, which is about to be public." >&2
  fi
fi

# ---- Sync and commit ---------------------------------------------------------------

if [ -d "$OUT/.git" ]; then
  echo "==> syncing into existing public repo at $OUT"
else
  echo "==> creating public repo at $OUT"
  mkdir -p "$OUT"
  git -C "$OUT" init -q -b main
fi
rsync -a --delete --exclude '.git' "$STAGE/" "$OUT/"
# core.hooksPath is deliberately NOT set in the mirror: its pre-push hook
# would refuse the one push it exists for, and its pre-commit gate is already
# applied here, to the whole tree, before every commit it receives.
git -C "$OUT" config --unset core.hooksPath 2>/dev/null || true

git -C "$OUT" add -A
if git -C "$OUT" diff --cached --quiet; then
  echo "    nothing changed since the last export"
else
  git -C "$OUT" -c user.name="${AUTHOR%% <*}" -c user.email="${AUTHOR#*<}" \
    commit -q --author="$AUTHOR" -m "Export from brain-logic ${SRC_SHA}"
  echo "    committed as: $AUTHOR"
fi

cat <<EOF

  Done. $(git -C "$OUT" rev-list --count HEAD) commit(s) in $OUT; none of this repo's history.

  Review:    git -C "$OUT" log --stat | head
  Publish:   cd "$OUT" && gh repo create brain-logic --public --source=. --remote=origin --push
  Later:     re-run this script, then: git -C "$OUT" push
EOF
