# Decision log

Append-only. Each entry: what was decided, why, and what would change it back.

## 2026-08-18 — Two repos, not one

`brain-logic` (this repo) holds engineering; `~/brain` holds knowledge. The
split enforces the privacy boundary at the filesystem level rather than in a
prompt: Claude Code sessions open only this repo, so there is no `~/brain` path
to resist reading.

*Would reverse if:* never. Merging them re-introduces the exact failure the
split prevents.

## 2026-08-18 — Installer stays in this repo; no public repo for now

`scripts/brain-setup.sh` lives here. Two repos total, not three.

Briefly considered extracting it to a public repo immediately, on the reasoning
that a repo public from commit #1 never needs its history scrubbed. That
reasoning is sound but does not apply here: the installer is a *single
self-contained file* with nothing identifying in it, so publishing it later
means copying it into a fresh repo — fresh history, nothing to scrub. The
history trap only bites when publishing a repo *with* its history.

Because this repo is private, `scripts/brain-setup.conf` holds real
configuration rather than being a gitignored copy of an example file.

*Would reverse if:* the installer grows enough that other people asking for it
becomes a maintenance burden worth its own repo.

## 2026-08-18 — No third-party git remote for `brain` or `brain-logic`

Remotes live on the Tailscale mesh. Offsite redundancy is restic (client-side
encrypted), not a git host.

Rejected: private GitHub + git-crypt. git-crypt encrypts file contents but not
filenames or directory structure — and in a brain repo, the filenames under
`people/` *are* the sensitive data. It is the option that feels secure and isn't.

*Would reverse if:* never for `brain`. For `brain-logic`, only via a separate
curated public repo with fresh history.

## 2026-08-18 — nomic-embed-text (768d) as the embedding model

GBrain's Ollama default. Local, cheap to store, fast to search.

Note: GBrain's *own* default provider is a cloud API — a bare `gbrain init`
would send personal notes to a third party. `--embedding-model ollama:...` is
mandatory, not stylistic.

*Would reverse if:* retrieval quality proves inadequate in real use — and it
costs a full re-index, so the bar is high.

## 2026-08-18 — One local model, not a Glimmer/Qwen ensemble

Considered routing between both bake-off models by their benchmark strengths
(Glimmer for MCP/tool-use, Qwen for terminal/computer-use) instead of picking one.

Rejected, for three reasons in descending order of force:

1. **It does not fit.** Both are ~17-18GB against ~15-16GB usable on 24GB.
   `MAX_LOADED_MODELS=1` is not a preference, it is arithmetic. Routing between
   them means a 10-30s model swap per route change, in a loop that re-prompts
   constantly.
2. **On the Mini it competes with Q8.** Two Q4 models (~35GB) fit in 48GB, but
   Q8 of one model (~30GB) does not leave room for a second. We already judged
   Q4→Q8 the single biggest local-reliability upgrade available, so the RAM is
   spoken for. One better model beats two worse ones.
3. **The premise is untested.** The strength split is a benchmark artifact. The
   bake-off exists precisely because we do not yet trust those numbers to
   describe this workload. Architecting around a distinction currently under
   test is backwards.

Also: a second routing axis inside "local" multiplies config surface against the
one axis that is actually load-bearing (data sensitivity, local vs Claude), and
adds a silent-misroute failure mode.

**The asymmetric version is still open.** A small model (3-4B, ~2-3GB) resident
*alongside* the main one, absorbing classification, routing, and simple triage —
"is this email worth surfacing" calls. That works because co-residency is cheap
at that size. Two 17GB peers is the shape that cannot work; big-plus-tiny is the
shape that can.

*Revisit at:* Phase 2, once the real query mix is visible.

## 2026-08-18 — Guardrail tests must use non-allowlisted values

The first pre-commit test used `AKIAIOSFODNN7EXAMPLE` and passed cleanly —
because gitleaks allowlists AWS's published documentation key by design. The
hook ran, scanned, and reported "no leaks found." A green result that proved
nothing.

Two lessons, both general:

1. A test fixture chosen for being *safe to publish* is often chosen for being
   *invisible to scanners*. Those are the same property.
2. The pre-push test had the same class of flaw: pushing to a nonexistent remote
   fails at connection setup, before git ever runs the hook. The failure looked
   like the guard working.

Both tests now use inputs that exercise the actual code path. General rule for
this repo: a guardrail test must be able to distinguish "the guard fired" from
"something else failed first."

**Open:** gitleaks' default ruleset does not clearly cover Telegram bot tokens
(`1234567890:AAF...`), which is the first real secret this machine will hold.
Needs a custom `.gitleaks.toml` before step 12.

## 2026-08-18 — Brain lives at ~/Code/brain; paths centralized

Kept the brain repo alongside brain-logic under `~/Code` rather than moving it
to `~/brain`. No functional difference — it is a sibling, not nested, which is
the only property that matters.

The real fix was that three cron scripts and the restore drill hardcoded
`$HOME/brain` and would have silently no-opped: the nightly commit doing
nothing, and the backup quietly excluding the one irreplaceable directory. Now
all locations live in `config/paths.env`, sourced by everything that needs them.
`brain-commit.sh` also fails loudly if the brain repo is missing rather than
exiting 0.

*Rule going forward:* no filesystem path appears in more than one file. A path
duplicated across scripts is a path that will be updated in some of them.

## 2026-08-18 — The brain does not auto-index the filesystem

Considered auto-ingesting all documents and files on the machine so the brain
has full context without manual curation.

Rejected. Three reasons:

1. **Retrieval degrades.** Vector search quality is not monotonic in corpus
   size. Junk chunks compete for the top-K slots on every query. In conservative
   mode the model sees ~10 chunks; each junk chunk displaces a real page.
2. **It maximizes the top-ranked threat.** T1 is prompt injection. Auto-ingest
   makes every file that ever landed in Downloads — PDFs, cloned-repo READMEs,
   saved email — into context a Q4 local model reads. Quantized models resist
   injection worse than frontier ones. This would be the single largest attack
   surface expansion available.
3. **Forgetting becomes impossible.** Deleting a source file does not remove its
   embeddings. Auto-ingest costs the ability to *not* remember something —
   client work, other people's data, documents that should not have been kept.

**The load-bearing distinction is authored vs received**, not any folder
boundary. Content you wrote is safe to ingest aggressively; injection is not a
concern in your own notes. Content that arrived from outside is an attack
surface however useful it looks.

**Architecture instead:**
- Auto-ingest a small set of authored sources (notes, specific repos), synced
  nightly by the dream cycle.
- Everything else goes through `inbox/`. Filing is deliberate. The small
  friction is doing real work.
- For the rest of the disk, give the agent **search, not memory** — an on-demand
  `mdfind`-backed lookup over an allowlist of roots. "Knows about my files"
  without "has silently absorbed my files." Retrieval without ingestion.

*Would reverse if:* never wholesale. The searchable-roots allowlist can grow.

*Next action:* read-only filesystem search skill — good first Claude Code task.

## 2026-08-18 — RUNBOOK.md's own test values block the pre-commit hook

Reconciling against the reference tarball made the runbook uncommittable.
Section 8 now uses three synthetic credentials chosen precisely because
gitleaks flags them — the previous `AKIAIOSFODNN7EXAMPLE` was allowlisted and
proved nothing. So the document that teaches you to test the hook is itself
caught by the hook. Not a mistake in either piece; the two requirements are
genuinely in tension.

Resolved with `.gitleaksignore` holding three line-anchored fingerprints
(`RUNBOOK.md:<rule>:<line>`), not a path allowlist on `RUNBOOK.md`. Verified by
appending a fresh `ghp_` token to the same file and confirming it still blocked.
Line anchoring means the entries stop matching if the file shifts, so the
failure direction is "blocks again," not "silently permits."

This does not close the open item from *Guardrail tests must use
non-allowlisted values* — there is still no Telegram bot-token rule, and
`.gitleaksignore` cannot add one. A `.gitleaks.toml` is still needed before
step 10.

*Would reverse if:* the runbook stops carrying live-looking credentials, or a
`.gitleaks.toml` with a scoped allowlist replaces the fingerprint list.

## 2026-08-18 — paths.env does not honor a pre-set BRAIN_DIR (open defect)

All three cron scripts carry this comment above the sourcing block:

