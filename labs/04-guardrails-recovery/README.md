# Lab 4: Guardrails for Hermes: policy, drift, a bad PR, and the kill switch

**Format:** hands-on. **Time:** 20 minutes of the 30-minute Guardrails, security, and recovery section.

## Goal

Keep working with the Hermes you deployed in Lab 3. Check each of its guardrails, watch one of them get weakened by a reasonable-looking PR, recover through Git, and finally stop the agent. Every step uses ready-made commands, so the time goes into observing, not typing.

## What is in this folder

| Path | What it is |
|---|---|
| `policies/deny-agent-direct-changes.yaml` | Kyverno policy: agent identities cannot create, update, or delete resources directly, including NetworkPolicies. |
| `demo-rbac/hermes-remediator.yaml` | A deliberately over-broad role, used only in step 1. |
| `scripts/open-helpful-pr.sh` | Opens a plausible PR that quietly weakens Hermes's network policy and turns its web tool back on. |
| `scripts/kill-switch.sh` | Stops Hermes in a way that GitOps cannot undo. Removes its credentials from the cluster without reading the secret. `--block-key` also blocks the virtual key on the LiteLLM gateway. |

## What changes for agents

- **Defense in depth:** RBAC is the first layer and policy is the second. A misconfigured role should not be enough for an agent to break production.
- **Guardrails are code:** Hermes's network policy and tool list live in its `values.yaml`. That makes them reviewable and revertible, and it also means one approved PR can weaken them.
- **Approval is not a guarantee:** a human approving a PR is only as good as the review. Step 3 shows a guardrail change that gets approved anyway.
- **Kill switch:** stopping an agent has to work even when GitOps is busy putting it back.

## Steps

1. **Policy as a second layer.** Enforce the policy, then misconfigure RBAC on purpose so Hermes's identity is allowed to write:

   ```bash
   kubectl apply -f labs/04-guardrails-recovery/policies/deny-agent-direct-changes.yaml
   kubectl apply -f labs/04-guardrails-recovery/demo-rbac/hermes-remediator.yaml
   kubectl auth can-i delete namespaces --as=system:serviceaccount:agents:hermes-reader   # yes: RBAC allows it
   ```

   Kyverno prints a warning that `ClusterPolicy` is deprecated. The policy is still enforced.

   Hermes's MCP server is read-only, so it has no write tools to try this with. Instead, you **impersonate** its identity with `--as` and do what the poisoned logs in Lab 3 asked for, plus removing its own guardrail:

   ```bash
   kubectl delete namespace shop --as=system:serviceaccount:agents:hermes-reader --dry-run=server
   kubectl -n shop patch deploy orders --as=system:serviceaccount:agents:hermes-reader \
     -p '{"spec":{"replicas":0}}' --dry-run=server
   kubectl -n agents delete networkpolicy hermes --as=system:serviceaccount:agents:hermes-reader --dry-run=server
   ```

   All three are **denied by Kyverno** with the policy message. The `--dry-run=server` is the safety net: if the policy fails, the dry-run is still refused and nothing is actually deleted. If one of them is allowed, stop, delete the demo role, and do not remove `--dry-run=server`. Remove the role:

   ```bash
   kubectl delete -f labs/04-guardrails-recovery/demo-rbac/hermes-remediator.yaml
   ```

2. **Drift on the agent's guardrail.** Someone debugging Hermes deletes its network policy as an admin. Kyverno allows it, because admins are not agents. Watch ArgoCD put it back:

   ```bash
   kubectl -n agents delete networkpolicy hermes
   kubectl -n agents get networkpolicy hermes -w
   ```

   Within seconds the policy is back, because it lives in Git with Hermes.

