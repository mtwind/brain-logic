#!/usr/bin/env bash
#
# brain-setup.sh — one-command local AI agent stack for macOS (Apple Silicon)
#
# Installs and configures: Homebrew, base toolchain, Ollama (tuned for agent
# workloads), your chosen models, PostgreSQL + pgvector, GBrain, and Claude Code.
#
# It deliberately stops short of anything that needs your judgment: it does not
# create your sandbox user, run OpenClaw's guided setup, or run `gbrain init`
# (the embedding choice there is permanent). See README.md.
#
# Usage:
#   bash brain-setup.sh                 # install everything except voice
#   bash brain-setup.sh --dry-run       # print what it would do, change nothing
#   bash brain-setup.sh --skip-models   # everything except the model pulls
#   bash brain-setup.sh --with-voice    # + optional speech-to-text / TTS deps
#
# Configure by editing brain-setup.conf (copy from brain-setup.conf.example),
# or by exporting any BRAIN_* variable before running.
#
# Safe to re-run. Every step checks before it installs.
#
# MIT licensed. See LICENSE.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------ configuration --

# A brain-setup.conf sitting next to this script wins over these defaults;
# environment variables win over both.
[ -f "$SCRIPT_DIR/brain-setup.conf" ] && . "$SCRIPT_DIR/brain-setup.conf"

# Models to pull. Space-separated. Add a second to run a bake-off; note that on
# a 24GB machine two ~17GB models cannot be resident at once (see MAX_LOADED).
: "${BRAIN_MODELS:=qwen3.6:27b-q4_K_M}"

# Embedding model. PERMANENT once you run `gbrain init` — dimensions are baked
# into the database schema. nomic-embed-text is 768d and GBrain's Ollama default.
: "${BRAIN_EMBED_MODEL:=nomic-embed-text}"

# Ollama runtime tuning. `auto` sizes the context window from installed RAM.
: "${BRAIN_CONTEXT_LENGTH:=auto}"
: "${BRAIN_KV_CACHE_TYPE:=q8_0}"
: "${BRAIN_FLASH_ATTENTION:=1}"
: "${BRAIN_MAX_LOADED_MODELS:=1}"
: "${BRAIN_KEEP_ALIVE:=30m}"

# Database
: "${BRAIN_PG_VERSION:=17}"
: "${BRAIN_DB_NAME:=gbrain}"

# Components — set any to 0 to skip
: "${BRAIN_INSTALL_OLLAMA:=1}"
: "${BRAIN_INSTALL_POSTGRES:=1}"
: "${BRAIN_INSTALL_GBRAIN:=1}"
: "${BRAIN_INSTALL_CLAUDE_CODE:=1}"

# Optional voice stack (off unless --with-voice)
: "${BRAIN_VOICE_DIR:=$HOME/brain/voice}"

# Disk guard. `auto` = 15GB base + 20GB per model.
: "${BRAIN_MIN_DISK_GB:=auto}"

# ------------------------------------------------------------------- flags ---

DRY_RUN=0
WITH_VOICE=0
SKIP_MODELS=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=1 ;;
    --with-voice)  WITH_VOICE=1 ;;
    --skip-models) SKIP_MODELS=1 ;;
    -h|--help)     sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- helpers ---

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
RED=$'\033[31m'; RESET=$'\033[0m'

