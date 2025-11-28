# ADR-1007: NAV Design System Integration

**Status**: Accepted

**Date**: 2025-11-28

**Deciders**: Fredrik Matheson, feature-developer agent

## Context

### Problem Statement

macOS apps need consistent visual design:
- SwiftUI defaults may not match organizational branding
- Ad-hoc color/spacing choices lead to inconsistency
- Accessibility requirements (contrast, sizing) need systematic approach
- Multiple developers need shared design vocabulary

### Forces at Play

**Technical Requirements:**
- Consistent colors across all UI components
- Predictable spacing scale
- Accessible contrast ratios
- Easy to apply and maintain

**Constraints:**
- Must work with SwiftUI
- Should be self-contained (no external dependencies)
- NAV (Norwegian Labour and Welfare Administration) branding context

**Assumptions:**
- Design tokens are more maintainable than ad-hoc values
- Centralized definitions prevent drift
- Semantic naming aids understanding

## Decision

Integrate **NAV Aksel design system** tokens as Swift constants:

### Implementation Details

**Color Definitions (NAVColors):**
```swift
struct NAVColors {
    // Primary
    static let blue500 = Color(hex: "#0067C5")
    static let blue400 = Color(hex: "#368FD8")
    static let blue600 = Color(hex: "#005AA4")

    // Semantic
    static let success = Color(hex: "#06893A")
    static let warning = Color(hex: "#FF9100")
    static let error = Color(hex: "#BA3A26")

    // Neutrals
    static let gray50 = Color(hex: "#F7F7F7")
    static let gray100 = Color(hex: "#E9E9E9")
    static let gray900 = Color(hex: "#262626")

    // Background
    static let surface = Color(hex: "#FFFFFF")
    static let surfaceSubtle = Color(hex: "#F7F7F7")
}
```

**Spacing Scale (NAVSpacing):**
```swift
struct NAVSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}
```

**Border Radius (NAVRadius):**
```swift
struct NAVRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let full: CGFloat = 9999
}
```

**Hex Color Extension:**
```swift
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b, a: UInt64
        switch hex.count {
        case 6: // RGB
            (r, g, b, a) = (int >> 16, int >> 8 & 0xFF, int & 0xFF, 255)
        case 8: // ARGB
            (r, g, b, a) = (int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF, int >> 24)
        default:
            (r, g, b, a) = (0, 0, 0, 255)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
```

**Usage in Components:**
```swift
struct RecordingCard: View {
    var body: some View {
        VStack(spacing: NAVSpacing.md) {
            Text(recording.title)
                .foregroundColor(NAVColors.gray900)

            StatusBadge(status: recording.status)
        }
        .padding(NAVSpacing.lg)
        .background(NAVColors.surface)
        .cornerRadius(NAVRadius.md)
    }
}
```

## Consequences

### Positive

- **Visual Consistency**: All components use same design tokens
- **Maintainability**: Change one value, update everywhere
- **Accessibility**: Tested contrast ratios in Aksel system
- **Semantic Naming**: `NAVColors.error` clearer than `Color.red`
- **No Dependencies**: Pure Swift, no external packages

### Negative

- **NAV Specific**: Branding may not suit all contexts
- **Manual Sync**: Tokens not auto-updated from Aksel source
- **Limited Scope**: Only colors, spacing, radius (not typography, icons)

### Neutral

- **SwiftUI Native**: Works with SwiftUI's color system
- **Extensible**: Easy to add more tokens as needed

## Alternatives Considered

### Alternative 1: SwiftUI Defaults

**Description**: Use SwiftUI's built-in colors and spacing.

**Rejected because**:
- Inconsistent with organizational branding
- No semantic naming
- Harder to maintain consistency

### Alternative 2: Full Aksel Package

**Description**: Import entire Aksel design system as dependency.

**Rejected because**:
- Aksel primarily targets web (React)
- Adds unnecessary dependency
- Overkill for macOS app needs

### Alternative 3: Custom Design System

**Description**: Create entirely custom design tokens.

**Rejected because**:
- Duplicates existing Aksel work
- Less tested for accessibility
- No established design language

## Real-World Results

**Application:**
- All UI components use NAV tokens
- Consistent look across app screens
- Easy to adjust branding if needed

**Maintenance:**
- Token updates are one-line changes
- No visual inconsistencies reported

## Related Decisions

- ADR-1006: Network Isolation as Default (UI indicators use NAV colors)

## References

- `Sources/AudioRecordingManager/main.swift` - NAVColors, NAVSpacing, NAVRadius definitions
- [Aksel Design System](https://aksel.nav.no/) - Source design system
- [NAV Aksel GitHub](https://github.com/navikt/aksel) - Reference implementation

## Revision History

- 2025-11-28: Initial decision (Accepted)

---

**Template Version**: 1.1.0
**Project**: Agentive Starter Kit / Audio Recording Manager
