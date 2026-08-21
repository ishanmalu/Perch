import AppKit

/// A small self-dismissing HUD. Avoids UNUserNotificationCenter so Perch
/// needs no notification permission and works unsigned.
enum Notifier {
    private static var window: NSWindow?

    static func show(_ title: String, _ body: String? = nil, duration: TimeInterval = 3) {
        DispatchQueue.main.async { present(title, body, duration) }
    }

    private static func present(_ title: String, _ body: String?, _ duration: TimeInterval) {
        window?.close()

        let text = NSTextField(labelWithString: title)
        text.font = .systemFont(ofSize: 13, weight: .semibold)
        text.textColor = .labelColor
        text.alignment = .center

        let stack = NSStackView(views: [text])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        if let body {
            let sub = NSTextField(wrappingLabelWithString: body)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            sub.alignment = .center
            sub.preferredMaxLayoutWidth = 300
            stack.addArrangedSubview(sub)
        }

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        let size = stack.fittingSize
        effect.frame = CGRect(origin: .zero, size: CGSize(width: max(240, size.width), height: size.height))
        stack.frame = effect.bounds
        stack.autoresizingMask = [.width, .height]
        effect.addSubview(stack)

        let w = NSWindow(contentRect: effect.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = effect
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            w.setFrameOrigin(CGPoint(x: f.midX - effect.frame.width / 2, y: f.minY + 120))
        }
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            w.animator().alphaValue = 1
        }
        window = w

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard window === w else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                w.animator().alphaValue = 0
            }, completionHandler: {
                w.close()
                if window === w { window = nil }
            })
        }
    }
}
