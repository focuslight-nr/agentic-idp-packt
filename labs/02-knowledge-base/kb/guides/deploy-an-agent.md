# Guide: deploy an agent on the platform

Agents are workloads like any other: they ship through the golden path. What is different is that every agent needs its own identity, a scoped LLM key, only the tools it needs, and no network access beyond them.

## Rules

1. **One identity per agent.** A dedicated ServiceAccount in the `agents` namespace, never `default`.
2. **Read-only by default.** Agents get `get`, `list`, and `watch`, and never read Secrets. Any write goes through a PR, never directly to the cluster.
3. **Tools through MCP.** Agents reach Kubernetes through the read-only Kubernetes MCP server (`k8s-mcp.agents.svc`), not through a raw kubeconfig. Built-in terminal, file, and web tools are disabled.
4. **Models through the gateway.** Agents call models only through LiteLLM, with their own virtual key. Never put provider keys in an agent. In production the provider key is central and hidden from everyone; on a workshop laptop the attendee holds their own capped provider key for their in-cluster gateway, but the agent still only ever sees its virtual key.
5. **No other credentials in the agent.** If the agent's work needs a token (for example, opening PRs), a separate, narrow service holds it and the agent calls that service. Anything an agent can read, a prompt injection can ask it to leak. Hermes proposes fixes in its report; `runbook-bot` opens the triage and fix PRs.
6. **Default-deny egress.** The agent's `values.yaml` enables `networkPolicy`, allowing only DNS, its tools, and the LiteLLM gateway, reached by a namespace and pod selector on port 4000 (LiteLLM runs in the same cluster, so a selector is enough — no VPC CIDR and no port-reservation hygiene rule on the workshop laptop). The policy lives in Git with the agent, so loosening it is a reviewed change. Review those PRs as security changes.
7. **Registered in the catalog.** The agent's `app.yaml` sets `owner` to the team that answers for it.

## Platform team prerequisites

These are created by the platform team, not in the agent's PR:

- The ServiceAccounts and a read-only ClusterRole and binding. The ClusterRole is annotated with `platform.workshop/identity: <agent-name>` so it appears in [agent identities](../generated/agent-identities.md). See `labs/03-hermes-triage/platform/rbac.yaml`.
- The Secret `<agent-name>-llm` in the `agents` namespace, with `OPENAI_BASE_URL` and the agent's LiteLLM virtual key in `OPENAI_API_KEY`.

## Steps

1. **App folder.** Create `labs/<lab>/apps/<agent-name>/` with:
   - `app.yaml`: `name`, `namespace: agents`, `owner`, `description`.
   - `values.yaml`: image, `serviceAccountName`, `envFromSecrets: [<agent-name>-llm]`, `networkPolicy` with explicit `ingress` and `egress`, and the agent's config in `configFiles`. Copy `labs/03-hermes-triage/starter/hermes/values.yaml` as a starting point.

   Every value is documented in the [chart reference](../generated/service-chart.md). The folder is `apps/` — that is the path the ArgoCD ApplicationSet scans (`labs/*/apps/*/app.yaml`).

   > **In Lab 3, `apps/` holds three agents, not one.** The triage setup ships `hermes`, `k8s-mcp`, and `runbook-bot` together, so the lab copies the whole `starter/` folder (`cp -r labs/03-hermes-triage/starter/* labs/03-hermes-triage/apps/`) rather than a single agent folder. Each of the three has its own `app.yaml`, so the ApplicationSet creates one Application for each.

2. **Validate.** Run `./labs/01-golden-path/scripts/validate-apps.sh` and fix any `fail` line.

3. **Regenerate the knowledge base.** Run `./labs/02-knowledge-base/scripts/generate-docs.sh` and commit the result with your change.

4. **Ship.** Open a PR. After the checks pass and the PR is merged, ArgoCD deploys the agent.

## Verify

```bash
kubectl -n agents get deploy,pods
kubectl auth can-i delete pods --as=system:serviceaccount:agents:<agent-name>-reader -A   # must print "no"
kubectl auth can-i get secrets --as=system:serviceaccount:agents:<agent-name>-reader -A   # must print "no"
```
