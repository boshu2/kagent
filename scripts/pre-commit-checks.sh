#!/usr/bin/env bash
#
# pre-commit-checks.sh - Fast local validation mirroring GitHub Actions CI
#
# Usage: ./scripts/pre-commit-checks.sh [OPTIONS]
#
# Options:
#   -f, --fail-fast     Exit on first failure (default: continue all checks)
#   -q, --quiet         Minimal output (only failures and summary)
#   -h, --help          Show this help message
#
# Runs the same checks as CI:
#   - Go lint (golangci-lint)
#   - Go unit tests (excluding E2E)
#   - Python lint (ruff check + format)
#   - Python tests (pytest)
#   - UI lint (npm run lint)
#   - Helm unit tests (helm unittest)
#   - Manifest check (make controller-manifests)

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Options
FAIL_FAST=false
QUIET=false

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
SKIP_COUNT=0

# Timing
declare -A CHECK_TIMES

# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Fast local validation mirroring GitHub Actions CI"
    echo ""
    echo "Options:"
    echo "  -f, --fail-fast     Exit on first failure (default: continue all checks)"
    echo "  -q, --quiet         Minimal output (only failures and summary)"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Checks:"
    echo "  - Go lint         golangci-lint run"
    echo "  - Go tests        go test -race -skip 'TestE2E.*' ./..."
    echo "  - Python lint     uv run ruff check && uv run ruff format --diff"
    echo "  - Python tests    uv run pytest ./packages/**/tests/"
    echo "  - UI lint         npm run lint"
    echo "  - Helm tests      helm unittest helm/kagent"
    echo "  - Manifests       make controller-manifests && git diff --exit-code"
}

log_info() {
    [[ "${QUIET}" == "true" ]] || echo -e "${BLUE}[INFO]${NC} $*"
}

log_section() {
    [[ "${QUIET}" == "true" ]] || {
        echo ""
        echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}  $*${NC}"
        echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
    }
}

check_pass() {
    local name="$1"
    local time="$2"
    echo -e "  ${GREEN}PASS${NC} ${name} ${BLUE}(${time}s)${NC}"
    ((PASS_COUNT++))
    CHECK_TIMES["${name}"]="${time}"
}

check_fail() {
    local name="$1"
    local time="$2"
    echo -e "  ${RED}FAIL${NC} ${name} ${BLUE}(${time}s)${NC}"
    ((FAIL_COUNT++))
    CHECK_TIMES["${name}"]="${time}"
}

check_skip() {
    local name="$1"
    local reason="$2"
    echo -e "  ${YELLOW}SKIP${NC} ${name} - ${reason}"
    ((SKIP_COUNT++))
}

# Run a check and track timing
run_check() {
    local name="$1"
    shift
    local cmd="$*"

    local start_time
    start_time=$(date +%s.%N)

    local output
    local exit_code=0

    if [[ "${QUIET}" == "true" ]]; then
        output=$($cmd 2>&1) || exit_code=$?
    else
        # Show output in real-time
        $cmd || exit_code=$?
    fi

    local end_time
    end_time=$(date +%s.%N)
    local elapsed
    elapsed=$(echo "${end_time} - ${start_time}" | bc | xargs printf "%.1f")

    if [[ ${exit_code} -eq 0 ]]; then
        check_pass "${name}" "${elapsed}"
        return 0
    else
        check_fail "${name}" "${elapsed}"
        if [[ "${QUIET}" == "true" && -n "${output}" ]]; then
            echo "${output}"
        fi
        if [[ "${FAIL_FAST}" == "true" ]]; then
            echo ""
            echo -e "${RED}Exiting on first failure (--fail-fast)${NC}"
            exit 1
        fi
        return 1
    fi
}

# Check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════
# PARSE ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--fail-fast)
            FAIL_FAST=true
            shift
            ;;
        -q|--quiet)
            QUIET=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

cd "${REPO_ROOT}"

TOTAL_START=$(date +%s.%N)

