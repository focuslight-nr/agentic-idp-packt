#!/usr/bin/env bash
# Preflight for the local kind environment. Prints one JSON line per check so a
# human or a coding agent (Cursor) can read why a check failed and fix exactly
# that. Exit code 0 when every check passes. This is pre-bootstrap: it checks
# the machine, the tools, and the fork. It does not create anything.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
FAILURES=0

# emit <check> <pass|fail> [error]
emit() {
  local check="$1" status="$2" error="${3:-}"
  if [[ -n "$error" ]]; then
    printf '{"check":"%s","status":"%s","error":"%s"}\n' "$check" "$status" "$error"
  else
    printf '{"check":"%s","status":"%s"}\n' "$check" "$status"
  fi
  if [[ "$status" == "fail" ]]; then FAILURES=$((FAILURES + 1)); fi
}

# --- machine ---------------------------------------------------------------
arch="$(uname -m)"
emit "arch" pass

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  mem_kb="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  mem_gb=$(( mem_kb / 1024 / 1024 ))
  if (( mem_gb >= 12 )); then
    emit "docker.memory" pass
  else
    emit "docker.memory" fail "docker is limited to ${mem_gb} GB; the stack needs at least 12 (16 recommended). Raise Docker Desktop settings."
  fi
  cpus="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
  if (( cpus >= 4 )); then
    emit "docker.cpus" pass
  else
    emit "docker.cpus" fail "docker sees ${cpus} CPUs; the 2-node kind cluster wants at least 4."
  fi
  disk_kb="$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')"
  disk_gb=$(( disk_kb / 1024 / 1024 ))
  if (( disk_gb >= 25 )); then
    emit "disk" pass
  else
    emit "disk" fail "only ${disk_gb} GB free; the images need at least 25 GB."
  fi
else
  emit "docker" fail "docker is not running. Start Docker Desktop (or your runtime) and re-run."
fi

# --- tools -----------------------------------------------------------------
need() { # need <name>
  if command -v "$1" >/dev/null 2>&1; then emit "tool.$1" pass
  else emit "tool.$1" fail "install '$1' and re-run."; fi
}
for t in git kind kubectl helm jq envsubst kubeconform helm-docs; do need "$t"; done

# yq is checked with a version assertion below, not in the loop.

if command -v gh >/dev/null 2>&1; then
  gh_ver="$(gh --version | head -1 | sed -n 's/.*version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1.\2/p')"
  gh_ok=0
  if [[ -n "$gh_ver" ]]; then
    major="${gh_ver%%.*}"; minor="${gh_ver#*.}"
    if (( major > 2 || (major == 2 && minor >= 50) )); then gh_ok=1; fi
  fi
  if (( gh_ok )); then emit "tool.gh" pass
  else emit "tool.gh" fail "gh is older than 2.50 (found: '${gh_ver:-none}'); update it, Lab 1 uses 'gh pr checks --watch'."
  fi
else
  emit "tool.gh" fail "install the gh CLI (2.50 or newer)."
fi

if command -v yq >/dev/null 2>&1; then
  yq_ver="$(yq --version 2>/dev/null | head -1)"
  if [[ "$yq_ver" == *"mikefarah"* && "$yq_ver" == *v4* ]]; then emit "tool.yq" pass
  else emit "tool.yq" fail "wrong yq (found: '${yq_ver:-unknown}'); this workshop uses mikefarah yq 4.x, not the Python yq."; fi
else
  emit "tool.yq" fail "install 'yq' (mikefarah 4.x) and re-run."
fi

# --- auth and fork -----------------------------------------------------------
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  emit "gh.auth" pass
else
  emit "gh.auth" fail "gh is not logged in. Run 'gh auth login'."
fi

if [[ -n "${GH_REPO:-}" ]]; then
  if command -v gh >/dev/null 2>&1; then
    default="$(gh repo view "$GH_REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo "")"
    if [[ "$default" == "main" ]]; then emit "fork" pass
    else emit "fork" fail "GH_REPO=$GH_REPO does not look like your fork (default branch: '${default:-unreachable}'). Check 'gh repo view $GH_REPO'."; fi
    actions="$(gh api "repos/$GH_REPO/actions" -q .disabled 2>/dev/null || echo "")"
    if [[ "$actions" == "false" ]]; then emit "fork.actions" pass
    elif [[ "$actions" == "true" ]]; then emit "fork.actions" fail "GitHub Actions is disabled on $GH_REPO. Settings -> General -> Actions: set to 'Allow all actions'."
    else emit "fork.actions" fail "could not check the Actions setting on $GH_REPO (permission?). Enable Actions on the fork before the workshop."; fi
  fi
else
  emit "fork" fail "GH_REPO is not set. Export it to your fork: export GH_REPO=<you>/agentic-idp-packt"
fi

# --- cluster state (informational: pre-bootstrap it is expected to be absent) --
if command -v kubectl >/dev/null 2>&1 && [[ "$(kubectl config current-context 2>/dev/null || echo "")" == "kind-agentic-idp" ]] && kubectl cluster-info >/dev/null 2>&1; then
  if kubectl -n argocd get applications >/dev/null 2>&1; then
    emit "cluster" pass
  else
    emit "cluster" fail "cluster kind-agentic-idp exists but Argo CD is not serving. Check with 'kubectl -n argocd get pods'."
  fi
else
  printf '{"check":"cluster","status":"info","note":"no kind-agentic-idp cluster yet - expected before bootstrap"}\n'
fi

printf '{"check":"summary","status":"%s","failures":%d}\n' "$([[ $FAILURES -eq 0 ]] && echo pass || echo fail)" "$FAILURES"
exit "$([[ $FAILURES -eq 0 ]] && echo 0 || echo 1)"
