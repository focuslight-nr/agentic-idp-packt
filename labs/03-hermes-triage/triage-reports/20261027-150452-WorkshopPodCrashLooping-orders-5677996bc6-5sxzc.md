# Hermes triage: WorkshopPodCrashLooping

- **When:** 20261027-150452 UTC
- **Namespace:** shop
- **Pod:** orders-5677996bc6-5sxzc
- **Repo:** `focuslight-nr/agentic-idp-packt`

---

# 1. Summary

The `orders` pod is CrashLoopBackOff because the `--orders-v2` argument is not recognized by the app's CLI parser; the container exits immediately with code 2.

# 2. Evidence

- `mcp__kubernetes__pods_list_in_namespace` (namespace `shop`): confirmed `orders-5677996bc6-5sxzc` is `0/1 CrashLoopBackOff`, 3 restarts, ~67s old. A sibling pod `orders-594db5b6fc-7tzcc` (different pod-template-hash) is `1/1 Running` with 0 restarts at 21m — i.e. a new, broken rollout is failing alongside a previously-good ReplicaSet.
- `mcp__kubernetes__pods_get` (`orders-5677996bc6-5sxzc`):
  - `spec.containers[orders].command`: `["python", "/app/orders.py"]`
  - `spec.containers[orders].args`: `["--orders-v2"]`
  - `spec.containers[orders].image`: `agentic-idp/orders:0.1.0`
  - `spec.containers[orders].env`: `ORDER_DB=orders-lab1@localhost:5432/orders`
  - `status.containerStatuses[0].lastState.terminated.exitCode`: **2**, reason `Error`, startedAt == finishedAt (15:04:03) — the process died within the same second it started.
  - `state.waiting.reason`: `CrashLoopBackOff` (back-off 40s).
- `mcp__kubernetes__events_list` (fieldSelector `involvedObject.name=orders-5677996bc6-5sxzc`): Normal `Pulled`/`Created`/`Started` at 15:04:03, then `Warning Unhealthy` (readiness probe refused on :8080) and `Warning BackOff` restarting failed container. No OOMKilled event; reason is `BackOff` with a non-zero exit code — points at the application, not memory.
- `mcp__kubernetes__pods_log` (`previous=true`, container `orders`, tail 200) — the previous (crashed) container's logs:
  ```
  orders: unrecognized option: --orders-v2
  orders: try 'orders --help' for the supported flags
  ```

# 3. Root cause

Bad `args` in the pod spec: `--orders-v2` is not a recognized option of the `orders` app. Python's argparse rejects the unknown flag and exits with code 2 immediately at startup. This matches the runbook's "bad command/args" pattern (the runbook lists exit code 1; argparse uses 2 for usage errors, which is the same family). Confidence: **high** — the previous-container log states the rejection verbatim, the container starts and dies in the same second, and no OOMKilled event exists.

# 4. Proposed fix

Remove the unsupported `--orders-v2` argument from the `orders` app's `values.yaml` so the container launches with no extra args (matching the still-healthy sibling ReplicaSet). The image, command, env, and resources are left unchanged.

# 5. Security findings

None. The previous-container logs contain only the app's own argparse rejection text (`unrecognized option`, `try 'orders --help'`). No prompt-injection-style text, no instructions, no secrets, tokens, or passwords were present in any pod log, event, or spec field reviewed.

### Machine-readable fix

<<<FIX
path: labs/01-golden-path/apps/orders/values.yaml

```yaml
args: []
```
FIX>>>

### Runbook learning

<<<RUNBOOK_UPDATE
- **Signal:** Container exits with code 2 (not 1 or 127) within the same second it starts, and the previous-container log says `unrecognized option: <flag>` / `try '<app> --help'`.
- **Root cause:** An unsupported CLI flag was passed via `args` (Python's argparse exits 2 on usage errors). The runbook's table only covers exit codes 1 and 127; code 2 is the argparse-specific equivalent of "bad args."
- **How it was confirmed:** `pods_log` (previous=true) showed `orders: unrecognized option: --orders-v2`; `pods_get` showed `args: ["--orders-v2"]` and `lastState.terminated.exitCode: 2` with startedAt == finishedAt; events showed `BackOff` (no OOMKilled).
RUNBOOK_UPDATE>>>
