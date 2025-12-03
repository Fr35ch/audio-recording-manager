# Versioning Guide

This document describes the versioning system for Audio Recording Manager (ARM).

## Semantic Versioning

We follow [Semantic Versioning 2.0.0](https://semver.org/):

```
MAJOR.MINOR.PATCH (e.g., 1.2.3)
```

### When to Bump Each Version

| Bump Type | When to Use | Example Changes |
|-----------|-------------|-----------------|
| **PATCH** | Bug fixes, no new features | Fix crash on startup, correct typo in UI, fix SD card detection |
| **MINOR** | New features, backward compatible | Add new export format, new menu item, UI improvements |
| **MAJOR** | Breaking changes | Change file format, remove features, major architecture change |

### Decision Guide

Ask yourself these questions:

1. **Does this break existing functionality?**
   - Yes → **MAJOR** bump
   - No → Continue to next question

2. **Does this add new features or capabilities?**
   - Yes → **MINOR** bump
   - No → Continue to next question

3. **Is this a bug fix, documentation update, or minor tweak?**
   - Yes → **PATCH** bump

## Version Files

The version is tracked in these locations:

| File | Purpose |
|------|---------|
| `VERSION` | Single source of truth for current version |
| `Info.plist` | macOS app bundle version (CFBundleShortVersionString) |
| `CHANGELOG.md` | Human-readable history of changes |

## Release Script

Use the automated release script to create new versions:

```bash
# Bug fix release (1.0.0 -> 1.0.1)
./scripts/release.sh patch

# Feature release (1.0.0 -> 1.1.0)
./scripts/release.sh minor

# Breaking change release (1.0.0 -> 2.0.0)
./scripts/release.sh major
```

### Script Options

```bash
./scripts/release.sh <patch|minor|major> [options]

Options:
  --dry-run     Preview changes without making them
  --no-tag      Skip git tag creation
  --no-commit   Skip git commit (implies --no-tag)
  --github      Create GitHub release after tagging
  --help        Show usage information
```

### What the Script Does

1. **Reads** current version from `VERSION` file
2. **Calculates** new version based on bump type
3. **Generates** release notes from git commits since last tag
4. **Updates** `VERSION` file with new version
5. **Updates** `Info.plist` version strings
6. **Updates** `CHANGELOG.md` with release notes
7. **Creates** git commit with all changes
8. **Creates** annotated git tag (e.g., `v1.2.3`)
9. **Optionally creates** GitHub release

### Example Workflow

```bash
# 1. Make sure all changes are committed
git status

# 2. Preview the release
./scripts/release.sh minor --dry-run

# 3. Create the release
./scripts/release.sh minor

# 4. Push to remote
git push && git push --tags

# 5. (Optional) Create GitHub release
./scripts/release.sh minor --github
```

## Changelog Format

We use [Keep a Changelog](https://keepachangelog.com/) format:

```markdown
## [1.2.0] - 2025-01-15

### Added
- New feature description

### Changed
- Changed behavior description

### Fixed
- Bug fix description

### Removed
- Removed feature description

### Security
- Security fix description
```

### Commit Message Guidelines

For best automatic categorization, use conventional commit prefixes:

| Prefix | Category |
|--------|----------|
| `feat:` or `add:` | Added |
| `fix:` or `bug:` | Fixed |
| `change:` or `update:` | Changed |
| `remove:` or `delete:` | Removed |
| `security:` | Security |

Examples:
```bash
git commit -m "feat: Add export to PDF functionality"
git commit -m "fix: Resolve crash when SD card is ejected"
git commit -m "update: Improve waveform visualization"
```

## Build Number

The build number (`CFBundleVersion` in Info.plist) is automatically calculated as the total number of git commits. This ensures:

- Build numbers always increase
- Each build is uniquely identifiable
- No manual tracking required

## Pre-release Versions

For pre-release versions, use suffixes:

```
1.0.0-alpha.1   # Alpha testing
1.0.0-beta.1    # Beta testing
1.0.0-rc.1      # Release candidate
```

Note: The release script doesn't currently support pre-release suffixes automatically. Add them manually to the VERSION file if needed.

## Version Display in App

To display the version in the app, read from Info.plist:

```swift
let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
print("Version \(version) (Build \(build))")
```

## Initial Setup

If starting fresh:

1. Create VERSION file: `echo "1.0.0" > VERSION`
2. Ensure Info.plist has version keys (already present)
3. Run first release: `./scripts/release.sh patch`
