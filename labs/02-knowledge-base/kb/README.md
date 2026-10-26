# Platform knowledge base

The single place where humans and agents learn how to use the platform.

## Generated (never edit by hand)

Regenerated from the platform sources by `labs/02-knowledge-base/scripts/generate-docs.sh`. CI fails any PR that leaves them stale.

- [Golden path chart reference](generated/service-chart.md): every value the `service` chart accepts.
- [Service catalog](generated/service-catalog.md): every app on the platform, its namespace, owner, and image.
- [Alerts and runbooks](generated/alerts.md): every alert and the runbook it links to.
- [Policies](generated/policies.md): every Kyverno policy enforced on the cluster.
- [Agent identities and permissions](generated/agent-identities.md): what each agent is allowed to do.

## Hand-written

- [Guide: onboarding a workshop environment (human or agent harness)](guides/onboarding.md)
- [Guide: deploy an agent on the platform](guides/deploy-an-agent.md)
- [Guide: the platform map — how the apps, labs, and tools link together](guides/platform-map.md)
- [Runbooks](../runbooks/): one per alert, linked from the alert's `runbook_url`.