step()  { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
ok()    { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
skip()  { printf '  %s·%s %s %s(already present)%s\n' "$DIM" "$RESET" "$*" "$DIM" "$RESET"; }
warn()  { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
note()  { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }
die()   { printf '\n%sFAILED:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry-run]%s %s\n' "$DIM" "$RESET" "$*"
  else
    "$@"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

brew_install() {          # brew_install <formula> [binary-to-check]
  local formula="$1" bin="${2:-$1}"
  if have "$bin"; then skip "$formula"; else
    run brew install "$formula" && ok "$formula"
  fi
}

brew_cask_install() {     # brew_cask_install <cask> <app-bundle-path>
  local cask="$1" check="$2"
  if [ -e "$check" ]; then skip "$cask"; else
    run brew install --cask "$cask" && ok "$cask"
  fi
}

append_once() {           # append_once <file> <match-pattern> <line>
  local file="$1" pattern="$2" line="$3"
  grep -q "$pattern" "$file" 2>/dev/null && return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry-run]%s append to %s: %s\n' "$DIM" "$RESET" "$file" "$line"
  else
    printf '%s\n' "$line" >> "$file"
  fi
}

# ------------------------------------------------------------- 0. preflight --

step "0. Preflight"

[ "$(uname -s)" = "Darwin" ] || die "this script is macOS-only"
[ "$(uname -m)" = "arm64" ]  || warn "not Apple Silicon — memory sizing advice below assumes it"
ok "macOS $(sw_vers -productVersion) on $(uname -m)"

RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
ok "${RAM_GB}GB unified memory"

# shellcheck disable=SC2206
MODEL_LIST=( $BRAIN_MODELS )
if [ "$BRAIN_MIN_DISK_GB" = "auto" ]; then
  if [ "$SKIP_MODELS" -eq 1 ]; then
    NEEDED_GB=15
  else
    NEEDED_GB=$(( 15 + 20 * ${#MODEL_LIST[@]} ))
  fi
else
  NEEDED_GB="$BRAIN_MIN_DISK_GB"
fi

AVAIL_GB=$(df -g / | awk 'NR==2 {print $4}')
if [ "${AVAIL_GB:-0}" -lt "$NEEDED_GB" ]; then
  die "only ${AVAIL_GB}GB free; need ~${NEEDED_GB}GB. Free space or run with --skip-models."
fi
ok "${AVAIL_GB}GB free (need ~${NEEDED_GB}GB)"

if ! xcode-select -p >/dev/null 2>&1; then
  warn "Xcode Command Line Tools missing — a GUI installer will open."
  warn "Let it finish, then re-run this script."
  run xcode-select --install
  [ "$DRY_RUN" -eq 0 ] && exit 1
else
  ok "Xcode Command Line Tools"
fi

# ------------------------------------------------------------- 1. homebrew --

step "1. Homebrew"

BREW_INSTALL_URL=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
if ! have brew; then
  # The curl lives inside the quoted string so --dry-run doesn't fetch it.
  # You will be prompted for your password.
  run bash -c "curl -fsSL '$BREW_INSTALL_URL' | bash"
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    append_once "$HOME/.zprofile" 'brew shellenv' \
      'eval "$(/opt/homebrew/bin/brew shellenv)"'
  fi
  ok "Homebrew"
else
  skip "Homebrew"
fi

# ---------------------------------------------------------- 2. base tooling --

step "2. Base tooling"

brew_install git
brew_install jq
brew_install ripgrep rg
brew_install wget
brew_install node
brew_install uv

if have bun; then skip "bun"; else
  run brew install oven-sh/bun/bun && ok "bun"
fi

# Bun's global bin is not on PATH by default — anything installed with
# `bun install -g` (GBrain) is invisible without this.
BUN_BIN="${BUN_INSTALL:-$HOME/.bun}/bin"
append_once "$HOME/.zshrc" '.bun/bin' 'export PATH="$HOME/.bun/bin:$PATH"'
export PATH="${BUN_BIN}:$PATH"

if have node; then
  NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
  [ "${NODE_MAJOR:-0}" -ge 22 ] || warn "Node $(node -v) is below 22 — OpenClaw's npm install may complain"
fi

# ------------------------------------------------------------- 3. ollama ----

if [ "$BRAIN_INSTALL_OLLAMA" = "1" ]; then
step "3. Ollama"

brew_cask_install ollama-app /Applications/Ollama.app
if ! have ollama && [ -x /Applications/Ollama.app/Contents/Resources/ollama ]; then
  warn "ollama CLI not on PATH yet — open Ollama.app once, it installs the CLI symlink"
fi

ollama_up() { curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; }

if [ "$DRY_RUN" -eq 0 ] && ! ollama_up; then
  run open -a Ollama
  # A first-ever launch shows a setup window and does not start listening until
  # you click through it. Wait generously, then ask rather than failing.
  warn "if Ollama shows a welcome/permission window, click through it now"
  printf '  waiting for the Ollama server (up to 3 min)'
  for _ in $(seq 1 180); do
    ollama_up && break
    printf '.'; sleep 1
  done
  printf '\n'

  # Still down? Give the user a chance to finish onboarding instead of dying.
  while ! ollama_up; do
    if [ ! -t 0 ]; then
      die "Ollama server not responding on :11434 (non-interactive shell)"
    fi
    warn "Ollama still isn't listening on :11434."
    warn "Open Ollama.app, complete any first-run prompts, and leave it running."
    printf '  press Return to retry, or Ctrl-C to abort: '
    read -r _
  done
fi

if [ "$DRY_RUN" -eq 0 ]; then
  ok "Ollama server up ($(ollama --version 2>/dev/null | head -1))"
fi

# --------------------------------------------- 4. Ollama runtime tuning ------

step "4. Ollama runtime tuning"

# These are the settings that matter more than model choice for agent work.
#
#   FLASH_ATTENTION   prerequisite — KV cache quantization does nothing without it
#   KV_CACHE_TYPE     q8_0 on K and V roughly doubles usable context on Apple Silicon
#   CONTEXT_LENGTH    sized from RAM; agent loops are prefill-heavy
#   MAX_LOADED_MODELS 1 keeps two large models from co-residing
#   KEEP_ALIVE        agent loops re-prompt constantly; cold loads ruin the feel

if [ "$BRAIN_CONTEXT_LENGTH" = "auto" ]; then
  if   [ "$RAM_GB" -ge 64 ]; then CTX=65536
  elif [ "$RAM_GB" -ge 48 ]; then CTX=32768
  elif [ "$RAM_GB" -ge 32 ]; then CTX=24576
  else                            CTX=16384
  fi
else
  CTX="$BRAIN_CONTEXT_LENGTH"
fi

set_ollama_env() {
  local key="$1" val="$2"
  # launchctl is what the macOS *app* reads; .zshrc covers CLI-launched servers.
  run launchctl setenv "$key" "$val"
  append_once "$HOME/.zshrc" "^export ${key}=" "export ${key}=${val}"
}

set_ollama_env OLLAMA_FLASH_ATTENTION   "$BRAIN_FLASH_ATTENTION"
set_ollama_env OLLAMA_KV_CACHE_TYPE     "$BRAIN_KV_CACHE_TYPE"
set_ollama_env OLLAMA_CONTEXT_LENGTH    "$CTX"
set_ollama_env OLLAMA_MAX_LOADED_MODELS "$BRAIN_MAX_LOADED_MODELS"
set_ollama_env OLLAMA_KEEP_ALIVE        "$BRAIN_KEEP_ALIVE"
ok "flash attention ${BRAIN_FLASH_ATTENTION}, KV cache ${BRAIN_KV_CACHE_TYPE}, context ${CTX}, ${BRAIN_MAX_LOADED_MODELS} model(s) resident"
warn "quit and reopen Ollama.app for launchctl vars to take effect"

# -------------------------------------------------------------- 5. models ---

step "5. Models"

if [ "$SKIP_MODELS" -eq 1 ]; then
  warn "skipping model pulls (--skip-models)"
else
  pull_model() {
    local tag="$1" note_text="${2:-}"
    if [ "$DRY_RUN" -eq 0 ] && ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$tag"; then
      skip "$tag"
    else
      [ -n "$note_text" ] \
        && printf '  pulling %s %s(%s)%s\n' "$tag" "$DIM" "$note_text" "$RESET" \
        || printf '  pulling %s\n' "$tag"
      run ollama pull "$tag" && ok "$tag"
    fi
  }

  for m in "${MODEL_LIST[@]}"; do pull_model "$m"; done
  pull_model "$BRAIN_EMBED_MODEL" "embeddings — permanent choice once gbrain init runs"

  if [ "${#MODEL_LIST[@]}" -gt 1 ] && [ "$RAM_GB" -lt 32 ]; then
    warn "${RAM_GB}GB RAM with ${#MODEL_LIST[@]} models configured. MAX_LOADED_MODELS=${BRAIN_MAX_LOADED_MODELS}"
    warn "keeps them from co-residing, but expect a cold load whenever you switch."
  fi
fi
fi  # BRAIN_INSTALL_OLLAMA

# ---------------------------------------------- 6. Postgres + pgvector ------

if [ "$BRAIN_INSTALL_POSTGRES" = "1" ]; then
step "6. PostgreSQL ${BRAIN_PG_VERSION} + pgvector"

PG_FORMULA="postgresql@${BRAIN_PG_VERSION}"
brew_install "$PG_FORMULA" psql
if ! brew list pgvector >/dev/null 2>&1; then
  run brew install pgvector && ok "pgvector"
else
  skip "pgvector"
fi

# postgresql@N is keg-only — its bin dir needs to be on PATH explicitly.
PG_BIN="$(brew --prefix 2>/dev/null || echo /opt/homebrew)/opt/${PG_FORMULA}/bin"
if [ -d "$PG_BIN" ]; then
  append_once "$HOME/.zshrc" "${PG_FORMULA}/bin" "export PATH=\"${PG_BIN}:\$PATH\""
  export PATH="${PG_BIN}:$PATH"
fi

if ! brew services list 2>/dev/null | grep -q "^${PG_FORMULA}.*started"; then
  run brew services start "$PG_FORMULA" && ok "${PG_FORMULA} service started"
  [ "$DRY_RUN" -eq 0 ] && sleep 3
else
  skip "${PG_FORMULA} service"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if psql -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw "$BRAIN_DB_NAME"; then
    skip "database '${BRAIN_DB_NAME}'"
  else
    createdb "$BRAIN_DB_NAME" && ok "created database '${BRAIN_DB_NAME}'"
  fi
  psql -d "$BRAIN_DB_NAME" -c 'CREATE EXTENSION IF NOT EXISTS vector;' >/dev/null \
    && ok "pgvector enabled in '${BRAIN_DB_NAME}'"
else
  run createdb "$BRAIN_DB_NAME"
  run psql -d "$BRAIN_DB_NAME" -c 'CREATE EXTENSION IF NOT EXISTS vector;'
fi
fi  # BRAIN_INSTALL_POSTGRES

# --------------------------------------------------------------- 7. GBrain --

if [ "$BRAIN_INSTALL_GBRAIN" = "1" ]; then
step "7. GBrain"

if have gbrain; then
  skip "gbrain"
else
  run bun install -g garrytan/gbrain
  if [ "$DRY_RUN" -eq 0 ]; then
    if have gbrain; then
      ok "gbrain ($(gbrain --version 2>/dev/null | head -1))"
    else
      warn "gbrain installed but not on PATH — open a new terminal and re-run"
    fi
    # Bun blocks postinstall scripts by default. Usually harmless; say so rather
    # than letting it scroll past in the install output.
    if bun pm -g untrusted 2>/dev/null | grep -q .; then
      warn "bun blocked a postinstall script. Inspect with: bun pm -g untrusted"
      warn "if gbrain misbehaves, that is the first thing to check"
    fi
  fi
fi

warn "NOT running 'gbrain init' — embedding dimensions are baked into the schema"
note "when you're ready:"
note "  gbrain init --url postgresql://localhost:5432/${BRAIN_DB_NAME} \\"
note "              --embedding-model ollama:${BRAIN_EMBED_MODEL}"
note "GBrain's default provider is a cloud API. Pass --embedding-model to stay local."
fi  # BRAIN_INSTALL_GBRAIN

# ---------------------------------------------------------- 8. Claude Code --

if [ "$BRAIN_INSTALL_CLAUDE_CODE" = "1" ]; then
step "8. Claude Code"

if have claude; then
  skip "claude ($(claude --version 2>/dev/null | head -1))"
else
  run bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
  ok "Claude Code (native installer)"
  append_once "$HOME/.zshrc" '.local/bin' 'export PATH="$HOME/.local/bin:$PATH"'
fi
fi  # BRAIN_INSTALL_CLAUDE_CODE

# ------------------------------------------------------- 9. voice (optional) --

step "9. Voice stack (optional)"

if [ "$WITH_VOICE" -eq 0 ]; then
  note "skipped. Re-run with --with-voice if you want speech-to-text and TTS."
else
  warn "These dependencies move fast. Install them when you'll actually use them."
  brew_install ffmpeg
  run mkdir -p "$BRAIN_VOICE_DIR"
  if [ ! -d "$BRAIN_VOICE_DIR/.venv" ]; then
    run uv venv "$BRAIN_VOICE_DIR/.venv" --python 3.12
    run uv pip install --python "$BRAIN_VOICE_DIR/.venv/bin/python" \
      faster-whisper kokoro-onnx soundfile
    ok "voice venv at $BRAIN_VOICE_DIR/.venv"
  else
    skip "voice venv"
  fi
fi

# --------------------------------------------------------- 10. verification --

step "10. Verification"

check() {                 # check <label> <command...>
  local label="$1"; shift
  if out=$("$@" 2>&1 | head -1); then
    printf '  %s✓%s %-18s %s%s%s\n' "$GREEN" "$RESET" "$label" "$DIM" "$out" "$RESET"
  else
    printf '  %s✗%s %-18s %snot working%s\n' "$RED" "$RESET" "$label" "$RED" "$RESET"
  fi
}

if [ "$DRY_RUN" -eq 1 ]; then
  note "dry run — nothing to verify"
else
  missing() { printf '  %s✗%s %-18s %snot on PATH%s\n' "$RED" "$RESET" "$1" "$RED" "$RESET"; }

  check "brew"     brew --version
  check "git"      git --version
  check "node"     node --version
  check "bun"      bun --version

  # Anything we were asked to install must be reported, present or not —
  # silently omitting a row makes a broken install look clean.
  if [ "$BRAIN_INSTALL_OLLAMA" = "1" ]; then
    have ollama && check "ollama" ollama --version || missing "ollama"
  fi
  if [ "$BRAIN_INSTALL_POSTGRES" = "1" ]; then
    have psql && check "postgres" psql --version || missing "postgres"
  fi
  if [ "$BRAIN_INSTALL_GBRAIN" = "1" ]; then
    have gbrain && check "gbrain" gbrain --version || missing "gbrain"
  fi
  if [ "$BRAIN_INSTALL_CLAUDE_CODE" = "1" ]; then
    have claude && check "claude" claude --version || missing "claude"
  fi
  have tailscale && check "tailscale" tailscale version || missing "tailscale"

  if have ollama; then
    printf '\n  %smodels:%s\n' "$BOLD" "$RESET"
    ollama list 2>/dev/null | sed 's/^/    /'
  fi

  if have psql; then
    printf '\n  %spgvector:%s\n' "$BOLD" "$RESET"
    psql -d "$BRAIN_DB_NAME" -tAc \
      "SELECT '    vector ' || extversion || ' in ${BRAIN_DB_NAME}' FROM pg_extension WHERE extname='vector';" \
      2>/dev/null || printf '    %snot found%s\n' "$RED" "$RESET"
  fi
fi

# ------------------------------------------------------------------ done ----

cat <<EOF

${BOLD}Done.${RESET} Open a new terminal (or: source ~/.zshrc).

What this script deliberately left for you:

  1. Quit and reopen Ollama.app        picks up the tuning env vars
  2. Create a sandboxed macOS user     before the agent touches anything
  3. Read the OpenClaw security docs   https://docs.openclaw.ai/gateway/security
  4. ollama launch openclaw            guided, interactive
  5. gbrain init                       permanent embedding choice — see §7 above
  6. claude  →  /login

EOF
