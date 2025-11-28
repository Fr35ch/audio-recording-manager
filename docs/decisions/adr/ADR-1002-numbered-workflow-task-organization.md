# ADR-1002: Numbered Workflow Task Organization

**Status**: Accepted

**Date**: 2025-11-28

**Deciders**: Fredrik Matheson, planner agent

## Context

### Problem Statement

Project task management typically requires external tools (Jira, Linear, Trello) which:
- Create dependency on external services
- Require context switching between code and task boards
- Don't integrate naturally with git workflows
- Can't be version-controlled alongside code

### Forces at Play

**Technical Requirements:**
- Tasks must be trackable without external dependencies
- Task state should be version-controlled
- Support for multiple workflow stages (backlog → done)
- Optional integration with Linear for team visibility

**Constraints:**
- Git-native approach preferred
- Human-readable task files
- Support for agent-driven task processing
- Linear API compatibility for sync

**Assumptions:**
- File location can represent task state
- Markdown files are sufficient for task specification
- Teams may or may not use Linear

## Decision

Organize tasks in **numbered workflow folders** that map directly to Linear issue statuses:

```
delegation/tasks/
├── 1-backlog/     → Tasks defined but not ready
├── 2-todo/        → Ready to start, dependencies met
├── 3-in-progress/ → Actively being worked on
├── 4-in-review/   → Implementation complete, under review
├── 5-done/        → Fully complete and verified
├── 6-canceled/    → Will not be implemented
├── 7-blocked/     → Temporarily blocked
├── 8-archive/     → Historical reference (not synced)
└── 9-reference/   → Templates and examples (not synced)
```

### Core Principles

1. **Location as State**: Task's folder location determines its workflow status
2. **Priority Resolution**: Status field (in file) > Folder location > Default (Backlog)
3. **Git-Native**: All task state is tracked in git, no external database required
4. **Graceful Integration**: Linear sync is optional, works without it

### Implementation Details

**Task File Naming:**
```
TASK-####-description.md    # Standard tasks
ASK-####-description.md     # Agentive Starter Kit tasks
```

**Task File Structure:**
```markdown
# TASK-0001: Task Title

**Status**: Todo
**Priority**: high
**Assigned To**: feature-developer
**Estimated Effort**: 2-3 hours

## Overview
Task description...

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2
```

**Status Determination Priority:**
1. **Status field** in task file (if Linear-native value)
2. **Folder location** (1-backlog → Backlog, 2-todo → Todo, etc.)
3. **Default**: Backlog

**Sync Behavior:**
- Folders 1-7: Synced to Linear (if configured)
- Folders 8-9: Never synced (archive/reference)

## Consequences

### Positive

- **Git-Native**: Full task history in version control
- **No Dependencies**: Works without Linear or any external service
- **Human-Readable**: Tasks are plain markdown files
- **Agent-Compatible**: Agents can create, move, and update tasks
- **Searchable**: Standard grep/search across all tasks
- **PR-Friendly**: Task changes visible in code reviews

### Negative

- **Manual State Changes**: Moving files between folders required
- **No Real-Time Sync**: Linear sync happens on push, not real-time
- **Folder Clutter**: Many folders in delegation/tasks/
- **Learning Curve**: Non-standard approach requires explanation

### Neutral

- **Linear Optional**: Teams can choose to use Linear or not
- **Numbering Convention**: 1-9 prefix enforces sort order

## Alternatives Considered

### Alternative 1: Linear-Only Task Management

**Description**: Use Linear as primary task system, no local files.

**Rejected because**:
- Creates external dependency
- Tasks not version-controlled with code
- Requires Linear account for all contributors

### Alternative 2: Single Folder with Status Field

**Description**: Keep all tasks in one folder, use Status field for state.

**Rejected because**:
- Harder to see workflow state at a glance
- No natural ordering in file listings
- Less intuitive for human operators

### Alternative 3: GitHub Issues Integration

**Description**: Use GitHub Issues for task tracking.

**Rejected because**:
- Separates tasks from codebase
- Less flexible task format
- Doesn't support agent-friendly markdown structure

## Real-World Results

**Implementation:**
- `scripts/sync_tasks_to_linear.py` handles GraphQL sync
- `.github/workflows/sync-to-linear.yml` auto-syncs on push
- `./project linearsync` command for manual sync

**Observed Benefits:**
- Tasks visible in git log and PRs
- Easy to move tasks between states (git mv)
- Works offline without external services
- Agents successfully create and manage tasks

## Related Decisions

- ADR-1009: Markdown-First Infrastructure Documentation
- ADR-1013: Optional Linear Integration

## References

- `delegation/tasks/README.md` - Task folder documentation
- `scripts/sync_tasks_to_linear.py` - Sync implementation
- `delegation/tasks/9-reference/templates/task-template.md` - Task template

## Revision History

- 2025-11-28: Initial decision (Accepted)

---

**Template Version**: 1.1.0
**Project**: Agentive Starter Kit / Audio Recording Manager
