#!/usr/bin/env bash
# Installs the in-cluster LiteLLM gateway and Langfuse v2 into the current
# kube context (the kind cluster), then wires Hermes to the gateway.
# Used by labs/00-setup/local/bootstrap.sh.
#
# One gateway per laptop, a virtual key with alias `attendee-local`, and traces
# in an in-cluster Langfuse (no signup, no shared project).
#
# Environment (from .env):
#   OPENROUTER_API_KEY    provider key; required for the gateway to route.
#   LITELLM_MASTER_KEY    gateway admin key; auto-generated if empty.
#   SKIP_LANGFUSE=true    install LiteLLM without the in-cluster Langfuse
#                         when the laptop is short on memory. Default: install it.
#
# The model alias is pinned below (LITELLM_MODEL_ID). The labs only see
# `qwen3.8-27b`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$SCRIPT_DIR/platform"

# --- Model route (the one place to change) ----------------------------------
# The stable alias every agent sees is fixed; the provider model ID behind it
# is the OpenRouter route for the workshop model. Confirmed against the
# public OpenRouter model list (openrouter.ai/api/v1/models): `qwen3.8-27b`
# is served as `qwen/qwen3.8-27b`.
LITELLM_MODEL_ALIAS="${LITELLM_MODEL_ALIAS:-qwen3.8-27b}"
LITELLM_MODEL_ID="${LITELLM_MODEL_ID:-openrouter/qwen/qwen3.8-27b}"

# --- Required context --------------------------------------------------------
if ! kubectl get ns >/dev/null 2>&1; then
  echo "No current cluster context. Run inside the kind bootstrap." >&2
  exit 1
fi

LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-$(openssl rand -hex 24)}"
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
if [[ -z "$OPENROUTER_API_KEY" ]]; then
  echo "==> WARN: OPENROUTER_API_KEY is empty."
  echo "    Installing LiteLLM without a provider key. The smoke gate"
  echo "    (smoke-hermes.sh) will fail until the key is added."
fi

# --- Langfuse (default on; SKIP_LANGFUSE=true is the B8 fallback) -----------
INSTALL_LANGFUSE="true"
if [[ "${SKIP_LANGFUSE:-}" == "true" ]]; then
  INSTALL_LANGFUSE="false"
  echo "==> SKIP_LANGFUSE=true: installing LiteLLM without Langfuse (B8 fallback)"
fi
LANGFUSE_PUBLIC_KEY=""
LANGFUSE_SECRET_KEY=""

if [[ "$INSTALL_LANGFUSE" == "true" ]]; then
  SALT="${SALT:-$(openssl rand -hex 16)}"
  ENCRYPTION_KEY="${ENCRYPTION_KEY:-$(openssl rand -hex 32)}"
  NEXTAUTH_SECRET="${NEXTAUTH_SECRET:-$(openssl rand -hex 32)}"
  ADMIN_EMAIL="${LANGFUSE_ADMIN_EMAIL:-workshop@example.com}"
  ADMIN_PASSWORD="${LANGFUSE_ADMIN_PASSWORD:-$(openssl rand -hex 12)}"
  LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-pk-lf-$(openssl rand -hex 20)}"
  LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-sk-lf-$(openssl rand -hex 20)}"

  echo "==> Installing in-cluster Langfuse v2 (one app + Postgres)"
  kubectl create namespace langfuse --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n langfuse create secret generic langfuse-secrets \
    --from-literal=SALT="$SALT" \
    --from-literal=ENCRYPTION_KEY="$ENCRYPTION_KEY" \
    --from-literal=NEXTAUTH_SECRET="$NEXTAUTH_SECRET" \
    --from-literal=LANGFUSE_INIT_ORG_NAME="workshop" \
    --from-literal=LANGFUSE_INIT_PROJECT_NAME="workshop" \
    --from-literal=LANGFUSE_INIT_PROJECT_PUBLIC_KEY="$LANGFUSE_PUBLIC_KEY" \
    --from-literal=LANGFUSE_INIT_PROJECT_SECRET_KEY="$LANGFUSE_SECRET_KEY" \
    --from-literal=LANGFUSE_INIT_USER_NAME="Workshop" \
    --from-literal=LANGFUSE_INIT_USER_EMAIL="$ADMIN_EMAIL" \
    --from-literal=LANGFUSE_INIT_USER_PASSWORD="$ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "$PLATFORM_DIR/langfuse.yaml"
  # Gate the app on Postgres so migrations do not race the database's
  # first-time init (that produces a P1000 auth error on a fresh bootstrap).
  kubectl -n langfuse rollout status deploy/langfuse-postgres --timeout=240s
  kubectl -n langfuse rollout status deploy/langfuse-web --timeout=300s
  echo "==> Langfuse project 'workshop' created headlessly (LANGFUSE_INIT_*)"
