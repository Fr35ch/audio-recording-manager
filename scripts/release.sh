#!/bin/bash

# =============================================================================
# Audio Recording Manager (ARM) - Release Script
# =============================================================================
# This script handles version bumping, changelog generation, and release creation.
#
# Usage:
#   ./scripts/release.sh patch    # 1.0.0 -> 1.0.1 (bug fixes)
#   ./scripts/release.sh minor    # 1.0.0 -> 1.1.0 (new features, backward compatible)
#   ./scripts/release.sh major    # 1.0.0 -> 2.0.0 (breaking changes)
#   ./scripts/release.sh --help   # Show usage information
#
# Options:
#   --dry-run     Show what would happen without making changes
#   --no-tag      Skip git tag creation
#   --no-commit   Skip git commit (implies --no-tag)
#   --github      Create GitHub release after tagging
#
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$PROJECT_ROOT/VERSION"
CHANGELOG_FILE="$PROJECT_ROOT/CHANGELOG.md"
INFO_PLIST="$PROJECT_ROOT/Info.plist"

# Flags
DRY_RUN=false
NO_TAG=false
NO_COMMIT=false
CREATE_GITHUB_RELEASE=false

# =============================================================================
# Helper Functions
# =============================================================================

print_usage() {
    echo -e "${BLUE}Audio Recording Manager (ARM) - Release Script${NC}"
    echo ""
    echo "Usage: $0 <patch|minor|major> [options]"
    echo ""
    echo "Version bump types:"
    echo "  patch   Bug fixes, no new features (1.0.0 -> 1.0.1)"
    echo "  minor   New features, backward compatible (1.0.0 -> 1.1.0)"
    echo "  major   Breaking changes (1.0.0 -> 2.0.0)"
    echo ""
    echo "Options:"
    echo "  --dry-run     Show what would happen without making changes"
    echo "  --no-tag      Skip git tag creation"
    echo "  --no-commit   Skip git commit (implies --no-tag)"
    echo "  --github      Create GitHub release after tagging"
    echo "  --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 patch                    # Bug fix release"
    echo "  $0 minor --github           # Feature release with GitHub release"
    echo "  $0 major --dry-run          # Preview major release"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get current version from VERSION file
get_current_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE" | tr -d '\n'
    else
        echo "0.0.0"
    fi
}

# Calculate new version based on bump type
calculate_new_version() {
    local current="$1"
    local bump_type="$2"

    local major=$(echo "$current" | cut -d. -f1)
    local minor=$(echo "$current" | cut -d. -f2)
    local patch=$(echo "$current" | cut -d. -f3)

    case "$bump_type" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
    esac

    echo "$major.$minor.$patch"
}

# Get the last git tag
get_last_tag() {
    git describe --tags --abbrev=0 2>/dev/null || echo ""
}

# Generate release notes from git commits
generate_release_notes() {
    local last_tag="$1"
    local new_version="$2"

    local date=$(date +%Y-%m-%d)
    local notes=""

    notes+="## [$new_version] - $date\n\n"

    # Get commits since last tag (or all commits if no tag)
    local commit_range=""
    if [ -n "$last_tag" ]; then
        commit_range="$last_tag..HEAD"
    fi

    # Categorize commits by conventional commit type
    local added=""
    local changed=""
    local fixed=""
    local removed=""
    local security=""
    local other=""

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        # Extract commit message (remove hash)
        local msg=$(echo "$line" | sed 's/^[a-f0-9]* //')

        # Categorize based on conventional commits or keywords
        if echo "$msg" | grep -qiE '^feat(\(|:)|add|implement'; then
            added+="- $msg\n"
        elif echo "$msg" | grep -qiE '^fix(\(|:)|bug|resolve'; then
            fixed+="- $msg\n"
        elif echo "$msg" | grep -qiE '^security|vuln|cve'; then
            security+="- $msg\n"
        elif echo "$msg" | grep -qiE '^remove|delete|deprecate'; then
            removed+="- $msg\n"
        elif echo "$msg" | grep -qiE '^refactor|change|update|improve'; then
            changed+="- $msg\n"
        else
            other+="- $msg\n"
        fi
    done < <(git log $commit_range --oneline --no-merges 2>/dev/null)

    # Build release notes
    if [ -n "$added" ]; then
        notes+="### Added\n$added\n"
    fi
    if [ -n "$changed" ]; then
        notes+="### Changed\n$changed\n"
    fi
    if [ -n "$fixed" ]; then
        notes+="### Fixed\n$fixed\n"
    fi
    if [ -n "$removed" ]; then
        notes+="### Removed\n$removed\n"
    fi
    if [ -n "$security" ]; then
        notes+="### Security\n$security\n"
    fi
    if [ -n "$other" ] && [ -z "$added$changed$fixed$removed$security" ]; then
        notes+="### Changes\n$other\n"
    fi

    echo -e "$notes"
}

# Update VERSION file
update_version_file() {
    local new_version="$1"

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would update VERSION to: $new_version"
    else
        echo "$new_version" > "$VERSION_FILE"
        log_success "Updated VERSION to: $new_version"
    fi
}

# Update Info.plist version strings
update_info_plist() {
    local new_version="$1"
    local build_number="$2"

    if [ ! -f "$INFO_PLIST" ]; then
        log_warning "Info.plist not found, skipping plist update"
        return
    fi

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would update Info.plist:"
        log_info "  CFBundleShortVersionString: $new_version"
        log_info "  CFBundleVersion: $build_number"
    else
        # Update CFBundleShortVersionString (display version)
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $new_version" "$INFO_PLIST"

        # Update CFBundleVersion (build number)
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$INFO_PLIST"

        log_success "Updated Info.plist versions"
    fi
}

