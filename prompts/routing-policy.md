# Routing policy

Work is routed by **data sensitivity**, not by difficulty.

## Local model (Ollama)

Anything that touches personal context, without exception:

- Reading, triaging, or summarizing email and messages
- Any query against GBrain
- Calendar, notes, reminders
- Morning briefings and tracked-item checks
- Anything referencing a person, relationship, or personal circumstance

This holds even when a frontier model would do it better. The point of the
system is that this data does not leave the machine; convenience is not a
reason to break that.

## Claude (frontier tier)

- Repo work in `brain-logic` and other project repos
- Feature development, refactors, debugging
- Infrastructure and tooling
- Research on public information

**Claude-facing sessions receive no GBrain, email, or personal context by
default.** Exceptions are explicit, per-task, and scoped — never a standing
grant, never "just this directory."

## The seam

The dangerous case is not a mis-routed task. It's a local-model summary of
personal data being passed into a Claude prompt as "context." That is
exfiltration with extra steps. When a task needs both tiers, the local half
returns a decision or an artifact, not a digest of personal information.
