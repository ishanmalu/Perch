import AppKit

/// Drag a window against a screen edge to tile it — left/right halves, top
/// to fill, corners to quarters. A translucent preview shows where it will
/// land before the mouse is released, and nothing happens if it isn't.
///
/// Built on a global mouse monitor plus Accessibility: on mouse-down we note
/// the window under the pointer; only if that window's *position* then changes
/// with its size unchanged is it being dragged (not resized, not a text
/// selection), and only then do edges count.
final class WindowSnapping {
    static let shared = WindowSnapping()

    enum Zone: Equatable {
        case left, right, top, topLeft, topRight, bottomLeft, bottomRight

        var pane: Pane {
            switch self {
            case .left: return Pane(0, 0, 0.5, 1)
            case .right: return Pane(0.5, 0, 0.5, 1)
            case .top: return Pane(0, 0, 1, 1)
            case .topLeft: return Pane(0, 0, 0.5, 0.5)
            case .topRight: return Pane(0.5, 0, 0.5, 0.5)
            case .bottomLeft: return Pane(0, 0.5, 0.5, 0.5)
            case .bottomRight: return Pane(0.5, 0.5, 0.5, 0.5)
            }
        }
    }

    /// Pure, self-tested. `point` and `screen` in AppKit coordinates
    /// (bottom-left origin). Corners win over edges within `corner` points.
    static func zone(for point: CGPoint, in screen: CGRect, edge: CGFloat = 4, corner: CGFloat? = nil) -> Zone? {
        // A corner is the outer eighth of each edge (at least 100 pt). Live
        // testing showed a fixed 40 pt band was too small to hit on purpose:
        // a drag to the top-left landed 43 pt down and snapped to a half.
        let corner = corner ?? max(100, min(screen.width, screen.height) / 8)
        let nearL = point.x <= screen.minX + edge, nearR = point.x >= screen.maxX - edge - 1
        let nearT = point.y >= screen.maxY - edge - 1, nearB = point.y <= screen.minY + edge
        let inTopBand = point.y >= screen.maxY - corner, inBottomBand = point.y <= screen.minY + corner
        let inLeftBand = point.x <= screen.minX + corner, inRightBand = point.x >= screen.maxX - corner
        if (nearL && inTopBand) || (nearT && inLeftBand) { return .topLeft }
        if (nearR && inTopBand) || (nearT && inRightBand) { return .topRight }
        if (nearL && inBottomBand) || (nearB && inLeftBand) { return .bottomLeft }
        if (nearR && inBottomBand) || (nearB && inRightBand) { return .bottomRight }
        if nearL { return .left }
        if nearR { return .right }
        if nearT { return .top }
        return nil
    }

    private var monitors: [Any] = []
    private var dragged: (win: AXWindow, start: CGRect)?
    private var moving = false
    private var current: (zone: Zone, screen: NSScreen)?
    private lazy var preview = SnapPreview()

    var isRunning: Bool { !monitors.isEmpty }

    func sync() { Prefs.shared.snapEnabled ? start() : stop() }

    func start() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.mouseDown()
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            self?.mouseDragged()
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            self?.mouseUp()
        }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        reset()
    }

    private func reset() {
        dragged = nil; moving = false; current = nil
        preview.hide()
    }

    private func mouseDown() {
        reset()
        guard AX.isTrusted(prompt: false) else { return }
        let p = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let axPoint = CGPoint(x: p.x, y: primaryHeight - p.y)
        // Cheap check first, from the window server: is this press in the
        // title-bar strip of a normal window? Only then ask Accessibility,
        // which is a round trip to the app and runs on every qualifying click.
        guard let hit = Screenshot.window(at: axPoint), axPoint.y - hit.frame.minY < 52,
              let win = Self.window(at: axPoint), let f = win.frame else { return }
        dragged = (win, f)
    }

    private func mouseDragged() {
        guard let d = dragged else { return }
        if !moving {
            guard let f = d.win.frame else { dragged = nil; return }
            let moved = abs(f.minX - d.start.minX) + abs(f.minY - d.start.minY) > 2
            let resized = abs(f.width - d.start.width) + abs(f.height - d.start.height) > 2
            if resized { dragged = nil; return }
            guard moved else { return }
            moving = true
        }
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }),
              let zone = Self.zone(for: p, in: screen.frame) else {
            if current != nil { current = nil; preview.hide() }
            return
        }
        if current?.zone != zone || current?.screen !== screen {
            current = (zone, screen)
            preview.show(WindowManager.shared.previewRect(for: zone.pane, on: screen))
        }
    }

    private func mouseUp() {
        defer { reset() }
        guard moving, let d = dragged, let c = current else { return }
        let win = d.win
        // Let the app finish its own drag before we move the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            WindowManager.shared.place(win, pane: c.zone.pane, on: c.screen)
        }
    }

    /// The window owning the element under an AX-space point.
    private static func window(at point: CGPoint) -> AXWindow? {
        let system = AXUIElementCreateSystemWide()
        // A hung app must never stall the main thread on a click.
        AXUIElementSetMessagingTimeout(system, 0.15)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        var node: AXUIElement? = element
        for _ in 0..<12 {
            guard let n = node else { break }
            if AX.string(n, kAXRoleAttribute) == kAXWindowRole {
                return AXWindow(element: n, pid: pid)
            }
            guard let parent = AX.copyValue(n, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = (parent as! AXUIElement)
        }
        return nil
    }
}

/// The translucent "it will land here" rectangle.
private final class SnapPreview {
    private var window: NSWindow?

    func show(_ rect: NSRect) {
        let w = window ?? make()
        let target = rect.insetBy(dx: 6, dy: 6)
        if !w.isVisible {
            w.setFrame(target, display: true)
            w.alphaValue = 0
            w.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            w.animator().setFrame(target, display: true)
            w.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let w = window, w.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            w.animator().alphaValue = 0
        }, completionHandler: { w.orderOut(nil) })
    }

    private func make() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.ignoresMouseEvents = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 2
        effect.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        effect.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        w.contentView = effect
        window = w
        return w
    }
}
