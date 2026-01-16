# Contributing to Cyclopes (kagent fork)

## Quick Start

```bash
# Check fork status
./scripts/sync-upstream.sh --status

# Sync with upstream
./scripts/sync-upstream.sh
```

## Making Changes

### For Upstream-Worthy Changes

1. Branch from upstream/main
2. Make changes
3. Open PR on github.com/kagent-dev/kagent
4. After merge, sync local

### For Fork-Specific Changes

1. Document why it can't go upstream
2. Add `// FORK: reason` comment
3. Keep minimal

## Key Commands

```bash
# Status check
./scripts/sync-upstream.sh --status

# See what's new upstream
./scripts/sync-upstream.sh --log

# Interactive sync
./scripts/sync-upstream.sh

# Push changes
git push gitlab main
```

## Getting Help

- See `docs/FORK-STRATEGY.md` for full policy
- See `~/gt/mayor/standards/FORK-STRATEGY.md` for town standard
