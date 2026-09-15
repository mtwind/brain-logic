# Standing instructions for Claude Code sessions in this repo

Sessions are started from the `brain-logic` repo and only from there.

## Hard boundaries

1. **Never read, list, or reference the brain repo.** Its location is
   `BRAIN_DIR` in `config/paths.env` — currently `~/Code/brain`. It holds
   personal knowledge and is out of scope for every task in this repo. Do not
   read it, list it, grep it, or `cd` into it. If a task appears to require it,
   stop and ask rather than reading.

   This applies to the *path*, not the literal string: `~/brain`,
   `~/Code/brain`, `$BRAIN_DIR`, and any future value are all the same rule.
2. **Never read `~/.openclaw/openclaw.json`** — it holds rendered credentials.
   Work against `config/openclaw.json.template` instead.
3. **Never commit a secret.** Values come from the Keychain at render time.
   A `gitleaks` pre-commit hook enforces this; do not bypass it with
   `--no-verify`.
4. **Branches and PRs only.** Never commit to or push `main`.

## What this repo is

Engineering scaffolding for a locally-hosted personal AI assistant:
- **OpenClaw** is the agent runtime (gateway, channels, cron, skills)
- **Ollama** serves local models for anything touching personal data
- **GBrain** is the memory layer (markdown + Postgres/pgvector)
- **Claude Code** — you — handles repo and feature work only

## Routing principle

Work is routed by **data sensitivity**, not difficulty. Anything touching
personal context runs on the local model even when a frontier model would do it
better. You get repo work, feature development, and infrastructure. That
division is deliberate; do not propose collapsing it for convenience.

## Conventions

- Shell scripts: `bash`, `set -euo pipefail`, idempotent, `--dry-run` where
  a run has side effects.
- `set -euo pipefail` kills scripts silently in three shapes that keep recurring
  here (four instances in one session; see `docs/decision-log.md`, 2026-09-05):
  a command substitution whose pipeline fails (`x=$(cmd | ...)` where `cmd`
  exits nonzero — `lsof` with nothing listening, `security` with no such item),
  and `... | head -c N`, where head exits first and the producer dies on
  SIGPIPE. Wrap the fallible part in `{ cmd || true; }` and end bounded
  pipelines with a consumer that reads to EOF, such as `cut`.
- Every cron job logs to `logs/` and fails loudly. Silent failure in an
  unattended job is worse than a crash.
- Config files in `config/` are templates with `${VAR}` placeholders. The
  rendered versions never enter the repo.

## Before you finish a task

- Re-run the thing you changed, in dry-run if it has one.
- If you added a cron job, say what happens when it fails at 3am.
- Record any non-obvious call in `docs/decision-log.md`: what was decided, why,
  and what would reverse it.
