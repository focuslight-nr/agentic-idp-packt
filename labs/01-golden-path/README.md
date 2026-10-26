# Lab 1: Ship a service through the golden path

**Format:** guided demo, with one "try it" step. **Time:** 5 minutes of the 20-minute Foundations section.

## Goal

See how every human and every agent deploys on this platform: add a folder, open a PR, let CI validate it, and let ArgoCD apply it. Nobody runs `kubectl apply` for an app.

The service is `orders`, in the `shop` namespace. It stays with you for the whole workshop: Lab 2 documents it, Hermes triages it in Lab 3, and Lab 4 checks what Hermes is allowed to do to it.

## What is in this folder

| Path | What it is |
|---|---|
| `platform/charts/service/` | The golden path Helm chart. Every app uses it, agents included. |
| `platform/argocd/applicationset.yaml` | Creates one ArgoCD Application per `labs/*/apps/<name>/app.yaml`. Already registered in your environment. |
| `apps/orders/` | The `orders` service: `app.yaml` (who and where) and `values.yaml` (what). Already deployed. |
| `scripts/validate-apps.sh` | Prints one JSON line per app. Run it before you open a pull request. |

## What changes for agents

- **Repositories:** one folder per app with a fixed shape is something an agent can scaffold correctly every time.
- **CI/CD:** the validation prints JSON with a clear `error` field, not a wall of logs, so an agent can read why its PR failed and fix it.
- **GitOps:** Git is the only write path, and `main` is protected. Every change, human or agent, gets review, history, and rollback.
- **State and drift:** ArgoCD self-heal reverts any change made outside Git. You will see it in Lab 4, on Hermes itself.

## Guided demo

1. Walk through `apps/orders/` and the chart.
2. Show `orders` in Argo CD at http://argocd.localhost (it also serves `orders` at http://orders.localhost/orders).
3. Change `orders` in a pull request (for example `ORDER_DB`), and show the `golden-path-ci` check, the merge, and the sync. Argo CD polls every 30 seconds. A hard refresh skips the wait: `kubectl -n argocd annotate application orders argocd.argoproj.io/refresh=hard --overwrite`.

## Try it (optional, non-blocking)

Break the golden path and read what an agent would see:

```bash
git checkout -b try-lab-01
sed -i.bak 's/tag: "0.1.0"/tag: latest/' labs/01-golden-path/apps/orders/values.yaml && rm labs/01-golden-path/apps/orders/values.yaml.bak
git commit -am "try: use latest tag" && git push -u origin try-lab-01
gh pr create --fill
gh pr checks --watch
```

The `validate` check fails with `{"app":"labs/01-golden-path/apps/orders","status":"fail","error":"image.tag is required and must not be latest"}`. `freshness` and `verify` fail too, because the generated service catalog lists the image tag and is now stale. Bootstrap required these checks on `main`, so the merge is blocked. Close the PR and go back to `main` when you are done:

```bash
gh pr close try-lab-01 --delete-branch && git checkout main
```
