import AppKit

/// The crosshair overlay you drag a selection in.
///
/// It covers every display, and after a capture it stays up so the next one is
/// another drag rather than another trip to the keyboard. Escape or a right
/// click ends it. A counter shows how many the run has taken, because the whole
/// point is losing count.
/// What the next capture does with what it grabs.
enum ShotMode: String {
    case image      // save and/or copy a picture
    case text       // read the words out of it instead
    case colour     // sample one pixel
    case pin        // save it and leave it floating

    var hint: String {
        switch self {
        case .image:  return "Drag to capture"
        case .text:   return "Drag to copy the text in it"
        case .colour: return "Click to sample a colour"
        case .pin:    return "Drag to capture and pin it"
        }
    }
}

@MainActor
final class ScreenshotOverlay {
    static let shared = ScreenshotOverlay()

    private var mode: ShotMode = .image
    private var windowPicking = false

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
            w.onClick = { [weak self] point in self?.clicked(at: point) }
            w.onCancel = { [weak self] in self?.close() }
            w.orderFrontRegardless()
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()

        // One key each, rather than modifiers: the overlay owns the keyboard
        // while it is up, and the hint line can then say what they are.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.close(); return nil }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "t": self.setMode(self.mode == .text ? .image : .text)
            case "c": self.setMode(self.mode == .colour ? .image : .colour)
            case "p": self.setMode(self.mode == .pin ? .image : .pin)
            case "w": self.windowPicking.toggle(); self.updateHint()
            case "f": self.captureWholeDisplay()
            case "d": self.captureAfterDelay()
            default: return event
            }
            return nil
        }
        updateHint()
    }

    /// A click, as opposed to a drag: picks a window, or samples a colour.
    private func clicked(at point: CGPoint) {
        if windowPicking {
            captureWindowUnderCursor()
        } else if mode == .colour {
            sampleColour(at: point)
        }
    }

    private func setMode(_ new: ShotMode) {
        mode = new
        windowPicking = false
        updateHint()
    }

    func close() {
        mode = .image
        windowPicking = false
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

    /// Counts down, then grabs the whole display. The only way to photograph
    /// a menu, a hover state, or anything else that closes the moment you
    /// reach for the mouse.
    private func captureAfterDelay() {
        guard !busy else { return }
        busy = true
        let seconds = 5
        windows.forEach { $0.alphaValue = 0 }
        Task { @MainActor in
            for remaining in stride(from: seconds, to: 0, by: -1) {
                Notifier.show("Capturing in \(remaining)…",
                              "Open the menu you want.", duration: 1)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard isOpen else { busy = false; return }
            }
            busy = false
            captureWholeDisplay()
        }
    }

    /// The whole display the pointer is on, without drawing a selection.
    private func captureWholeDisplay() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                        ?? NSScreen.main else { return }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let f = screen.frame
        capture(CGRect(x: f.minX, y: primaryMaxY - f.maxY, width: f.width, height: f.height))
    }

    /// Grabs the window under the pointer on its own, background excluded.
    private func captureWindowUnderCursor() {
        let mouse = NSEvent.mouseLocation
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: mouse.x, y: primaryMaxY - mouse.y)
        guard let hit = Screenshot.window(at: point) else {
            Notifier.show("No window there", "Point at a window and click again.", duration: 2)
            return
        }
        run { await Screenshot.captureWindow(id: hit.id) } placedAt: { hit.frame }
    }

    private func capture(_ rect: CGRect) {
        if mode == .colour {
            sampleColour(at: CGPoint(x: rect.midX, y: rect.midY))
            return
        }
        if windowPicking {
            captureWindowUnderCursor()
            return
        }
        run { await Screenshot.capture(rect: rect) } placedAt: { rect }
    }

    private func sampleColour(at point: CGPoint) {
        guard !busy else { return }
        busy = true
        windows.forEach { $0.alphaValue = 0 }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            if let colour = await Screenshot.colour(at: point) {
                let hex = Screenshot.hex(colour)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(hex, forType: .string)
                taken += 1
                Notifier.show(hex, "Copied to the clipboard.", duration: 3)
            } else {
                reportCaptureFailure()
            }
            finish()
        }
    }

    /// Shared tail for every mode: hide the overlay, grab, deliver, re-arm.
    private func run(_ grab: @escaping () async -> CGImage?,
                     placedAt where: @escaping () -> CGRect) {
        guard !busy else { return }
        busy = true
        let mode = self.mode
        // Hide the overlay for the grab, or it appears in its own screenshot.
        windows.forEach { $0.alphaValue = 0 }

        Task { @MainActor in
            // One runloop turn so the hidden overlay is off screen before the
            // capture, which reads the compositor's current frame.
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard let image = await grab() else {
                reportCaptureFailure()
                finish()
                return
            }

            switch mode {
            case .text:
                let text = Screenshot.recognizeText(in: image)
                if text.isEmpty {
                    Notifier.show("No text found", "Nothing legible in that selection.", duration: 3)
                } else {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    taken += 1
                    let first = text.split(separator: "\n").first.map(String.init) ?? ""
                    Notifier.show("Text copied", first, duration: 3)
                }
            case .image, .pin:
                Screenshot.deliver(image, to: .init(toFile: Prefs.shared.screenshotToFile,
                                                    toClipboard: Prefs.shared.screenshotToClipboard))
                if mode == .pin { PinnedShot.show(image, near: `where`()) }
                taken += 1
            case .colour:
                break   // handled before we get here
            }
            finish()
        }
    }

    private func reportCaptureFailure() {
        Notifier.show("Nothing was captured",
                      "Perch needs Screen Recording access in System Settings.", duration: 4)
    }

    /// Re-arms for another, or ends the run.
    private func finish() {
        busy = false
        if Prefs.shared.screenshotBurst && isOpen {
            windows.forEach { $0.alphaValue = 1; $0.reset() }
            updateHint()
        } else {
            close()
        }
    }

    private func updateHint() {
        let action = windowPicking ? "Click a window" : mode.hint
        let keys = "W window · F display · D delayed · T text · C colour · P pin · Esc done"
        let count = taken == 0 ? "" : "\(taken) taken  ·  "
        windows.forEach { $0.setHint(count + action + "\n" + keys) }
    }
}

/// One display's worth of overlay: a dimmed sheet with a clear selection.
private final class SelectionWindow: NSWindow {
    var onSelect: ((CGRect) -> Void)?
    var onClick: ((CGPoint) -> Void)?
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
        view.onClick = { [weak self] local in
            guard let self else { return }
            let r = Screenshot.globalRect(
                local: CGRect(origin: local, size: .zero),
                windowFrame: self.frame,
                primaryMaxY: NSScreen.screens[0].frame.maxY)
            self.onClick?(CGPoint(x: r.minX, y: r.minY))
        }
        view.onCancel = { [weak self] in self?.onCancel?() }
        contentView = view
    }

    func reset() { view.reset() }
    func setHint(_ text: String) { view.hint = text; view.needsDisplay = true }
}

private final class SelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onClick: ((NSPoint) -> Void)?
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
        guard let rect = selection else { return }
        // A drag is a selection; anything smaller is a click, which window
        // picking and the eyedropper both need.
        if rect.width >= 4, rect.height >= 4 {
            onSelect?(rect)
        } else {
            onClick?(convert(event.locationInWindow, from: nil))
        }
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