echo ""
echo -e "${BOLD}kagent Pre-Commit Checks${NC}"
echo -e "Repository: ${REPO_ROOT}"
echo -e "Mode: $(if [[ "${FAIL_FAST}" == "true" ]]; then echo "fail-fast"; else echo "continue-on-failure"; fi)"
echo ""

# ───────────────────────────────────────────────────────────────────────────
# Go Checks
# ───────────────────────────────────────────────────────────────────────────

log_section "Go Checks"

if command_exists golangci-lint; then
    run_check "Go lint" bash -c "cd go && golangci-lint run" || true
else
    check_skip "Go lint" "golangci-lint not installed"
fi

if command_exists go; then
    run_check "Go tests" bash -c "cd go && go test -race -skip 'TestE2E.*' ./..." || true
else
    check_skip "Go tests" "go not installed"
fi

# ───────────────────────────────────────────────────────────────────────────
# Python Checks
# ───────────────────────────────────────────────────────────────────────────

log_section "Python Checks"

if command_exists uv; then
    run_check "Python lint (ruff check)" bash -c "cd python && uv run ruff check" || true
    run_check "Python lint (ruff format)" bash -c "cd python && uv run ruff format --diff ." || true
    run_check "Python tests" bash -c "cd python && uv run pytest ./packages/**/tests/" || true
else
    check_skip "Python lint" "uv not installed"
    check_skip "Python tests" "uv not installed"
fi

# ───────────────────────────────────────────────────────────────────────────
# UI Checks
# ───────────────────────────────────────────────────────────────────────────

log_section "UI Checks"

if command_exists npm && [[ -d "${REPO_ROOT}/ui" ]]; then
    if [[ -d "${REPO_ROOT}/ui/node_modules" ]]; then
        run_check "UI lint" bash -c "cd ui && npm run lint" || true
    else
        check_skip "UI lint" "node_modules not installed (run: cd ui && npm ci)"
    fi
else
    check_skip "UI lint" "npm not installed or ui/ directory missing"
fi

# ───────────────────────────────────────────────────────────────────────────
# Helm Checks
# ───────────────────────────────────────────────────────────────────────────

log_section "Helm Checks"

if command_exists helm; then
    # Check if unittest plugin is installed
    if helm plugin list 2>/dev/null | grep -q unittest; then
        run_check "Helm tests" helm unittest helm/kagent || true
    else
        check_skip "Helm tests" "helm-unittest plugin not installed (run: helm plugin install https://github.com/helm-unittest/helm-unittest)"
    fi
else
    check_skip "Helm tests" "helm not installed"
fi

# ───────────────────────────────────────────────────────────────────────────
# Manifest Check
# ───────────────────────────────────────────────────────────────────────────

log_section "Manifest Check"

if command_exists make && command_exists go; then
    # Run manifest generation and check for uncommitted changes
    run_check "Manifests" bash -c "make controller-manifests && git diff --exit-code" || true
else
    check_skip "Manifests" "make or go not installed"
fi

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

TOTAL_END=$(date +%s.%N)
TOTAL_ELAPSED=$(echo "${TOTAL_END} - ${TOTAL_START}" | bc | xargs printf "%.1f")

log_section "Summary"

TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))

echo -e "  ${GREEN}Passed:${NC}  ${PASS_COUNT}"
echo -e "  ${RED}Failed:${NC}  ${FAIL_COUNT}"
echo -e "  ${YELLOW}Skipped:${NC} ${SKIP_COUNT}"
echo ""
echo -e "  ${BLUE}Total time:${NC} ${TOTAL_ELAPSED}s"
echo ""

# Show timing breakdown for completed checks
if [[ ${#CHECK_TIMES[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Timing breakdown:${NC}"
    for check in "${!CHECK_TIMES[@]}"; do
        printf "    %-25s %ss\n" "${check}" "${CHECK_TIMES[${check}]}"
    done | sort -t'.' -k1 -n -r
    echo ""
fi

if [[ ${FAIL_COUNT} -eq 0 ]]; then
    echo -e "${GREEN}All checks passed!${NC}"
    exit 0
else
    echo -e "${RED}${FAIL_COUNT} check(s) failed.${NC}"
    echo ""
    echo "Fix the issues above before committing."
    exit 1
fi
