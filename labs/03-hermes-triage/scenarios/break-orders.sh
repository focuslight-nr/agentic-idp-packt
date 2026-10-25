#!/usr/bin/env bash
# Breaks the orders service through a PR, the same way a real bad change would arrive.
# Usage: break-orders.sh <crashloop|oom|bad-config|undo>
set -euo pipefail

SCENARIO="${1:-}"
ROOT="$(git rev-parse --show-toplevel)"
VALUES="$ROOT/labs/01-golden-path/apps/orders/values.yaml"
PREFIX="lab-03 scenario:"

if [[ "$(git -C "$ROOT" branch --show-current)" != "main" ]]; then
  echo "Run this from an up-to-date main: git checkout main && git pull" >&2
  exit 1
fi

case "$SCENARIO" in
  crashloop)
    TITLE="$PREFIX orders crash loop"
    EDIT='.command = ["python", "/app/orders.py"] | .args = ["--orders-v2"]'
    BODY="Starts orders with a flag the app does not know, so it exits at startup and ends up in CrashLoopBackOff."
    ;;
  oom)
    TITLE="$PREFIX orders OOMKilled"
    EDIT='.resources.requests.memory = "4Mi" | .resources.limits.memory = "6Mi"'
    BODY="Lowers the memory limit below what orders needs, so the kernel kills it."
    ;;
  bad-config)
    TITLE="$PREFIX orders bad config"
    EDIT='.envFromSecrets = ["orders-db"]'
    BODY="Points orders at a Secret that does not exist, so the container can never start."
    ;;
  undo)
    SHA="$(git -C "$ROOT" log --grep="^$PREFIX" -n 1 --no-merges --format=%H)"
    REVERTED="$(git -C "$ROOT" log "${SHA:-HEAD}..HEAD" --format=%H --grep="This reverts commit $SHA" --grep="^Revert \"$PREFIX")"
    if [[ -z "$SHA" || -n "$REVERTED" ]]; then
      echo "Nothing to undo: no unreverted '$PREFIX' commit on main." >&2
      exit 1
    fi
    BRANCH="undo-scenario-$(date +%H%M%S)"
    git -C "$ROOT" checkout -b "$BRANCH"
    git -C "$ROOT" revert --no-edit "$SHA"
    git -C "$ROOT" push -u origin "$BRANCH"
    gh pr create --head "$BRANCH" --fill
    git -C "$ROOT" checkout main
    echo "Revert PR opened. Merge it, and orders recovers within about a minute."
    exit 0
    ;;
  *)
    echo "Usage: $0 <crashloop|oom|bad-config|undo>" >&2
    exit 1
    ;;
esac

BRANCH="scenario/$SCENARIO-$(date +%H%M%S)"
git -C "$ROOT" checkout -b "$BRANCH"
yq -i "$EDIT" "$VALUES"
git -C "$ROOT" add "$VALUES"
git -C "$ROOT" commit -m "$TITLE"
git -C "$ROOT" push -u origin "$BRANCH"
gh pr create --head "$BRANCH" --title "$TITLE" --body "$BODY"
git -C "$ROOT" checkout main

echo "PR opened. Merge it, then watch Hermes: kubectl -n agents logs deploy/hermes -f"
