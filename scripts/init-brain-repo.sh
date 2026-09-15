#!/usr/bin/env bash
# Creates ~/brain with the GBrain schema, hooks, and gitignore already in place.
#
# Run this BEFORE `gbrain init` and before ingesting anything — retrofitting a
# deny-by-default gitignore onto a repo that already has history is work you
# don't want to do twice.
set -euo pipefail

BRAIN="${BRAIN_DIR:-$HOME/brain}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say() { printf '  %s\n' "$*"; }
run() { if [ "$DRY" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

if [ -d "$BRAIN/.git" ]; then
  echo "$BRAIN is already a git repo — refusing to touch it." >&2
  exit 1
fi

# The brain must never live inside another repo. Nesting it under brain-logic
# would let personal knowledge be committed into the repo Claude Code opens,
# which is the exact failure the two-repo split exists to prevent.
BRAIN_ABS="$(cd "$(dirname "$BRAIN")" 2>/dev/null && pwd)/$(basename "$BRAIN")"
enclosing_repo=""
probe="$(dirname "$BRAIN_ABS")"
while [ "$probe" != "/" ] && [ -n "$probe" ]; do
  if [ -d "$probe/.git" ]; then enclosing_repo="$probe"; break; fi
  probe="$(dirname "$probe")"
done
if [ -n "$enclosing_repo" ]; then
  echo "REFUSING: $BRAIN_ABS would sit inside the git repo at $enclosing_repo." >&2
  echo "The brain must be a sibling of brain-logic, not nested in it." >&2
  echo "Unset BRAIN_DIR to use the default (\$HOME/brain)." >&2
  exit 1
fi

# Fail before creating anything, not halfway through.
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "gitleaks is required (the pre-commit hook fails closed without it):" >&2
  echo "  brew install gitleaks" >&2
  exit 1
fi
if ! git config user.email >/dev/null 2>&1; then
  echo "git identity not configured:" >&2
  echo "  git config --global user.email you@example.com" >&2
  echo "  git config --global user.name  'Your Name'" >&2
  exit 1
fi

echo "==> Creating brain repo at $BRAIN"
run mkdir -p "$BRAIN"
run chmod 700 "$BRAIN"

# GBrain's recommended schema.
for d in people companies deals meetings projects ideas concepts writing \
         programs org civic media personal household hiring sources prompts \
         inbox archive templates; do
  run mkdir -p "$BRAIN/$d"
done
say "created 20 schema directories"

if [ "$DRY" -eq 0 ]; then
  for f in RESOLVER.md schema.md index.md log.md; do
    [ -f "$BRAIN/$f" ] || printf '# %s\n\n' "${f%.md}" > "$BRAIN/$f"
  done

  # union merge on the append-only files, or the nightly dream cycle will hand
  # you merge conflicts forever.
  cat > "$BRAIN/.gitattributes" <<'GA'
log.md      merge=union
index.md    merge=union
*.md        text diff
.raw/**     -diff
GA

  # Deny by default. The opposite of how most gitignores are written, and the
  # right way round for a repo whose filenames are themselves sensitive.
  cat > "$BRAIN/.gitignore" <<'GI'
*
!*/
!*.md
!*.json
!.gitignore
!.gitattributes
!.githooks/
!.githooks/*

# Never, regardless of the allowlist above
.env
*.key
*.pem
openclaw.json
attachments/
GI

  mkdir -p "$BRAIN/.githooks"
  cat > "$BRAIN/.githooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
command -v gitleaks >/dev/null 2>&1 || { echo "gitleaks missing" >&2; exit 1; }
gitleaks git --staged --redact --no-banner . || {
  echo "BLOCKED: possible secret in staged brain changes" >&2
  exit 1
}
HOOK

  cat > "$BRAIN/.githooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
remote_url="${2:-}"
case "$remote_url" in
  *github.com*|*gitlab.com*|*bitbucket.org*|https://*|http://*)
    echo "REFUSED: the brain repo does not push to third-party hosts." >&2
    echo "  attempted: $remote_url" >&2
    exit 1 ;;
esac
HOOK
  chmod +x "$BRAIN/.githooks"/*

  cd "$BRAIN"
  git init -q
  git add -A
  git commit -qm "init: GBrain schema, hooks, deny-by-default gitignore"
  # Activate hooks only after the scaffold commit lands.
  git config core.hooksPath .githooks
fi

cat <<EOF

  Done. $BRAIN is initialized with hooks active and no remote configured.

  Next:
    1. Add a remote ONLY on your Tailscale mesh:
         git remote add origin <tailscale-host>:brain-remote/brain.git
       The pre-push hook refuses github/gitlab/bitbucket.
    2. gbrain init --url postgresql://localhost:5432/gbrain \\
                   --embedding-model ollama:nomic-embed-text
    3. On any FRESH CLONE of this repo, re-activate the hooks — core.hooksPath
       is local config and does not travel with the repo:
         git config core.hooksPath .githooks
    4. Write SOUL.md / USER.md into $BRAIN/personal/, then install copies
       into the agent account:
         bash scripts/install-agent-prompts.sh
       Do NOT symlink them into ~/.openclaw/. That instruction stood here
       until 2026-09-07 and could never work: the agent runs as 'brain',
       which cannot read $BRAIN, and these are workspace files
       (~/.openclaw/workspace/) rather than ~/.openclaw/ files anyway.
       USER.md has a hard 4,000-character budget; the installer enforces it.

EOF
