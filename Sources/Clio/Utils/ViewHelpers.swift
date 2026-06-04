import SwiftUI

// MARK: - Cursor Modifier
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.background(
            GeometryReader { geometry in
                CursorHostingView(cursor: cursor, frame: geometry.frame(in: .local))
            }
        )
    }

    func introspectSplitView(customize: @escaping (NSSplitView) -> Void) -> some View {
        self.background(
            SplitViewIntrospector(customize: customize)
        )
    }
}

// MARK: - SplitView Introspector
struct SplitViewIntrospector: NSViewRepresentable {
    let customize: (NSSplitView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let splitView = self.findSplitView(in: view) {
                self.customize(splitView)
                // Set delegate to prevent resizing
                splitView.delegate = context.coordinator
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func findSplitView(in view: NSView) -> NSSplitView? {
        var current: NSView? = view
        while let parent = current?.superview {
            if let splitView = parent as? NSSplitView {
                return splitView
            }
            current = parent
        }
        return nil
    }

    class Coordinator: NSObject, NSSplitViewDelegate {
        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            return false
        }

        func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
            return true
        }

        func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
            // Return zero rect to make divider non-interactive
            return .zero
        }
    }
}

struct CursorHostingView: NSViewRepresentable {
    let cursor: NSCursor
    let frame: CGRect

    func makeNSView(context: Context) -> CursorTrackingView {
        let view = CursorTrackingView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: CursorTrackingView, context: Context) {
        nsView.cursor = cursor
    }
}

class CursorTrackingView: NSView {
    var cursor: NSCursor = .arrow
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate,
        ]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }
}