fi

# --- LiteLLM secrets + config ------------------------------------------------
echo "==> Creating litellm-secrets"
if ! kubectl get ns litellm >/dev/null 2>&1; then
  kubectl create namespace litellm
  kubectl wait --for=condition=Active ns/litellm --timeout=120s
fi
kubectl -n litellm create secret generic litellm-secrets \
  --from-literal=LITELLM_MASTER_KEY="$LITELLM_MASTER_KEY" \
  --from-literal=OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
  --from-literal=LANGFUSE_PUBLIC_KEY="$LANGFUSE_PUBLIC_KEY" \
  --from-literal=LANGFUSE_SECRET_KEY="$LANGFUSE_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Rendering litellm-config"
CONFIG="model_list:
  - model_name: ${LITELLM_MODEL_ALIAS}
    litellm_params:
      model: ${LITELLM_MODEL_ID}
      api_key: os.environ/OPENROUTER_API_KEY"
if [[ "$INSTALL_LANGFUSE" == "true" ]]; then
  CONFIG="${CONFIG}
litellm_settings:
  success_callback: [\"langfuse\"]"
fi
kubectl -n litellm create configmap litellm-config \
  --from-literal=litellm-config.yaml="$CONFIG" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- LiteLLM ------------------------------------------------------------------
echo "==> Installing LiteLLM"
kubectl apply -f "$PLATFORM_DIR/litellm.yaml"
kubectl -n litellm rollout status deploy/litellm-postgres --timeout=240s
kubectl -n litellm rollout status deploy/litellm --timeout=300s

# --- Virtual key -------------------------------------------------------------
# Short-lived port-forward to create the attendee-local virtual key through
# the gateway's admin API. The bootstrap keeps its own forward for the smoke
# gate; the key persists in LiteLLM's Postgres.
echo "==> Creating the attendee-local virtual key"
kubectl -n litellm port-forward svc/litellm 4000:4000 >/dev/null 2>&1 &
PF_PID=$!
sleep 2
ADMIN_URL="http://localhost:4000"
for i in $(seq 1 30); do
  if curl -fsS "$ADMIN_URL/health/readiness" >/dev/null 2>&1; then break; fi
  sleep 2
done
KEY_RESPONSE="$(
  curl -fsS -X POST "$ADMIN_URL/key/generate" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d '{"key_alias": "attendee-local", "max_budget": 10, "max_parallel_requests": 4, "tpm_limit": 200000}'
)" || { echo "key/generate failed" >&2; kill "$PF_PID" 2>/dev/null || true; exit 1; }
ATTENDEE_KEY="$(echo "$KEY_RESPONSE" | jq -r '.key // .token // empty')"
kill "$PF_PID" 2>/dev/null || true
if [[ -z "$ATTENDEE_KEY" ]]; then
  echo "Could not create the attendee-local virtual key. Gateway response:" >&2
  echo "$KEY_RESPONSE" >&2
  exit 1
fi
echo "==> attendee-local key created"

# --- Wire Hermes to the gateway ---------------------------------------------
echo "==> Writing agents/hermes-llm (Hermes's credentials)"
kubectl get ns agents >/dev/null 2>&1 || kubectl create namespace agents
kubectl -n agents create secret generic hermes-llm \
  --from-literal=OPENAI_BASE_URL="http://litellm.litellm.svc.cluster.local:4000/v1" \
  --from-literal=OPENAI_API_KEY="$ATTENDEE_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- Persist the admin key for the kill switch ------------------------------
echo "==> Storing LITELLM_MASTER_KEY for the kill switch"
echo "LITELLM_MASTER_KEY=$LITELLM_MASTER_KEY" >> "$SCRIPT_DIR/.litellm-admin"
chmod 600 "$SCRIPT_DIR/.litellm-admin" 2>/dev/null || true

cat <<EOF

==> In-cluster LiteLLM + Langfuse ready.

  gateway:     http://litellm.litellm.svc.cluster.local:4000/v1
  alias:       $LITELLM_MODEL_ALIAS
  attendee:    agents/hermes-llm (virtual key alias attendee-local)
  langfuse:    $([[ "$INSTALL_LANGFUSE" == "true" ]] && echo "in-cluster (kubectl -n langfuse port-forward svc/langfuse-web 3000)" || echo "skipped (SKIP_LANGFUSE)")

Next: the bootstrap runs spike/smoke-hermes.sh against this gateway.
EOF