# Update CHANGELOG.md with new release
update_changelog() {
    local release_notes="$1"

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would prepend to CHANGELOG.md:"
        echo -e "$release_notes"
        return
    fi

    # Create temp file with new content
    local temp_file=$(mktemp)

    # Write header
    echo "# Changelog" > "$temp_file"
    echo "" >> "$temp_file"
    echo "All notable changes to the Audio Recording Manager (ARM) will be documented in this file." >> "$temp_file"
    echo "" >> "$temp_file"
    echo "The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)," >> "$temp_file"
    echo "and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)." >> "$temp_file"
    echo "" >> "$temp_file"

    # Add new release notes
    echo -e "$release_notes" >> "$temp_file"
    echo "---" >> "$temp_file"
    echo "" >> "$temp_file"

    # Append existing content (skip header)
    tail -n +8 "$CHANGELOG_FILE" >> "$temp_file"

    # Replace original file
    mv "$temp_file" "$CHANGELOG_FILE"
    log_success "Updated CHANGELOG.md"
}

# Create git commit and tag
create_git_release() {
    local new_version="$1"

    if $NO_COMMIT; then
        log_info "Skipping git commit (--no-commit flag)"
        return
    fi

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would create git commit and tag:"
        log_info "  Commit: 'Release v$new_version'"
        log_info "  Tag: 'v$new_version'"
        return
    fi

    # Stage changed files
    git add "$VERSION_FILE" "$CHANGELOG_FILE" "$INFO_PLIST" 2>/dev/null || true

    # Create commit (skip pre-commit tests for release commits)
    SKIP_TESTS=1 git commit -m "Release v$new_version

- Bump version to $new_version
- Update CHANGELOG.md with release notes
- Update Info.plist version strings

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

    log_success "Created git commit"

    if $NO_TAG; then
        log_info "Skipping git tag (--no-tag flag)"
        return
    fi

    # Create annotated tag
    git tag -a "v$new_version" -m "Release v$new_version"
    log_success "Created git tag: v$new_version"
}

# Create GitHub release
create_github_release() {
    local new_version="$1"
    local release_notes="$2"

    if ! $CREATE_GITHUB_RELEASE; then
        return
    fi

    if ! command -v gh &> /dev/null; then
        log_warning "GitHub CLI (gh) not found, skipping GitHub release"
        log_info "Install with: brew install gh"
        return
    fi

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would create GitHub release: v$new_version"
        return
    fi

    # Create release notes file
    local notes_file=$(mktemp)
    echo -e "$release_notes" > "$notes_file"

    gh release create "v$new_version" \
        --title "v$new_version" \
        --notes-file "$notes_file"

    rm "$notes_file"
    log_success "Created GitHub release: v$new_version"
}

# =============================================================================
# Main Script
# =============================================================================

# Parse arguments
BUMP_TYPE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        patch|minor|major)
            BUMP_TYPE="$1"
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --no-tag)
            NO_TAG=true
            ;;
        --no-commit)
            NO_COMMIT=true
            NO_TAG=true
            ;;
        --github)
            CREATE_GITHUB_RELEASE=true
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
    shift
done

# Validate bump type
if [ -z "$BUMP_TYPE" ]; then
    log_error "Missing version bump type"
    print_usage
    exit 1
fi

# Change to project root
cd "$PROJECT_ROOT"

# Check for uncommitted changes (unless dry run)
if ! $DRY_RUN && ! $NO_COMMIT; then
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        log_warning "You have uncommitted changes. Consider committing them first."
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
fi

# Get versions
CURRENT_VERSION=$(get_current_version)
NEW_VERSION=$(calculate_new_version "$CURRENT_VERSION" "$BUMP_TYPE")
LAST_TAG=$(get_last_tag)

# Calculate build number (total commits + 1)
BUILD_NUMBER=$(( $(git rev-list --count HEAD 2>/dev/null || echo "0") + 1 ))

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Audio Recording Manager (ARM) - Release${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
log_info "Current version: $CURRENT_VERSION"
log_info "New version:     $NEW_VERSION ($BUMP_TYPE bump)"
log_info "Build number:    $BUILD_NUMBER"
log_info "Last tag:        ${LAST_TAG:-'(none)'}"
echo ""

if $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN MODE - No changes will be made]${NC}"
    echo ""
fi

# Generate release notes
log_info "Generating release notes..."
RELEASE_NOTES=$(generate_release_notes "$LAST_TAG" "$NEW_VERSION")

echo ""
echo -e "${BLUE}Release Notes Preview:${NC}"
echo "─────────────────────────────────────────────────────────────────"
echo -e "$RELEASE_NOTES"
echo "─────────────────────────────────────────────────────────────────"
echo ""

# Confirm release (unless dry run)
if ! $DRY_RUN; then
    read -p "Proceed with release? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Release cancelled"
        exit 0
    fi
fi

# Execute release steps
echo ""
log_info "Starting release process..."
echo ""

update_version_file "$NEW_VERSION"
update_info_plist "$NEW_VERSION" "$BUILD_NUMBER"
update_changelog "$RELEASE_NOTES"
create_git_release "$NEW_VERSION"
create_github_release "$NEW_VERSION" "$RELEASE_NOTES"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Release v$NEW_VERSION complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if ! $DRY_RUN && ! $NO_TAG; then
    log_info "Next steps:"
    echo "  1. Review the changes: git show"
    echo "  2. Push to remote:     git push && git push --tags"
    echo ""
    log_info "Once you push the tag, GitHub Actions will automatically:"
    echo "  - Build the app"
    echo "  - Run tests"
    echo "  - Create a GitHub Release with downloadable .app"
fi
