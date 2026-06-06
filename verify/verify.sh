#!/usr/bin/env bash
# Self-assessment harness for the DevOps engineering technical exercise.
#
# Runs 16 checks against the candidate's submission. Exits 0 only if all pass.
#
# Run from the bundle root:
#   make verify
#
# Or directly:
#   bash verify/verify.sh
#
# This script does NOT modify the candidate's source. It boots a kind cluster
# from the candidate's Terraform, asserts the deployment is healthy and
# policies fire, then tears down (unless KEEP=1 is set).

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_DIR="${ENV_DIR:-terraform/envs/local}"
KEEP="${KEEP:-0}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
DIM='\033[2m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
FAILED_CHECKS=()

check_pass() {
  local name="$1"
  local detail="${2:-}"
  PASS_COUNT=$((PASS_COUNT + 1))
  if [ -n "$detail" ]; then
    echo -e "  ${GREEN}PASS${NC}  ${name}  ${DIM}${detail}${NC}"
  else
    echo -e "  ${GREEN}PASS${NC}  ${name}"
  fi
}

check_fail() {
  local name="$1"
  local detail="${2:-}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_CHECKS+=("$name")
  if [ -n "$detail" ]; then
    echo -e "  ${RED}FAIL${NC}  ${name}  ${DIM}${detail}${NC}"
  else
    echo -e "  ${RED}FAIL${NC}  ${name}"
  fi
}

step() {
  echo
  echo -e "${YELLOW}$1${NC}"
}

# Verbose mode runs commands inline; quiet mode captures.
run_quiet() {
  local logfile="$1"
  shift
  "$@" >"$logfile" 2>&1
  return $?
}

# ────────────────────────────────────────────────────────────────
# 1. Pre-flight
# ────────────────────────────────────────────────────────────────
step "1. Pre-flight: required tools"
if bash "$ROOT_DIR/verify/preflight.sh" >/tmp/dx-preflight.log 2>&1; then
  check_pass "all required tools on PATH"
else
  check_fail "missing tools" "see /tmp/dx-preflight.log"
  cat /tmp/dx-preflight.log
  exit 1
fi

# ────────────────────────────────────────────────────────────────
# 2. Terraform lint (fmt + validate — counts as one atomic check)
# ────────────────────────────────────────────────────────────────
step "2. Terraform fmt + validate"
LINT_FMT_OK=1
LINT_VALIDATE_OK=1
LINT_DETAIL=""

if ! terraform fmt -check -recursive terraform/ >/tmp/dx-fmt.log 2>&1; then
  LINT_FMT_OK=0
  LINT_DETAIL="fmt: $(tail -1 /tmp/dx-fmt.log | tr '\n' ' '); "
fi

if [ ! -d "$ENV_DIR" ]; then
  check_fail "env directory exists" "$ENV_DIR not found"
  echo
  echo -e "${RED}ENV_DIR ($ENV_DIR) does not exist. Build your Terraform first.${NC}"
  exit 1
fi

cd "$ENV_DIR"
if ! terraform init -backend-config=backend.hcl -input=false >/tmp/dx-init.log 2>&1; then
  check_fail "terraform init" "$(tail -3 /tmp/dx-init.log | tr '\n' ' ')"
  cd "$ROOT_DIR"
  echo
  echo -e "${RED}terraform init failed — see /tmp/dx-init.log${NC}"
  exit 1
fi

if ! terraform validate >/tmp/dx-validate.log 2>&1; then
  LINT_VALIDATE_OK=0
  LINT_DETAIL="${LINT_DETAIL}validate: $(tail -1 /tmp/dx-validate.log | tr '\n' ' ')"
fi
cd "$ROOT_DIR"

if [ "$LINT_FMT_OK" = "1" ] && [ "$LINT_VALIDATE_OK" = "1" ]; then
  check_pass "terraform fmt + validate"
else
  check_fail "terraform fmt + validate" "$LINT_DETAIL"
fi

# ────────────────────────────────────────────────────────────────
# 3. Terraform plan
# ────────────────────────────────────────────────────────────────
step "3. Terraform plan"
cd "$ENV_DIR"
if terraform plan -out=tfplan -input=false >/tmp/dx-plan.log 2>&1; then
  check_pass "terraform plan produces a plan"
else
  check_fail "terraform plan" "$(tail -5 /tmp/dx-plan.log | tr '\n' ' ')"
  cd "$ROOT_DIR"
  exit 1
fi
terraform show -json tfplan > /tmp/dx-plan.json 2>/dev/null
cd "$ROOT_DIR"