> Anything already exported wins, so a one-off override still works:
> `BRAIN_DIR=/tmp/x bash cron/brain-commit.sh`

It does not. `config/paths.env` uses plain assignment (`BRAIN_DIR="$HOME/Code/brain"`),
so sourcing it clobbers anything exported. Confirmed:

```
BRAIN_DIR=/tmp/override-probe bash -c '. config/paths.env; echo $BRAIN_DIR'
-> /Users/<owner>/Code/brain
```

Found by using the documented override to test the missing-brain-repo guard.
The override was discarded, so the test ran `brain-commit.sh` against the real
brain repo — it reached `git status` inside `$BRAIN_DIR` and would have
committed there had anything been uncommitted. The documented safe way to
exercise these scripts points them at live personal data.

Left unfixed pending a decision, because changing it is a hand-edit to the
reference and hand-editing is what caused the drift this commit repaired. The
fix is `: "${BRAIN_DIR:=$HOME/Code/brain}"` per line, or drop the comment.

*Would reverse if:* the override is deliberately not wanted, in which case the
comment in all three scripts should go instead — the two must agree.

## 2026-08-18 — .gitleaks.toml: rules for the formats actually in play

Closes the open item from *Guardrail tests must use non-allowlisted values*.

Confirmed the gap rather than assuming it: a synthetic Telegram bot token and a
Tailscale auth key both scanned **clean** against gitleaks' default ruleset. The
hook has been working this whole time and would not have caught the first real
secret this machine is about to hold.

Three rules added, `useDefault = true` so nothing is given up:

- `telegram-bot-token` — `<id>:AA<32-34>`. The length floor is what lets
  RUNBOOK.md and this log keep writing `1234567890:AAF...` without tripping the
  scanner. Docs should be able to name a format.
- `restic-password-literal` — no fixed format to match, so it matches the
  dangerous *shape*: the password written as a literal. Values starting with `$`
  are excluded so `RESTIC_PASSWORD=$(security find-generic-password ...)` in
  cron/restic-backup.sh does not flag itself.
- `tailscale-auth-key` — anticipatory. Step 12 is deferred, but an auth key is
  the credential that step introduces, and the rule is cheaper to write now than
  to remember later.

Proven, not assumed. Eight cases: each of the three rules fires on a synthetic
value; a default rule still fires (defaults not clobbered); and four negatives
stay silent — the `${TELEGRAM_TOKEN}` placeholder, the Keychain read in
restic-backup.sh, the truncated doc example, and a near-miss short token.
Then end-to-end through the real hook: a staged Telegram token gets
`BLOCKED: possible secret in staged changes` and no commit lands. The CLI test
proves the rule; only the hook test proves the wiring.

Also confirmed `.gitleaksignore` is still load-bearing under the new config —
removing it surfaces exactly the three RUNBOOK.md findings again.

*Would reverse if:* a rule starts producing false positives in normal work. Fix
the regex rather than deleting the rule; a scanner people route around is worse
than no scanner.

## 2026-09-02 — Postgres trust is a sandbox escape; peer auth blocked by gbrain

Setting up the `brain` sandbox user surfaced that the account provides no
isolation as configured. Homebrew's default `pg_hba.conf`:

```
local   all all                trust
host    all all 127.0.0.1/32   trust
```

`trust` ignores the OS user, the only login role is the owner's, that role is
superuser, and the server runs as the owner. So the sandboxed account can
connect as superuser with no password and reach `pg_read_file()` and
`COPY ... FROM PROGRAM` — reading the mode-700 brain repo and executing code as
the desktop user. Postgres' own shipped comment says as much: it warns that
local trust lets any local user connect as any user, "including the database
superuser."

This is T1 with the agent's own database as the escape route, and it makes the
file-permission question downstream: hardening the repo while leaving this open
accomplishes nothing.

**Chosen fix (P1): socket-only `peer`.** The OS user becomes the credential —
nothing to store, rotate, or leak — and there is no TCP path a local account can
reach. Implemented in `scripts/harden-postgres-auth.sh`.

**Blocked, and reverted.** gbrain 0.46.19.0 has no Unix-socket path. Every DSN
form (`?host=/tmp`, `?host=%2Ftmp`, `//%2Ftmp/`) still dials TCP and fails on
`::1`. Applying peer auth locked gbrain out of its own database; pg_hba and the
DSN were restored from backup and verified byte-identical.

*Also worth recording:* the first verification of the socket DSN was wrong.
`gbrain doctor` reported `[OK] connection` — but over TCP, which was still
trusted at that point. A green check that passes for the wrong reason, which is
the same failure as the `AKIAIOSFODNN7EXAMPLE` test. The test only became
meaningful once TCP was closed and the check could distinguish the two paths.
`scripts/harden-postgres-auth.sh` now refuses to run without
`ASSUME_SOCKET_CLIENTS_OK=1` so this cannot be repeated by accident.

**Open — the hole is still open.** Three ways forward, in preference order:

1. Upgrade gbrain (0.48.1.0 is available) and re-test socket support. Keeps P1
   intact with no new secret. Upgrade touches schema, so it is a deliberate act.
2. Narrow TCP exception with `scram-sha-256` for a dedicated non-superuser role
   that owns the gbrain database, password in the Keychain and rendered like
   `${TELEGRAM_TOKEN}`. Closes the escalation and keeps the superuser reachable
   only over the socket. Costs one more secret, and makes
   `~/.gbrain/config.json` a credentials file needing the same treatment as
   `~/.openclaw/openclaw.json`.
3. Do nothing until OpenClaw exists. Acceptable only while no untrusted input
   reaches the machine — which stops being true at step 12.

*Would reverse if:* option 1 works, in which case option 2's secret is
unnecessary and should not be created.

## 2026-09-02 — Postgres is socket-only peer auth; gbrain reaches it via PGHOST

Applied. The trust-based escalation recorded above is closed: `pg_hba.conf` is
now `local ... peer` with TCP explicitly rejected, so no local account can
connect as a role it does not own, and the superuser is reachable only over the
Unix socket by the OS user of the same name. The agent account has no role in
the cluster at all.

Getting there took an upgrade and one non-obvious detail.

**Upgrade.** gbrain 0.46.19.0 → 0.48.1.0, schema v132 → v145 (`schema_version:
Version 145 (latest: 145)`). Backed up first with `cron/nightly-pgdump.sh` —
its first real run, 232K to `$BRAIN_BACKUP_DIR`.

**The detail.** gbrain's client is postgres.js, not libpq, and the two disagree
about how to reach a socket:

| form | psql | postgres.js |
|---|---|---|
| `postgresql:///gbrain?host=/tmp` | socket | forwards `host` to the server as a startup option; server rejects it |
| `postgresql:///gbrain` (bare) | socket | **TCP to ::1** |
| `postgresql:///gbrain` + `PGHOST=/tmp` | socket | socket |

So the URL cannot express this and the environment must. `config/paths.env`
exports `PGHOST=/tmp` — the only exported var in that file, because it has to
cross into a child process rather than just be read by a script.

*Failure mode if PGHOST is missing:* postgres.js falls back to TCP, pg_hba
rejects it, and the caller gets a hard connection error. Loud, not silent —
which is the behaviour this repo wants. **Interactive `gbrain` runs do not
source `paths.env`**, so a bare terminal invocation will fail until
`export PGHOST=/tmp` is in the shell profile. Any future launchd job running
gbrain must set it in `EnvironmentVariables` for the same reason.

**On verifying this.** Three separate green checks along the way were false.
`[OK] connection` passed twice while the client was quietly on TCP, because TCP
was still trusted at the time — the same shape of error as the
`AKIAIOSFODNN7EXAMPLE` test and the nonexistent-remote pre-push test. What
settled it was observing `pg_stat_activity.client_addr` during a real gbrain
run and seeing NULL. **General rule, now three for three in this repo: when a
guard and a fallback can both produce "it worked", the test has to name which
one fired.**

*Would reverse if:* gbrain gains real socket support in the URL, in which case
the PGHOST export can go and the DSN carries it. Rollback is
`cp /opt/homebrew/var/postgresql@17/pg_hba.conf.backup-* pg_hba.conf` plus a
reload; dumps are in `$BRAIN_BACKUP_DIR`.

## 2026-09-02 — cron/*.sh wired into launchd; restic deliberately not loaded

