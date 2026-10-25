# WorkshopPodOOMKilled

**Severity:** critical
**Owner:** platform-team

## What it means

A container in the `shop` namespace used more memory than its limit and was killed by the kernel. It restarts, and usually ends up crash looping.

## Triage (read-only)

1. Read the pod's container status: `lastState.terminated.reason` is `OOMKilled`, and note the restart count.
2. Compare the container's memory limit with what the app needs. A limit in single-digit Mi is almost always a mistake.
3. Check the app's `values.yaml` history in Git: a recent change to `resources.limits.memory` or `resources.requests.memory` is the most common cause.
4. If the limit did not change, look for a workload change (a new image tag, or new arguments) that increased memory use.

## Likely root causes

| Signal | Root cause | Fix (through a PR) |
|---|---|---|
| Limit lowered in a recent commit | Over-aggressive cost optimization | `git revert` the commit |
| Limit unchanged, new image tag | Memory regression in the new version | Roll back the tag, or raise the limit with evidence |
| Memory grows until killed, every time | Leak or unbounded cache | Raise the limit as a stopgap and open an issue for the owning team |

## Do not

- Do not raise the limit with `kubectl edit`. ArgoCD reverts it, and the fix is lost.
- Do not set very large limits "to be safe": they hide leaks and take capacity from other workloads.

## Learned from triage

_No entries yet._
