# Local kind environment

You get a kind cluster on your laptop — cluster name `agentic-idp`, from [`kind-config.yaml`](kind-config.yaml) — and you work against a fork of this repository. LiteLLM and Langfuse run inside that cluster. Argo CD polls the fork. There is no push webhook.

`bootstrap.sh` creates the cluster, installs the platform (`install-platform.sh`), applies the post–Lab 2 state (`apply-post-lab2.sh`), installs LiteLLM and Langfuse (`install-litellm-langfuse.sh`), creates the `hermes-llm` Secret with an `attendee-local` virtual key, and ends with the model smoke gate (`spike/smoke-hermes.sh`).

## Prerequisites

Docker with 16 GB of memory and 4 CPUs, plus `kind`, `kubectl`, `helm`, `yq` (mikefarah 4.x), `jq`, `envsubst`, `kubeconform`, and `helm-docs`. The `gh` CLI (2.50 or newer) must be logged in. About 25 GB of free disk.

## Steps

```bash
# 0. Preflight: machine, tools, and fork. One JSON line per check.
./labs/00-setup/local/preflight.sh
# Fix every "fail" line (names and fixes are in
# labs/02-knowledge-base/kb/guides/onboarding.md) until the summary is "pass".

# 1. Fork this repository, clone your fork, and point gh at it:
git clone https://github.com/<you>/agentic-idp-packt.git
cd agentic-idp-packt
gh repo set-default <you>/agentic-idp-packt
export GH_REPO=<you>/agentic-idp-packt

# 2. Fill in your environment file and run the bootstrap:
cp labs/00-setup/local/.env.example labs/00-setup/local/.env
./labs/00-setup/local/bootstrap.sh
```

The bootstrap leaves the cluster in the post–Lab 2 state: `orders` and `runbooks` are `Synced` and `Healthy`.

Before Lab 3, build the images and load them into kind. The bootstrap prints the commands when it finishes.

## Auto-onboarding with Cursor

1. Ask Cursor: "Read `labs/02-knowledge-base/kb/guides/onboarding.md` and get this workshop environment running."
2. The agent runs `preflight.sh`, fixes each failing check, and re-runs until the summary passes.
3. It creates `.env` from values you provide, then runs `bootstrap.sh`.

Do not guess tokens. The golden-path rules in `AGENTS.md` still apply.

## What the bootstrap does

- **LiteLLM and Langfuse in the cluster.** The gateway is `litellm.litellm.svc.cluster.local:4000`. Langfuse v2 is `langfuse-web.langfuse.svc.cluster.local:3000`. The bootstrap creates the Langfuse project and the `attendee-local` virtual key. Hermes only sees that virtual key. Set `SKIP_LANGFUSE=true` in `.env` to skip Langfuse when the laptop is short on memory.
- **Hermes egress.** The network policy reaches LiteLLM with a namespace and pod selector on port 4000.
- **Model smoke gate.** `spike/smoke-hermes.sh` calls `qwen3.8-27b` through the gateway with a forced tool call. `FAIL` means the cluster is not ready for Lab 3. Check `OPENROUTER_API_KEY`.

## Layout

| Path | What it is |
|---|---|
| `preflight.sh` | Machine, tools, and fork checks. One JSON line each. |
| `bootstrap.sh` | Creates the kind cluster and runs the installers. |
| `install-litellm-langfuse.sh` | Installs LiteLLM and Langfuse, and writes `hermes-llm`. |
| `platform/litellm.yaml`, `platform/langfuse.yaml` | Gateway and tracing manifests. |
| `kind-config.yaml` | kind cluster definition. |
| `.env.example` | Fork URL and provider key. Copy to `.env`. Do not commit `.env`. |
