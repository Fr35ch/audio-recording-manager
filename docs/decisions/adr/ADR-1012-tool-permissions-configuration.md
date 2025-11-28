# ADR-1012: Tool Permissions Configuration

**Status**: Accepted

**Date**: 2025-11-28

**Deciders**: Fredrik Matheson, planner agent

## Context

### Problem Statement

AI agents need tool access to be productive, but unrestricted access creates risks:
- Agents might execute dangerous commands
- Subagents inherit permissions from parent
- No visibility into what tools agents can use
- Security requires explicit capability boundaries

### Forces at Play

**Technical Requirements:**
- Agents need Bash, file operations, web access
- Subagents (via Task tool) need appropriate permissions
- Security-sensitive operations should be explicit
- Permissions should be auditable

**Constraints:**
- Claude Code uses settings.local.json for permissions
- Permissions are grant-based (allow list)
- Pattern matching for Bash commands

**Assumptions:**
- Explicit permissions safer than implicit
- Pattern-based allows flexibility with safety
- Subagents should inherit parent permissions

## Decision

Configure **explicit tool permissions** in `.claude/settings.local.json`:

### Implementation Details

**Settings Structure:**
```json
{
  "permissions": {
    "allow": [
      // Bash commands with patterns
      "Bash(git add:*)",
      "Bash(git commit:*)",
      "Bash(git push:*)",
      "Bash(swift build:*)",
      "Bash(swift test:*)",
      "Bash(pytest:*)",
      "Bash(./build.sh)",

      // MCP tools
      "mcp__serena__activate_project",
      "mcp__serena__find_symbol",
      "mcp__serena__read_file",
      "mcp__serena__replace_content",

      // File operations (implicit but can be explicit)
      "Read",
      "Edit",
      "Write",
      "Glob",
      "Grep"
    ],
    "deny": []
  }
}
```

**Pattern Syntax:**
```
Bash(command:*)     - Allow command with any arguments
Bash(command)       - Allow command with no arguments
Bash(path/script)   - Allow specific script execution
```

**Permission Categories:**

1. **Version Control:**
```json
"Bash(git add:*)",
"Bash(git commit:*)",
"Bash(git push:*)",
"Bash(git status)",
"Bash(git diff:*)",
"Bash(gh run list:*)",
"Bash(gh run view:*)"
```

2. **Build/Test:**
```json
"Bash(swift build:*)",
"Bash(swift test:*)",
"Bash(pytest:*)",
"Bash(./build.sh)",
"Bash(pre-commit run:*)"
```

3. **Serena MCP:**
```json
"mcp__serena__activate_project",
"mcp__serena__find_symbol",
"mcp__serena__get_symbols_overview",
"mcp__serena__read_file",
"mcp__serena__replace_content",
"mcp__serena__list_dir"
```

4. **Development Utilities:**
```json
"Bash(curl:*)",
"Bash(python3:*)",
"Bash(pip3 install:*)",
"Bash(open:*)"
```

**Subagent Inheritance:**
When an agent uses the Task tool to launch a subagent, the subagent inherits the permissions from settings.local.json. This ensures consistent capability boundaries.

## Consequences

### Positive

- **Explicit Security**: Only allowed operations can execute
- **Auditable**: Permission list is version-controlled
- **Pattern Flexibility**: Wildcards allow useful variations
- **Subagent Safety**: Spawned agents have same boundaries
- **Documentation**: Settings file documents capabilities

### Negative

- **Maintenance Burden**: New tools need permission additions
- **Permission Errors**: Missing permissions cause failures
- **Learning Curve**: Must understand pattern syntax
- **No Per-Agent Permissions**: All agents share same config

### Neutral

- **Deny List Empty**: Currently allow-only model
- **MCP Tools**: Explicit MCP server tool permissions

## Alternatives Considered

### Alternative 1: No Explicit Permissions

**Description**: Allow all tools by default.

**Rejected because**:
- Security risk from unrestricted access
- No visibility into agent capabilities
- Accidents more likely

### Alternative 2: Per-Agent Permissions

**Description**: Different permissions for each agent type.

**Rejected because**:
- Claude Code doesn't support per-agent configs
- Adds complexity
- Most agents need similar capabilities

### Alternative 3: Runtime Permission Prompts

**Description**: Ask user approval for each tool use.

**Rejected because**:
- Interrupts agent workflow
- Slow for repetitive operations
- Pre-approved list more efficient

## Real-World Results

**Permission Count:**
- ~45 explicit permissions configured
- Covers all common development operations

**Common Issues:**
- Occasionally need to add new tool patterns
- MCP tools require explicit naming

**Security Benefit:**
- Clear record of agent capabilities
- Easy to audit what agents can do

## Related Decisions

- ADR-1001: Multi-Agent Coordination Architecture
- ADR-1011: Task-Based Agent Handoff Protocol

## References

- `.claude/settings.local.json` - Permission configuration
- `.agent-context/OPERATIONAL-RULES.md` - Agent operational guidelines
- Claude Code documentation on permissions

## Revision History

- 2025-11-28: Initial decision (Accepted)

---

**Template Version**: 1.1.0
**Project**: Agentive Starter Kit / Audio Recording Manager
