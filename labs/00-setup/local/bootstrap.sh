#!/usr/bin/env bash
# The main (and only) attendee path: a kind cluster on the laptop with the same
# platform stack and the same post-Lab 2 state, worked against a fork of the
# public upstream repository.
set -euo pipefail

LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$(cd "$LOCAL_DIR/.." && pwd)"
ROOT="$(git rev-parse --show-toplevel)"
CLUSTER_NAME="agentic-idp"
ENV_FILE="$LOCAL_DIR/.env"

for tool in docker kind kubectl helm yq envsubst; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Copy $LOCAL_DIR/.env.example to $ENV_FILE and fill it in first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${REPO_URL:?Set REPO_URL in $ENV_FILE}"
: "${REPO_WEB_URL:?Set REPO_WEB_URL in $ENV_FILE}"
: "${OPENROUTER_API_KEY:?Set OPENROUTER_API_KEY in $ENV_FILE (your capped provider key)}"

if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "==> Creating kind cluster $CLUSTER_NAME"
  kind create cluster --config "$LOCAL_DIR/kind-config.yaml"
else
  echo "==> kind cluster $CLUSTER_NAME already exists"
fi
kubectl config use-context "kind-$CLUSTER_NAME"

"$SETUP_DIR/install-platform.sh"
export REPO_URL REPO_WEB_URL
"$SETUP_DIR/apply-post-lab2.sh"

# In-cluster LiteLLM gateway + Langfuse, and the hermes-llm Secret wired to the
# gateway's attendee-local virtual key. Also creates the Langfuse project and
# LiteLLM API keys headlessly, and renders the LiteLLM -> Langfuse callback.
# Set SKIP_LANGFUSE=true in .env to run the B8 memory fallback (no Langfuse).
export OPENROUTER_API_KEY
export LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-}"
export SKIP_LANGFUSE="${SKIP_LANGFUSE:-}"
"$LOCAL_DIR/install-litellm-langfuse.sh"

# The runbook bot's GitHub token (contents + pull requests on the fork).
echo "==> Creating the runbook bot Secret"
kubectl -n agents create secret generic runbook-bot-github \
  --from-literal=GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
  --from-literal=GITHUB_REPO="$(echo "$REPO_URL" | sed -E 's#https?://github.com/##; s#\.git$##')" \
  --dry-run=client -o yaml | kubectl apply -f -

# Model smoke gate: attendee key -> in-cluster gateway -> model, with a forced
# tool call. If this does not pass, the environment is not ready for Lab 3.
# It runs against the live gateway through a short-lived port-forward.
echo "==> Model smoke gate (spike/smoke-hermes.sh)"
SMOKE_URL_PORT=4000
kubectl -n litellm port-forward svc/litellm "$SMOKE_URL_PORT:4000" >/dev/null 2>&1 &
PF_PID=$!
sleep 2
ATTENDEE_KEY="$(kubectl -n agents get secret hermes-llm -o jsonpath='{.data.OPENAI_API_KEY}' | base64 -d)"
SMOKE_OK=0
"$ROOT/spike/smoke-hermes.sh" "$ATTENDEE_KEY" "http://localhost:$SMOKE_URL_PORT" && SMOKE_OK=1 || true
kill "$PF_PID" 2>/dev/null || true
SMOKE_STATUS="$([[ "$SMOKE_OK" == "1" ]] && echo PASS || echo "FAIL - check OPENROUTER_API_KEY in $ENV_FILE")"
LANGFUSE_NOTE="$( [[ "${SKIP_LANGFUSE:-}" == "true" ]] && echo "" || echo " + Langfuse" )"

cat <<EOF

==> Local cluster is ready (post-Lab 2 state + in-cluster LiteLLM${LANGFUSE_NOTE}).

Smoke gate: $SMOKE_STATUS
  gateway:  http://litellm.litellm.svc.cluster.local:4000/v1  (alias qwen3.8-27b)
  hermes:   agents/hermes-llm (virtual key alias attendee-local)
  kill:     kill-switch.sh local --block-key uses LITELLM_MASTER_KEY (see .litellm-admin)

Before Lab 3, build the images and load them into kind:
  docker build -t orders:0.1.0 labs/01-golden-path/apps/orders
  docker build -t hermes-triage:0.1.0 labs/03-hermes-triage/hermes
  docker build -t runbook-bot:0.1.0 labs/03-hermes-triage/runbook-bot
  kind load docker-image orders:0.1.0 hermes-triage:0.1.0 runbook-bot:0.1.0 --name $CLUSTER_NAME
Point the image repositories in those apps' values.yaml at the bare names above
(orders, hermes-triage, runbook-bot). GH_REPO must be your fork.
EOF