Three user agents, `com.personalbrain.{brain-commit,pgdump,restic}`, installed
by `scripts/install-cron-agents.sh`. Ordering is load-bearing: commit the brain
(03:00), dump the database (03:15), then back both up (03:45). restic must run
after pgdump or it snapshots yesterday's dump.

**What each does when it fails at 3am**, which is what shaped the design:

- `brain-commit` logged `NO BRAIN REPO` and exited 1 with nothing else. launchd
  does not surface a nonzero exit, so the brain would quietly stop being
  committed and you would find out weeks later. It now posts a notification on
  that path, matching what it already did for a gitleaks-blocked commit.
- `nightly-pgdump` was already loud — logs, notifies, exits 1. Correct, and the
  one that matters most: a silent failure here is discovered on restore day.
- `restic-backup` cannot run at all. restic is not installed and
  `brain/restic-password` is not in the Keychain. **Its plist is written but
  deliberately not loaded.** A job that fails every single night is worse than
  no job, because it teaches you to dismiss the notifications that do matter.
  `--status` reports the gap every time it is asked.

**The non-obvious part: launchd hands a job an almost empty environment.** Both
of these are required in `EnvironmentVariables` and neither is obvious from
reading the scripts:

- `PGHOST=/tmp` — pg_hba is socket-only now, so without it the job connects
  over TCP and is rejected.
- `USER` — gbrain's client takes the Postgres role name from it. Without it the
  server sees user `unknown` and peer auth fails with an error that points at
  authentication rather than at the missing variable. Found by running gbrain
  under `env -i`, which is the closest thing to launchd's environment.

`PATH` too: launchd's default has no `/opt/homebrew/bin`, so `restic`, `psql`
and `gbrain` would all be missing.

Verified by kickstarting through launchd rather than running the scripts in a
shell — a shell test proves nothing about the environment launchd supplies.
pgdump: exit 0, 249K written. brain-commit: exit 0, `no changes`, empty stderr.

*Also fixed in passing:* `scripts/install-ollama-agent.sh` still wrote logs to
`$HOME/brain-logic/logs` from before the repo moved under `~/Code`. The running
Ollama agent has been writing to a stray `~/brain-logic/logs/` containing a 66KB
error log nobody would think to look at. The installer now sources `paths.env`;
**the running agent keeps the old path until it is reinstalled.**

*Would reverse if:* the jobs move under OpenClaw's own cron once it exists. Two
schedulers running the same jobs would be worse than either.

## 2026-09-02 — The agent account gets one rendered file, not the repo

Running OpenClaw as the sandboxed `brain` user, as the install checklist
requires, hit a wall: `/Users/<owner>` is mode 750, so `brain` cannot
traverse to `~/Code/brain-logic` at all, and Keychain items are per-user, so it
cannot read `brain/telegram-token` either. `scripts/render-config.sh` therefore
cannot run on the agent's side.

Three ways out were on the table:

1. Loosen `/Users/<owner>` to o+x so `brain` can traverse in.
2. Store a second copy of the Telegram token in `brain`'s own Keychain and give
   it a copy of the repo.
3. Render on the owner's side and hand over only the rendered file.

Chose 3. The other two widen the blast radius to solve what is really a
one-file delivery problem: 1 exposes every world-readable thing under the home
directory to the account we are specifically sandboxing, and 2 duplicates a
secret, which doubles the places it can leak from and the places it must be
rotated. The agent needs `openclaw.json` at runtime; it does not need the
template, the scripts, or the token in raw form.

`scripts/install-openclaw-config.sh` renders here, installs to
`/Users/brain/.openclaw/openclaw.json` mode 600 owned by `brain`, and then
verifies. The verification is the part worth keeping: it asserts the boundary
still holds by requiring the negative cases to fail — `brain` must NOT be able
to read `$BRAIN_DIR`, must NOT be able to connect to Postgres — while requiring
Ollama on loopback to succeed. It confirms the token placeholder was substituted
by checking length and the absence of `${`, never by printing the value.

*Consequence, accepted:* the agent cannot re-render its own config. Every
template change needs this script re-run by the owner. That is a feature — the
account that reads untrusted input should not be able to rewrite its own
model, channel, or approval policy.

*Would reverse if:* OpenClaw grows a way to read config from a path the owner
controls, in which case the file can live on this side and be read directly.

## 2026-09-05 — The gateway runs as `brain`, as a LaunchDaemon

A status check found the sandbox only half-built. `scripts/install-openclaw-config.sh`
had been written and committed but never run: `/Users/brain/.openclaw/openclaw.json`
did not exist. The gateway that was actually serving was OpenClaw's own
`ai.openclaw.gateway` agent in the **owner** account, and it had two further
problems:

- Its `ProgramArguments` pointed at `~/.openclaw/service-env/…-env-wrapper.sh`,
  a directory that no longer exists. The process survived only because it was
  already resident; the next reboot or `KeepAlive` restart would have failed.
- `StandardErrorPath` was `/dev/null`, so that failure would have left nothing
  to read.

There was also no `openclaw.json` anywhere in the owner's home, meaning the
running gateway was on defaults — no Ollama `baseUrl`, no channel, no approval
policy. The sandbox decision of 2026-09-02 was on paper only.

**A user agent could not fix this.** Agents are bootstrapped into `gui/<uid>`,
which exists only while that user has a login session. Nobody logs into the
sandbox account, so an agent in `/Users/brain/Library/LaunchAgents` would never
start. `scripts/install-gateway-daemon.sh` therefore installs a LaunchDaemon at
`/Library/LaunchDaemons/com.personalbrain.openclaw-gateway.plist` with
`UserName brain`, which starts at boot with no session — the same shape as
`com.personalbrain.gpulimit`. `HOME` is set explicitly in
`EnvironmentVariables`; without it the process inherits root's and never finds
its config.

The old owner-side agent is deleted rather than repaired. Repairing an agent
being abandoned is wasted work, and leaving it in place would contend for port
18789. The installer waits for the socket to clear after `bootout` — the bind
race otherwise presents as a config error.

*Consequences, both accepted:*

- The gateway loses anything gated on a GUI session or the owner's TCC grants.
  Telegram is network-only and unaffected; a future iMessage channel would not
  work from this account.
- The agent starts with an empty `~/.openclaw` workspace and state. Anything
  paired inside the old gateway must be redone once. That is the point of the
  move, not a side effect — the account that reads untrusted input should not
  inherit the owner's session.

*Also learned, again:* the first `--dry-run` reported "brain cannot execute
node" when the real cause was sudo having no terminal to prompt from. That is
the same defect as the two guardrail-test entries above — a check that cannot
tell "the guard fired" from "something else failed first" — and it pointed at
the sandbox boundary, the most misleading possible answer. Preflight now calls
`sudo -v` first and fails with the real reason.

*Would reverse if:* OpenClaw grows first-class support for running its own
service as another user, in which case its installer should own the plist
rather than this repo.

## 2026-09-05 — `gateway.mode` is required; the config is validated before install

The first real start of the sandboxed gateway crash-looped 19 times, exiting
78 (EX_CONFIG) every 10 seconds. The cause was one missing key:

    Gateway start blocked: existing config is missing gateway.mode

`config/openclaw.json.template` had never been loaded by OpenClaw — the old
owner-side gateway ran with no config file at all — so nothing had ever
validated it. `gateway.mode` is `local` or `remote` (OpenClaw 2026.8.2);
`local` is correct here.

`gateway.bind` is set explicitly to `loopback` even though that is already the
default. On a machine whose entire design is a privacy boundary, an exposure
setting should not be able to change because an upstream default changed.

**The real fix is the validation, not the key.** `install-openclaw-config.sh`
now parses the rendered config before installing it and refuses to hand over
one that is missing `gateway.mode` or an unsubstituted token; `--verify-only`
checks the installed copy for the same. Values are compared, never printed.

Why that matters more than the key itself: a rejected config does not produce
an error anyone sees. It produces a launchd crash loop, with the reason in a
log inside another user's home directory, reachable only with sudo. The
distance between "the assistant is down" and "here is the missing key" was
three round trips. Anything the gateway refuses to start without belongs in
that validator as it is discovered.

*Superseded within the hour* — see the next entry. OpenClaw already has an
authoritative validator; the hand-rolled check was replaced with it.

## 2026-09-05 — The template had never been validated; openclaw validates it now

