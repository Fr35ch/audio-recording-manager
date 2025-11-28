# ADR-1013: Optional Linear Integration

**Status**: Accepted

**Date**: 2025-11-28

**Deciders**: Fredrik Matheson, planner agent

## Context

### Problem Statement

Teams have different project management preferences:
- Some use Linear for visual task boards
- Some prefer git-native task management only
- External service dependencies can be problematic
- Integration should enhance, not require

### Forces at Play

**Technical Requirements:**
- Task management must work without Linear
- Linear sync should be easy to enable
- Sync failures shouldn't break workflows
- Team visibility benefits from Linear boards

**Constraints:**
- Linear API requires authentication
- GitHub Actions can't access secrets in job conditions
- Sync is one-way (files → Linear)

**Assumptions:**
- Primary system is file-based
- Linear is enhancement, not requirement
- Graceful degradation is essential

## Decision

Implement **Linear integration as optional enhancement**:

### Core Principles

1. **File-First**: Markdown tasks are primary source of truth
2. **Graceful Skip**: Missing API key → silent skip, not failure
3. **One-Way Sync**: Files → Linear (not bidirectional)
4. **Zero Config Default**: Works without any Linear setup

### Implementation Details

**Workflow with Graceful Skip (.github/workflows/sync-to-linear.yml):**
```yaml
jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - name: Check for Linear API key
        id: check-key
        run: |
          if [ -z "${{ secrets.LINEAR_API_KEY }}" ]; then
            echo "skip=true" >> $GITHUB_OUTPUT
            echo "⏭️ LINEAR_API_KEY not configured - skipping sync"
          else
            echo "skip=false" >> $GITHUB_OUTPUT
          fi

      - name: Sync tasks to Linear
        if: steps.check-key.outputs.skip != 'true'
        run: python scripts/sync_tasks_to_linear.py
        env:
          LINEAR_API_KEY: ${{ secrets.LINEAR_API_KEY }}

      - name: Summary
        if: always()
        run: |
          if [ "${{ steps.check-key.outputs.skip }}" = "true" ]; then
            echo "## Linear Sync Skipped" >> $GITHUB_STEP_SUMMARY
            echo "LINEAR_API_KEY not configured." >> $GITHUB_STEP_SUMMARY
            echo "To enable: Add LINEAR_API_KEY to repository secrets" >> $GITHUB_STEP_SUMMARY
          else
            echo "## Linear Sync Complete" >> $GITHUB_STEP_SUMMARY
          fi
```

**Manual Sync (project CLI):**
```bash
# Works if .env has LINEAR_API_KEY
./project linearsync

# List available teams
./project teams
```

**Environment Configuration (.env.template):**
```bash
# Optional - for task synchronization
# Get your key at: https://linear.app/settings/api
LINEAR_API_KEY=

# Optional - specify team (auto-detects if not set)
# Accepts: Team KEY (e.g., "AL2") or UUID
LINEAR_TEAM_ID=
```

**Feature Detection:**
```python
def main():
    api_key = os.getenv("LINEAR_API_KEY")
    if not api_key:
        print("⏭️ LINEAR_API_KEY not set - skipping sync")
        print("   To enable: Set LINEAR_API_KEY in .env")
        return  # Exit gracefully, not error

    # Proceed with sync...
```

**User Experience:**

| Scenario | Behavior |
|----------|----------|
| No LINEAR_API_KEY | Workflow passes, shows "skipped" |
| Invalid API key | Workflow fails with clear error |
| Valid API key | Tasks sync to Linear |
| Manual sync without key | Helpful message, no error |

## Consequences

### Positive

- **Zero Friction Start**: New projects work immediately
- **No Lock-In**: Teams can use or ignore Linear
- **CI Never Breaks**: Missing key = skip, not fail
- **Clear Guidance**: Helpful messages explain how to enable
- **Team Flexibility**: Each team chooses their workflow

### Negative

- **One-Way Sync**: Changes in Linear don't flow back
- **Potential Staleness**: Linear may diverge from files
- **Two Systems**: Teams using Linear have two sources
- **Discovery**: Teams may not know Linear sync exists

### Neutral

- **GitHub Actions Trigger**: Syncs on push to task folders
- **Manual Override**: `./project linearsync` always available

## Alternatives Considered

### Alternative 1: Required Linear Integration

**Description**: Make Linear mandatory for task management.

**Rejected because**:
- Creates external dependency
- Not all teams use Linear
- Adds onboarding friction

### Alternative 2: Bidirectional Sync

**Description**: Sync changes from Linear back to files.

**Rejected because**:
- Complexity of conflict resolution
- Risk of overwriting local changes
- One-way simpler and safer

### Alternative 3: Database-Backed Tasks

**Description**: Use database with Linear as one view.

**Rejected because**:
- Adds infrastructure dependency
- Not git-native
- Overkill for most projects

## Real-World Results

**Adoption:**
- Some projects enable Linear sync
- Others use file-only workflow
- Both work seamlessly

**CI Behavior:**
- Workflow always passes
- Clear summary shows sync status
- No confusion about failures

## Related Decisions

- ADR-1002: Numbered Workflow Task Organization
- ADR-1009: Markdown-First Infrastructure Documentation

## References

- `scripts/sync_tasks_to_linear.py` - Sync implementation
- `.github/workflows/sync-to-linear.yml` - CI workflow
- `.env.template` - Configuration template
- `project` CLI - Manual sync command

## Revision History

- 2025-11-28: Initial decision (Accepted)

---

**Template Version**: 1.1.0
**Project**: Agentive Starter Kit / Audio Recording Manager
