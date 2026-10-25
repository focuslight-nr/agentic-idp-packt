#!/usr/bin/env bash
# Installs the platform stack (ArgoCD, kube-prometheus-stack, Kyverno) into the current kube context.
# Used by labs/00-setup/local/bootstrap.sh (kind).
#
# Environment:
#   ARGOCD_WEBHOOK_SECRET  optional, shared secret for the GitHub push webhook
#   ARGOCD_WEBHOOK_HOST    optional, hostname exposing only /api/webhook through the host ingress
set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Chart versions are pinned so a chart release between the week-1 spike and
# delivery cannot change what gets installed into 30 environments. Bump these
# deliberately and re-run the spike; record the versions that pass here.
#   argo-cd              10.10.1   (appVersion v3.5.4)
#   kube-prometheus-stack 92.1.1   (appVersion v0.94.1)
#   kyverno               3.9.1
ARGOCD_CHART_VERSION="10.10.1"
PROM_CHART_VERSION="92.1.1"
KYVERNO_CHART_VERSION="3.9.1"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add kyverno https://kyverno.github.io/kyverno >/dev/null
helm repo update >/dev/null

echo "==> Installing ArgoCD"
argocd_args=(--values "$SETUP_DIR/values/argocd.yaml")
if [[ -n "${ARGOCD_WEBHOOK_SECRET:-}" ]]; then
  argocd_args+=(--set-string "configs.secret.githubSecret=$ARGOCD_WEBHOOK_SECRET")
fi
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  "${argocd_args[@]}" \
  --wait --timeout 10m

if [[ -n "${ARGOCD_WEBHOOK_HOST:-}" ]]; then
  echo "==> Exposing only the ArgoCD webhook endpoint at $ARGOCD_WEBHOOK_HOST"
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-webhook
  namespace: argocd
spec:
  ingressClassName: nginx
  rules:
    - host: $ARGOCD_WEBHOOK_HOST
      http:
        paths:
          - path: /api/webhook
            pathType: Exact
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF
fi

echo "==> Installing kube-prometheus-stack"
prom_args=(--values "$SETUP_DIR/values/kube-prometheus-stack.yaml")
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "$PROM_CHART_VERSION" \
  --namespace monitoring --create-namespace \
  "${prom_args[@]}" \
  --wait --timeout 10m

echo "==> Installing Kyverno"
helm upgrade --install kyverno kyverno/kyverno \
  --version "$KYVERNO_CHART_VERSION" \
  --namespace kyverno --create-namespace \
  --set admissionController.replicas=1 \
  --set backgroundController.replicas=1 \
  --set cleanupController.replicas=1 \
  --set reportsController.replicas=1 \
  --wait --timeout 10m

echo "==> Platform stack installed"
