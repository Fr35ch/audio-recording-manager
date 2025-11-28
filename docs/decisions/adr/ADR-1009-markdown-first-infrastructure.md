# ADR-1009: Markdown-First Infrastructure Documentation

**Status**: Accepted

**Date**: 2025-11-28

**Deciders**: Fredrik Matheson, planner agent

## Context

### Problem Statement

AI agent systems need infrastructure definitions that are:
- Human-readable and reviewable
- Version-controllable alongside code
- Parseable by automation
- Portable across environments

Traditional infrastructure uses databases, APIs, or proprietary formats.

### Forces at Play

**Technical Requirements:**
- Agent definitions must be version-controlled
- Task specifications need human review
- Workflows should be documentable and auditable
- Automation should parse infrastructure definitions

**Constraints:**
- No external database dependencies
- Must work offline
- Changes visible in git diffs/PRs

**Assumptions:**
- Markdown is universally readable
- Frontmatter provides structured metadata
- Git provides sufficient version control

## Decision

Use **markdown files as first-class infrastructure components**:

### Core Principles

1. **Documentation as Code**: Infrastructure definitions are markdown files
2. **Git-Native**: All infrastructure version-controlled
3. **Human-First**: Readable without special tools
4. **Machine-Parseable**: Structured for automation

### Implementation Details

**Agent Definitions (.claude/agents/*.md):**
```markdown
---
name: feature-developer
description: Feature implementation specialist
model: claude-opus-4-5-20251101
tools:
  - Bash
  - Read
  - Edit
  - Write
---

# Feature Developer Agent

System prompt content that defines agent behavior...

## Responsibilities
- Implement features according to task specifications
- Follow TDD workflow
- Update documentation

## Guidelines
...
```

**Task Specifications (delegation/tasks/*.md):**
```markdown
# TASK-0001: Task Title

**Status**: Todo
**Priority**: high
**Assigned To**: feature-developer
**Estimated Effort**: 2-3 hours

## Overview
What this task accomplishes...

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Implementation Plan
...
```

**Workflow Procedures (.agent-context/workflows/*.md):**
```markdown
# Testing Workflow

## Pre-commit
1. Run `pytest tests/ -x -q`
2. Verify all tests pass
3. If tests fail, fix before committing

## CI/CD
...
```

**ADR Documents (docs/decisions/adr/*.md):**
```markdown
# ADR-0001: Decision Title

**Status**: Accepted
**Date**: 2025-01-01

## Context
...

## Decision
...

## Consequences
...
```

**Parsing for Automation:**
```python
import re
from pathlib import Path

def parse_task_metadata(task_file: Path) -> dict:
    content = task_file.read_text()

    # Extract frontmatter-style metadata
    status = re.search(r'\*\*Status\*\*:\s*(.+)', content)
    priority = re.search(r'\*\*Priority\*\*:\s*(.+)', content)

    return {
        'status': status.group(1) if status else None,
        'priority': priority.group(1) if priority else None,
    }
```

## Consequences

### Positive

- **Version Control**: Full git history for all infrastructure
- **Review Process**: Infrastructure changes visible in PRs
- **No Dependencies**: Works without external services
- **Human-Readable**: Anyone can read/edit without special tools
- **Portable**: Copy files to new project, infrastructure follows
- **Searchable**: Standard text search across all infrastructure

### Negative

- **Manual Updates**: No database validation/constraints
- **Parsing Fragility**: Markdown format changes can break automation
- **No Real-Time Sync**: Changes require commit/push
- **Schema Evolution**: Format changes need migration

### Neutral

- **50+ Infrastructure Files**: Significant markdown footprint
- **Convention-Based**: Relies on following established patterns

## Alternatives Considered

### Alternative 1: Database-Backed Infrastructure

**Description**: Store agent/task definitions in SQLite or PostgreSQL.

**Rejected because**:
- Adds external dependency
- Not version-controllable in git
- Requires database tooling

### Alternative 2: YAML/JSON Configuration

**Description**: Use structured data formats instead of markdown.

**Rejected because**:
- Less human-readable for long content
- Harder to include documentation alongside config
- Markdown supports both structure and prose

### Alternative 3: Code-Based Definitions

**Description**: Define agents/tasks in Python/Swift code.

**Rejected because**:
- Requires programming knowledge to edit
- Harder for non-developers to review
- Mixes infrastructure with application code

## Real-World Results

**Infrastructure Files:**
- 10+ agent definitions
- 15+ task specifications
- 8 workflow procedures
- 30+ ADR documents
- All version-controlled and reviewable

**Automation Built:**
- Linear sync parses task files
- Agent launcher reads markdown definitions
- CI validates markdown structure

## Related Decisions

- ADR-1001: Multi-Agent Coordination Architecture
- ADR-1002: Numbered Workflow Task Organization

## References

- `.claude/agents/` - Agent definitions
- `delegation/tasks/` - Task specifications
- `.agent-context/workflows/` - Workflow procedures
- `docs/decisions/adr/` - Architecture decisions

## Revision History

- 2025-11-28: Initial decision (Accepted)

---

**Template Version**: 1.1.0
**Project**: Agentive Starter Kit / Audio Recording Manager
