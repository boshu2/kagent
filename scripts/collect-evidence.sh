#!/usr/bin/env bash
#
# collect-evidence.sh - Collect deployment evidence for PR submission
#
# Usage: ./scripts/collect-evidence.sh [-n namespace] [-o output_dir]
#
# Gathers artifacts from an OpenShift kagent deployment to include in PRs
# as evidence that enterprise features work.
#
# Output:
#   evidence/
#   ├── README.md            # Summary of captured artifacts
#   ├── metadata.txt         # Timestamp, version, git info
#   ├── pods.yaml            # Pod definitions
#   ├── pdb.yaml             # PodDisruptionBudget definitions
#   ├── servicemonitor.yaml  # ServiceMonitor definitions
#   ├── prometheusrule.yaml  # PrometheusRule definitions
#   ├── controller.log       # Controller logs
#   └── validate-output.txt  # Output of kagent-validate

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

NAMESPACE="${KAGENT_NAMESPACE:-kagent-dev}"
OUTPUT_DIR="evidence"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ═══════════════════════════════════════════════════════════════════════════
# FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [-n namespace] [-o output_dir] [-h]

Collect deployment evidence for PR submission.

Options:
    -n namespace    Kubernetes namespace (default: kagent-dev)
    -o output_dir   Output directory (default: evidence)
    -h              Show this help message

Examples:
    $(basename "$0")                      # Use defaults
    $(basename "$0") -n my-namespace      # Custom namespace
    $(basename "$0") -o pr-evidence       # Custom output dir
EOF
}

# Capture a resource, handling missing resources gracefully
capture_resource() {
    local resource_type="$1"
    local output_file="$2"
    local description="$3"

    log_info "Capturing ${description}..."

    if oc get "${resource_type}" -n "${NAMESPACE}" -o yaml > "${OUTPUT_DIR}/${output_file}" 2>/dev/null; then
        # Check if we got actual resources or just an empty list
        if grep -q "items: \[\]" "${OUTPUT_DIR}/${output_file}"; then
            log_warn "No ${description} found in ${NAMESPACE}"
            echo "# No ${description} found in ${NAMESPACE}" > "${OUTPUT_DIR}/${output_file}"
            return 1
        else
            local count
            count=$(grep -c "^- apiVersion:" "${OUTPUT_DIR}/${output_file}" 2>/dev/null || echo "1")
            log_info "Captured ${count} ${description}"
            return 0
        fi
    else
        log_warn "Failed to get ${description} (resource type may not exist)"
        echo "# Failed to retrieve ${description} - resource type may not exist in cluster" > "${OUTPUT_DIR}/${output_file}"
        return 1
    fi
}

# Capture controller logs
capture_logs() {
    log_info "Capturing controller logs..."

    if oc logs -l app.kubernetes.io/component=controller -n "${NAMESPACE}" --tail=500 > "${OUTPUT_DIR}/controller.log" 2>/dev/null; then
        local lines
        lines=$(wc -l < "${OUTPUT_DIR}/controller.log" | tr -d ' ')
        log_info "Captured ${lines} lines of controller logs"
        return 0
    else
        log_warn "Failed to capture controller logs"
        echo "# Failed to capture controller logs - controller may not be running" > "${OUTPUT_DIR}/controller.log"
        return 1
    fi
}

# Run kagent-validate and capture output
capture_validate_output() {
    log_info "Running kagent-validate and capturing output..."

    # Source .envrc to get the kagent-validate function
    if [[ -f "${REPO_ROOT}/.envrc" ]]; then
        # Run in subshell to avoid polluting current environment
        (
            export KAGENT_QUIET=1
            source "${REPO_ROOT}/.envrc" 2>/dev/null
            export KAGENT_NAMESPACE="${NAMESPACE}"
            kagent-validate 2>&1
        ) > "${OUTPUT_DIR}/validate-output.txt" 2>&1 || true
        log_info "Captured kagent-validate output"
    else
        log_warn ".envrc not found, running manual validation..."
        {
            echo "=== Pods ==="
            oc get pods -n "${NAMESPACE}" 2>/dev/null || echo "Failed to get pods"
            echo ""
            echo "=== PDBs ==="
            oc get pdb -n "${NAMESPACE}" 2>/dev/null || echo "Failed to get PDBs"
            echo ""
            echo "=== ServiceMonitors ==="
            oc get servicemonitor -n "${NAMESPACE}" 2>/dev/null || echo "Failed to get ServiceMonitors"
            echo ""
            echo "=== Controller Logs (last 20 lines) ==="
            oc logs -l app.kubernetes.io/component=controller -n "${NAMESPACE}" --tail=20 2>/dev/null || echo "Failed to get logs"
        } > "${OUTPUT_DIR}/validate-output.txt" 2>&1
    fi
}

