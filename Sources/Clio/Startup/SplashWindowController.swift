import AppKit
import SwiftUI

@MainActor
final class SplashWindowController {

    var window: NSWindow?
    var onDismiss: (() -> Void)?

    func show(coordinator: StartupCoordinator) {
        let w = makeWindow()
        let container = RoundedContainerView(frame: NSRect(x: 0, y: 0, width: 680, height: 420))

        let imageView = NSImageView(frame: container.bounds)
        if let url = Bundle.main.url(forResource: "SplashBackground", withExtension: "svg") {
            imageView.image = NSImage(contentsOf: url)
        } else {
            imageView.image = NSImage(named: "Splash")
        }
        imageView.imageScaling     = .scaleAxesIndependently
        imageView.imageAlignment   = .alignCenter
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)

        let host = NSHostingView(rootView:
            SplashView(coordinator: coordinator) { [weak self] in self?.dismiss() }
        )
        host.frame             = container.bounds
        host.autoresizingMask  = [.width, .height]
        container.addSubview(host)

        w.contentView = container
        w.center()
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { w.invalidateShadow() }
        window = w
    }

    func dismiss() {
        let win      = window
        let callback = onDismiss
        window    = nil
        onDismiss = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration       = 0.42
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win?.animator().alphaValue = 0
        }, completionHandler: {
            win?.orderOut(nil)
            callback?()
        })
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask:   [.borderless, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        w.isOpaque                    = false
        w.backgroundColor             = .clear
        w.hasShadow                   = true
        w.isMovableByWindowBackground = true
        w.level                       = .floating
        w.titlebarAppearsTransparent  = true
        w.titleVisibility             = .hidden
        w.animationBehavior           = .none   // fix 1 — disables macOS fade-in
        w.alphaValue                  = 1.0     // fix 1 — explicit full opacity
        w.isRestorable                = false   // fix 2 — prevents session restoration
        return w
    }
}

private final class RoundedContainerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer               = true
        layer?.cornerRadius      = 28
        layer?.cornerCurve       = .continuous
        layer?.masksToBounds     = true
        layer?.backgroundColor   = NSColor.black.cgColor
        autoresizingMask         = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError() }
}
