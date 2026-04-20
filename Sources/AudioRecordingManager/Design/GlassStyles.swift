// GlassStyles.swift
// AudioRecordingManager
//
// ⚠️ DESIGN SURFACE — read `Design/README.md` before editing.
//
// Liquid-Glass button styles and related view modifiers. Everything here
// is composable across the app; callers should not re-invent equivalent
// styles inline.
//
// Rules:
//   - If a style decision changes (e.g. change in material, corner radius,
//     hover behaviour), change it here so every caller updates together.
//   - `glassEffect` is a macOS 26+ API. Every usage must be wrapped in a
//     `#available(macOS 26.0, *)` check (see `glassEffectIfAvailable`).
//     macOS 14/15 fall back to the plain material.

import SwiftUI
import AppKit

// MARK: - Glass effect helper

extension View {
    /// Applies Liquid Glass on macOS 26+; no-op on earlier versions.
    /// Always use this instead of calling `glassEffect` directly so
    /// compile-time-availability is handled once, here.
    @ViewBuilder
    func glassEffectIfAvailable(in shape: RoundedRectangle) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
        }
    }
}

// MARK: - GlassButtonStyle

/// Primary button style: rounded material background with Liquid Glass
/// hover/press states on macOS 26+. Hover changes the cursor to the
/// pointing hand so the element reads as clickable.
struct GlassButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.lg)
            .background {
                if isHovering || configuration.isPressed {
                    if #available(macOS 26.0, *) {
                        RoundedRectangle(cornerRadius: AppRadius.medium)
                            .fill(.thinMaterial)
                            .glassEffect(.regular.tint(.blue).interactive(), in: .rect(cornerRadius: AppRadius.medium))
                    } else {
                        RoundedRectangle(cornerRadius: AppRadius.medium)
                            .fill(.thinMaterial)
                    }
                } else {
                    if #available(macOS 26.0, *) {
                        RoundedRectangle(cornerRadius: AppRadius.medium)
                            .fill(.ultraThinMaterial)
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: AppRadius.medium))
                    } else {
                        RoundedRectangle(cornerRadius: AppRadius.medium)
                            .fill(.ultraThinMaterial)
                    }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    DispatchQueue.main.async { NSCursor.pointingHand.set() }
                case .ended:
                    isHovering = false
                    DispatchQueue.main.async { NSCursor.arrow.set() }
                }
            }
    }
}

// MARK: - HoverButtonStyle

/// Minimal button style: transparent until hover, then a subtle
/// ultra-thin-material fill. Use for list-row buttons and secondary
/// affordances where the primary `GlassButtonStyle` would be too loud.
struct HoverButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if isHovering {
                    RoundedRectangle(cornerRadius: AppRadius.small)
                        .fill(.ultraThinMaterial)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    DispatchQueue.main.async { NSCursor.pointingHand.set() }
                case .ended:
                    isHovering = false
                    DispatchQueue.main.async { NSCursor.arrow.set() }
                }
            }
    }
}