# Generate metadata file
generate_metadata() {
    log_info "Generating metadata..."

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local git_commit
    git_commit=$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")

    local git_branch
    git_branch=$(git -C "${REPO_ROOT}" branch --show-current 2>/dev/null || echo "unknown")

    local version
    version="${KAGENT_VERSION:-dev-$(date +%Y%m%d)-$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo 'local')}"

    local cluster_context
    cluster_context=$(oc config current-context 2>/dev/null || echo "unknown")

    cat > "${OUTPUT_DIR}/metadata.txt" <<EOF
# kagent Evidence Collection Metadata
# Generated by scripts/collect-evidence.sh

Timestamp:      ${timestamp}
Namespace:      ${NAMESPACE}
Cluster:        ${cluster_context}
Git Commit:     ${git_commit}
Git Branch:     ${git_branch}
Version:        ${version}
Collector:      $(whoami)@$(hostname)
EOF

    log_info "Metadata captured"
}

# Generate README summary
generate_readme() {
    log_info "Generating evidence README..."

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local git_commit
    git_commit=$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")

    local version
    version="${KAGENT_VERSION:-dev-$(date +%Y%m%d)-${git_commit}}"

    cat > "${OUTPUT_DIR}/README.md" <<EOF
# kagent Deployment Evidence

Evidence collected from OpenShift deployment to verify enterprise features.

## Collection Info

| Field | Value |
|-------|-------|
| Timestamp | ${timestamp} |
| Namespace | ${NAMESPACE} |
| Version | ${version} |
| Git Commit | ${git_commit} |

## Artifacts Collected

| File | Description | Status |
|------|-------------|--------|
EOF

    # Check each artifact and add to table
    local artifacts=(
        "pods.yaml|Pod definitions"
        "pdb.yaml|PodDisruptionBudget definitions"
        "servicemonitor.yaml|ServiceMonitor definitions"
        "prometheusrule.yaml|PrometheusRule definitions"
        "controller.log|Controller logs (last 500 lines)"
        "validate-output.txt|Output of kagent-validate command"
        "metadata.txt|Collection metadata"
    )

    for artifact in "${artifacts[@]}"; do
        local file="${artifact%%|*}"
        local desc="${artifact#*|}"
        local status

        if [[ -f "${OUTPUT_DIR}/${file}" ]]; then
            if grep -q "^# No\|^# Failed" "${OUTPUT_DIR}/${file}" 2>/dev/null; then
                status="Not Available"
            else
                status="Captured"
            fi
        else
            status="Missing"
        fi

        echo "| ${file} | ${desc} | ${status} |" >> "${OUTPUT_DIR}/README.md"
    done

    cat >> "${OUTPUT_DIR}/README.md" <<EOF

## Enterprise Features Verified

Based on collected evidence:

- **PodDisruptionBudgets**: Check pdb.yaml for PDB definitions
- **ServiceMonitor**: Check servicemonitor.yaml for Prometheus scrape config
- **PrometheusRule**: Check prometheusrule.yaml for alert definitions
- **Controller Operation**: Check controller.log for startup and reconciliation logs

## How to Use This Evidence

Include these artifacts in your PR to demonstrate:

1. Enterprise features are deployed and functioning
2. Resources were created correctly by Helm charts
3. Controller is running and processing resources

---
*Generated by \`scripts/collect-evidence.sh\`*
EOF

    log_info "README generated"
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

# Parse arguments
while getopts "n:o:h" opt; do
    case ${opt} in
        n)
            NAMESPACE="${OPTARG}"
            ;;
        o)
            OUTPUT_DIR="${OPTARG}"
            ;;
        h)
            usage
            exit 0
            ;;
        \?)
            usage
            exit 1
            ;;
    esac
done

# Verify oc is available
if ! command -v oc &>/dev/null; then
    log_error "oc command not found. Please install OpenShift CLI."
    exit 1
fi

# Verify we can connect to the cluster
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster. Run 'oc login' first."
    exit 1
fi

log_section "Collecting Evidence for kagent PR"

log_info "Namespace: ${NAMESPACE}"
log_info "Output:    ${OUTPUT_DIR}/"
echo ""

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Track success/failure
CAPTURED=0
FAILED=0

# Capture all resources
capture_resource "pods" "pods.yaml" "pods" && ((CAPTURED++)) || ((FAILED++))
capture_resource "pdb" "pdb.yaml" "PodDisruptionBudgets" && ((CAPTURED++)) || ((FAILED++))
capture_resource "servicemonitor" "servicemonitor.yaml" "ServiceMonitors" && ((CAPTURED++)) || ((FAILED++))
capture_resource "prometheusrule" "prometheusrule.yaml" "PrometheusRules" && ((CAPTURED++)) || ((FAILED++))

# Capture logs
capture_logs && ((CAPTURED++)) || ((FAILED++))

# Capture validate output
capture_validate_output && ((CAPTURED++)) || ((FAILED++))

# Generate metadata and README
generate_metadata
generate_readme

log_section "Evidence Collection Complete"

echo -e "  ${GREEN}Captured: ${CAPTURED}${NC}"
echo -e "  ${YELLOW}Missing:  ${FAILED}${NC}"
echo ""
echo "Evidence directory: ${OUTPUT_DIR}/"
echo ""
ls -la "${OUTPUT_DIR}/"
echo ""

if [[ "${FAILED}" -gt 0 ]]; then
    log_warn "Some resources could not be captured. This may be expected if certain features are not enabled."
fi

log_info "Done! Review ${OUTPUT_DIR}/README.md for summary."
