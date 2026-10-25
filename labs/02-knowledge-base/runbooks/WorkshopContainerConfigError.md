# WorkshopContainerConfigError

**Severity:** critical
**Owner:** platform-team

## What it means

A container in the `shop` namespace cannot start because its configuration or image cannot be resolved. The pod never runs, so there are no application logs.

## Triage (read-only)

1. Read the pod events. They name the exact missing object or the image that failed to pull.
2. For `CreateContainerConfigError`: check that every ConfigMap and Secret referenced in the pod spec exists in the namespace, with the referenced keys.
3. For `ErrImagePull` or `ImagePullBackOff`: check the image name and tag against the app's `values.yaml`.

## Likely root causes

| Signal | Root cause | Fix (through a PR) |
|---|---|---|
| `configmap "<name>" not found` | ConfigMap missing or in another namespace | Add the ConfigMap to the app, or fix the reference |
| `couldn't find key <key>` | Key renamed or missing | Fix the key in the ConfigMap or in the reference |
| `manifest unknown` | Image tag does not exist | Fix the tag in `values.yaml` |

## Do not

- Do not create the missing ConfigMap by hand with `kubectl`. It will drift from Git and ArgoCD will remove it.

## Learned from triage

_No entries yet._
