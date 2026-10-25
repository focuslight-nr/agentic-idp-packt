#!/usr/bin/env bash
# Stops Hermes in a way ArgoCD self-heal cannot undo.
#
# The attendee part removes the agent's credentials from the cluster: with the
# Secret gone, Hermes cannot start, and ArgoCD cannot recreate a Secret it does
# not manage. Crucially, this path does NOT read the secret's value -- an agent
# must never be stopped by someone extracting its own credential (that is the
# anti-pattern this workshop teaches against).
#
# The --block-key part is the "real" kill switch: it blocks the agent's virtual
# key on the LiteLLM gateway, which stops it everywhere at once (including the
# budget). Each attendee's LiteLLM is in their own cluster, so each one blocks
# their own local key (alias attendee-local). It resolves the key from its
# alias through the gateway's own
# admin API, so it never reads the cluster secret either.
#
# Usage:
#   kill-switch.sh                        # remove credentials from the cluster
#   LITELLM_ADMIN_URL=... LITELLM_MASTER_KEY=sk-... \
#     kill-switch.sh local --block-key    # block the key on the in-cluster gateway
#
# The credential path needs no argument. The --block-key path takes the alias
# suffix: "local" resolves to the in-cluster key attendee-local.
set -euo pipefail

ATTENDEE="${1:-}"
MODE="${2:-}"
KEY_ALIAS="attendee-$ATTENDEE"

if [[ "$MODE" == "--block-key" && -z "$ATTENDEE" ]]; then
  echo "usage: kill-switch.sh <attendee-id> --block-key" >&2
  exit 1
fi

echo "==> Removing Hermes's LLM credentials (attendee step)"
kubectl -n agents delete secret hermes-llm --ignore-not-found

echo "==> Restarting Hermes pods, which now cannot start without the Secret"
kubectl -n agents delete pod -l app.kubernetes.io/name=hermes --wait=false

if [[ "$MODE" == "--block-key" ]]; then
  : "${LITELLM_ADMIN_URL:?--block-key needs LITELLM_ADMIN_URL}"
  : "${LITELLM_MASTER_KEY:?--block-key needs LITELLM_MASTER_KEY}"

  echo "==> Resolving the key for alias '$KEY_ALIAS' via the gateway admin API"
  # /key/list returns either {"keys":["<raw-key>"]} (this LiteLLM) or
  # {"keys":[{token|key: ...}]} on other versions; handle both shapes.
  raw_key="$(
    curl -fsS "$LITELLM_ADMIN_URL/key/list?key_alias=$KEY_ALIAS" \
      -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
      | jq -r '.keys[0] | if type == "string" then . else (.token // .key // empty) end'
  )"
  [[ -n "$raw_key" ]] || { echo "could not resolve a key for alias '$KEY_ALIAS'" >&2; exit 1; }

  echo "==> Blocking the key on the gateway (stops it everywhere, budget included)"
  curl -fsS -X POST "$LITELLM_ADMIN_URL/key/block" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"key\": \"$raw_key\"}"
  echo
fi

echo "==> Hermes is stopped. Check with: kubectl -n agents get pods"
echo "    (The pod cannot start; ArgoCD self-heal restores the Deployment, not the Secret.)"
