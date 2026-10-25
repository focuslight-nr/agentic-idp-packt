# 00: Set up your environment

You run the platform in a kind cluster on your own laptop, against a fork of the public workshop repository. The full bootstrap takes about 15 minutes on a warm machine and should be done **before** the session.

## What you get

- **Your own kind cluster**, `agentic-idp`, from [`local/kind-config.yaml`](local/kind-config.yaml). You are cluster-admin, and nothing else is visible to you.
- **A fork of the public upstream repository.** `main` is protected: every change goes through a PR with passing checks. There is no push webhook — ArgoCD polls.
- Inside your cluster: ArgoCD, Prometheus and Alertmanager, Kyverno, and the golden path, already in the state after Lab 2. The in-cluster LiteLLM and Langfuse are part of the same bootstrap.

Create the cluster with the bootstrap in [`local/`](local/). If a laptop breaks, pair with a neighbour, then reset with `kind delete cluster --name agentic-idp` and a re-bootstrap.

## Steps

1. Fork the public upstream repository on GitHub, and clone your fork:

   ```bash
   git clone https://github.com/<you>/agentic-idp-packt.git
   cd agentic-idp-packt
   cursor .
   ```

2. Make `gh` target your fork, not the upstream:

   ```bash
   gh repo set-default <you>/agentic-idp-packt
   export GH_REPO=<you>/agentic-idp-packt   # and add to your shell profile
   ```

3. Fill in your environment file and run the bootstrap:

   ```bash
   cp labs/00-setup/local/.env.example labs/00-setup/local/.env   # add your fork URL and the provider key you were given
   ./labs/00-setup/local/bootstrap.sh
   ```

4. Check that ArgoCD sees your apps:

   ```bash
   kubectl config current-context    # kind-agentic-idp
   kubectl -n argocd get applications
   ```

   You should see `orders` and `runbooks`, both `Synced` and `Healthy`.

## ArgoCD UI

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

Log in at http://localhost:8080 as `admin`.

## If something is broken

Reset with `kind delete cluster --name agentic-idp`, then re-run [`local/bootstrap.sh`](local/bootstrap.sh). Your fork and its pull requests are unaffected.

## What lives in this folder

| Path | What it is |
|---|---|
| `install-platform.sh` | Installs Argo CD, kube-prometheus-stack, and Kyverno into the current kube context. |
| `apply-post-lab2.sh` | Registers the ApplicationSet, runbooks, Hermes identities, and alert rules. Your cluster already has this after bootstrap. |
| `values/` | Helm values for the platform stack. |
| [`local/`](local/) | The kind cluster and the fork setup. |
