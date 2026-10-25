#!/usr/bin/env bash
# Validates every app on the golden path and prints one JSON object per app,
# so both humans and agents can read why an app failed.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CHART="$ROOT/labs/01-golden-path/platform/charts/service"
failed=0

emit() {
  local app="$1" status="$2" error="${3:-}"
  jq -cn --arg app "$app" --arg status "$status" --arg error "$error" \
    '{app: $app, status: $status} + (if $error == "" then {} else {error: $error} end)'
  if [[ "$status" == "fail" && -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error file=${app}/values.yaml::${error}" >&2
  fi
}

for app_file in "$ROOT"/labs/*/apps/*/app.yaml; do
  app_dir="$(dirname "$app_file")"
  rel_dir="${app_dir#"$ROOT"/}"

  for field in name namespace owner; do
    if [[ "$(yq ".$field // \"\"" "$app_file")" == "" ]]; then
      emit "$rel_dir" fail "app.yaml is missing required field '$field'"
      failed=1
      continue 2
    fi
  done

  name="$(yq '.name' "$app_file")"
  if [[ "$name" != "$(basename "$app_dir")" ]]; then
    emit "$rel_dir" fail "app.yaml name '$name' must match the folder name '$(basename "$app_dir")'"
    failed=1
    continue
  fi

  if [[ "$(yq '.resources.limits.memory // ""' "$app_dir/values.yaml")" == "" ]] &&
     [[ "$(yq '.resources.limits.memory // ""' "$CHART/values.yaml")" == "" ]]; then
    emit "$rel_dir" fail "resources.limits.memory is required"
    failed=1
    continue
  fi

  if ! rendered="$(helm template "$name" "$CHART" -f "$app_dir/values.yaml" 2>&1)"; then
    emit "$rel_dir" fail "$(echo "$rendered" | grep -m1 '^Error:' | sed 's/^Error: execution error at ([^)]*): //; s/^Error: //')"
    failed=1
    continue
  fi

  if ! result="$(echo "$rendered" | kubeconform -strict -summary -output text - 2>&1)"; then
    emit "$rel_dir" fail "$result"
    failed=1
    continue
  fi

  emit "$rel_dir" pass
done

exit "$failed"