# ────────────────────────────────────────────────────────────────
# 4. Plan-as-policy (Conftest on JSON plan)
# ────────────────────────────────────────────────────────────────
step "4. Conftest on Terraform plan"
if conftest test --policy "$ROOT_DIR/verify/policies/terraform/" /tmp/dx-plan.json >/tmp/dx-conftest-tf.log 2>&1; then
  check_pass "plan-as-policy"
else
  check_fail "plan-as-policy" "$(tail -5 /tmp/dx-conftest-tf.log | tr '\n' ' ')"
fi

# ────────────────────────────────────────────────────────────────
# 5. Terraform apply (the real bring-up)
# ────────────────────────────────────────────────────────────────
step "5. Terraform apply (bringing up cluster + ArgoCD + ESO + Kyverno)"
echo -e "  ${DIM}This may take 3-5 minutes on first run...${NC}"
echo -e "  ${DIM}Using -parallelism=3 to avoid overwhelming the kind cluster's API server${NC}"
cd "$ENV_DIR"
if terraform apply -auto-approve -input=false -parallelism=3 >/tmp/dx-apply.log 2>&1; then
  check_pass "terraform apply"
else
  check_fail "terraform apply" "see /tmp/dx-apply.log"
  cd "$ROOT_DIR"
  echo
  echo "Last 20 lines of apply log:"
  tail -20 /tmp/dx-apply.log
  exit 1
fi
# Resolve kubeconfig — the env must re-export the kind-cluster module's
# `kubeconfig_path` output (spec §4.5). Without this, every kubectl call below
# silently falls back to localhost:8080 and we get unhelpful "connection
# refused" errors. Hard-error here with a clear message instead.
KUBECONFIG_PATH=$(terraform output -raw kubeconfig_path 2>/dev/null || echo "")
cd "$ROOT_DIR"
if [ -z "$KUBECONFIG_PATH" ] || [ ! -f "$KUBECONFIG_PATH" ]; then
  echo
  echo -e "${RED}Could not resolve kubeconfig_path from terraform output in $ENV_DIR.${NC}"
  echo -e "${YELLOW}Your env (terraform/envs/local/) must declare:${NC}"
  echo
  echo '  output "kubeconfig_path" {'
  echo '    value = module.<your_kind_cluster_module>.kubeconfig_path'
  echo '  }'
  echo
  echo -e "${YELLOW}so the harness can locate the cluster. See spec §4.5.${NC}"
  exit 1
fi
export KUBECONFIG="$KUBECONFIG_PATH"

# ────────────────────────────────────────────────────────────────
# 6. Wait for ArgoCD root Application
# ────────────────────────────────────────────────────────────────
step "6. Wait for ArgoCD root Application to be Synced + Healthy"
# Fast-fail if the candidate forgot to replace the repoURL placeholder.
PLACEHOLDER_HITS=$(grep -rlE "<YOUR_GIT_REPO_URL>" "$ROOT_DIR/argocd/" 2>/dev/null || true)
if [ -n "$PLACEHOLDER_HITS" ]; then
  check_fail "ArgoCD repoURL placeholder replaced" "still found '<YOUR_GIT_REPO_URL>' in: $(echo "$PLACEHOLDER_HITS" | tr '\n' ' ')"
  echo
  echo -e "${RED}Replace <YOUR_GIT_REPO_URL> with your public Git repo URL and push, then re-run.${NC}"
  exit 1
fi

