import AppKit

/// A capture left floating above everything else.
///
/// The use is comparison: a number, a design, a log line you need while you
/// work somewhere else. Copying it into a note and switching back and forth is
/// the thing this removes.
@MainActor
final class PinnedShot {
    private static var open: [PinnedShot] = []

    private let window: NSWindow

    /// Puts `image` on screen near where it was taken, at its natural size,
    /// scaled down if it would not fit.
    @discardableResult
    static func show(_ image: CGImage, near rect: CGRect) -> PinnedShot {
        let pin = PinnedShot(image: image, near: rect)
        open.append(pin)
        return pin
    }

    static func closeAll() {
        open.forEach { $0.window.orderOut(nil) }
        open.removeAll()
    }

    static var count: Int { open.count }

    private init(image: CGImage, near rect: CGRect) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var size = NSSize(width: CGFloat(image.width) / scale,
                          height: CGFloat(image.height) / scale)
        // Never larger than the screen it lands on.
        if let visible = NSScreen.main?.visibleFrame {
            let fit = min(1, min(visible.width * 0.8 / size.width,
                                 visible.height * 0.8 / size.height))
            size = NSSize(width: size.width * fit, height: size.height * fit)
        }

        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true

        let view = PinView(image: NSImage(cgImage: image, size: size))
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        view.onClose = { [weak self] in self?.dismiss() }
        window.contentView = view

        // Sit where the capture was taken, converted back to AppKit's
        // bottom-left origin, nudged clear of the selection itself.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let origin = NSPoint(x: rect.minX + 12,
                             y: primaryMaxY - rect.maxY - size.height - 12)
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    private func dismiss() {
        window.orderOut(nil)
        Self.open.removeAll { $0 === self }
    }
}

/// Draws the shot with a close control that appears on hover.
private final class PinView: NSView {
    var onClose: (() -> Void)?
    private let image: NSImage
    private var hovering = false

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        if hovering, closeRect.contains(convert(event.locationInWindow, from: nil)) {
            onClose?()
            return
        }
        super.mouseDown(with: event)
    }

    /// Double-click copies it, which is why you pinned it.
    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        Notifier.show("Copied", "The pinned capture is on the clipboard.", duration: 2)
    }

    private var closeRect: NSRect {
        NSRect(x: bounds.maxX - 24, y: bounds.maxY - 24, width: 18, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        path.addClip()
        image.draw(in: bounds)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()

        guard hovering else { return }
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(ovalIn: closeRect).fill()
        let x = NSBezierPath()
        let r = closeRect.insetBy(dx: 5.5, dy: 5.5)
        x.move(to: NSPoint(x: r.minX, y: r.minY)); x.line(to: NSPoint(x: r.maxX, y: r.maxY))
        x.move(to: NSPoint(x: r.minX, y: r.maxY)); x.line(to: NSPoint(x: r.maxX, y: r.minY))
        NSColor.white.setStroke()
        x.lineWidth = 1.6
        x.stroke()
    }
}
