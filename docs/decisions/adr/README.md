# Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records (ADRs) documenting significant architectural and design decisions for the Agentive Starter Kit and Audio Recording Manager.

## What are ADRs?

ADRs capture important architectural decisions along with their context and consequences. Each ADR describes:
- **Context**: The forces and factors influencing the decision
- **Decision**: What was decided and why
- **Consequences**: The positive, negative, and neutral implications

ADRs are **immutable** once accepted. If a decision changes, we create a new ADR that supersedes the old one, preserving the historical context.

## Format

We use [Michael Nygard's ADR format](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions). See [TEMPLATE-FOR-ADR-FILES.md](TEMPLATE-FOR-ADR-FILES.md) for the full template.

## Naming Convention

ADRs use the format **`ADR-####-description.md`** where:
- `ADR-` is the required prefix
- `####` is a four-digit sequential number
- `-description` is a short kebab-case description

**Number Ranges:**
- `0001-0099`: Foundation/infrastructure ADRs
- `1001-1099`: Agentive Starter Kit ADRs

## Index

### Foundation ADRs (0001-0099)

| ADR | Title | Date | Status |
|-----|-------|------|--------|
| [0001](ADR-0001-system-prompt-size-considerations.md) | System Prompt Size Considerations | - | Accepted |
| [0002](ADR-0002-serena-mcp-integration.md) | Serena MCP Integration | - | Accepted |

### Agentive Starter Kit ADRs (1001-1099)

| ADR | Title | Date | Status | Priority |
|-----|-------|------|--------|----------|
| [1001](ADR-1001-multi-agent-coordination-architecture.md) | Multi-Agent Coordination Architecture | 2025-11-28 | Accepted | HIGH |
| [1002](ADR-1002-numbered-workflow-task-organization.md) | Numbered Workflow Task Organization | 2025-11-28 | Accepted | HIGH |
| [1003](ADR-1003-separated-library-for-testable-code.md) | Separated Library for Testable Code | 2025-11-28 | Accepted | MEDIUM |
| [1004](ADR-1004-pre-commit-hooks-quality-gate.md) | Pre-commit Hooks as Quality Gate | 2025-11-28 | Accepted | HIGH |
| [1005](ADR-1005-adversarial-evaluation-loop.md) | Adversarial Evaluation Loop | 2025-11-28 | Accepted | HIGH |
| [1006](ADR-1006-network-isolation-default.md) | Network Isolation as Default | 2025-11-28 | Accepted | MEDIUM |
| [1007](ADR-1007-nav-design-system-integration.md) | NAV Design System Integration | 2025-11-28 | Accepted | LOW |
| [1008](ADR-1008-serena-lsp-integration.md) | Serena LSP Integration | 2025-11-28 | Accepted | MEDIUM |
| [1009](ADR-1009-markdown-first-infrastructure.md) | Markdown-First Infrastructure | 2025-11-28 | Accepted | MEDIUM |
| [1010](ADR-1010-two-layer-build-strategy.md) | Two-Layer Build Strategy | 2025-11-28 | Accepted | MEDIUM |
| [1011](ADR-1011-task-based-agent-handoff-protocol.md) | Task-Based Agent Handoff Protocol | 2025-11-28 | Accepted | MEDIUM |
| [1012](ADR-1012-tool-permissions-configuration.md) | Tool Permissions Configuration | 2025-11-28 | Accepted | LOW |
| [1013](ADR-1013-optional-linear-integration.md) | Optional Linear Integration | 2025-11-28 | Accepted | LOW |

### ADR Categories

**System Architecture (Core)** - HIGH Priority:
- ADR-1001: Multi-Agent Coordination Architecture
- ADR-1004: Pre-commit Hooks as Quality Gate
- ADR-1005: Adversarial Evaluation Loop

**Project Organization** - HIGH/MEDIUM Priority:
- ADR-1002: Numbered Workflow Task Organization
- ADR-1009: Markdown-First Infrastructure
- ADR-1011: Task-Based Agent Handoff Protocol
- ADR-1013: Optional Linear Integration

**Quality & Testing** - MEDIUM Priority:
- ADR-1003: Separated Library for Testable Code

**Build & Development** - MEDIUM Priority:
- ADR-1008: Serena LSP Integration
- ADR-1010: Two-Layer Build Strategy
- ADR-1012: Tool Permissions Configuration

**Application (Audio Recording Manager)** - MEDIUM/LOW Priority:
- ADR-1006: Network Isolation as Default
- ADR-1007: NAV Design System Integration

### Superseded ADRs

None yet.

## Process

### Creating a New ADR

1. **Identify the decision**: Is this an architectural decision that affects the project's structure, behavior, or future direction?

2. **Assign a number**: Use the next sequential number in the appropriate range

3. **Draft the ADR**: Use the [template](TEMPLATE-FOR-ADR-FILES.md), focusing on:
   - **Context**: What forces led to this decision?
   - **Decision**: What was decided and why?
   - **Consequences**: What are the trade-offs?

4. **Review**: Get feedback from project stakeholders

5. **Accept**: Mark status as "Accepted" and update this index

6. **Commit**: Include the ADR in your commit

### Superseding an ADR

When a decision changes:

1. **Create a new ADR** documenting the new decision
2. **Update the old ADR**: Change status to "Superseded by ADR-XXXX"
3. **Update this index**: Move the old ADR to "Superseded" section
4. **Preserve history**: Never delete or significantly modify accepted ADRs

## When to Write an ADR

**Write an ADR when:**
- Making architectural choices that affect project structure
- Choosing between competing technical approaches
- Establishing patterns or conventions
- Making trade-offs with significant implications
- Decisions that future developers will need to understand

**Don't write an ADR for:**
- Routine bug fixes
- Feature implementations following established patterns
- Temporary experimental code
- Configuration changes without architectural impact

## ADR Priority Levels

- **HIGH**: Core architecture, must understand to work on project
- **MEDIUM**: Important patterns, helpful for most development
- **LOW**: Specific features, reference as needed

## Related Documentation

- [README.md](../../../README.md) - Project overview
- [SETUP.md](../../../SETUP.md) - Setup instructions
- [delegation/tasks/](../../../delegation/tasks/) - Task specifications
- [.claude/agents/](../../../.claude/agents/) - Agent definitions
- [.agent-context/](../../../.agent-context/) - Agent coordination

## References

- [Documenting Architecture Decisions](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions) - Michael Nygard
- [ADR GitHub Organization](https://adr.github.io/) - ADR tools and resources
- [Why Write ADRs](https://github.blog/2020-08-13-why-write-adrs/) - GitHub Engineering blog

---

**Maintainer**: planner agent, feature-developer
**Last Updated**: 2025-11-28
**ADR Count**: 15 (2 foundation + 13 starter kit)
**Project**: Agentive Starter Kit / Audio Recording Manager