`gateway.mode` was not the only thing wrong with `config/openclaw.json.template`.
It was the only thing the gateway reported *first*. Once past it, strict schema
validation rejected four more:

| What | Reality |
|---|---|
| `channels.telegram.token` | The key is `botToken` |
| root `approval` block | No such key exists in OpenClaw |
| model-level `think` | Only valid inside `params` |
| every `"// ..."` key | Unrecognized keys are rejected outright |

None of these had ever been detected, because the file had never been loaded by
OpenClaw. A template that has never been parsed by the thing that consumes it is
a guess, however carefully written.

**The `approval` block is the one that matters.** It read
`require: [send_message, send_email, purchase, file_delete, git_push]` and had
been sitting in the repo looking like a working confirmation gate. It never was
one. The real surfaces are `tools.allow` / `tools.deny` (deny wins, wildcards)
and exec approvals. It is deliberately left unset rather than translated:
which actions need confirmation is a values question and belongs to the owner.
**The current effective posture is no tool gate at all** — that was already
true, it was just invisible.

*The comment keys are kept and stripped at render.* They document the values
they sit next to — the `/v1`-breaks-tool-calling warning earns its place beside
`baseUrl`, not in a doc nobody opens — so `render-config.sh` drops every key
starting with `//` on the way out. The template stays strict JSON rather than
JSON5 so the installer can parse and check it before handing it over.

*Validation is now openclaw's own.* `install-openclaw-config.sh` runs
`OPENCLAW_CONFIG_PATH=<staging> openclaw doctor --lint` and refuses to install a
config that fails. The hand-maintained required-key list written earlier the
same day passed a config with three schema violations in it — a check that is
always one release behind the schema it is checking is worth very little.
Proven against all four defects above: each is rejected with its own path, and
the current template is accepted.

Rendering now stages into a private `mktemp -d` instead of `$HOME`. OpenClaw
derives its state root from the directory holding the config, so linting a
staging file in the home directory invites it to reason about paths there —
and the token no longer touches `$HOME` at all.

*Still open:* `core/doctor/gateway-auth` warns that gateway auth is off. On a
loopback bind that is not fatal, and the gateway starts, but any local process
can drive the agent unauthenticated. That is a posture decision for the owner.

*Would reverse if:* the agent account ever needs to edit its own config, which
would make render-then-install the wrong shape entirely.

## 2026-09-05 — Gateway auth token, mDNS off, and a tool policy that exists

Three settings added once the gateway actually started, plus one more defect in
the verification around it.

**Gateway auth token, rendered from the Keychain.** The gateway logged that it
had *"Generated a runtime token for this startup without changing config;
restart will generate a different token"* and suggested persisting one with
`openclaw config set gateway.auth.token`. That command is the agent account
rewriting its own config, which is precisely what the sandbox shape forbids.
`scripts/new-gateway-token.sh` generates 48 random characters into the Keychain
as `brain/gateway-token`, and the template renders it like the Telegram token.
The direction of control stays the same: the owner writes, the agent receives.

Without it, `gateway.auth` was off — on a loopback bind that is not fatal, but
any local process could drive the assistant with no credential. On a machine
that has two accounts specifically so that not everything on it is equally
trusted, that was the wrong default to leave in place.

*Accepted:* `security` will not read a password from stdin, so the value passes
through argv and is briefly visible to `ps`. The only other account here is the
agent, which receives that same token in its config file — so it leaks to
nobody who does not already hold it. **That reasoning does not survive a third
local account.**

**mDNS advertising off.** The bundled `bonjour` plugin auto-starts on macOS and
was announcing this gateway over the LAN — `port=18789 state=announcing`, with
the machine name in the record. Nothing could connect, since the bind is
loopback, but a repo built around a privacy boundary should not broadcast the
existence of the assistant to every device on the network.
`discovery.mdns.mode: "off"` suppresses advertising without disabling the plugin.

**A tool policy, replacing the block that never worked.** `tools.deny` now
denies `group:runtime` (exec, process, code_execution), `group:ui` (browser,
screen, terminal, portal, canvas, dashboard), `group:nodes` (nodes, computer —
computer control), the three mutating filesystem tools, and `gateway`, which is
the agent's route to administering itself. `read`, web search/fetch, sessions,
memory, messaging, goals, media and cron stay.

This is a starting point, not a settled policy, and it is deliberately the
runbook's own posture for the sandbox account: grant nothing up front, add back
one at a time when something actually breaks. Note that with no `tools.profile`
set, the effective policy before this was `full` — every tool, including
computer control and shell exec, on an account whose entire job is reading
messages from the internet.

*Consequence:* the planned `mdfind` filesystem-search skill will need `exec`
back, or its own tool. Better to hit that as a visible failure than to leave
exec available for everything else in the meantime.

**And the verification lied again.** `lsof` only reports sockets owned by other
users when it runs as root, and this daemon runs as `brain` by design. The
check printed `FAIL: port 18789 listener is 'nothing'` while `curl` and `pgrep`
directly beneath it both confirmed the gateway was up and owned by `brain`. It
now runs under `sudo -n` and reports `?` — "cannot tell without sudo" — as a
distinct outcome from "nothing is listening", because those two are not the
same claim. Third instance today of the same lesson: **a check that cannot
distinguish its failure modes reports a confident wrong answer.**

*Would reverse if:* a second person or device needs gateway access, at which
point token-in-config becomes the wrong shape and this should move to SecretRefs.

## 2026-09-05 — Four silent deaths from `set -euo pipefail` in one session

`scripts/new-gateway-token.sh` printed nothing and stored nothing, twice, on
the machine it was written for. Two independent bugs in seven lines:

1. `existing_len=$(security find-generic-password ... | tr ... | wc -c)` —
   `security` exits 1 when the item does not exist, `pipefail` propagates that
   out of the assignment, and `set -e` exits. The script died *before creating
   the item it exists to create*, on exactly the path it was written for: the
   item not existing yet.
2. `tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48` — `head` exits at 48 bytes,
   `tr` dies on SIGPIPE, `pipefail` reports 141, `set -e` exits. Silent again.

