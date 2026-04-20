# Design Surface — Protected Boundary

**This folder is the design boundary for Audio Recording Manager.**
Everything inside is a deliberate design decision. Outside this folder, the
rest of the app consumes design tokens and style modifiers; it does not
define new ones.

## Files

| File | Role |
|------|------|
| `DesignTokens.swift` | `AppColors`, `AppSpacing`, `AppRadius` — colours, spacing, radii |
| `GlassStyles.swift`  | `GlassButtonStyle`, `HoverButtonStyle`, `glassEffectIfAvailable` |
| `WindowChrome.swift` | Canonical window-chrome documentation + `TabContentChrome` modifier + `WindowSize` |

## Rules for editing

### 1. Do not "fix" layout by editing this folder

If the app looks off somewhere, it is more likely that a *callsite* is using
the wrong token, or is missing a chrome hook, than that a design token is
wrong. Start with the callsite. Change a token only when the design owner
has explicitly asked for it.

### 2. Do not add chrome workarounds outside this folder

The following patterns are **banned outside `Design/`** because they
historically fought the canonical chrome pipeline:

- `.ignoresSafeArea(edges: .top)` on the main view tree
- `Spacer().frame(height: 52)` as a manual title-bar inset
- `.toolbarBackground(.hidden, for: .windowToolbar)`
- `.navigationTitle("")` added solely to suppress chrome
- Direct `NSWindow` manipulation via `DispatchQueue.main.async` in
  `AppDelegate` (titlebarAppearsTransparent, fullSizeContentView, styleMask,
  titleVisibility)

These were all attempts to wrestle SwiftUI into a particular look. The
current chrome lets SwiftUI do its job via `.windowStyle(.hiddenTitleBar)`
and `.windowToolbarStyle(.unified(showsTitle: false))` on the `WindowGroup`,
plus a single invisible `.toolbar { }` item to trigger unified chrome.

### 3. `VirginProjectApp.body` chrome modifiers and `WindowChrome.swift` must stay in sync

SwiftUI requires the `.windowStyle()` and `.windowToolbarStyle()` modifiers
to be attached directly to the `Scene` in `VirginProjectApp.body`. They
can't be factored into a `ViewModifier`. So the actual modifiers live in
`main.swift`, but the canonical shape is documented in
`WindowChrome.swift`. If you change one, change the other.

### 4. Never hardcode

- A colour → use an `AppColors.*` value. If no token fits, add one here
  first, then use it.
- A padding or margin → use an `AppSpacing.*` value.
- A corner radius → use an `AppRadius.*` value.

### 5. Adding new tokens is cheap; renaming or removing is not

Adding `AppColors.newFoo = Color(...)` is safe — nothing depends on it yet.
Renaming or removing is a breaking change across the app; `grep` before
deleting.

## For future Claude sessions

If the user reports a UI regression, the fix is almost certainly **not** in
`Design/`. Start by reading `main.swift` and the view involved — look for
chrome workarounds the list in rule 2 says not to add. Remove them. The
canonical chrome in `VirginProjectApp.body` should carry the rendering.

Do not edit this folder speculatively. If you believe a token needs to
change, ask the user first. Reverting is always cheaper than re-guessing.
