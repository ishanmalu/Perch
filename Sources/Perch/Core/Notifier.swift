import AppKit

/// A small self-dismissing HUD, positioned above the Dock.
///
/// Deliberately not UNUserNotificationCenter: that needs a notification
/// permission and a registered bundle, neither of which an unsigned local
/// build reliably has.
enum Notifier {
    private static var window: NSWindow?
    private static var dismissWorkItem: DispatchWorkItem?

    static func show(_ title: String, _ body: String? = nil, duration: TimeInterval = 3) {
        DispatchQueue.main.async { present(title, body, duration) }
    }

    private static func present(_ title: String, _ body: String?, _ duration: TimeInterval) {
        dismissWorkItem?.cancel()
        window?.orderOut(nil)
        window?.close()
        window = nil

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [titleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let body, !body.isEmpty {
            let bodyLabel = NSTextField(wrappingLabelWithString: body)
            bodyLabel.font = .systemFont(ofSize: 11)
            bodyLabel.textColor = .secondaryLabelColor
            bodyLabel.alignment = .center
            bodyLabel.lineBreakMode = .byWordWrapping
            bodyLabel.maximumNumberOfLines = 3
            stack.addArrangedSubview(bodyLabel)
        }

        // Rounded corners need to be clipped by a plain layer-backed view; a
        // NSVisualEffectView masks its own material but not a border drawn on it,
        // which is what made the old HUD look unfinished at the edges.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 13
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(effect)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])

        let fitting = container.fittingSize
        let size = NSSize(width: max(260, ceil(fitting.width)), height: ceil(fitting.height))

        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        // ARC owns this window; without this AppKit would release it again on close.
        w.isReleasedWhenClosed = false
        w.contentView = container
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            w.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2,
                                     y: visible.minY + 90))
        }

        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 1
        }
        window = w

        let dismiss = DispatchWorkItem {
            guard window === w else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                w.animator().alphaValue = 0
            }, completionHandler: {
                w.orderOut(nil)
                w.close()
                if window === w { window = nil }
            })
        }
        dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismiss)
    }
}
