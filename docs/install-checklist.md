# Personal Brain — Install Checklist

Companion to `brain-setup.sh`. The script handles everything that can run
unattended. This file covers the steps that need your judgment, your password,
or a browser — plus the handoff brief for Claude Code at the end.

**Status going in:** Tailscale installed. Nothing else.

---

## 0. Run the script

```bash
cd ~/Downloads          # or wherever you saved it
bash brain-setup.sh --dry-run    # read what it will do
bash brain-setup.sh
```

Roughly 40 minutes on a decent connection, most of it the two ~17–18GB model
pulls. It will ask for your password once (Homebrew) and may open the Xcode
Command Line Tools installer — if it does, let that finish and re-run.

Flags: `--skip-models` (skip the 36GB of pulls), `--with-voice` (Phase 5 deps —
**don't**, see §7), `--dry-run`.

Then open a new terminal so the PATH and env changes take effect.

**One thing to notice in the output:** the RAM/disk numbers it prints. If free
disk is under ~60GB the script stops rather than half-pulling a model.

---

## 1. Restart Ollama.app

The script sets Ollama's tuning via `launchctl setenv`, which the macOS app only
reads at launch. Quit Ollama from the menu bar and reopen it.

Verify the settings took:

```bash
ollama ps        # should be empty
ollama run qwen3.6:27b-q4_K_M "say hi in five words"
ollama ps        # check the CONTEXT column reads 16384
```

What got set, and why (plan §3):

| Variable | Value | Reason |
|---|---|---|
| `OLLAMA_FLASH_ATTENTION` | `1` | Prerequisite — KV cache quantization does nothing without it |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | Roughly doubles usable context on Apple Silicon |
| `OLLAMA_CONTEXT_LENGTH` | `16384` | 24GB budget. Raise to 32–64K on the Mini |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | Two 17GB models must never co-reside on 24GB |
| `OLLAMA_KEEP_ALIVE` | `30m` | Agent loops re-prompt constantly; cold loads kill the feel |

**Head-up on a real tension:** OpenClaw's docs recommend ≥64K context for agent
work. Your plan caps you at 16K on this machine, and that cap is correct — 18GB
of weights plus a 64K KV cache does not fit in ~15GB usable. Expect OpenClaw to
warn you. The honest read is that long agent chains will be cramped until the
Mini arrives; that's the known cost of the interim host, not a misconfiguration.
If a task genuinely needs the window, OpenClaw can route it to a cloud model.

---

## 2. Sandbox user — do this BEFORE OpenClaw touches anything

Plan §6 non-negotiable #2. A local quantized model reading untrusted email with
shell access is the exact prompt-injection target the plan warns about, and Q4
models resist injection *worse* than provider-filtered cloud models.

1. System Settings → Users & Groups → Add User
2. Type: **Standard** (not Admin). Name it `brain`.
3. Log in as `brain` once to create the home directory.
4. Grant it Full Disk Access to nothing. Add permissions only when something
   actually breaks, one at a time.
5. Ollama runs from your main user and serves on `127.0.0.1:11434` — the
   sandboxed user can reach it without needing its own copy of the models.

Then run OpenClaw as that user. Fast-user-switch, or `su - brain` from Terminal.

---

## 3. Read these three before connecting a single channel

Not optional, and not long:

- [OpenClaw Security](https://docs.openclaw.ai/gateway/security)
- [Gateway exposure runbook](https://docs.openclaw.ai/gateway/security/exposure-runbook)
- [Ollama provider config](https://docs.openclaw.ai/providers/ollama)

The one config detail that bites people: OpenClaw's Ollama `baseUrl` must be
`http://localhost:11434` with **no** `/v1` suffix. The `/v1` OpenAI-compat
endpoint silently breaks tool calling — which looks exactly like "the local
model is bad at agent work," and isn't.

---

## 4. OpenClaw

```bash
ollama launch openclaw
```

Guided setup. It will offer to install itself via npm, show a security notice,
let you pick a model, and start the gateway with a TUI.

- Pick `muse-glimmer:30b` or `qwen3.6:27b-q4_K_M` — whichever you want to start
  the bake-off week with. You'll swap in a week.
- Requires Ollama ≥ 0.17 (the script installs current).

Then channels:

```bash
openclaw configure --section channels    # Telegram first
openclaw configure --section web
```

**Telegram token:** message [@BotFather](https://t.me/botfather) on Telegram,
`/newbot`, follow the prompts, paste the token when OpenClaw asks. Put the token
in the keychain or env, **never** in the brain repo (plan §6 #5).

Stop the gateway with `openclaw gateway stop`.

---

## 5. GBrain — the one permanent decision

The script installed GBrain, created a `gbrain` Postgres database, and enabled
pgvector. It deliberately did **not** run `gbrain init`, because embedding
dimensions are baked into the schema at init time. Changing your mind later
means `gbrain reinit-pglite` and a full re-index of everything you've ingested.

The script pulled `nomic-embed-text` (768d) — GBrain's default Ollama embedding
model and the sane default for a local, privacy-first brain. Alternatives GBrain
supports via Ollama: `mxbai-embed-large` (1024d), `snowflake-arctic-embed-l-v2`
(1024d), `all-minilm` (384d), `qwen3-embed-8b` (4096d).

**Recommendation: take `nomic-embed-text` and stop deliberating.** It's the
default, it's 768d (cheap to store and fast to search), and it keeps embeddings
local — which is the whole point. The higher-dimension models buy marginal
retrieval quality at real storage and latency cost, and none of them buy enough
to justify a re-index gamble on a brain you intend to grow for years.

When you're ready:

```bash
gbrain init --url postgresql://localhost:5432/gbrain \
            --embedding-model ollama:nomic-embed-text
```

Two notes:

- GBrain's *default* embedding provider is ZeroEntropy, a **cloud API**. If you
  run bare `gbrain init` and accept defaults, your personal notes get embedded
  by a third party. That violates the plan's first governing principle. Pass
  `--embedding-model ollama:nomic-embed-text` explicitly.
- GBrain also offers PGLite (embedded WASM Postgres) for brains under ~1,000
  pages. The script set up real Postgres instead, because you're building for
  years and migrating later is work you don't need.

After init: `gbrain doctor` to verify.

---

## 6. Claude Code

```bash
claude
```

Then `/login` in the session and follow the browser flow for Claude Max OAuth.
Verify with `claude doctor`.

Per plan §3, wire the guardrails before letting it run autonomously: branches
only, PRs for review, no push to main.

---

## 7. Voice stack — skip for now

You asked for everything installable, and the script *can* do it with
`--with-voice`. My recommendation is don't. Phase 5 is several months out,
`faster-whisper` and the TTS side both move fast, and anything you install today
you'll reinstall then. The flag is there when you get there.

---

## 8. Verify before you hand off

```bash
bash brain-setup.sh          # re-run: everything should say "already present"
tailscale status
ollama list
psql -d gbrain -c '\dx'      # should list vector
claude doctor
```

---

## Handoff brief for Claude Code

Paste this into a fresh `claude` session in your brain working directory.

> I'm building a personal AI assistant ("Personal Brain") on this MacBook Pro
> (M5 Pro, 24GB, Apple Silicon). The full plan lives in my Claude project doc
> `personal-brain-plan.md` — ask me to paste it if you need the detail.
>
> **Already installed and verified:** Tailscale, Homebrew, git, Node, Bun,
> Ollama (with flash attention on, KV cache q8_0, context 16384, max 1 loaded
> model, keep-alive 30m), models `muse-glimmer:30b` + `qwen3.6:27b-q4_K_M` +
> `nomic-embed-text`, PostgreSQL 17 with pgvector enabled on a `gbrain`
> database, GBrain CLI, Claude Code.
>
> **Not yet done:** OpenClaw guided setup, the sandboxed `brain` macOS user,
> Telegram channel, `gbrain init`, SOUL.md/USER.md, the two-model bake-off,
> git-backed brain repo + nightly pg_dump cron.
>
> **Constraints that are not negotiable:**
> - Personal data never leaves this machine. Local model for anything touching
>   personal context; you (Claude) handle repo and feature work only.
> - Claude-facing agents get no GBrain/email/personal context by default.
> - Nothing listens on a public port. Tailscale only.
> - Secrets live in the keychain or env, never in the brain repo or any file
>   the local model can read.
> - Code changes go on branches with PRs. Never push to main.
> - Outbound actions (send email, send message, purchase) need an approval gate.
>
> **Known gotcha:** OpenClaw's Ollama `baseUrl` must have no `/v1` suffix or
> tool calling silently fails.
>
> Start by helping me set up the sandboxed user and OpenClaw config, then the
> brain git repo with the nightly pg_dump cron.

---

## Sources

- [OpenClaw — Ollama integration](https://docs.ollama.com/integrations/openclaw)
- [OpenClaw setup tutorial (Ollama blog)](https://ollama.com/blog/openclaw-tutorial)
- [OpenClaw — Ollama provider config](https://docs.openclaw.ai/providers/ollama)
- [OpenClaw — Gateway security](https://docs.openclaw.ai/gateway/security)
- [OpenClaw — Gateway exposure runbook](https://docs.openclaw.ai/gateway/security/exposure-runbook)
- [muse-glimmer on Ollama](https://ollama.com/library/muse-glimmer)
- [qwen3.6:27b-q4_K_M on Ollama](https://ollama.com/library/qwen3.6:27b-q4_K_M)
- [GBrain — getting started & installation](https://deepwiki.com/garrytan/gbrain/1.1-getting-started-and-installation)
- [GBrain — embedding providers](https://github.com/garrytan/gbrain/blob/master/docs/integrations/embedding-providers.md)
- [pgvector](https://github.com/pgvector/pgvector)
- [Claude Code — setup](https://code.claude.com/docs/en/setup)
