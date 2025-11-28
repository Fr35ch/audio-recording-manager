# ADR-1011: Task-Based Agent Handoff Protocol

**Status**: Accepted

**Date**: 2025-11-28

**Deciders**: Fredrik Matheson, planner agent

## Context

### Problem Statement

Multi-agent systems face context transfer challenges:
- Agent A completes work, Agent B needs to continue
- Context windows don't persist between agent invocations
- Important decisions made by Agent A may be lost
- No standard way to transfer state between agents

### Forces at Play

**Technical Requirements:**
- Preserve context across agent boundaries
- Document decisions for audit trail
- Enable asynchronous agent coordination
- Support multi-session workflows

**Constraints:**
- Agents are stateless between invocations
- Context windows have token limits
- Human oversight needed at handoff points

**Assumptions:**
- Structured handoffs reduce information loss
- Documentation overhead worth the context preservation
- Handoffs are discrete, identifiable events

## Decision

Implement **structured handoff protocol** with:

1. **State tracking** in `agent-handoffs.json`
2. **Handoff documents** for detailed context transfer
3. **Task starters** for invoking next agent

### Implementation Details

**State Tracking (.agent-context/agent-handoffs.json):**
```json
{
  "agents": {
    "planner": {
      "status": "idle",
      "current_task": null,
      "last_active": "2025-11-28T12:00:00Z"
    },
    "feature-developer": {
      "status": "assigned",
      "current_task": "TASK-0001",
      "brief_note": "Implementing Linear sync infrastructure",
      "details_link": ".agent-context/TASK-0001-HANDOFF-feature-developer.md"
    },
    "powertest-runner": {
      "status": "idle",
      "current_task": null
    }
  },
  "last_updated": "2025-11-28T12:00:00Z",
  "active_task": "TASK-0001"
}
```

**Handoff Document (.agent-context/TASK-0001-HANDOFF-feature-developer.md):**
```markdown
# TASK-0001 Handoff: Feature Developer

**Task**: TASK-0001 - Linear Sync Infrastructure
**From**: planner
**To**: feature-developer
**Date**: 2025-11-28

## Context Summary
Brief overview of what's been done and what needs to happen.

## Key Decisions Made
1. Decision about approach X
2. Decision about implementation Y

## Files Modified
- `scripts/sync_tasks_to_linear.py` - Main sync script
- `tests/test_linear_sync.py` - Test suite

## Next Steps
1. [ ] Complete implementation of sync_task function
2. [ ] Add error handling for API failures
3. [ ] Run full test suite

## Blockers/Notes
- API rate limiting may require exponential backoff
- Consider batch processing for large task counts

## Resources
- Task file: `delegation/tasks/3-in-progress/TASK-0001.md`
- Reference implementation: thematic-cuts/scripts/sync_tasks_to_linear.py
```

**Task Starter Message:**
```markdown
## Task Assignment: TASK-0001

**Agent**: feature-developer
**Task**: Linear Sync Infrastructure

### Overview
Implement task synchronization from markdown files to Linear.

### Acceptance Criteria
- [ ] Sync script reads task files
- [ ] Creates/updates Linear issues
- [ ] 80%+ test coverage

### Time Estimate
4-6 hours total

### Files to Read
1. Task file: `delegation/tasks/3-in-progress/TASK-0001.md`
2. Handoff: `.agent-context/TASK-0001-HANDOFF-feature-developer.md`
```

**Handoff Flow:**
```
1. Planner receives user request
2. Planner creates task specification
3. Planner updates agent-handoffs.json (assigns agent)
4. Planner creates handoff document
5. Planner invokes agent via Task tool with task starter
6. Agent reads handoff, executes task
7. Agent updates handoff with progress/completion
8. Agent updates agent-handoffs.json (status change)
9. Control returns to planner
```

## Consequences

### Positive

- **Context Preservation**: Key decisions documented at handoff
- **Audit Trail**: Clear record of what each agent did
- **Resumability**: Work can continue after interruption
- **Visibility**: Humans can inspect handoff state
- **Scalability**: Supports complex multi-agent workflows

### Negative

- **Overhead**: Creating handoff documents takes time
- **Maintenance**: State files need cleanup
- **Complexity**: Multiple files to coordinate
- **Staleness**: Handoff docs may become outdated

### Neutral

- **Git-Tracked**: Handoffs version-controlled
- **Agent Responsibility**: Agents must update state

## Alternatives Considered

### Alternative 1: No Explicit Handoffs

**Description**: Agents work independently, no state transfer.

**Rejected because**:
- Context lost between agents
- Repeated work due to missing information
- No audit trail

### Alternative 2: Database State Storage

**Description**: Store handoff state in database.

**Rejected because**:
- Adds external dependency
- Not git-trackable
- Overkill for agent count

### Alternative 3: Single Conversation Context

**Description**: Keep all agents in one long conversation.

**Rejected because**:
- Context window limits
- Can't parallelize agents
- Harder to audit individual agent actions

## Real-World Results

**Observed Benefits:**
- Smooth task transitions between planner and developers
- Clear record of decisions when reviewing PRs
- Easy to resume interrupted work

**Challenges:**
- Handoff document quality varies
- State files occasionally get stale

## Related Decisions

- ADR-1001: Multi-Agent Coordination Architecture
- ADR-1009: Markdown-First Infrastructure Documentation

## References

- `.agent-context/agent-handoffs.json` - State tracking
- `.agent-context/*.md` - Handoff documents
- `.claude/agents/TASK-STARTER-TEMPLATE.md` - Task starter template
- `.agent-context/PROCEDURAL-KNOWLEDGE-INDEX.md` - Workflow index

## Revision History

- 2025-11-28: Initial decision (Accepted)

---

**Template Version**: 1.1.0
**Project**: Agentive Starter Kit / Audio Recording Manager
