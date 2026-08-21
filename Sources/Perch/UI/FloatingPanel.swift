import AppKit
import SwiftUI

/// A borderless, key-capable panel used for the clipboard and window switcher.
final class FloatingPanel: NSPanel {
    init<Content: View>(size: CGSize, @ViewBuilder content: () -> Content) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                   backing: .buffered, defer: false)
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

        let host = NSHostingView(rootView: AnyView(content()))
        host.frame = CGRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]

        let container = NSVisualEffectView(frame: host.frame)
        container.material = .popover
        container.state = .active
        container.blendingMode = .behindWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.addSubview(host)
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func showCentered() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(CGPoint(x: f.midX - frame.width / 2,
                                   y: f.midY - frame.height / 2 + f.height * 0.08))
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}
