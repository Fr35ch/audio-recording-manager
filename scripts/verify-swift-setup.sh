#!/bin/bash
# Pre-flight verification for Swift TDD infrastructure setup
# Usage: ./scripts/verify-swift-setup.sh

echo "🔍 Verifying Swift prerequisites..."
echo

ERRORS=0
WARNINGS=0

# Check Xcode or Swift toolchain
echo "Checking Xcode/Swift toolchain..."
if xcodebuild -version 2>/dev/null; then
    echo "✅ Full Xcode detected"
elif swift --version 2>/dev/null; then
    echo "✅ Swift toolchain detected (Command Line Tools)"
    echo "   Note: Using Swift Package Manager workflow (no Xcode project)"
else
    echo "❌ No Swift toolchain found"
    echo "   Install Xcode from: https://developer.apple.com/xcode/"
    echo "   Or install Command Line Tools: xcode-select --install"
    ERRORS=$((ERRORS + 1))
fi

# Check Swift version
echo
echo "Checking Swift version..."
if swift --version 2>/dev/null | grep -qE "Swift version [5-9]"; then
    echo "✅ Swift 5+ detected: $(swift --version 2>&1 | head -1)"
else
    echo "❌ Swift 5+ required"
    ERRORS=$((ERRORS + 1))
fi

# Check git configuration
echo
echo "Checking git configuration..."
if git config user.name > /dev/null 2>&1 && git config user.email > /dev/null 2>&1; then
    echo "✅ Git configured ($(git config user.name) <$(git config user.email)>)"
else
    echo "❌ Git not configured"
    echo "   Run: git config --global user.name \"Your Name\""
    echo "   Run: git config --global user.email \"you@example.com\""
    ERRORS=$((ERRORS + 1))
fi

# Check for Python (for pre-commit)
echo
echo "Checking Python (for pre-commit)..."
if python3 --version 2>/dev/null; then
    echo "✅ Python 3 detected: $(python3 --version 2>&1)"
else
    echo "❌ Python 3 required for pre-commit"
    ERRORS=$((ERRORS + 1))
fi

# Check for pre-commit
echo
echo "Checking pre-commit..."
if command -v pre-commit &> /dev/null; then
    echo "✅ pre-commit installed: $(pre-commit --version 2>&1)"
else
    echo "⚠️  pre-commit not installed"
    echo "   Run: pip3 install pre-commit"
    WARNINGS=$((WARNINGS + 1))
fi

# Verify project structure
echo
echo "Checking project structure..."
for item in "README.md" ".agent-context" "Sources/AudioRecordingManager"; do
    if [ -e "$item" ]; then
        echo "✅ $item exists"
    else
        echo "❌ $item not found"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check Swift source files
echo
echo "Checking Swift source files..."
if [ -f "Sources/AudioRecordingManager/main.swift" ]; then
    echo "✅ main.swift exists"
else
    echo "❌ main.swift not found"
    ERRORS=$((ERRORS + 1))
fi

if [ -f "Sources/AudioRecordingManager/SVGImageView.swift" ]; then
    echo "✅ SVGImageView.swift exists"
else
    echo "⚠️  SVGImageView.swift not found (optional)"
    WARNINGS=$((WARNINGS + 1))
fi

# Check existing build script
echo
echo "Checking build tooling..."
if [ -f "build.sh" ]; then
    echo "✅ build.sh exists"
else
    echo "⚠️  build.sh not found"
    WARNINGS=$((WARNINGS + 1))
fi

# Check SwiftLint (optional but recommended)
echo
echo "Checking SwiftLint..."
if command -v swiftlint &> /dev/null; then
    echo "✅ SwiftLint installed: $(swiftlint version 2>&1)"
else
    echo "⚠️  SwiftLint not installed (recommended)"
    echo "   Run: brew install swiftlint"
    WARNINGS=$((WARNINGS + 1))
fi

# Check for existing pre-commit config
echo
echo "Checking existing assets..."
if [ -f ".pre-commit-config.yaml" ]; then
    echo "✅ .pre-commit-config.yaml exists"
else
    echo "⚠️  .pre-commit-config.yaml missing"
    WARNINGS=$((WARNINGS + 1))
fi

# Check gh CLI (optional)
echo
echo "Checking GitHub CLI (gh)..."
if command -v gh &> /dev/null; then
    if gh auth status &> /dev/null 2>&1; then
        echo "✅ gh CLI installed and authenticated"
    else
        echo "⚠️  gh CLI installed but not authenticated"
        echo "   Run: gh auth login"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo "⚠️  gh CLI not installed (optional, needed for CI checks)"
    WARNINGS=$((WARNINGS + 1))
fi

# Summary
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo "✅ All prerequisites met! Ready to proceed with TDD infrastructure setup."
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo "⚠️  Prerequisites mostly met ($WARNINGS warnings)"
    echo "   You can proceed, but consider addressing warnings."
    exit 0
else
    echo "❌ $ERRORS prerequisite(s) failed, $WARNINGS warning(s)."
    echo "   Fix errors before proceeding."
    exit 1
fi
