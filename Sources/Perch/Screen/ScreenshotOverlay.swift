import AppKit

/// The crosshair overlay you drag a selection in.
///
/// It covers every display, and after a capture it stays up so the next one is
/// another drag rather than another trip to the keyboard. Escape or a right
/// click ends it. A counter shows how many the run has taken, because the whole
/// point is losing count.
@MainActor
final class ScreenshotOverlay {
    static let shared = ScreenshotOverlay()

    private var windows: [SelectionWindow] = []
    private var monitor: Any?
    private var taken = 0
    private var busy = false

    var isOpen: Bool { !windows.isEmpty }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard !isOpen else { return }
        taken = 0
        for screen in NSScreen.screens {
            let w = SelectionWindow(screen: screen)
            w.onSelect = { [weak self] rect in self?.capture(rect) }
            w.onCancel = { [weak self] in self?.close() }
            w.orderFrontRegardless()
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()

        // Escape anywhere ends the run, not just on the window with focus.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.close()
            return nil
        }
        updateHint()
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if taken > 0 {
            Notifier.show(taken == 1 ? "1 screenshot saved" : "\(taken) screenshots saved",
                          Screenshot.saveFolder().path, duration: 3)
        }
        taken = 0
    }

    private func capture(_ rect: CGRect) {
        guard !busy else { return }
        busy = true
        let stayArmed = Prefs.shared.screenshotBurst
        // Hide the overlay for the grab, or it appears in its own screenshot.
        windows.forEach { $0.alphaValue = 0 }

        Task { @MainActor in
            // One runloop turn so the hidden overlay is off screen before the
            // capture, which reads the compositor's current frame.
            try? await Task.sleep(nanoseconds: 90_000_000)
            let image = await Screenshot.capture(rect: rect)
            if let image {
                Screenshot.deliver(image, to: .init(toFile: Prefs.shared.screenshotToFile,
                                                    toClipboard: Prefs.shared.screenshotToClipboard))
                taken += 1
            } else {
                Notifier.show("Nothing was captured",
                              "Perch needs Screen Recording access in System Settings.", duration: 4)
            }
            busy = false
            if stayArmed && isOpen {
                windows.forEach { $0.alphaValue = 1; $0.reset() }
                updateHint()
            } else {
                close()
            }
        }
    }

    private func updateHint() {
        let base = "Drag to capture  ·  Esc to finish"
        windows.forEach { $0.setHint(taken == 0 ? base : "\(taken) taken  ·  " + base) }
    }
}

/// One display's worth of overlay: a dimmed sheet with a clear selection.
private final class SelectionWindow: NSWindow {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private let view = SelectionView()

    override var canBecomeKey: Bool { true }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless,
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false          // AppKit would over-release it
        level = .init(Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        setFrame(screen.frame, display: true)
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        view.onSelect = { [weak self] local in
            guard let self else { return }
            // Local view coordinates are bottom-left; screen space is top-left.
            self.onSelect?(Screenshot.globalRect(
                local: local,
                windowFrame: self.frame,
                primaryMaxY: NSScreen.screens[0].frame.maxY))
        }
        view.onCancel = { [weak self] in self?.onCancel?() }
        contentView = view
    }

    func reset() { view.reset() }
    func setHint(_ text: String) { view.hint = text; view.needsDisplay = true }
}

private final class SelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var hint = ""
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    func reset() { start = nil; current = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { reset() }
        guard let rect = selection, rect.width >= 4, rect.height >= 4 else { return }
        onSelect?(rect)
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    private var selection: CGRect? {
        guard let a = start, let b = current else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        if let rect = selection, rect.width > 0, rect.height > 0 {
            // Punch the selection clear so what is being captured is visible.
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1
            path.stroke()
            drawLabel(String(format: "%.0f × %.0f", rect.width, rect.height),
                      at: NSPoint(x: rect.midX, y: rect.maxY + 14))
        } else if !hint.isEmpty {
            drawLabel(hint, at: NSPoint(x: bounds.midX, y: bounds.midY))
        }
    }

    private func drawLabel(_ text: String, at point: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let box = NSRect(x: point.x - size.width / 2 - 8, y: point.y - size.height / 2 - 4,
                         width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                  withAttributes: attrs)
    }
}
