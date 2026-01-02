#!/usr/bin/env bash
#
# test-workflow.sh - Verify E2E testing workflow is properly integrated
#
# Usage: ./scripts/test-workflow.sh
#
# This script validates that all components of the kagent local testing
# workflow are in place and functional. It does NOT run actual deployments
# but verifies the integration is ready for manual E2E testing.
#
# Workflow being tested:
#   1. scripts/pre-commit-checks.sh - Fast checks before build
#   2. source .envrc && kagent-build - Build images
#   3. kagent-deploy - Deploy to ocppoc
#   4. scripts/validate-enterprise.sh - Runtime validation
#   5. scripts/collect-evidence.sh - Gather PR artifacts
#

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Counters
PASS_COUNT=0
FAIL_COUNT=0

# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

log_section() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

check_pass() {
    echo -e "  ${GREEN}PASS${NC} $*"
    ((PASS_COUNT++)) || true
}

check_fail() {
    echo -e "  ${RED}FAIL${NC} $*"
    ((FAIL_COUNT++)) || true
}

check_warn() {
    echo -e "  ${YELLOW}WARN${NC} $*"
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

cd "${REPO_ROOT}"

echo ""
echo -e "${BOLD}kagent E2E Workflow Integration Test${NC}"
echo -e "Repository: ${REPO_ROOT}"
echo ""

# ───────────────────────────────────────────────────────────────────────────
# Test 1: Check that all scripts exist and are executable
# ───────────────────────────────────────────────────────────────────────────

log_section "Test 1: Script Existence and Permissions"

SCRIPTS=(
    "scripts/pre-commit-checks.sh"
    "scripts/collect-evidence.sh"
    "scripts/validate-enterprise.sh"
)

for script in "${SCRIPTS[@]}"; do
    if [[ -f "${REPO_ROOT}/${script}" ]]; then
        if [[ -x "${REPO_ROOT}/${script}" ]]; then
            check_pass "${script} exists and is executable"
        else
            check_fail "${script} exists but is NOT executable"
        fi
    else
        check_fail "${script} does not exist"
    fi
done

# ───────────────────────────────────────────────────────────────────────────
# Test 2: Verify pre-commit-checks.sh works (--help)
# ───────────────────────────────────────────────────────────────────────────

log_section "Test 2: pre-commit-checks.sh Functionality"

if "${REPO_ROOT}/scripts/pre-commit-checks.sh" --help >/dev/null 2>&1; then
    check_pass "pre-commit-checks.sh --help executes successfully"
else
    check_fail "pre-commit-checks.sh --help failed"
fi

# Verify it documents expected checks
HELP_OUTPUT=$("${REPO_ROOT}/scripts/pre-commit-checks.sh" --help 2>&1 || true)
EXPECTED_CHECKS=("Go lint" "Go tests" "Python lint" "Helm tests" "Manifests")

for check in "${EXPECTED_CHECKS[@]}"; do
    if echo "${HELP_OUTPUT}" | grep -qi "${check}"; then
        check_pass "pre-commit-checks.sh documents '${check}'"
    else
        check_fail "pre-commit-checks.sh missing documentation for '${check}'"
    fi
done

# ───────────────────────────────────────────────────────────────────────────
# Test 3: Verify collect-evidence.sh works (-h)
# ───────────────────────────────────────────────────────────────────────────

log_section "Test 3: collect-evidence.sh Functionality"

if "${REPO_ROOT}/scripts/collect-evidence.sh" -h >/dev/null 2>&1; then
    check_pass "collect-evidence.sh -h executes successfully"
else
    check_fail "collect-evidence.sh -h failed"
fi

# Verify it documents expected options
HELP_OUTPUT=$("${REPO_ROOT}/scripts/collect-evidence.sh" -h 2>&1 || true)
EXPECTED_OPTIONS=("namespace" "output_dir")

for opt in "${EXPECTED_OPTIONS[@]}"; do
    if echo "${HELP_OUTPUT}" | grep -qi "${opt}"; then
        check_pass "collect-evidence.sh documents '-n ${opt}' option"
    else
        check_fail "collect-evidence.sh missing documentation for '${opt}'"
    fi
done

# ───────────────────────────────────────────────────────────────────────────
# Test 4: Verify .envrc defines required functions
# ───────────────────────────────────────────────────────────────────────────

log_section "Test 4: .envrc Shell Functions"

if [[ -f "${REPO_ROOT}/.envrc" ]]; then
    check_pass ".envrc exists"

    REQUIRED_FUNCTIONS=(
        "kagent-build"
        "kagent-deploy"
        "kagent-validate"
        "kagent-undeploy"
        "kagent-context"
        "kagent-logs"
        "kagent-pf"
        "kagent-dev"
        "kagent-info"
    )

    ENVRC_CONTENT=$(cat "${REPO_ROOT}/.envrc")

    for func in "${REQUIRED_FUNCTIONS[@]}"; do
        if echo "${ENVRC_CONTENT}" | grep -q "^${func}()"; then
            check_pass ".envrc defines function '${func}'"
        else
            check_fail ".envrc missing function '${func}'"
        fi
    done
else
    check_fail ".envrc does not exist"
fi

# ───────────────────────────────────────────────────────────────────────────
# Test 5: Verify validate-enterprise.sh exists
# ───────────────────────────────────────────────────────────────────────────

log_section "Test 5: validate-enterprise.sh Checks"

if [[ -f "${REPO_ROOT}/scripts/validate-enterprise.sh" ]]; then
    check_pass "validate-enterprise.sh exists"

    # Verify it tests enterprise features
    VALIDATE_CONTENT=$(cat "${REPO_ROOT}/scripts/validate-enterprise.sh")
    ENTERPRISE_CHECKS=(
        "PodDisruptionBudgets"
        "ServiceMonitor"
        "PrometheusRule"
        "Namespace Isolation"
        "Audit"
    )

    for feature in "${ENTERPRISE_CHECKS[@]}"; do
        if echo "${VALIDATE_CONTENT}" | grep -qi "${feature}"; then
            check_pass "validate-enterprise.sh tests '${feature}'"
        else
            check_fail "validate-enterprise.sh missing test for '${feature}'"
        fi
    done
else
    check_fail "validate-enterprise.sh does not exist"
fi

# ───────────────────────────────────────────────────────────────────────────
# Test 6: Verify deployment configuration exists
# ───────────────────────────────────────────────────────────────────────────

log_section "Test 6: Deployment Configuration"

DEPLOY_FILES=(
    "deploy/ocppoc/values.yaml"
    "helm/kagent/Chart-template.yaml"
    "helm/kagent-crds/Chart-template.yaml"
    "helm/kagent/values.yaml"
    "helm/kagent-crds/values.yaml"
)

for file in "${DEPLOY_FILES[@]}"; do
    if [[ -f "${REPO_ROOT}/${file}" ]]; then
        check_pass "${file} exists"
    else
        check_fail "${file} missing"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════
# WORKFLOW SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

log_section "E2E Workflow Summary"

echo -e "${BOLD}The complete E2E workflow when run manually:${NC}"
echo ""
echo "  1. ${BLUE}scripts/pre-commit-checks.sh${NC}"
echo "     Run fast local checks (lint, test, manifests)"
echo "     Mirrors GitHub Actions CI for local validation"
echo ""
echo "  2. ${BLUE}source .envrc && kagent-build${NC}"
echo "     Load environment and build container images"
echo "     Pushes to internal registry (${KAGENT_REGISTRY:-dprusocplvjmp01.deepsky.lab:5000})"
echo ""
echo "  3. ${BLUE}kagent-deploy${NC}"
echo "     Deploy to OpenShift using Helm"
echo "     Enables enterprise features (PDB, ServiceMonitor, namespace isolation)"
echo ""
echo "  4. ${BLUE}scripts/validate-enterprise.sh${NC}"
echo "     Verify enterprise features are working"
echo "     Tests: pods, PDBs, ServiceMonitors, namespace isolation, audit logs"
echo ""
echo "  5. ${BLUE}scripts/collect-evidence.sh${NC}"
echo "     Gather deployment artifacts for PR submission"
echo "     Output: evidence/ directory with YAML exports and logs"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

log_section "Integration Test Results"

TOTAL=$((PASS_COUNT + FAIL_COUNT))

echo -e "  ${GREEN}Passed:${NC}  ${PASS_COUNT}"
echo -e "  ${RED}Failed:${NC}  ${FAIL_COUNT}"
echo ""

if [[ ${FAIL_COUNT} -eq 0 ]]; then
    echo -e "${GREEN}All integration tests passed!${NC}"
    echo ""
    echo "The E2E workflow is ready for manual testing."
    echo "Run the workflow with:"
    echo ""
    echo "  source .envrc"
    echo "  ./scripts/pre-commit-checks.sh"
    echo "  kagent-build && kagent-deploy"
    echo "  ./scripts/validate-enterprise.sh"
    echo "  ./scripts/collect-evidence.sh"
    echo ""
    exit 0
else
    echo -e "${RED}${FAIL_COUNT} integration test(s) failed.${NC}"
    echo ""
    echo "Fix the issues above before running E2E tests."
    exit 1
fi
