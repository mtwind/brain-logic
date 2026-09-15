# Runbook — zero to Claude Code handoff

Ordered. Each step assumes the one before it finished. Roughly 90 minutes,
most of it waiting on model downloads.

Deeper reasoning for any step: [docs/install-checklist.md](docs/install-checklist.md)
and [docs/repo-structure-and-security.md](docs/repo-structure-and-security.md).

---

## Step 1 — Put this repo in place

```bash
mkdir -p ~/brain-logic
# unpack the tarball into ~/brain-logic, then:
cd ~/brain-logic
```

Check `scripts/brain-setup.conf`. It currently pulls **both** bake-off models
(~36GB). If you'd rather start with one and add the second later, edit
`BRAIN_MODELS` now.

---

## Step 2 — Git identity and gitleaks

Both are prerequisites; the hooks fail closed without gitleaks, and the init
script refuses to start if either is missing.

```bash
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
brew install gitleaks    # if brew isn't installed yet, do this after step 3
```

---

## Step 3 — Run the installer

```bash
bash scripts/brain-setup.sh --dry-run    # read this output before continuing
bash scripts/brain-setup.sh
```

It will ask for your password once (Homebrew), and may open the Xcode Command
Line Tools installer — let that finish and re-run. Downloads ~36GB.

When it's done, **open a new terminal** so PATH and env changes apply.

---

## Step 3.5 — New terminal, and put bun's global bin on PATH

The installer appends to `.zshrc`; a shell that was already open never sees it.

```bash
# open a NEW terminal, then:
echo $PATH | tr ':' '\n' | grep -E 'bun|postgresql|local/bin'
gbrain --version
```

If `gbrain` isn't found, add it by hand — `bun install -g` puts binaries
somewhere that isn't on PATH by default:

```bash
echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.zshrc
export PATH="$HOME/.bun/bin:$PATH"
```

---

## Step 4 — Restart Ollama.app

The tuning is set via `launchctl setenv`, which the app reads only at launch.
Quit it from the menu bar and reopen.

```bash
ollama run qwen3.6:27b-q4_K_M --think=false "say hi in five words"
ollama ps      # CONTEXT column should read 16384
```

`--think=false` matters. Thinking mode is **on by default** in Ollama and will
produce a long reasoning trace before the answer. Leave it on for agent runs and
Qwen produces silent tool-call failures — the worst kind, because nothing errors.
Keep it off for both models so the bake-off measures the models, not the config.

Read three columns:

- **CONTEXT** should be `16384`. If it's `4096`, the app didn't pick up the env
  vars — quit fully (menu bar → Quit, not just closing the window; confirm no
  `ollama` process survives in Activity Monitor) and reopen.
- **UNTIL** should be ~5 minutes out. It was 30m until 2026-09-07, cut because
  a resident 17GB model stops macOS from starting any audio device — see
  `docs/decision-log.md`. Raise `BRAIN_KEEP_ALIVE` only alongside a smaller model.
- **PROCESSOR** should be `100% GPU`. Any CPU percentage means the model is
  spilling out of the GPU's allocation and generation will be slow.

