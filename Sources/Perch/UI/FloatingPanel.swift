import AppKit
import SwiftUI

/// A borderless, key-capable panel used for the clipboard and window switcher.
final class FloatingPanel: NSPanel {
    convenience init<Content: View>(size: CGSize, @ViewBuilder content: () -> Content) {
        let host = NSHostingView(rootView: AnyView(content()))
        host.frame = CGRect(origin: .zero, size: size)
        self.init(size: size, hosting: host)
    }

    /// Designated path — takes an already-built view so callers can hand over
    /// an NSHostingController and keep its state.
    init(size: CGSize, hosting view: NSView) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   // Not .nonactivatingPanel: these panels are keyboard-driven,
                   // and a non-activating panel does not reliably become key, so
                   // Escape and type-to-filter would leak to the app underneath.
                   styleMask: [.fullSizeContentView, .borderless],
                   backing: .buffered, defer: false)
        // ARC owns this panel; without this AppKit would release it again on close.
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        view.frame = CGRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]

        let container = NSVisualEffectView(frame: view.frame)
        container.material = .popover
        container.state = .active
        container.blendingMode = .behindWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        container.addSubview(view)
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Anchors under the top-right corner, where the menu bar item would be,
    /// shrinking and clamping so the panel is always fully on screen.
    func showTopTrailing() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let width = min(frame.width, f.width - 24)
            let height = min(frame.height, f.height - 24)
            let x = max(f.minX + 12, f.maxX - width - 12)
            let y = max(f.minY + 12, f.maxY - height - 6)
            setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
        }
        present()
    }

    func showCentered() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(CGPoint(x: f.midX - frame.width / 2,
                                   y: f.midY - frame.height / 2 + f.height * 0.08))
        }
        present()
    }

    /// Brings the panel up and makes sure it actually owns the keyboard.
    ///
    /// Calling `makeKeyAndOrderFront` straight after `activate` is not enough
    /// from an accessory app: activation has not finished, so the panel appears
    /// but is not key and every keystroke goes to whatever was in front. That
    /// left the clipboard's ⌘1-9, the switcher's type-to-filter and Escape all
    /// dead until the panel was clicked. Re-asserting key status on the next
    /// runloop pass, and once more shortly after, makes it stick.
    private func present() {
        orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)

        for delay in [0.0, 0.05, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isVisible, !self.isKeyWindow else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.makeKey()
            }
        }
    }
}
