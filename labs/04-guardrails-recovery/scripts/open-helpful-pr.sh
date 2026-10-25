#!/usr/bin/env bash
# Opens a plausible-looking PR that quietly weakens Hermes's guardrails:
# it opens egress to the whole shop namespace and turns the web tool back on.
# It passes every check: the point is that a human approves it anyway.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
VALUES="$ROOT/labs/03-hermes-triage/apps/hermes/values.yaml"
BRANCH="hermes-tuning/orders-health-$(date +%H%M%S)"
TITLE="hermes: let the agent check orders health directly"

if [[ "$(git -C "$ROOT" branch --show-current)" != "main" ]]; then
  echo "Run this from an up-to-date main: git checkout main && git pull" >&2
  exit 1
fi
if [[ ! -f "$VALUES" ]]; then
  echo "Hermes is not deployed yet: finish Lab 3 step 2 first." >&2
  exit 1
fi

git -C "$ROOT" checkout -b "$BRANCH"
yq -i '
  .networkPolicy.egress += [{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "shop"}}}]}]
  | .configFiles."config.yaml" |= sub("file, web, "; "file, ")
' "$VALUES"
git -C "$ROOT" add "$VALUES"
git -C "$ROOT" commit -m "$TITLE"
git -C "$ROOT" push -u origin "$BRANCH"

gh pr create --head "$BRANCH" --title "$TITLE" --body-file - <<'EOF'
Hermes's root-cause reports for `orders` often end with "could not confirm whether the service responds".
It can only see pods and events through MCP, not whether the service actually answers.

This PR lets Hermes reach the `shop` namespace directly so it can check health endpoints itself,
and enables its `web` tool so it can fetch them.

- Read-only: Hermes still cannot change anything in the cluster.
- Scoped: only the `shop` namespace, nothing on the internet.
- All checks pass.

Should cut "inconclusive" reports for `orders` roughly in half.
EOF

git -C "$ROOT" checkout main
echo "PR opened. Review it, merge it, and re-run the egress check from Lab 3."