If CONTEXT is still wrong after a genuine restart, you have hit a known desktop
app bug (ollama/ollama#16896). Confirm launchd has the value, then serve
directly instead of via the app:

```bash
launchctl getenv OLLAMA_CONTEXT_LENGTH     # expect 16384
pkill ollama
OLLAMA_CONTEXT_LENGTH=16384 OLLAMA_KV_CACHE_TYPE=q8_0 \
OLLAMA_FLASH_ATTENTION=1 OLLAMA_KEEP_ALIVE=30m ollama serve
```

This matters less than it looks: OpenClaw sends `num_ctx` per request, which
overrides the server default. The server default mainly affects CLI testing.

**On PROCESSOR spill:** macOS caps GPU-wired memory near 75% of RAM (~18GB of
24GB), and a 17-18GB model plus KV cache lands just past it. Optional, does not
survive reboot, and takes memory from the OS:

```bash
sudo sysctl iogpu.wired_limit_mb=20480
sudo bash scripts/install-gpu-limit.sh
```

The first line applies it now; the second installs a LaunchDaemon so it survives
reboot. It is a ceiling, not a reservation — macOS keeps whatever the GPU does
not actually wire. The script refuses any value leaving macOS under ~12% of RAM.

The app *does* ignore its environment (ollama/ollama#16896), and worse: its
login item restarts it at every boot, where it takes `:11434` from the agent
below and leaves that agent crash-looping with its tuning ignored, behind an
endpoint that answers normally. Turn off "launch at login" in Ollama.app's
settings, then replace the menu-bar server with a launchd agent:

```bash
bash scripts/install-ollama-agent.sh
```

---

## Step 5 — Initialize this repo as git

```bash
cd ~/brain-logic
git init
git config core.hooksPath githooks
git add -A
git commit -m "initial commit: scaffold"
```

No remote yet — that's step 9.

---

## Step 6 — Prove the guardrails work

Do not skip this. A guardrail you haven't watched fire is one you're guessing
about.

First confirm the hooks are wired at all. **A hook without the executable bit is
skipped silently** — the failure mode that leaves you unprotected while looking
fine.

```bash
git config core.hooksPath
ls -l githooks/
```

Expect `githooks` and an `x` bit on both files. If missing: `chmod +x githooks/*`.

**pre-push.** Do NOT test this by pushing to a nonexistent remote. Git runs
pre-push only *after* the remote responds with its refs, so a bad URL fails at
the connection stage and the hook never runs — you get a failure that proves
nothing. Invoke it the way git does instead:

```bash
echo "" | bash githooks/pre-push origin https://github.com/example/x.git
echo "exit=$?"
```

Expect `REFUSED...` and `exit=1`. Then confirm it does not block a legitimate
destination:

```bash
echo "" | bash githooks/pre-push origin tailhost:brain-remote/brain-logic.git
echo "exit=$?"
```

Expect no output and `exit=0`.

*Scope of this guard:* it cannot stop a push to an unreachable remote, because
it never runs there. It does stop the case that matters — a real, authenticated
third-party repo — where git fetches refs, runs the hook, and aborts before any
object transfer.

**pre-commit.** No network dependency, so this one fires directly:

Do **not** test with `AKIAIOSFODNN7EXAMPLE`. That is AWS's published
documentation key and gitleaks allowlists it by design, so it produces a
confident "no leaks found" that proves nothing. Use values that are not
allowlisted (these are randomly generated, not real). And not AWS-shaped ones:
GitHub's push protection blocks an `AKIA...` key on sight, fake or not, which
is how the public mirror's first push failed. The two below trip gitleaks
(`generic-api-key`, `github-pat`) and nothing at GitHub, since a PAT with a
bad checksum is not a PAT to it:

```bash
cat > scratch.md <<'SECRETS'
api_key = "q7vX2mNp4LkR9sT1uW8yZ3bC6dF0hJ5eK2wQ"
github_token = ghp_au4LLW6Q7Tpvx9jOFLZgPY6jJm5LZcYMw5nC
SECRETS
git add scratch.md && git commit -m test
rm scratch.md && git reset
```

Expect `BLOCKED: possible secret in staged changes`.

If a test commit does land, remove it: `git reset --hard HEAD~1`.

**Telegram bot tokens are covered.** Gitleaks' default rules handle common
cloud and SaaS formats but caught neither a Telegram bot token
(`1234567890:AAF...`) nor a Tailscale auth key -- both scanned clean against the
defaults. `.gitleaks.toml` in the repo root now adds rules for those two plus a
literal-assigned restic password, extending the defaults rather than replacing
them.

Confirm it still fires before a real token goes in the Keychain. The token is
generated at runtime rather than written here, so this file does not itself
carry a value the scanner has to be told to ignore:

```bash
tok="8123456789:AA$(LC_ALL=C tr -dc 'A-Za-z0-9_-' </dev/urandom | head -c33)"
printf 'telegram_token = %s\n' "$tok" > scratch.md
git add scratch.md && git commit -m test
rm -f scratch.md && git reset
```

Expect `BLOCKED` again. If it commits cleanly, the rule regressed -- check
`.gitleaks.toml` is at the repo root, since gitleaks loads it from the scan
target path.

If either guard passes when it should fail, stop and fix it before continuing.

---

## Step 7 — Create the brain repo

Before `gbrain init`, before ingesting anything.

```bash
bash scripts/init-brain-repo.sh --dry-run
bash scripts/init-brain-repo.sh
```

Creates `~/brain` at mode 700 with the GBrain schema, union-merge
`.gitattributes`, deny-by-default `.gitignore`, and hooks active.

---

## Step 8 — Initialize GBrain

The embedding model is **permanent** — dimensions are written into the schema,
and changing it later forces a full re-index.

```bash
gbrain init --url postgresql://localhost:5432/gbrain \
            --embedding-model ollama:nomic-embed-text
gbrain doctor
```

Do not run bare `gbrain init`. Its default embedding provider is a cloud API,
which would send your notes to a third party.

**A confusing detail:** GBrain talks to Ollama's embedding endpoint at
`http://localhost:11434/v1` — *with* the `/v1`. That does not contradict the
OpenClaw rule. OpenClaw must omit `/v1` because the OpenAI-compat path breaks
**tool calling**; embeddings have no tool calling to break, and GBrain uses the
compat path deliberately. Different endpoints, different rules.

---

## Step 9 — Remotes (Tailscale only)

On whichever machine will hold the bare repos, over Tailscale:

```bash
mkdir -p ~/brain-remote
git init --bare ~/brain-remote/brain.git
git init --bare ~/brain-remote/brain-logic.git
```

Back on the MacBook:

```bash
cd ~/brain-logic && git remote add origin <tailscale-host>:brain-remote/brain-logic.git && git push -u origin main
cd ~/brain       && git remote add origin <tailscale-host>:brain-remote/brain.git       && git push -u origin main
```

Skip this if the desktop isn't on Tailscale yet — both repos work fine with no
remote. Come back before you've ingested anything you'd hate to lose.

---

## Step 10 — Sandbox user

System Settings → Users & Groups → Add User. **Standard**, not Admin. Name it
`brain`. Log in once to create the home directory, then log out; nobody logs
into this account again. Grant it nothing up front; add permissions one at a
time when something actually breaks.

Two facts the installers below assert on every run, as pass conditions:
`brain` must **not** be able to read `$BRAIN_DIR` (your home is mode 750, so
it cannot), and `brain` **must** reach Ollama on `127.0.0.1:11434`. It never
reaches Postgres — peer auth over the socket makes the OS user the credential.

The gateway runs in this account as a LaunchDaemon, not a LaunchAgent: a user
agent lives in `gui/<uid>`, which only exists while that user is logged in, so
it would never start. Every installer that writes into `/Users/brain` needs
`sudo` and asks for it once, up front — run them from a terminal.

---

## Step 11 — Read before connecting anything

- [OpenClaw security](https://docs.openclaw.ai/gateway/security)
- [Gateway exposure runbook](https://docs.openclaw.ai/gateway/security/exposure-runbook)

The detail that bites people: OpenClaw's Ollama `baseUrl` must have **no `/v1`
suffix**. The OpenAI-compat endpoint silently breaks tool calling, which
presents as "the local model is bad at agent work."

---

## Step 12 — OpenClaw + Telegram

**Do not run `ollama launch openclaw` or `openclaw onboard`.** Both install a
gateway in *your* account, on defaults — no Ollama `baseUrl`, no channel, no
tool policy, `StandardErrorPath` at `/dev/null` — which is the unconfigured
owner-side gateway removed on 2026-09-05. OpenClaw itself is already installed
(`npm install -g openclaw`, on `PATH` as `/opt/homebrew/bin/openclaw`):

```bash
openclaw --version      # 2026.8.2 is the version the config template was validated against
```

Get a bot token from [@BotFather](https://t.me/botfather) (`/newbot`). It and
the gateway auth token live in *your* Keychain, never in a file:

```bash
security add-generic-password -a "$USER" -s brain/telegram-token -w
bash scripts/new-gateway-token.sh          # --force rotates
```

Then, in this order — the same two commands apply every later config change:

```bash
bash scripts/install-openclaw-config.sh    # render template -> openclaw validates -> install as brain, mode 600
bash scripts/install-gateway-daemon.sh     # LaunchDaemon com.personalbrain.openclaw-gateway, runs as brain, verifies it came up
```

Never edit `/Users/brain/.openclaw/openclaw.json` by hand. Edit
`config/openclaw.json.template` and re-run both. The agent account cannot
re-render its own config, by design. The first script refuses a template that
OpenClaw's own linter rejects — a rejected config does not error, it crash-loops
with exit 78 and the reason in a log inside `/Users/brain`.

Give the assistant a purpose before you talk to it. Write `SOUL.md` and
`USER.md` in `$BRAIN_DIR/personal/` (USER.md under 4,000 characters — OpenClaw
truncates it silently past that), then copy them across the boundary:

```bash
bash scripts/install-agent-prompts.sh      # --verify-only, --dry-run, --uninstall
```

Without them it runs on a generic persona and invents facts about you.

Pair your Telegram account. Message the bot; it answers with a pairing code
(`dmPolicy: pairing` — every other sender is refused). Approve it from *this*
account, running the CLI as `brain` so it sees the gateway's config:

```bash
sudo -u brain -H openclaw pairing list
sudo -u brain -H openclaw pairing approve telegram <code>
```

Approval writes `commands.ownerAllowFrom` into the installed config.
`install-openclaw-config.sh` carries that key forward on re-render, so pairing
survives config changes.

Finally:

```bash
sudo -v && bash scripts/health-check.sh
```

Every row should read `OK`, including `prompts`. Under sudo it also reports the
gateway's launchd state and socket owner; without it those read `UNKNOWN`,
which is deliberate.

---

## Step 13 — Claude Code login

```bash
claude
# then: /login
claude doctor
```

---

## Step 14 — Hand off

See [the handoff section below](#handoff-to-claude-code).

---

## Handoff to Claude Code

Always start sessions from `~/brain-logic`. Never from `~/brain`, and never
from your home directory — Claude Code takes the directory you launch it in as
its working root, and that directory *is* your privacy boundary.

```bash
cd ~/brain-logic
claude
```

`CLAUDE.md` loads automatically and carries the standing rules. You don't need
to restate them.

**First session prompt:**

> Read CLAUDE.md, README.md, and docs/repo-structure-and-security.md, then
> confirm back to me in three sentences what this repo is and what you are not
> allowed to touch.
>
> Then: I've finished the runbook through step 13. Everything installs and the
> guardrails are verified. I want to work on the first cron jobs — a morning
> briefing and a tracked-item check — as OpenClaw skills under `skills/`.
>
> Start by reading `cron/` and `prompts/routing-policy.md` so you match the
> existing conventions. Work on a branch. Before you write anything, tell me
> what you plan to build and what happens when it fails at 3am.

The confirmation-back is worth the tokens. If it says anything about reading
`~/brain`, you've caught it in the first thirty seconds rather than three weeks
in.

**Good early tasks for it:**

- The two cron skills above
- Wiring `cron/*.sh` into launchd with correct scheduling and logging
- A `scripts/health-check.sh` that verifies Ollama, Postgres, gateway, and last
  successful backup in one command
- Filling in `docs/decision-log.md` as you make calls during the bake-off

**Tasks to keep for yourself:**

- Anything that writes to `~/brain`
- The bake-off judgment — that's a week of your real use, not a benchmark
- Approval-gate policy: which actions need confirmation is a values question
