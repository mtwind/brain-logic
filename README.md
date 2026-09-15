# brain-logic

The engineering half of my Personal Brain. Config, skills, prompts, cron jobs,
scripts, and design docs.

**This working copy is private and stays private.** Not "private for now" — see
[docs/repo-structure-and-security.md](docs/repo-structure-and-security.md).
The public mirror is a separate repo with fresh history, built by
`scripts/export-public.sh` from an allowlist of committed files, scanned for
secrets and for anything naming the owner or the machine before a single
commit is made. Nothing is ever flipped public in place.

## The rule that makes this repo work

**This repo contains no personal knowledge.** The brain — everything I know,
everyone I know — lives in a separate repo (`BRAIN_DIR` in `config/paths.env`,
currently `~/Code/brain`) that Claude Code is never pointed at. That separation is the enforcement mechanism for the privacy
boundary, not a filing preference. A rule in a prompt can be talked around; a
directory an agent was never given can't be read.

If you are an agent working in this repo: do not read, list, or reference the
brain repo at `BRAIN_DIR`. If a task seems to need it, stop and ask.

## Layout

```
config/     paths.env (filesystem locations) + config TEMPLATES (never secrets)
skills/     OpenClaw skill definitions
prompts/    routing policy, SOUL/USER templates (structure only)
cron/       scheduled jobs — backups, brain commits, checks
scripts/    installer, brain-repo init, config rendering, restore drills
docs/       runbook detail, repo/security design, decision log
logs/       hook and cron output (gitignored)
```

## Bootstrap a new machine

```bash
git clone git@<tailscale-host>:brain-logic.git ~/brain-logic
cd ~/brain-logic
git config core.hooksPath githooks       # local config, does not survive a clone
bash scripts/brain-setup.sh --dry-run
bash scripts/brain-setup.sh
bash scripts/init-brain-repo.sh          # creates ~/brain with hooks in place
```

Full ordered procedure: [RUNBOOK.md](RUNBOOK.md).

## Secrets

None are in this repo, and none ever will be. They live in the macOS Keychain:

```bash
security add-generic-password -a "$USER" -s brain/telegram-token -w
security find-generic-password -a "$USER" -s brain/telegram-token -w
```

`scripts/render-config.sh` reads the keychain and writes the real
`~/.openclaw/openclaw.json` from the template in `config/`.
