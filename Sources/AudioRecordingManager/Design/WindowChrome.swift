// WindowChrome.swift
// AudioRecordingManager
//
// ⚠️ DESIGN SURFACE — read `Design/README.md` before editing.
//
// Documents the canonical window-chrome decisions for the app so they
// can be understood, audited, and changed in ONE place rather than
// hunted across `main.swift`. SwiftUI's `WindowGroup` modifiers must
// actually live on the `Scene` builder in `VirginProjectApp.body`
// (they can't be packaged into a `ViewModifier`), so this file's role
// is mainly documentary — the canonical shape is reproduced here as
// a non-executing reference, and `VirginProjectApp.body` should match
// it byte-for-byte.
//
// Rules:
//   - Do not change chrome modifiers in `VirginProjectApp.body` without
//     also updating this file. The two must stay in sync.
//   - Do not add chrome workarounds (`Spacer(height: N)`,
//     `ignoresSafeArea(edges: .top)`, `toolbarBackground(.hidden)`)
//     inside `MainView` or tab bodies. SwiftUI's chrome pipeline (see
//     canonical shape below) handles it.
//   - Tab content views that need nav-chrome integration should use
//     `NavigationStack` or `NavigationSplitView`. Bare `VStack` / `HStack`
//     tab content will render without the window's unified chrome,
//     which is what produces the "flat" look on non-list tabs.

import SwiftUI

// MARK: - Canonical chrome shape (documentation, non-executing)

/// The canonical window-chrome configuration. Kept here so there is a
/// single, readable reference of WHY each modifier exists. The actual
/// modifiers are applied in `VirginProjectApp.body` (since SwiftUI
/// requires them on the `Scene`) — the two must stay in sync.
///
/// ```swift
/// WindowGroup {
///     ZStack {
///         MainView()
///         if !startupCoordinator.isComplete {
///             SplashView(coordinator: startupCoordinator)
///                 .zIndex(1000)
///                 .transition(.opacity)
///         }
///     }
///     // Invisible toolbar item triggers SwiftUI's unified chrome.
///     // Without this, `windowToolbarStyle(.unified(showsTitle:))`
///     // silently falls back to the plain title bar look.
///     .toolbar {
///         ToolbarItem(placement: .automatic) { EmptyView() }
///     }
/// }
/// // Hide the system-drawn title area so traffic lights float over
/// // the window's content. Required for the modern rounded look.
/// .windowStyle(.hiddenTitleBar)
/// // macOS 15+: unified toolbar without title text. This is what
/// // gives the Tahoe/Sequoia "airy" floating-traffic-lights chrome.
/// .windowToolbarStyle(.unified(showsTitle: false))
/// ```
///
/// If you need to change the chrome, change it in `VirginProjectApp.body`
/// AND update the comment block above so the next reader sees the
/// current truth.
enum WindowChromeReference {}

// MARK: - Tab chrome integration

/// ## The rounded-corner pipeline rule
///
/// On macOS Tahoe with `.windowStyle(.hiddenTitleBar) +
/// .windowToolbarStyle(.unified(showsTitle: false))`, SwiftUI's chrome
/// pipeline extends content to the window's **outer** rounded frame
/// ONLY for navigation-container views. Bare `VStack` / `ZStack` content
/// is clipped to the smaller safe-area inner rectangle, which has a
/// smaller rounded-corner radius — producing the "wrong radius" look
/// where the inner content's corners don't match the window frame.
///
/// `NavigationSplitView` is the container SwiftUI's unified-toolbar
/// chrome on Tahoe latches onto. `NavigationStack` is **not** — it does
/// not trigger the same outer-frame extension.
///
/// ### How to get bare content into the pipeline
///
/// Wrap the content in `NavigationSplitView(columnVisibility: .constant(.detailOnly))`
/// with an `EmptyView()` sidebar. That satisfies SwiftUI's "is this a
/// navigation container?" check without showing a visible sidebar. Add
/// `.toolbar(removing: .sidebarToggle)` to hide the default sidebar-toggle
/// button that `NavigationSplitView` would otherwise place in the toolbar.
///
/// ### Example
///
/// ```swift
/// NavigationSplitView(columnVisibility: .constant(.detailOnly)) {
///     EmptyView()
/// } detail: {
///     MyBareContentView()
///         .toolbar(removing: .sidebarToggle)
/// }
/// .navigationSplitViewStyle(.balanced)
/// ```
///
/// ### What NOT to try
///
/// Prior-session dead-ends that look tempting but don't solve this issue:
/// - `.ignoresSafeArea()` on an inner `Color` — only extends that layer,
///   not the clipping envelope.
/// - `NSWindow.fullSizeContentView`, `titlebarAppearsTransparent` —
///   affects title bar transparency, not the content-clip rectangle.
/// - `NavigationStack` wrap — wrong nav container for this pipeline.
/// - `.containerBackground(.thinMaterial, for: .window)` — paints a
///   material backdrop but doesn't change the clipping shape.
///
/// ### Where this rule applies in this codebase
///
/// - `Lydopptak` (`RecordingsNativeView`) and `Transkripsjoner`
///   (`TranscriptsView`) use `NavigationSplitView` natively — correct.
/// - `Ta opp lyd` (`RecordingView`) is bare content; wrapped at the
///   `MainView.body` callsite using the detail-only trick above.
/// - `SplashView` is bare content overlay; wrapped in its own body using
///   the detail-only trick above.
///
/// If you add a new tab or view that renders full-screen inside the
/// window, apply the same pattern or expect wrong corner radii.
struct TabContentChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Nothing today — reserved for future chrome additions so
            // every tab has a single, named place to apply them.
            // Example: a `.toolbar { ... }` block that all tabs share.
    }
}

// MARK: - Window sizing

/// Canonical minimum window size. Applied to `MainView`.
enum WindowSize {
    /// Below this width, the NavPanel + content layout becomes too
    /// cramped to be useful. Kept here so any future size change is
    /// done in one place.
    static let minWidth: CGFloat = 900
    /// Below this height, the list + detail split views don't have
    /// enough room to be useful.
    static let minHeight: CGFloat = 600
}
