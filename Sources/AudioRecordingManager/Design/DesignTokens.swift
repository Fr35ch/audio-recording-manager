// DesignTokens.swift
// AudioRecordingManager
//
// ⚠️ DESIGN SURFACE — read `Design/README.md` before editing.
//
// Canonical design tokens: colors, spacing, corner radii. These are the
// numeric and colour values the rest of the app composes UIs from.
//
// Rules:
//   - Values here are deliberate. Don't tweak them to "fix" a layout that
//     looks off somewhere — either the layout is using the wrong token,
//     or the design system itself needs updating with the design owner.
//   - Never hardcode a colour or spacing value elsewhere in the app.
//     Always reference `AppColors.*`, `AppSpacing.*`, or `AppRadius.*`.
//   - Adding new tokens is fine; renaming or removing existing ones is a
//     breaking change — grep before deleting.

import SwiftUI

// MARK: - AppColors

/// Modern Liquid Glass colour palette, driven by system colours so the
/// app tracks light/dark appearance automatically.
struct AppColors {
    // Brand accent
    static let accent = Color.blue
    static let accentSubtle = Color.blue.opacity(0.2)

    // Status
    static let destructive = Color.red
    static let success = Color.green
    static let warning = Color.orange
}

// MARK: - AppSpacing

/// Spacing scale used throughout the app. Always prefer one of these over
/// a hard-coded padding value; if a specific place wants a bespoke
/// spacing, that's a signal the scale needs a new step, not that the
/// callsite should invent its own.
struct AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - AppRadius

/// Corner radius scale. Window-level radius is handled by macOS itself
/// (via `.windowStyle(.hiddenTitleBar)` on the `WindowGroup`), so these
/// are for inner elements: buttons, dialog backgrounds, card insets.
struct AppRadius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 8
    static let large: CGFloat = 10
    static let xlarge: CGFloat = 12
}
