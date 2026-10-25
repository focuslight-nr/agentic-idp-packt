#!/usr/bin/env bash
# Local verification suite for the workshop repository. No cluster, no AWS, no
# GitHub needed. This is what the `repo-verify` CI workflow runs, and it is the
# thing you run before pushing, so a broken script or a stale knowledge base is
# caught on your machine, not in 30 attendee environments.
#
# Usage: ./scripts/verify.sh
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

failures=0
step() { echo; echo "==> $*"; }
ok() { echo "    ok: $*"; }
err() { echo "    FAIL: $*" >&2; failures=$((failures + 1)); }

# --- 0. Tools ----------------------------------------------------------------
step "Checking required tools"
for tool in bash python3 yq; do
  command -v "$tool" >/dev/null 2>&1 || err "missing required tool: $tool"
done
if [[ $failures -gt 0 ]]; then
  echo; echo "verify: $failures tool check(s) failed." >&2
  exit 1
fi
ok "bash, python3, yq present"

# --- 1. Bash syntax ------------------------------------------------------------
step "bash -n on every shell script"
bash_errors=0
while IFS= read -r -d '' script; do
  if ! bash -n "$script" 2>err.tmp; then
    echo "    FAIL: bash -n $script" >&2
    cat err.tmp >&2
    bash_errors=$((bash_errors + 1))
  fi
done < <(find . -type f -name '*.sh' -not -path './.git/*' -print0)
rm -f err.tmp
if [[ $bash_errors -eq 0 ]]; then ok "all shell scripts parse"; else err "$bash_errors shell script(s) failed bash -n"; fi

# --- 2. Python compile ---------------------------------------------------------
step "python -m py_compile on every .py file"
py_errors=0
while IFS= read -r -d '' module; do
  if ! python3 -m py_compile "$module" 2>err.tmp; then
    echo "    FAIL: py_compile $module" >&2
    cat err.tmp >&2
    py_errors=$((py_errors + 1))
  fi
done < <(find . -type f -name '*.py' -not -path './.git/*' -print0)
rm -f err.tmp
if [[ $py_errors -eq 0 ]]; then ok "all Python modules compile"; else err "$py_errors Python module(s) failed to compile"; fi

# --- 3. Helm lint ---------------------------------------------------------------
step "helm lint the golden path chart"
if command -v helm >/dev/null 2>&1; then
  if helm lint labs/01-golden-path/platform/charts/service \
      --set image.repository=example --set image.tag=1.0.0 >err.tmp 2>&1; then
    ok "chart lints clean"
  else
    echo "    FAIL: helm lint" >&2; cat err.tmp >&2; err "helm lint failed"
  fi
  rm -f err.tmp
else
  echo "    skip: helm not installed"
fi

# --- 4. Knowledge base determinism (run twice, diff) ----------------------------
step "generate-docs.sh twice and diff (determinism)"
if command -v helm-docs >/dev/null 2>&1; then
  run1="$(mktemp -d)"
  ( cd "$ROOT" && ./labs/02-knowledge-base/scripts/generate-docs.sh >/dev/null 2>&1 )
  ( cp -r labs/02-knowledge-base/kb/generated "$run1/first" )
  ( cd "$ROOT" && ./labs/02-knowledge-base/scripts/generate-docs.sh >/dev/null 2>&1 )
  ( cp -r labs/02-knowledge-base/kb/generated "$run1/second" )
  if diff -r "$run1/first" "$run1/second" >/dev/null 2>&1; then
    ok "knowledge base output is deterministic"
  else
    echo "    FAIL: generate-docs.sh is non-deterministic:" >&2
    diff -r "$run1/first" "$run1/second" >&2
    err "knowledge base is non-deterministic"
  fi
  rm -rf "$run1"
  # The committed KB must also match what the generator produces now.
  if [[ -n "$(git status --porcelain -- labs/02-knowledge-base/kb/generated 2>/dev/null)" ]]; then
    err "committed kb/generated/ is stale relative to the generator (run generate-docs.sh and commit)"
  else
    ok "committed kb/generated/ matches the generator"
  fi
else
  echo "    skip: helm-docs not installed (docs determinism not checked)"
fi

# --- 5. YAML parse check --------------------------------------------------------
# Helm chart templates (*/templates/*.yaml) contain Go template syntax and are not
# valid plain YAML; they are validated by `helm template` in the golden-path CI,
# not by yq. Everything else must parse as YAML.
step "yq parse check on every YAML file (except Helm templates)"
yaml_errors=0
while IFS= read -r -d '' doc; do
  if ! yq eval '.' "$doc" >/dev/null 2>err.tmp; then
    echo "    FAIL: yq parse $doc" >&2
    cat err.tmp >&2
    yaml_errors=$((yaml_errors + 1))
  fi
done < <(find . -type f \( -name '*.yaml' -o -name '*.yml' \) \
  -not -path './.git/*' \
  -not -path '*/charts/*/templates/*' -print0)
rm -f err.tmp
if [[ $yaml_errors -eq 0 ]]; then ok "all non-template YAML files parse"; else err "$yaml_errors YAML file(s) failed to parse"; fi

echo
if [[ $failures -eq 0 ]]; then
  echo "verify: all checks passed."
  exit 0
else
  echo "verify: $failures check(s) FAILED." >&2
  exit 1
fi