Same session, same class, two more: `who="$(listener)"` where `lsof` exits 1
with nothing listening (killed the gateway installer's verification), and the
identical `security` pattern in `install-openclaw-config.sh`'s Telegram check.

The common shape is **a nonzero exit that is a normal result, not an error** —
"no such Keychain item", "nothing is listening on that port", "I have the bytes
I asked for" — arriving inside a construct where `set -e` cannot tell the
difference. Every one produced silence rather than a message, and two of them
produced silence in a *verification* step, which reads as success.

Convention added to `CLAUDE.md`: wrap the fallible part in `{ cmd || true; }`,
and end bounded pipelines with a consumer that reads to EOF (`cut`, not
`head -c`).

*Also fixed:* `install-gateway-daemon.sh` refused to re-install, because it
booted out the owner-side agent but not its own daemon, then waited for a port
its own daemon was still holding. Re-install is the normal way to apply a
config change here, so that path has to work.

*Would reverse if:* these scripts move to a language with real error handling,
which is the honest fix if this recurs a fifth time.

## 2026-09-06 — memory-core disabled: it defaults to OpenAI embeddings

First live Telegram exchange looped: `🗂️ Session Settings blocked` /
`🧠 Memory Search` repeating with no answer. Two causes, one of them serious.

**The serious one.** The gateway log carried:

    [memory] sync failed (session-startup-catchup): Error: No API key found for
    provider "openai".

OpenClaw's bundled `memory-core` plugin embeds conversation content to make it
searchable, and `memory.search.provider` **defaults to `openai` when unset**.
It was trying to send this machine's conversation content to a cloud API. It
failed only because no OpenAI key is configured — the routing principle in
`CLAUDE.md` held by accident, not by design. Had this machine ever had an
OpenAI key configured for anything, personal content would have gone out.

`plugins.entries.memory-core.enabled: false`. GBrain is the memory layer here;
a second store that phones out is not wanted at any price. Re-enable only with
`memory.search.provider` pinned to `ollama` — the same rule that already
governs GBrain's embeddings.

*This is the second time a default has pointed at a cloud provider* — the first
was `gbrain init`'s default embedding provider, caught in the runbook. Assume
any component's default embedding path is remote until checked.

**The loop's other half.** `🗂️ Session Settings blocked` is the `gateway`
tool, denied yesterday as the agent's self-administration surface. The denial is
working as intended; the agent retries it at session start and the card shows.
Kept denied. If it proves noisy once memory is gone, the fix is to allow
`gateway` back, not to widen the tool policy generally.

**Runtime-owned config keys now survive a re-render.** `openclaw pairing
approve` wrote `commands.ownerAllowFrom` into the installed config —
so the agent account *can* modify its own config, which the 2026-09-02 entry
assumed it could not. Re-rendering would have silently dropped the command
owner and de-authorized the operator for privileged commands.

`install-openclaw-config.sh` now carries `commands` forward from the installed
file. The template cannot hold it: it is a Telegram account id discovered at
pairing time, and personal data that does not belong in this repo.

*Caught in testing:* the first version of that merge used
`sudo cat "$DEST" | python3 - "$STAGING" <<'PY'`, where the heredoc occupies
stdin and the piped config never arrives — `json.load(sys.stdin)` reads the
script's own text. Both configs are passed as arguments now. Proven both ways:
`commands` is carried forward when present, and reported as nothing to carry
when absent.

*Would reverse if:* GBrain gains a first-class OpenClaw integration, at which
point memory-core's tools might front it rather than duplicate it.

## 2026-09-06 — The agent has no SOUL, and a tool catalog it cannot handle

memory-core is confirmed off — no `[memory] sync failed` lines after the
restart. The agent then looped differently:

    [tools] update_goal failed: goal not found
      raw_params={"status":"complete","note":"Goal completed - provided
      comprehensive summary of all 8 commits with detailed breakdowns."}

repeating, alongside a `web_fetch` of
`https://docs.openclaw.ai/concepts/soul`. Read those two together and the
diagnosis is not subtle: the model was closing goals it never opened, and
looking up what a "soul" is. **It has no purpose configured.**

**The architectural conflict.** `prompts/SOUL.md.template` says the real file
lives in `$BRAIN_DIR/personal/SOUL.md`, symlinked into `~/.openclaw/`, and
`scripts/init-brain-repo.sh` still instructs exactly that. That design predates
the sandbox. The agent's `~` is now `/Users/brain`, and `brain` provably cannot
read `$BRAIN_DIR` — the config installer asserts that failure as a pass
condition. **So the assistant is running with no soul, no user context, and no
stated purpose.** The symlink instruction in `init-brain-repo.sh` cannot work
and should not be followed.

This is the same shape as the config problem solved on 2026-09-02 — personal
content the agent needs, in a place the agent cannot reach — and it wants the
same answer: render or copy on the owner's side, install one file into the
agent account. It is **not** being decided unilaterally here: SOUL.md and
USER.md are personal writing, and how they cross the boundary is the owner's
call.

**Interim: `tools.profile: "minimal"`.** That is `session_status` only.
Deliberately severe and explicitly temporary. Replies are not tools, so the
assistant can still hold a conversation — which is the thing that has never
once worked end to end and needs to, before anything is added.

The judgement behind it: `qwen3.6:27b` is not a frontier model, and a large
tool catalog is not free. Every tool is prompt surface it has to reason about,
and this one spent an entire turn failing to close an imaginary goal instead of
sending the answer it had already written. The deny list stays alongside the
profile, so a future profile change cannot silently re-grant shell exec.

*Note the cost of the loop:* every retry is a fresh inference pass on a 16GB
model. The machine getting hot enough to notice was this loop, not idle
keep-alive.

*Would reverse if:* the bake-off moves to a model that handles wide tool
catalogs, at which point re-widen deliberately and watch for the same signature.

## 2026-09-06 — The restic job was loaded, and health-check gets three states

Two things, both about failures that announce themselves as nothing at all.

**The restic agent was loaded.** `install-cron-agents.sh:153` refuses to load
it until `restic_ready()` passes, and `--status` reported the prerequisites as
missing — yet `launchctl print gui/501/com.personalbrain.restic` answered, which
only a loaded job does. It had never fired (no `logs/restic.log`), so how it got
loaded is unrecoverable; a manual `bootstrap` during setup is the likely path.

Its next 03:45 would have died at `cron/restic-backup.sh:19`, on
`security find-generic-password` returning nonzero under `set -euo pipefail` —
*before* the `{ ... } || { ... notification; }` block that exists to make this
loud. No log line, no notification, launchd not surfacing the exit status. The
fourth instance of the same landmine, and the first one found in a job that had
not run yet rather than after the fact.

Booted out. The plist stays on disk, which is the state the installer intends.

*Also unfixed, deliberately:* `restic_ready()` checks the binary and the
Keychain item but not `BRAIN_RESTIC_REPO`, which `restic-backup.sh:21` requires
and `config/paths.env` does not set. Install restic and add the password and the
guard passes, the job loads, and it fails nightly on the third prerequisite.
Left for whoever does the restic work, and called out in `HANDOFF.md`.

**`scripts/health-check.sh` reports OK / DOWN / UNKNOWN, not pass/fail.** The
distinction is the whole design. A refused connection on loopback is proof that
nothing is bound — that is DOWN. A timeout is not: a gateway mid-inference on a
27B model and a wedged one are identical from outside, so that is UNKNOWN. The
privileged facts are the same case. The gateway is a system-domain LaunchDaemon
whose socket belongs to `brain`, so `launchctl print` and `lsof` both need root;
the script uses `sudo -n` only and reports "needs root" rather than guessing.
Two states would collapse "cannot tell" into "broken", and a check that cries
wolf on every unprivileged run is one nobody reads — the same reasoning that
keeps the restic plist unloaded.

Consequences worth knowing:

- An HTTP probe is the authoritative liveness signal and any status code counts,
  401 included. `install-gateway-daemon.sh`'s `--status` uses `curl -fsS`, which
  treats 401 as failure; it happens to be right today only because the gateway
  answers 200 unauthenticated on `/`.
- Ollama serving is checked separately from Ollama serving *the configured
  model*, read from `config/openclaw.json.template` — which is valid JSON and
  `jq`-readable, comment keys and all.
- Postgres is checked twice: `pg_isready` for the server, then a real
  `select 1`, because peer auth means the OS user is the credential and the
  server being up says nothing about this user reaching this database.
- restic's absence is reported, never scored. A known gap that fails the run
  every night trains you to ignore the runs that mean something.
- Exit 0 / 1 / 2 for ok / something down / something unknown.

*Caught in testing:* `config/paths.env` assigns unconditionally, so
`BRAIN_BACKUP_DIR=/nope bash scripts/health-check.sh` was silently ignored and
three fault injections "passed" against the real, healthy paths.
`cron/restic-backup.sh:11-13` documents the opposite ("anything already exported
wins"), and that comment is wrong for every variable in the file. health-check
snapshots overrides before sourcing rather than change shared config —
`PGHOST` is forced to the socket on purpose. Ten fault injections after that:
both down paths, both timeouts, missing model, four backup states, and the
exit codes. The sudo branch is unverified, needing a password this session
could not supply.

*Would reverse if:* something starts consuming the output non-interactively, at
which point UNKNOWN needs a policy — page or ignore — rather than a number.

## 2026-09-07 — Audio dies because a 17GB model starves the mlock floor

Reported symptom: after the assistant runs, audio stops working — Spotify,
video, anything — until the machine is rebooted. Speakers fine.

**Root cause, from `log show --predicate 'process == "coreaudiod"'`:**

    HALB_SharedBuffer::Lock: mlock failed: addr 0x102098000, byte size 81920
    HALS_IOContext_Legacy_Impl::IOWorkLoop: failed to start the hardware
    StartIOThread: the IO thread failed to start, Error: 2003329396

2003329396 is `'what'`, CoreAudio's unspecified hardware error. CoreAudio wires
(mlocks) an 80KB buffer to hand the output device a real-time-safe region.
macOS refuses every mlock once free memory falls below
`vm.global_no_user_wire_amount` — **5,898 MB** on this machine. So the audio
device never starts, and `coreaudiod` stays alive and healthy the whole time,
which is why the speakers test fine and only a reboot appears to fix it.

Measured across a single model unload:

| State | Free memory |
|---|---|
| 17GB model resident | 7% (~1.7GB) — a third of what mlock requires |
| model unloaded | 81% (~19.9GB) |

312 mlock failures in 18 hours, each paired 1:1 with an IO-thread start failure.

**The budget this implies:** 19.9GB free − 5.9GB floor = **~14GB is the largest
resident model this machine can hold and still start an audio device.** The
current one is 17GB. Being GPU-wired at 100%, those bytes are neither
compressible nor swappable, so the pressure lands entirely on everything else.
No tuning closes a 3.4GB gap: `iogpu.wired_limit_mb=20480` permits the GPU to
wire 20 of 24GB, which is what makes breaching the floor possible, but lowering
that ceiling only spills layers onto the CPU. `27b-q3_K_M` (~13GB) is marginal;
a 14B at q4 (~9GB) has room. **Model size is now an audio constraint, not only
a quality one** — a real input to the bake-off, and the owner's call.

*Honest limit of the diagnosis:* mlock failures appear in every hour of the log,
including hours when no model was loaded. The machine runs tight generally
(6GB of 7GB swap in use). The model is the dominant contributor, not the only one.

*Recovery without a reboot,* in this order — restarting the daemon while memory
is still under the floor just fails again:

```bash
ollama stop qwen3.6:27b-q4_K_M
sudo killall coreaudiod
```

## 2026-09-07 — The configured Ollama server was never the one running

Found while chasing the audio bug. `com.personalbrain.ollama` had been
crash-looping **every 10 seconds since setup**:

    Error: listen tcp 127.0.0.1:11434: bind: address already in use

Ollama.app's menu-bar server (started by a login item) owned the port.
`install-ollama-agent.sh` quits the app before installing — but the app comes
back at the next login and wins, and `KeepAlive` then respawns the losing agent
forever. Consequences, all silent:

- `OLLAMA_CONTEXT_LENGTH`, `OLLAMA_KEEP_ALIVE`, `OLLAMA_KV_CACHE_TYPE`,
  `OLLAMA_FLASH_ATTENTION`, `OLLAMA_MAX_LOADED_MODELS` **were never in effect**.
  The assistant has been talking to a default-configured server since day one.
- The endpoint answered the whole time, so every check that probed
  `127.0.0.1:11434` reported health. "A server answered" and "our server
  answered" are different facts, and only the second one was ever wanted.
- Its logs went to `~/brain-logic/logs/` — not this repo. `LOG_DIR` fell back to
  `${BRAIN_LOGIC_DIR:-$HOME/brain-logic}` on a run predating that variable, and
  646KB of the reason accumulated in a directory nobody had cause to open. The
  fallback is now a hard failure: a wrong log path is worse than none, because
  it looks like logging.

**`BRAIN_KEEP_ALIVE` default cut 30m → 5m.** Decided by the owner, given the
audio finding above: 30m of residency after every message means audio is broken
for most of the day. 5m matches what the default-configured server was
effectively doing, so it is not a regression from observed behaviour. Reloads
cost seconds while the weights are still in the page cache.

The installer now refuses to install an agent that would lose the port, and
verifies after loading that the agent's own pid — not merely *some* pid — holds
`:11434`, printing the environment that actually took effect.

`scripts/health-check.sh` gained an `ollama-svc` row for exactly this: agent
loaded, not crash-looping, and owning the port, plus the live `context` and
`keep-alive` read from the running process rather than from the plist. Verified
against five injected faults: foreign server on the port, nothing listening,
agent absent, agent loaded-but-stopped, and a purpose-built crash-looping job.

*Not done, and it will undo all of this:* Ollama.app's "launch at login" is
still on. No script here can turn it off — it is an SMAppService login item, not
a plist this repo owns. Next login, the app wins the port again. health-check
reports it within one run; that is the whole mitigation.

*Would reverse if:* Ollama ships a supported way to configure the desktop app's
server environment (ollama/ollama#16896), at which point the agent is redundant.

## 2026-09-07 — SOUL.md and USER.md cross the boundary by copy

The decision left to the owner on 2026-09-06 is settled. Three answers.

**Where they live: a permanent copy in the agent account.**
`/Users/brain/.openclaw/workspace/`, mode 600, owned by `brain`, installed by
`scripts/install-agent-prompts.sh` from `$BRAIN_DIR/personal/`. The owner
copies; the agent never reaches across the boundary. Same shape as the config
answer on 2026-09-02, and the installer asserts the same pass condition: after
installing, `brain` must still fail to read `$BRAIN_DIR`.

The alternative considered and rejected was session-time injection through the
`agent:bootstrap` hook, with the content held by an owner-side daemon and
fetched over a local socket, so it never lands on the agent's disk. Rejected on
cost/benefit rather than principle: it buys a narrower at-rest window with an
always-on daemon, an IPC surface the sandboxed account can call at will, custom
code against an internal hook API that upgrades can break, and a new silent
failure where the assistant loses its persona mid-conversation. A compromised
agent under that design simply asks the daemon for the content. On a FileVault
machine where this copy is in no backup set, the residual gain is thin.

**How much of them: SOUL.md in full, USER.md deliberately trimmed.** Not a
privacy compromise — a runtime constraint. Per OpenClaw's own docs, `USER.md`
is injected under a **hard, separate 4,000-character budget**, and oversized
bootstrap files are *truncated at injection, not rejected*. A full dossier
therefore reaches the agent as an arbitrary prefix of itself, cut mid-sentence,
every session, with nothing reporting it. The only real choice is whether the
owner picks what survives or the truncator does. `SOUL.md` falls under
`bootstrapMaxChars` (20,000), which is ample. The installer refuses an
over-budget `USER.md` outright rather than let it be silently cut.

**The broken instruction: fixed, in three places, and it was wrong twice over.**
`init-brain-repo.sh:142-144` and both `prompts/*.template` files said to symlink
these from `$BRAIN_DIR/personal/` into `~/.openclaw/`. Beyond the symlink
pointing at a directory `brain` cannot read, **`~/.openclaw/` is the wrong
destination regardless of any sandbox**: these are *workspace* files
(`~/.openclaw/workspace/`), while `~/.openclaw/` holds config, credentials and
sessions. On a single-account machine with no boundary at all, that instruction
would still have done nothing. It has been in the repo since setup.

Two properties worth knowing:

- **No gateway restart is needed.** OpenClaw reads workspace files at the start
  of every session, so a re-run lands on the next message. The corollary is that
  a stale copy is indistinguishable from a fresh one — the agent's files do not
  track their source, and only re-running the installer updates them.
- **A missing SOUL.md is silent.** OpenClaw injects a "missing file" marker and
  continues with a generic persona. That is precisely the state that produced
  *"I can see from your workspace that you prefer concise updates"* about a
  workspace that did not exist. `health-check.sh` gained a `prompts` row for it.

The script never prints file contents — only paths, character counts and a
12-character hash. It is run by an assistant that must not read the owner's
personal writing, and output is the obvious way that leaks. Character counts use
`wc -m`, not `wc -c`: the budget is characters, and one em dash is three bytes.

*Would reverse if:* OpenClaw's `agent:bootstrap` hook becomes a stable public
API, at which point the injection design costs much less than it does today.

## 2026-09-07 — The model stays; there is nothing smaller to move to

The audio budget said the resident model should be under ~14GB and this one is
17GB, so the obvious answer was a smaller model. The registry says otherwise.

`registry.ollama.ai` does not serve `/tags/list` for these repos, but manifest
lookups work — verified against a tag known to exist before trusting any
negative result:

    qwen3.6:27b-q4_K_M -> 200      (control)
    qwen3.6:14b        -> 404
    qwen3.6:27b-q3_K_M -> 404

Probing the plausible space leaves:

    qwen3.6:      latest, 27b, 27b-q4_K_M, 27b-q8_0
    muse-glimmer: latest, 30b

**Neither bake-off candidate ships a smaller variant, and qwen3.6's only other
quant is larger.** So the choice is not "27B or a 14B" — it is "keep a candidate
you are evaluating, or abandon both for an unevaluated third family on no
quality data, to fix an annoyance." Keeping it. Context length is not a lever
either: the KV cache at 16384/q8_0 is a fraction of a gigabyte against a 3.4GB
overshoot; the weights are the whole problem.

**Mitigation instead: `scripts/audio-recover.sh`.** The failure is sticky —
freeing memory later does not revive a device whose IO thread already failed to
start, which is why it looked like only a reboot helped. The daemon has to be
restarted, and the model has to be unloaded *first* or the restart reproduces
the failure. That ordering is the whole script. `--status` reports free memory
against the floor and what is resident, changing nothing.

Combined with keep-alive at 5m, the exposure is now roughly five minutes after
each message rather than thirty, with a two-second recovery instead of a reboot.

**The budget becomes a selection criterion.** When the bake-off next considers a
candidate, ≤14GB resident is a hard requirement on this machine, alongside
quality. A model that breaks audio for five minutes per message is paying a real
cost that a benchmark will not show.

*Would reverse if:* qwen3.6 ships a smaller or more aggressively quantized
variant, or the machine gains RAM. Re-probe with the manifest method above
rather than assuming a tag exists — this session recommended a 14B that does not.

## 2026-09-07 — Two health-check bugs, found by running it under sudo

Both invisible until the first privileged run, and both worth recording because
the shapes recur.

**`sudo -n wc -m < file` does not read a file as root.** The shell performs the
redirection *before* sudo runs, as the invoking user. Against a mode-600 file
owned by `brain` that is a "Permission denied" on stderr and an empty read, so a
correctly installed SOUL.md reported `? chars` and USER.md reported `0 chars` —
which reads as "installed but empty", the opposite of the truth. The path has to
be an argument: `sudo -n wc -m "$file"`. **Privilege applies to the command,
never to a redirect.**

**`last exit code = (never exited)` is not a number.** Splitting on whitespace
and taking field 5 yields `(never`, which rendered as
`launchd: running, last exit (never` — a line that looks like the tool is broken
in the middle of an otherwise clean report. Now only numeric exit codes print.

Neither changed a verdict — the row was `OK` throughout, correctly. But a check
whose details are visibly wrong stops being read, which is the same failure mode
as a check that cries wolf.

## 2026-09-07 — The heartbeat was driving the model every 30 minutes

Found while checking whether the setup was ready to hand off. The new Ollama
server's log showed `/api/chat` at 19:51:58, 20:21:57, 20:52:00, 21:22:00 —
exactly half-hourly, ~38 seconds of 100% GPU each. Nobody was chatting.

It is OpenClaw's **heartbeat monitor**: a scheduler-owned automation, on by
default, `agents.defaults.heartbeat.every` defaulting to 30 minutes. Per its own
docs, *"If no scratch exists, the heartbeat still runs and the model decides
what to do."* No checklist exists here, and `tools.profile` is `minimal`, so
every half hour a 27B model was loaded to work out that there was nothing to do.

The cost is not the GPU time. **A 17GB resident model puts free memory under the
floor macOS requires to start an audio device**, so an unattended heartbeat was
breaking audio for the length of the keep-alive window, every 30 minutes,
indefinitely — which is why audio failures appeared in every hour of the
CoreAudio log, including hours when nobody had messaged the assistant. That
observation was recorded earlier the same day as "the machine runs tight
generally"; this is the actual explanation.

Set to `"0m"`, which OpenClaw's docs recommend while evaluating a setup. Only the
recurring cadence stops; event-driven wakes still work. Validated against the
schema before installing, per the standing rule that a rejected config is
invisible:

    OPENCLAW_CONFIG_PATH=<rendered> openclaw doctor --lint --only core/doctor/gateway-config
    {"ok":true,"checksRun":1,"checksSkipped":58,"findings":[]}

*This is the third on-by-default behaviour to be caught pointing somewhere
expensive* — after `memory-core` defaulting to OpenAI embeddings and `gbrain
init` doing the same. The pattern holds: **assume any component's defaults are
tuned for a hosted deployment on someone else's hardware, and check.**

*Would reverse if:* the agent gains tools and a monitor checklist worth running.
Then set a cadence deliberately, with the audio budget in mind — every heartbeat
is a keep-alive window with no audio.

## 2026-09-07 — The restic guard checks three things, and the config installer asks for sudo first

Two small changes from the first post-handoff session, both in the same family
as the entries above: a check that cannot tell its failure modes apart.

**`restic_ready()` now checks `BRAIN_RESTIC_REPO`.** Left deliberately unfixed
on 2026-09-06 and called out in `HANDOFF.md`; fixed now because it is repo
work that does not depend on the backend decision. The guard checked the binary
and the Keychain password, and `cron/restic-backup.sh` dies on
`${BRAIN_RESTIC_REPO:?}` without the third — so satisfying the first two would
have loaded a job that fails every night at 03:45. `--status` and the install
path now name exactly which prerequisites are missing, in the same words
`health-check.sh` uses. Verified with shims for all four states: none present,
binary+password only, repo only, and all three (loads in `--dry-run`).
`config/paths.env` carries a commented, documented `BRAIN_RESTIC_REPO`
placeholder. **Which backend it names is the owner's call and is not made
here.**

**`install-openclaw-config.sh` preflights `sudo -v`.** Run `--verify-only`
without a cached credential and it reported `FAIL: brain cannot read
/Users/brain/.openclaw/openclaw.json` and `FAIL: brain cannot reach Ollama` —
both were sudo asking for a password on a non-interactive stdin, both read as
the sandbox boundary being wrong. Identical to the 2026-09-05 "brain cannot
execute node" misdiagnosis, in the other installer. `--dry-run` touches
nothing and stays unprivileged.

**The heartbeat is observed off.** No `POST /api/chat` between 21:22 and
22:16, spanning the old cadence's 21:52 slot and a full 30 minutes after the
gateway came up on the `0m` config at 21:35:23. The 2026-09-07 heartbeat entry
above was true-by-construction when written; it is now true-by-observation.

*Also learned:* a Claude Code session has no terminal, so `sudo -v` cannot
cache a credential from inside it, and macOS caches sudo per-tty by default.
The privileged rows of `health-check.sh` — gateway launchd state, socket
owner, `prompts` — are therefore only observable when the owner runs the
check from their own terminal. That is not a defect in the script; it is what
UNKNOWN was designed to say.

**All three handoff items are now observed.** Under sudo from the owner's
terminal: `prompts OK` at 1991 and 861 characters, gateway `launchd: running`
with the socket owned by `brain`. On Telegram, asked how SOUL.md affects it,
the assistant described its rules and declined to claim context it was not
given — the opposite of the invented-workspace turn of 2026-09-06. One turn.

**`health-check.sh` refuses to run as root.** The owner ran it as
`sudo bash scripts/health-check.sh` — reasonable, and what this session's
message asked for — and it reported `ollama-svc DOWN` and `postgres DOWN`
while both were fine. As root, `gui/$(id -u)` is `gui/0`, which holds no
agents, and Postgres peer auth sees role `root`. Two confident wrong DOWNs
from a check whose whole design is not to do that. It now exits 2 with the
correct invocation when `EUID` is 0: sudo is cached with `sudo -v`, and the
script runs as the owner and uses `sudo -n` only for the facts that need it.
The docs said this; the script now enforces it.

*Would reverse if:* restic's prerequisites move somewhere the guard cannot
read, at which point the job itself has to be the check.

## 2026-09-12 — The public mirror: a third repo, built by script, never this one

The 2026-08-18 entry left one door open for `brain-logic`: "a separate curated
public repo with fresh history." The owner wants to walk through it. This is
the mechanism, and three things found on the way.

**`scripts/export-public.sh` is the only path to public.** It stages an
allowlist of files from `HEAD` — never the working tree, so nothing unreviewed
leaks — scans the result with gitleaks over the whole tree, scans it again
for the owner's username, home path, hostnames and git identity (derived from
the machine at run time, so the script itself names nobody), and only then
syncs into a separate repo and commits under the GitHub noreply address.
Repeat runs add commits there; the mirror's history is a series of snapshots
of this repo, never its log. The script never pushes. The push is one `gh`
command it prints, and it is the owner's.

Not shipped: `HANDOFF.md` (the state of *this* machine, and who is paired)
and `scripts/brain-setup.conf` (real configuration; the `.example` ships).
`githooks/` ships whole, pre-push included, because a reader building their
own private copy wants the hook that refuses third-party hosts — but the
mirror itself never sets `core.hooksPath`, or that hook would refuse the one
push it exists for. The pre-push hook here is unchanged: this repo still
cannot push to GitHub, and that is the point.

**Found: `.gitleaksignore` had been stale since 2026-09-07.** Its three
fingerprints were anchored to RUNBOOK.md lines 196–198; the synthetic
credentials had moved to 201–203 when step 4 grew. The 2026-08-18 reasoning
was that a shift makes the hook block again, "the safe direction to fail."
It did not block, because `gitleaks git --staged` scans only the changed
hunks and those lines were never in a hunk. The first whole-tree scan — the
export's — was the first thing to notice. The three values are now
allowlisted **by value** in `.gitleaks.toml`, and the ignore file is gone.
Proven both ways: the runbook's fakes pass when staged; a freshly generated
fake token on the same line shape is blocked.

**Redacted from the record.** The owner's username appeared in four places
in this log and the Telegram account id once in `HANDOFF.md`. Replaced with
`<owner>` and a pointer to the installed config. The log is append-only by
convention; substituting an identifier for a placeholder does not change
what was decided, and a history that is going nowhere near GitHub does not
need to be rewritten for it.

*Still the owner's:* a `LICENSE` (the export warns when there is none; a
public repo without one grants nobody anything), and the `gh repo create`.
The `README.md` still reads as a first-person private repo. That is
accurate for the copy it describes; whether the mirror wants its own
framing is a later, cheap change.

*Would reverse if:* the mirror ever needs to carry something the allowlist
excludes, at which point the exclusion is the thing to argue about — not
whether to flip this repo public. Never that.

## 2026-09-14 — The runbook's fake AWS key blocked the mirror's first push

`gh repo create --public --push` created `mtwind/brain-logic` and then GitHub
push protection rejected the push: "Amazon AWS Access Key ID" and "Secret
Access Key", in `RUNBOOK.md` and in the `.gitleaks.toml` allowlist that
named the same values. Both were the synthetic pair from the guardrail test.
GitHub matches provider formats on sight; it does not know or care that a
value is allowlisted in this repo's scanner config.

Two ways out: click GitHub's bypass link twice with "used in tests", or stop
using provider-shaped fakes. The second, because the bypass would be needed
again by anyone cloning the mirror and pushing it anywhere with push
protection on, and because a runbook that trips the next scanner along is
the same defect it was written to catch. The test now uses a generic
high-entropy `api_key` (gitleaks `generic-api-key`) and the existing fake
PAT (`github-pat`; GitHub ignores it because the checksum is wrong).
Verified: both trip the pre-commit hook; the export's whole-tree scan is
clean; the push goes through.

The mirror was deleted and rebuilt rather than amended: push protection
scans every commit in the push, so a history that ever held the AKIA value
cannot be pushed, only replaced. Cheap while the mirror is one commit old;
the reason to keep the mirror's history disposable.

## 2026-09-17 — restic backs up to the Windows desktop over Tailscale; the desktop also holds a bare git remote

**Backend: the owner's Windows desktop, SFTP over Tailscale.** Decided by the
owner on 2026-09-07 and built 2026-09-16/17. No cloud account exists yet, and
an external disk is unplugged at 03:45 by definition. This is off-disk, not
off-site: fire or theft takes both machines. Accepted, with B2 as the obvious
second repository later — restic makes a second target a second job, not a
redesign. restic encrypts on the MacBook, so the desktop holds ciphertext.

Windows-side setup was done by a Claude session on the desktop, from a
self-contained brief carrying the MacBook's public key and nothing about the
project beyond "encrypted backups it cannot read". Three Windows facts cost
time and are worth keeping:

- Windows OpenSSH ignores a user's own `authorized_keys` for Administrators
  unless the `Match Group administrators` block in `sshd_config` is removed.
- A loopback SSH test on the desktop proves nothing about the MacBook's key.
  The only test that counts runs from the MacBook with `-o BatchMode=yes`,
  which is the condition the nightly job runs under.
- Windows OpenSSH hands commands to `cmd.exe`, which does not strip the
  single quotes git puts around the repository path, so `git push` fails
  with a doubled-quote path. Setting sshd's `DefaultShell` to Git's
  `bash.exe` fixes it and leaves SFTP untouched.

First backup: 431 files, 4.9 MiB, `restic check` clean; job loaded, fires
03:45 daily; `health-check.sh` now reads the job's last result and time
from its log; `restore-drill.sh` restores the latest snapshot into scratch
and counts files. When it fails at 03:45: desktop asleep, Tailscale down on
either end, or the key rejected all write `RESTIC FAILED` to `logs/restic.log`
and post a notification.

**The desktop holds a bare `brain-logic.git`, as remote `desktop`.** RUNBOOK
step 9, finally, minus half of it: **no git remote for the brain repo.** That
half predates restic. The brain is already on the desktop encrypted; a bare
git remote would add a plaintext copy of the most sensitive data here to a
machine that is not a sandbox and whose disk encryption is unknown. Restic
only, for the brain. *Would reverse if:* the desktop gains verified disk
encryption and a concrete reason to want history rather than snapshots.

The remote is named `desktop`, not `origin`: it is a copy, not the source of
truth, and the owner pushes to it by hand. The pre-push hook allows it as a
mesh destination.

**Also found: Ollama.app had owned `:11434` since 22:59 on 2026-09-07** —
ten minutes after launch-at-login was turned off, almost certainly because
opening the app to change the setting started its server, which outlived
the window. The agent crash-looped for ten days behind an endpoint that
answered normally, exactly the 2026-09-07 landmine. Quitting the app via
AppleScript left `ollama serve` orphaned under launchd; it had to be killed
by pid. The agent reclaimed the port within 15s. Nothing catches this but
running the health check, which nobody did between 09-07 and 09-17. That
gap is the actual finding.

## 2026-09-17 — Machine identities live in `config/paths.local.env`, never in the repo

The first export after the restic work staged
`BRAIN_RESTIC_REPO="sftp:<user>@<desktop>.<tailnet>.ts.net:brain-restic"` —
the owner's Windows username, the desktop's Tailscale name and the tailnet
identifier. Not a credential, and the name resolves only inside the tailnet,
but it is the same class of fact the export already refuses for this machine,
and the scan missed it because its list is derived from this machine alone.
Caught by reading the snapshot before pushing; the mirror was reset.

Decided by the owner: keep it private, and not only for privacy — the repo is
meant to become fully public, and a stranger reading someone else's hostnames
in a config file learns nothing useful and may copy them.

`config/paths.env` now sources an optional, gitignored `paths.local.env`
last, for anything that identifies a person or a machine rather than the
layout. `BRAIN_RESTIC_REPO` moves there; `paths.env` keeps the documented,
commented placeholder. The desktop's names go in `config/export-denylist.local`
(also gitignored), so the export refuses them from now on. Proven: the
denylist blocked the old committed value in `--dry-run`; the cron guard,
`health-check.sh` and the job itself still read the repo through the include.

*Would reverse if:* the number of local values grows past a handful, at
which point a real config layering scheme beats a second env file.

## 2026-09-17 — brain-logic's working repo moves to a private GitHub repo

Reverses the 2026-08-18 "no third-party remote" rule for `brain-logic` only.
The brain repo is unchanged: never a third-party remote, restic only.

What changed since August: the tree no longer names the owner or either
machine (`paths.local.env`, the export denylist), gitleaks has scanned every
commit, and the public question is already answered by the fresh-history
mirror. What did not change, and is why this is private rather than public:
the *history* holds the Telegram account id, the home path, the machine name,
the retired AWS-shaped test fakes (which GitHub push protection rejects on
sight), and every version of `HANDOFF.md`. A private repo shows that history
to nobody new; a public one would require rewriting it.

Gains: pull requests as the merge mechanism, which is how the owner already
works; a hosted copy of history updated on every push. The desktop bare repo
of the same morning is redundant and its remote entry is removed, so a stale
copy cannot masquerade as current. The pre-push hook allows exactly one URL
and still refuses the public mirror's, so an accidental `git push` to the
wrong repo fails.

Costs, accepted: GitHub holds the history, including the identifiers above,
under the owner's account; the security-boundary map in this log is visible
to anyone who ever gets that account. Same reasoning as the gateway token
on 2026-09-05: it leaks to nobody who does not already hold the keys.

*Would reverse to fully public* once the bring-up is over and `HANDOFF.md`
stops being a weekly machine-state file: rewrite history with git filter-repo,
drop the excluded files from it, run the identifier scan in the pre-push hook,
and retire the mirror. One afternoon, later.

*Would reverse to local-only* if a third person ever needs write access to
the GitHub account, or if the account is compromised.
