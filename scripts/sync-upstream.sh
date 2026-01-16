#!/bin/bash
# Lightweight upstream sync for derivative product forks
# Pattern: Track upstream closely, minimize divergence
#
# Usage:
#   ./scripts/sync-upstream.sh           # Interactive merge
#   ./scripts/sync-upstream.sh --status  # Show fork divergence
#   ./scripts/sync-upstream.sh --log     # Show new upstream commits

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="main"
LOCAL_BRANCH="main"

log() { echo -e "${BLUE}[sync]${NC} $1"; }
warn() { echo -e "${YELLOW}[warn]${NC} $1"; }
error() { echo -e "${RED}[error]${NC} $1"; exit 1; }
success() { echo -e "${GREEN}[ok]${NC} $1"; }

show_status() {
    log "Fork status:"
    echo ""

    git fetch "$UPSTREAM_REMOTE" 2>/dev/null

    local ahead=$(git rev-list --count "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}..${LOCAL_BRANCH}" 2>/dev/null || echo "?")
    local behind=$(git rev-list --count "${LOCAL_BRANCH}..${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" 2>/dev/null || echo "?")

    echo "  Local branch:  ${LOCAL_BRANCH}"
    echo "  Upstream:      ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"
    echo ""
    echo "  Commits ahead:  ${ahead}"
    echo "  Commits behind: ${behind}"
    echo ""

    if [ "$ahead" != "?" ] && [ "$ahead" != "0" ]; then
        log "Your local commits:"
        git log --oneline "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}..${LOCAL_BRANCH}"
        echo ""
    fi

    # Pattern guidance
    if [ "$ahead" != "?" ]; then
        if [ "$ahead" -lt 50 ]; then
            success "Derivative product pattern (healthy)"
        else
            warn "Consider Enterprise Fork pattern (50+ commits ahead)"
            echo "  See: ~/gt/mayor/standards/FORK-STRATEGY.md"
        fi
    fi
}

show_upstream_log() {
    log "Fetching upstream..."
    git fetch "$UPSTREAM_REMOTE"

    echo ""
    log "New commits in upstream/${UPSTREAM_BRANCH} not in ${LOCAL_BRANCH}:"
    echo ""

    local count=$(git rev-list --count "${LOCAL_BRANCH}..${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" 2>/dev/null || echo "0")

    if [ "$count" = "0" ]; then
        success "Already up to date with upstream"
        return 0
    fi

    git log --oneline "${LOCAL_BRANCH}..${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"
    echo ""
    log "Total: ${count} commits"
}

do_sync() {
    # Ensure we're on the right branch
    local current_branch=$(git branch --show-current)
    if [ "$current_branch" != "$LOCAL_BRANCH" ]; then
        error "Not on ${LOCAL_BRANCH} branch. Currently on: ${current_branch}"
    fi

    # Check for uncommitted changes
    if ! git diff-index --quiet HEAD --; then
        error "Uncommitted changes detected. Commit or stash first."
    fi

    log "Fetching upstream..."
    git fetch "$UPSTREAM_REMOTE"

    local count=$(git rev-list --count "${LOCAL_BRANCH}..${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" 2>/dev/null || echo "0")

    if [ "$count" = "0" ]; then
        success "Already up to date with upstream"
        return 0
    fi

    log "Found ${count} new commits from upstream"
    echo ""

    # Show what's coming
    git log --oneline "${LOCAL_BRANCH}..${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" | head -20
    if [ "$count" -gt 20 ]; then
        echo "  ... and $(($count - 20)) more"
    fi
    echo ""

    # Confirm
    read -p "Merge these ${count} commits? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Aborted"
        return 1
    fi

    # Attempt merge
    log "Merging upstream/${UPSTREAM_BRANCH}..."
    if git merge "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" -m "Sync upstream $(date +%Y-%m-%d)"; then
        success "Merge successful!"
        echo ""
        log "Push to remotes with:"
        echo "  git push origin main"
        echo "  git push gitlab main"
    else
        warn "Merge conflicts detected!"
        echo ""
        log "Conflicting files:"
        git diff --name-only --diff-filter=U
        echo ""
        log "Options:"
        log "  1. Resolve conflicts manually"
        log "  2. Run: git merge --abort  (to cancel)"
        log "  3. After resolving: git add . && git commit"
        return 1
    fi
}

show_help() {
    cat << EOF
Lightweight upstream sync for kagent fork.

Usage:
    $(basename "$0") [options]

Options:
    (no option)      Interactive merge sync
    --status, -s     Show fork divergence status
    --log, -l        Show new upstream commits
    --help, -h       Show this help

Remotes:
    upstream  → github.com/kagent-dev/kagent (original)
    origin    → github.com/boshu2/kagent (your fork)
    gitlab    → git.deepskylab.io/olympus/cyclopes (private)

Examples:
    # Check divergence
    $(basename "$0") --status

    # See what's new
    $(basename "$0") --log

    # Sync with upstream
    $(basename "$0")

Documentation:
    docs/FORK-STRATEGY.md
    ~/gt/mayor/standards/FORK-STRATEGY.md
EOF
}

# Main
case "${1:-}" in
    --status|-s)
        show_status
        ;;
    --log|-l)
        show_upstream_log
        ;;
    --help|-h)
        show_help
        ;;
    "")
        do_sync
        ;;
    *)
        error "Unknown option: $1. Use --help for usage."
        ;;
esac