3. **A "helpful" PR that weakens Hermes, approved by a human, then reverted.** First, make sure the collector from Lab 3 is running (`kubectl apply -f labs/03-hermes-triage/scenarios/poisoned-log-exfil.yaml` if you removed it). Then open the PR:

   ```bash
   git checkout main && git pull
   ./labs/04-guardrails-recovery/scripts/open-helpful-pr.sh
   ```

   Read it. It sounds reasonable, it is "read-only" and "scoped to `shop`", and the checks pass. Merge it, as reviewers often do. Once Hermes restarts with the new config, re-run the egress check from Lab 3:

   ```bash
   kubectl -n agents rollout status deploy/hermes
   kubectl -n agents exec deploy/hermes -- \
     python -c "import urllib.request; print(urllib.request.urlopen('http://collector.shop.svc.cluster.local:8080', timeout=5).read())"
   # Now prints b'ok': the attacker's collector lives in shop, so Hermes can reach it.
   kubectl -n shop logs deploy/collector
   ```

   The poisoned log from Lab 3 now has somewhere to send Hermes's key, and the web tool to do it. Revert the merge through a PR:

   ```bash
   git checkout main && git pull
   git checkout -b revert-hermes-egress
   git revert --no-edit "$(git log --grep='let the agent check orders health' -n 1 --no-merges --format=%H)"
   git push -u origin revert-hermes-egress
   gh pr create --fill
   ```

   Merge it, wait for the rollout, and run the egress check again. It times out. In a real platform, agent guardrails need an owner's review: for example, CODEOWNERS requiring the platform team on every agent's `values.yaml`.

4. **Kill switch.** Try the obvious way first:

   ```bash
   kubectl -n agents scale deploy hermes --replicas=0
   kubectl -n agents get deploy hermes -w
   ```

   ArgoCD self-heal scales it back to 1. Now use the real kill switch, which removes the agent's credentials from the cluster instead. Note it does **not** read the secret's value — an agent is never stopped by extracting its own credential:

   ```bash
   ./labs/04-guardrails-recovery/scripts/kill-switch.sh
   kubectl -n agents get pods
   ```

   The Hermes pod cannot start without its Secret, and ArgoCD cannot recreate a Secret it does not manage.

   The **real** kill switch blocks the agent's virtual key on the LiteLLM gateway, which stops it everywhere at once, budget included. Here each of you is your own gateway, so you run it against your in-cluster LiteLLM (the key's alias is `attendee-local`):

   ```bash
   kubectl -n litellm port-forward svc/litellm 4000:4000 &
   set -a
   source labs/00-setup/local/.litellm-admin
   set +a
   LITELLM_ADMIN_URL=http://localhost:4000 ./labs/04-guardrails-recovery/scripts/kill-switch.sh local --block-key
   ```

   The script resolves the key by alias `attendee-local` through the gateway's `/key/list`, then calls `/key/block`. Bootstrap writes the admin key to `labs/00-setup/local/.litellm-admin`. In production this is one command against one central gateway, for one key at a time.

## If you finished early

Hermes is now stopped (its credentials are gone), so pick something that does not need a live agent:

- **Read the Kyverno policy you enforced.** Open `labs/04-guardrails-recovery/policies/deny-agent-direct-changes.yaml` and walk the rule that blocked the impersonated `--as` writes in step 1. Then re-run one of those `kubectl --as` commands and read the policy message again.
- **Review the "helpful" PR as a security change.** Re-open the PR from step 3 in your browser and look at exactly which line in `values.yaml` opened the egress hole. This is the diff you would have caught with a CODEOWNERS rule on `labs/*/apps/*/values.yaml`.
- **Check the audit trail.** In the in-cluster Langfuse, find this environment's traces and see the tool calls, token cost, and the moment the (now-blocked) key would have been used. Together with the Git history and the Kyverno policy, that is the audit story for what the agent did.
- **Read the runbook that Hermes tried to update.** Open `labs/02-knowledge-base/runbooks/` and look at the PR the runbook bot opened — if its entry was flagged, that is the platform labeling a possible injection for a human to decide on.
