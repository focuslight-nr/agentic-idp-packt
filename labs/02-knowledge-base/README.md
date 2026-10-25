# Lab 2: The self-documenting knowledge base

**Format:** guided demo, with one "try it" step. **Time:** 5 minutes of the 15-minute Knowledge base section.

## Goal

Make the platform understandable to humans and agents from one source, and make it impossible for that source to drift from the platform.

## What is in this folder

| Path | What it is |
|---|---|
| `scripts/generate-docs.sh` | Generates `kb/generated/` from the chart, apps, alerts, policies, and RBAC. |
| `kb/generated/` | Generated reference. Never edited by hand. Run the generator and commit the result with your change. |
| `kb/guides/deploy-an-agent.md` | Hand-written guide. Lab 3 follows it to deploy Hermes. |
| `runbooks/` | One runbook per alert, plus a template. Alerts link here through `runbook_url`. |
| `llms.txt` | Machine-readable index of the knowledge base. |

The repository-wide agent rules are in [`AGENTS.md`](../../AGENTS.md).

## What changes for agents

- Agents trust what they read. Stale docs are worse for an agent than no docs, so reference docs are generated, and CI fails when they are stale.
- Humans add what generators cannot know: guides, runbooks, and rules in `AGENTS.md`.
- Alerts link to runbooks, so the on-call human and the triage agent start from the same page.
- Agents write back: in Lab 3, Hermes proposes runbook updates through a PR that a human reviews.

## Guided demo

1. Run `./labs/02-knowledge-base/scripts/generate-docs.sh` and walk through `kb/generated/`.
2. Add a value to the chart's `values.yaml` without regenerating, open a PR, and show the `docs-freshness` check failing. Regenerate, push, and show it pass.
3. Show `orders` in the generated service catalog, and walk through the `WorkshopPodCrashLooping` runbook: this is what Hermes reads when `orders` breaks in Lab 3.

## Try it (optional, non-blocking)

Open Cursor in your repository and ask, in a new chat:

> Following the platform knowledge base, what are the exact steps to deploy a new agent called `hermes` on this platform?

Cursor should find `AGENTS.md`, follow it to the guide, and answer with the folder, ServiceAccount, Secret, and PR steps. If it guesses or suggests `kubectl apply`, the knowledge base has a gap. The fix is in the docs, not in the prompt.