wait_argocd_app() {
  local app="$1"
  local namespace="${2:-argocd}"
  # 600s — apply itself takes 3-5min, then ArgoCD needs another 1-3min to pull
  # and reconcile the root + child apps. 300s was too tight on slower laptops.
  local deadline=$(($(date +%s) + 600))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sync=$(kubectl -n "$namespace" get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
    health=$(kubectl -n "$namespace" get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
    if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

if wait_argocd_app "root" argocd; then
  check_pass "root Application Synced+Healthy"
else
  check_fail "root Application Synced+Healthy" "timed out after 300s"
fi

# ────────────────────────────────────────────────────────────────
# 7. Wait for sample-app Application
# ────────────────────────────────────────────────────────────────
step "7. Wait for sample-app Application"
if wait_argocd_app "sample-app" argocd; then
  check_pass "sample-app Application Synced+Healthy"
else
  check_fail "sample-app Application Synced+Healthy" "timed out after 300s"
fi

# ────────────────────────────────────────────────────────────────
# 8. HTTP probe of the sample app
# ────────────────────────────────────────────────────────────────
step "8. HTTP probe of sample-app via port-forward"
# Detect the namespace where sample-app is deployed
SAMPLE_NS=$(kubectl get application sample-app -n argocd -o jsonpath='{.spec.destination.namespace}' 2>/dev/null || echo "sample-app")
PROBE_PORT=$((RANDOM % 10000 + 20000))
kubectl -n "$SAMPLE_NS" wait --for=condition=available --timeout=60s deployment -l app.kubernetes.io/name=sample-app >/dev/null 2>&1 || true

kubectl -n "$SAMPLE_NS" port-forward "svc/sample-app" "${PROBE_PORT}:80" >/tmp/dx-pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3
if curl -fsS --max-time 5 "http://localhost:${PROBE_PORT}/" >/tmp/dx-curl.log 2>&1; then
  check_pass "sample-app responds 200 OK" "via port-forward localhost:${PROBE_PORT}"
else
  check_fail "sample-app HTTP probe" "$(tail -3 /tmp/dx-curl.log | tr '\n' ' ')"
fi
kill $PF_PID 2>/dev/null || true
trap - EXIT

# ────────────────────────────────────────────────────────────────
# 9. ExternalSecret sync check
# ────────────────────────────────────────────────────────────────
step "9. ExternalSecret sync"
ES_NAME=$(kubectl -n "$SAMPLE_NS" get externalsecret -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$ES_NAME" ]; then
  check_fail "ExternalSecret in $SAMPLE_NS namespace" "no ExternalSecret found"
else
  TARGET_SECRET=$(kubectl -n "$SAMPLE_NS" get externalsecret "$ES_NAME" -o jsonpath='{.spec.target.name}' 2>/dev/null || echo "")
  if [ -n "$TARGET_SECRET" ] && kubectl -n "$SAMPLE_NS" get secret "$TARGET_SECRET" >/dev/null 2>&1; then
    check_pass "ExternalSecret produced target Secret" "$TARGET_SECRET in $SAMPLE_NS"
  else
    check_fail "ExternalSecret produced target Secret" "target secret '$TARGET_SECRET' not found"
  fi
fi

# ────────────────────────────────────────────────────────────────
# 10. Kyverno rejects bad-examples
# ────────────────────────────────────────────────────────────────
step "10. Kyverno rejects deliberately-violating manifests"
REJECTED_ALL=true
for bad in "$ROOT_DIR"/verify/bad-examples/*.yaml; do
  name=$(basename "$bad")
  if kubectl apply --dry-run=server -f "$bad" >/tmp/dx-bad.log 2>&1; then
    # Server-side dry-run admitted it — that's a fail (Kyverno should have rejected)
    REJECTED_ALL=false
    check_fail "$name rejected by Kyverno" "admitted by server (Kyverno did not block)"
  else
    # Confirm the rejection came from Kyverno, not some other error
    if grep -qiE "(kyverno|policy|denied|admission)" /tmp/dx-bad.log; then
      :
    else
      REJECTED_ALL=false
      check_fail "$name rejected by Kyverno" "rejected, but not by Kyverno — $(tail -1 /tmp/dx-bad.log)"
      continue
    fi
  fi
done
if [ "$REJECTED_ALL" = "true" ]; then
  count=$(ls "$ROOT_DIR"/verify/bad-examples/*.yaml | wc -l | tr -d ' ')
  check_pass "all ${count} bad-examples rejected by Kyverno"
fi

# ────────────────────────────────────────────────────────────────
# 11. Conftest on argocd/apps
# ────────────────────────────────────────────────────────────────
step "11. Conftest on ArgoCD Application manifests"
if [ -z "$(ls -A "$ROOT_DIR"/argocd/apps/*.yaml 2>/dev/null)" ]; then
  check_fail "argocd/apps/ has at least one Application" "directory is empty"
else
  if conftest test --policy "$ROOT_DIR/verify/policies/argocd/" "$ROOT_DIR"/argocd/apps/*.yaml >/tmp/dx-conftest-argocd.log 2>&1; then
    check_pass "all ArgoCD Apps pass policy"
  else
    check_fail "ArgoCD policy" "$(tail -5 /tmp/dx-conftest-argocd.log | tr '\n' ' ')"
  fi
fi

# ────────────────────────────────────────────────────────────────
# 12. Conftest on Helm-rendered output
# ────────────────────────────────────────────────────────────────
step "12. Conftest on Helm-rendered output"
VALUES_FILE=""
# Canonical location is alongside the chart. Fallbacks supported for legacy layouts.
for candidate in "$ROOT_DIR/helm/charts/sample-app/values.local.yaml" \
                 "$ROOT_DIR/terraform/envs/local/values.local.yaml" \
                 "$ROOT_DIR/values.local.yaml"; do
  if [ -f "$candidate" ]; then
    VALUES_FILE="$candidate"
    break
  fi
done
if [ -z "$VALUES_FILE" ]; then
  check_fail "values.local.yaml exists for helm-render" "no values.local.yaml found in standard locations"
else
  if helm template sample-app "$ROOT_DIR/helm/charts/sample-app" --values "$VALUES_FILE" 2>/tmp/dx-helm.log | \
     conftest test --policy "$ROOT_DIR/verify/policies/helm/" - >/tmp/dx-conftest-helm.log 2>&1; then
    check_pass "rendered helm passes policy" "values: $(basename "$(dirname "$VALUES_FILE")")/$(basename "$VALUES_FILE")"
  else
    check_fail "Helm-rendered policy" "$(tail -5 /tmp/dx-conftest-helm.log | tr '\n' ' ')"
  fi
fi

# ────────────────────────────────────────────────────────────────
# 13. Checkov on terraform/
# ────────────────────────────────────────────────────────────────
step "13. Checkov on terraform/"
if checkov -d "$ROOT_DIR/terraform" --quiet --compact --soft-fail-on LOW,MEDIUM \
       --skip-check CKV_TF_1,CKV_TF_2 \
       --output=cli >/tmp/dx-checkov.log 2>&1; then
  check_pass "checkov clean (HIGH/CRITICAL only)"
else
  EXIT=$?
  if [ $EXIT -eq 0 ]; then
    check_pass "checkov clean (HIGH/CRITICAL only)"
  else
    check_fail "checkov" "HIGH/CRITICAL findings — see /tmp/dx-checkov.log"
  fi
fi

# ────────────────────────────────────────────────────────────────
# 14. README has an AI-tools-used disclosure section
# ────────────────────────────────────────────────────────────────
step "14. README has an AI-tools-used disclosure section"
if grep -qiE "^#+ *(ai tools used|ai disclosure|ai usage|use of ai)" "$ROOT_DIR/README.md" 2>/dev/null; then
  check_pass "README declares AI usage" "matches '# AI tools used' or similar heading"
else
  check_fail "README has AI disclosure section" "no '# AI tools used' heading in README.md — spec §12"
fi

# ────────────────────────────────────────────────────────────────
# 15. Required GitHub Actions workflow files present
# ────────────────────────────────────────────────────────────────
step "15. Required GitHub Actions workflow files present"
MISSING_WF=()
for wf in terraform-plan.yml policy-test.yml security-scan.yml; do
  if [ ! -f "$ROOT_DIR/.github/workflows/$wf" ]; then
    MISSING_WF+=("$wf")
  fi
done
if [ ${#MISSING_WF[@]} -eq 0 ]; then
  check_pass "all 3 GitHub Actions workflows present"
else
  check_fail "GitHub Actions workflows" "missing: ${MISSING_WF[*]}"
fi

# ────────────────────────────────────────────────────────────────
# 16. At least two validation blocks in terraform/modules/
# ────────────────────────────────────────────────────────────────
step "16. At least two validation blocks in terraform/modules/"
VALIDATION_COUNT=$(grep -rE "^[[:space:]]*validation[[:space:]]*\{" "$ROOT_DIR/terraform/modules/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$VALIDATION_COUNT" -ge 2 ]; then
  check_pass "validation blocks found" "$VALIDATION_COUNT block(s) in terraform/modules/"
else
  check_fail "at least 2 validation blocks required" "found only $VALIDATION_COUNT in terraform/modules/ — spec §4.3"
fi

# ────────────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────────────
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo
echo "==============================================================="
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}✓ ${PASS_COUNT}/${TOTAL} checks passed${NC}"
else
  echo -e "${RED}✗ ${PASS_COUNT}/${TOTAL} checks passed (${FAIL_COUNT} failed)${NC}"
  echo
  echo "Failed checks:"
  for f in "${FAILED_CHECKS[@]}"; do
    echo "  - $f"
  done
fi
echo

# ────────────────────────────────────────────────────────────────
# Teardown (opt-out with KEEP=1)
# ────────────────────────────────────────────────────────────────
if [ "$KEEP" != "1" ] && [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${DIM}Tearing down (set KEEP=1 to keep the cluster running)...${NC}"
  cd "$ENV_DIR" && terraform destroy -auto-approve -input=false >/tmp/dx-destroy.log 2>&1 || true
  cd "$ROOT_DIR"
fi

[ "$FAIL_COUNT" -eq 0 ]
