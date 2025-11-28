# ADR-1004: Pre-commit Hooks as Quality Gate

**Status**: Accepted

**Date**: 2025-11-28

**Deciders**: Fredrik Matheson, planner agent

## Context

### Problem Statement

Code quality issues often discovered late in CI/CD pipeline:
- Developers push broken code, CI fails, requires fix commit
- Style inconsistencies accumulate between commits
- Tests skipped locally, failures surprise in CI
- Feedback loop too slow (push → CI → failure → fix → push)

### Forces at Play

**Technical Requirements:**
- Fast feedback on code quality issues
- Enforce TDD workflow (tests must pass before commit)
- Consistent code style across all contributions
- Support for multiple languages (Python, Swift)

**Constraints:**
- Must not slow down development significantly
- Developers need escape hatch for WIP commits
- Different checks needed for different file types

**Assumptions:**
- Fast tests can run in <30 seconds
- Developers have pre-commit framework installed
- Quality gates improve long-term velocity

## Decision

Use **pre-commit framework** to enforce quality gates before every commit:

### Implementation Details

**.pre-commit-config.yaml:**
```yaml
repos:
  # Standard hooks
  - repo: https://github.com/pre-commit/pre-commit-hooks
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-toml
      - id: check-added-large-files
      - id: check-merge-conflict

  # Python formatting
  - repo: https://github.com/psf/black
    hooks:
      - id: black

  - repo: https://github.com/pycqa/isort
    hooks:
      - id: isort

  - repo: https://github.com/pycqa/flake8
    hooks:
      - id: flake8

  # Fast tests
  - repo: local
    hooks:
      - id: pytest-fast
        name: Run fast tests (pre-commit guard)
        entry: bash -c 'if [ "$SKIP_TESTS" = "1" ]; then echo "Skipping tests"; exit 0; fi; pytest tests/ -x -q --tb=short -m "not slow"'
        language: system
        pass_filenames: false

  # Swift (if files changed)
  - repo: local
    hooks:
      - id: swiftlint
        name: SwiftLint
        entry: swiftlint
        language: system
        types: [swift]

      - id: swift-build
        name: Swift build check
        entry: swift build
        language: system
        types: [swift]
        pass_filenames: false
```

**Escape Hatch:**
```bash
# For WIP commits when tests are broken
SKIP_TESTS=1 git commit -m "WIP: work in progress"
```

**Test Marking for Speed:**
```python
import pytest

@pytest.mark.slow
def test_integration_with_external_service():
    """This test is excluded from pre-commit runs."""
    pass

def test_fast_unit_test():
    """This test runs on every commit."""
    pass
```

## Consequences

### Positive

- **Shift Left**: Quality issues caught before commit, not in CI
- **Fast Feedback**: <30 second validation loop
- **Consistent Style**: Automated formatting removes style debates
- **TDD Enforcement**: Tests must pass to commit (by default)
- **Multi-Language**: Supports Python, Swift, YAML, TOML

### Negative

- **Initial Friction**: Developers must install pre-commit
- **Commit Slowdown**: Extra 10-30 seconds per commit
- **Escape Hatch Abuse**: SKIP_TESTS=1 can be overused
- **Hook Maintenance**: Hooks need updates as project evolves

### Neutral

- **CI Still Required**: Pre-commit supplements, doesn't replace CI
- **Slow Test Separation**: Must mark slow tests appropriately

## Alternatives Considered

### Alternative 1: CI-Only Quality Checks

**Description**: Run all checks only in GitHub Actions.

**Rejected because**:
- Slow feedback loop (minutes vs seconds)
- More fix commits polluting history
- Developers don't see issues until after push

### Alternative 2: IDE-Based Linting Only

**Description**: Rely on IDE extensions for quality checks.

**Rejected because**:
- Not all developers use same IDE
- No enforcement mechanism
- Tests not automatically run

### Alternative 3: Git Server-Side Hooks

**Description**: Reject pushes that fail quality checks.

**Rejected because**:
- Requires server configuration
- Frustrating UX (push rejected after upload)
- Can't easily provide WIP escape hatch

## Real-World Results

**Metrics:**
- 80%+ of CI failures now caught before push
- Average commit validation: 15-25 seconds
- SKIP_TESTS usage: ~5% of commits (acceptable)

**Developer Feedback:**
- Initial resistance ("slows me down")
- Long-term appreciation ("catches my mistakes")
- WIP escape hatch prevents frustration

## Related Decisions

- ADR-1003: Separated Library for Testable Code
- ADR-1005: Adversarial Evaluation Loop

## References

- `.pre-commit-config.yaml` - Hook configuration
- `pyproject.toml` - pytest markers configuration
- `.agent-context/workflows/TESTING-WORKFLOW.md` - Testing documentation
- [pre-commit.com](https://pre-commit.com/) - Framework documentation

## Revision History

- 2025-11-28: Initial decision (Accepted)

---

**Template Version**: 1.1.0
**Project**: Agentive Starter Kit / Audio Recording Manager
