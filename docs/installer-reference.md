# scripts/brain-setup.sh — reference

One idempotent script that installs the local half of a private AI agent stack
on macOS (Apple Silicon): Ollama tuned for agent workloads, your chosen models,
PostgreSQL + pgvector, [GBrain](https://github.com/garrytan/gbrain), and Claude
Code.

It is opinionated about the settings that actually determine whether local agent
work feels good, and deliberately silent about the decisions that are yours.

```bash
cd ~/brain-logic
bash scripts/brain-setup.sh --dry-run    # read what it will do
bash scripts/brain-setup.sh
```

Configured by `scripts/brain-setup.conf`, which is committed — this repo is
private and the file holds no secrets.

## What it installs

| Step | Component |
|---|---|
| 1–2 | Homebrew, git, node, bun, uv, jq, ripgrep, wget |
| 3–4 | Ollama + runtime tuning (see below) |
| 5 | Your configured models + an embedding model |
| 6 | PostgreSQL + pgvector, with a database created and the extension enabled |
| 7 | GBrain CLI |
| 8 | Claude Code |
| 9 | *Optional* — `faster-whisper` + TTS, behind `--with-voice` |
| 10 | Verification pass |

## The settings that matter

Model choice gets all the attention; these matter more for agent work.

| Variable | Default | Why |
|---|---|---|
| `OLLAMA_FLASH_ATTENTION` | `1` | Prerequisite — KV cache quantization does nothing without it |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | Quantizing K and V roughly doubles usable context on Apple Silicon |
| `OLLAMA_CONTEXT_LENGTH` | sized from RAM | Agent loops are prefill-heavy; every turn re-reads the system prompt, memory context, and tool results |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | Two ~17GB models must never co-reside on a 24GB machine |
| `OLLAMA_KEEP_ALIVE` | `30m` | Cold loads between agent turns ruin the feel |

Budget honestly: macOS uses 6–10GB, so treat 24GB as ~15–16GB usable.

## What it deliberately does *not* do

These need your judgment, and a script that made the call for you would be
making the wrong kind of decision:

- **Create a sandboxed user.** Run the agent as a dedicated standard (non-admin)
  macOS user. A local model reading untrusted input with shell access is a
  prompt-injection target, and quantized local models resist injection *worse*
  than provider-filtered cloud models. The smaller the model, the stronger the
  guardrails need to be.
- **Run `gbrain init`.** Embedding dimensions are baked into the database schema
  at init time. Changing your mind later forces a full re-index. The script pulls
  the model and prints the command; you run it when you've decided.
- **Run OpenClaw's guided setup.** It is interactive by design — read the
  [security guide](https://docs.openclaw.ai/gateway/security) first.
- **Touch any credential.** Nothing here reads, writes, or asks for a secret.

## Gotchas worth knowing before you hit them

**GBrain's default embedding provider is a cloud API.** A bare `gbrain init`
sends your notes to a third party to be embedded. If the point of your setup is
that personal data stays local, pass `--embedding-model ollama:<model>`
explicitly. The script prints the full command.

**OpenClaw's Ollama `baseUrl` must not have a `/v1` suffix.** The OpenAI-compat
endpoint silently breaks tool calling, which presents as "the local model is bad
at agent work" rather than as a configuration error.

**Agent runtimes recommend ≥64K context; your hardware may disagree.** 18GB of
weights plus a 64K KV cache does not fit in ~15GB usable. Expect warnings. The
cap is correct and the warnings are honest — that's a hardware constraint, not
something to configure around.

## Flags

| Flag | Effect |
|---|---|
| `--dry-run` | Print every action, change nothing. Run this first. |
| `--skip-models` | Everything except the model pulls |
| `--with-voice` | Add `faster-whisper` + TTS dependencies in a venv |
| `--help` | Usage |

## Configuration

Copy `brain-setup.conf.example` to `brain-setup.conf` and edit, or export any
`BRAIN_*` variable. Environment beats config file beats defaults. See the
example file — it is commented with the reasoning behind each default.

## Safety

Re-running is safe. Every step checks before it installs, appends to `.zshrc`
only once per key, and refuses to start if free disk is below what the
configured models need — so you don't discover the problem 14GB into a pull.

## Requirements

macOS 13+, Apple Silicon recommended. Roughly 35GB free for a single-model
install, plus 20GB per additional model.

## If you ever want to publish this

Copy `scripts/brain-setup.sh` and `brain-setup.conf.example` into a fresh
repo and add an MIT license. Fresh history, no scrubbing — the script has never
contained anything identifying. What you cannot safely publish is *this* repo,
with its history.
