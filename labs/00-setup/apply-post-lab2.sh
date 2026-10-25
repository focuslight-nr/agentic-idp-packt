#!/usr/bin/env bash
# Applies the state every attendee environment starts in: ApplicationSet, runbooks,
# Hermes identities, and alert rules. Used by labs/00-setup/local/bootstrap.sh.
#
# Requires: kubectl pointed at the target cluster, REPO_URL, and REPO_WEB_URL.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
: "${REPO_URL:?REPO_URL is required}"
: "${REPO_WEB_URL:?REPO_WEB_URL is required}"
export REPO_URL REPO_WEB_URL

echo "==> Applying post-Lab 2 state"
envsubst '${REPO_URL}' < "$ROOT/labs/01-golden-path/platform/argocd/applicationset.yaml" | kubectl apply -f -
envsubst '${REPO_URL}' < "$ROOT/labs/02-knowledge-base/runbooks-app.yaml" | kubectl apply -f -
kubectl apply -f "$ROOT/labs/03-hermes-triage/platform/rbac.yaml"
envsubst '${REPO_WEB_URL}' < "$ROOT/labs/03-hermes-triage/alerts/prometheus-rules.yaml" | kubectl apply -f -
echo "==> Post-Lab 2 state applied"
