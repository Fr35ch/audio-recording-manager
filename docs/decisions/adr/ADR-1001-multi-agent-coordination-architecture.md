# ADR-1001: Multi-Agent Coordination Architecture

**Status**: Accepted

**Date**: 2025-11-28

**Deciders**: Fredrik Matheson, planner agent

## Context

### Problem Statement

Traditional AI code assistants use a single general-purpose agent for all tasks. This approach has limitations:
- Context window exhaustion on complex tasks
- No specialization for different task types
- Difficulty maintaining consistent quality across diverse operations
- No separation of concerns between planning, implementation, testing, and review

### Forces at Play

**Technical Requirements:**
- Support for complex multi-step tasks (feature development, refactoring, testing)
- Maintainable context across task boundaries
- Specialized tooling for different roles (development vs. testing vs. security)
- Quality assurance at multiple stages

**Constraints:**
- Claude Code's subprocess model for launching agents
- Token limits per conversation
- Need for human oversight at key decision points

**Assumptions:**
- Specialization improves output quality
- Explicit handoffs reduce context loss
- Different tasks benefit from different system prompts

## Decision

Implement a **multi-agent coordination system** with specialized AI agents, each defined by:
1. A markdown file containing the system prompt (`.claude/agents/*.md`)
2. A defined role and set of responsibilities
3. Explicit tool permissions in `.claude/settings.local.json`
4. State tracking via `.agent-context/agent-handoffs.json`

### Core Principles

1. **Specialization over Generalization**: Each agent focuses on a specific domain (planning, development, testing, security)
2. **Explicit Handoffs**: Agents transfer context through structured handoff documents
3. **Centralized Coordination**: The planner agent orchestrates task distribution
4. **Infrastructure as Code**: Agent definitions are version-controlled markdown

### Implementation Details

**Agent Types (10+):**
- `planner` - Task planning, coordination, oversight
- `feature-developer` - Feature implementation
- `powertest-runner` - Comprehensive testing and TDD
- `security-reviewer` - Security analysis
- `document-reviewer` - Documentation quality
- `ci-checker` - CI/CD verification
- `Explore` - Codebase exploration
- `Plan` - Implementation planning
- And more specialized agents as needed

**Agent Definition Structure:**
```markdown
---
name: agent-name
description: One sentence description
model: claude-opus-4-5-20251101  # or sonnet, haiku
tools:
  - Bash
  - Read
  - Edit
  - Write
---

# Agent Name

System prompt content here...
```

**Coordination Flow:**
1. User request → Planner agent
2. Planner creates task specification
3. Planner delegates to specialized agent via Task tool
4. Agent executes, updates handoff state
5. Control returns to planner for next steps

## Consequences

### Positive

- **Improved Quality**: Specialized prompts yield better results per domain
- **Scalable Complexity**: Multi-step tasks decompose naturally across agents
- **Maintainable Context**: Each agent operates with focused context
- **Auditable Process**: Handoff files document decision chains
- **Extensible**: New agents added by creating markdown files

### Negative

- **Coordination Overhead**: Handoffs add process complexity
- **Context Fragmentation**: Information can be lost between agents
- **Learning Curve**: Operators must understand agent ecosystem
- **Token Cost**: Multiple agent invocations use more tokens than single conversation

### Neutral

- **Model Selection**: Different agents can use different model tiers (opus/sonnet/haiku)
- **Tool Permissions**: Each agent's capabilities are explicitly configured

## Alternatives Considered

### Alternative 1: Single General-Purpose Agent

**Description**: Use one agent with a comprehensive system prompt for all tasks.

**Rejected because**:
- Context exhaustion on complex tasks
- No specialization benefits
- Difficult to maintain quality across diverse operations

### Alternative 2: External Orchestration System

**Description**: Use external workflow tools (LangChain, AutoGen) for agent coordination.

**Rejected because**:
- Adds external dependencies
- Less integrated with Claude Code ecosystem
- More complex deployment

### Alternative 3: Human-Only Coordination

**Description**: Human operator manually switches between specialized prompts.

**Rejected because**:
- High cognitive load on operator
- Inconsistent handoff quality
- Slower iteration cycles

## Real-World Results

**Observed Benefits:**
- 85% test pass rate maintained across complex features
- 30-50% faster completion of multi-step tasks
- Clear audit trail via handoff documents
- Successful delegation of specialized tasks (security review, testing)

**Challenges Encountered:**
- Initial setup complexity
- Occasional context loss at handoff boundaries
- Need for explicit handoff documentation discipline

## Related Decisions

- ADR-1011: Task-Based Agent Handoff Protocol
- ADR-1012: Tool Permissions Configuration
- ADR-0001: System Prompt Size Considerations

## References

- `.claude/agents/` - Agent definitions
- `.agent-context/agent-handoffs.json` - State tracking
- `.claude/agents/AGENT-TEMPLATE.md` - Template for new agents
- Claude Code documentation on Task tool

## Revision History

- 2025-11-28: Initial decision (Accepted)

---

**Template Version**: 1.1.0
**Project**: Agentive Starter Kit / Audio Recording Manager
