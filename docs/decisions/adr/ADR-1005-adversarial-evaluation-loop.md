# ADR-1005: Adversarial Evaluation Loop

**Status**: Accepted

**Date**: 2025-11-28

**Deciders**: Fredrik Matheson, planner agent

## Context

### Problem Statement

AI-generated task specifications and implementation plans may contain:
- Logical inconsistencies
- Missing edge cases
- Overly complex solutions
- Assumptions that don't match project context
- Scope creep or feature bloat

Single-model systems lack independent critique capability.

### Forces at Play

**Technical Requirements:**
- Independent review of AI-generated plans before implementation
- Catch design flaws before coding begins
- Reduce iteration cycles caused by poor specifications
- Leverage multiple AI models' different perspectives

**Constraints:**
- Additional API cost per evaluation (~$0.04-0.08)
- Adds process step before implementation
- Requires OpenAI API key

**Assumptions:**
- Different models catch different issues
- Claude excels at implementation, GPT-4o provides good critique
- Early design review saves implementation time

## Decision

Implement **adversarial evaluation** using GPT-4o to review task specifications before Claude implements them.

### Core Principles

1. **Separation of Concerns**: Claude implements, GPT-4o critiques
2. **Pre-Implementation Review**: Catch issues before coding starts
3. **Bounded Iteration**: Max 2-3 evaluation cycles per task
4. **Optional but Recommended**: System works without evaluation

### Implementation Details

**Evaluation Command:**
```bash
# For task files < 500 lines
adversarial evaluate delegation/tasks/active/TASK-0001.md

# For large files (auto-confirms)
echo y | adversarial evaluate delegation/tasks/active/TASK-0001.md
```

**Evaluation Output:**
```
.adversarial/logs/TASK-0001-PLAN-EVALUATION.md
```

**Verdict Types:**
- `APPROVED` - Ready for implementation
- `NEEDS_REVISION` - Issues found, revise specification
- `REJECTED` - Fundamental problems, rethink approach

**Directory Structure:**
```
.adversarial/
├── config/           # Evaluation configuration
├── docs/             # Workflow documentation
│   └── EVALUATION-WORKFLOW.md
└── logs/             # Evaluation results
    └── TASK-0001-PLAN-EVALUATION.md
```

**Integration with Agent Workflow:**
```markdown
## In feature-developer agent prompt:

### Evaluator Workflow (When You Need Design Clarification)

**When to Run Evaluation**:
- Ambiguous requirements in task spec
- Design decisions with multiple valid approaches
- Unclear acceptance criteria
- Potential breaking changes

**Iteration Limits**: Max 2-3 evaluations per task.
Escalate to user if contradictory feedback.
```

## Consequences

### Positive

- **Early Issue Detection**: Design flaws caught before implementation
- **Multi-Model Perspective**: Different AI models have different blind spots
- **Reduced Rework**: Better specs mean fewer implementation iterations
- **Documented Rationale**: Evaluation logs preserve design discussions
- **Quality Culture**: Encourages thorough specification writing

### Negative

- **Additional Cost**: ~$0.04-0.08 per evaluation
- **Process Overhead**: Extra step before implementation
- **API Dependency**: Requires OpenAI API key
- **Potential Contradiction**: GPT-4o and Claude may disagree

### Neutral

- **Optional Feature**: Works without evaluation (just less review)
- **External Tool**: Uses aider-chat as GPT-4o interface

## Alternatives Considered

### Alternative 1: Single-Model Self-Review

**Description**: Have Claude review its own specifications.

**Rejected because**:
- Same blind spots in generation and review
- No adversarial perspective
- Less likely to challenge own assumptions

### Alternative 2: Human-Only Review

**Description**: Require human review of all specifications.

**Rejected because**:
- Bottleneck on human availability
- Inconsistent review quality
- Slower iteration cycles

### Alternative 3: Multiple Claude Instances

**Description**: Use different Claude prompts for generation vs review.

**Rejected because**:
- Same underlying model, similar blind spots
- Less diversity of perspective
- True adversarial review benefits from different architecture

## Real-World Results

**Usage Pattern:**
- ~60% of tasks evaluated before implementation
- Average 1.3 evaluations per task
- ~15% of evaluations return NEEDS_REVISION

**Cost Analysis:**
- Average evaluation cost: $0.05
- Estimated rework savings: 30-60 minutes per caught issue
- ROI positive for complex tasks

**Example Catches:**
- Missing error handling requirements
- Overly complex solutions (simplified after feedback)
- Scope creep (features removed after evaluation)
- Missing test requirements

## Related Decisions

- ADR-1001: Multi-Agent Coordination Architecture
- ADR-1004: Pre-commit Hooks as Quality Gate

## References

- `.adversarial/docs/EVALUATION-WORKFLOW.md` - Complete workflow guide
- `.adversarial/config/` - Evaluation configuration
- [aider-chat](https://aider.chat/) - GPT-4o interface tool

## Revision History

- 2025-11-28: Initial decision (Accepted)

---

**Template Version**: 1.1.0
**Project**: Agentive Starter Kit / Audio Recording Manager
