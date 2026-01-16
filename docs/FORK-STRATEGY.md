# Fork Strategy: Cyclopes (kagent fork)

## Overview

Cyclopes is a **Derivative Product** fork of [kagent-dev/kagent](https://github.com/kagent-dev/kagent). We track upstream closely and minimize divergence.

## Classification

| Aspect | Value |
|--------|-------|
| **Pattern** | Derivative Product |
| **Upstream** | kagent-dev/kagent |
| **Target divergence** | <10 commits (50 max) |
| **Sync frequency** | Weekly or on upstream release |

## Remote Configuration

| Remote | URL | Purpose |
|--------|-----|---------|
| `upstream` | github.com/kagent-dev/kagent | Original source |
| `origin` | github.com/boshu2/kagent | Personal fork for PRs |
| `gitlab` | git.deepskylab.io/olympus/cyclopes | Internal deployment |

## Sync Workflow

```bash
# Check status
./scripts/sync-upstream.sh --status

# See new commits
./scripts/sync-upstream.sh --log

# Sync
./scripts/sync-upstream.sh

# Push to all remotes
git push origin main
git push gitlab main
```

## Branch Strategy

| Branch | Purpose |
|--------|---------|
| `main` | Tracks upstream/main, may have local patches |
| `feature/*` | Local development |
| `polecat/*` | Gas Town worker branches |
| `pr/*` | Upstream PR preparation |

## Contributing Changes Upstream

1. **Create PR branch from upstream/main**
   ```bash
   git fetch upstream
   git checkout -b pr/feature-name upstream/main
   ```

2. **Make changes and push to origin**
   ```bash
   git push origin pr/feature-name
   ```

3. **Open PR on github.com/kagent-dev/kagent**

4. **After merge, sync local main**
   ```bash
   ./scripts/sync-upstream.sh
   ```

## Fork-Specific Changes

When changes cannot go upstream:

1. Create with clear comment: `// FORK: reason for local change`
2. Document in `.agents/patches/` if significant
3. Keep minimal - prefer upstream PRs

## Red Lines (Never Diverge On)

- Core API types
- Controller logic without good reason
- Build/CI that breaks upstream compatibility

## See Also

- `~/gt/mayor/standards/FORK-STRATEGY.md` - Town-wide fork policy
- `CONTRIBUTING-FORK.md` - Contributor guide
