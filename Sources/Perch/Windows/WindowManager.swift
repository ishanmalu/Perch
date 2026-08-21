import AppKit

/// Places windows using the Accessibility API.
///
/// AX works in a top-left-origin space anchored to the primary display, while
/// NSScreen is bottom-left-origin, so every rect crosses `axFrame` on the way out.
final class WindowManager {
    static let shared = WindowManager()

    /// Whichever app was frontmost when the Perch panel opened. Panel-driven
    /// actions target this rather than Perch itself.
    var panelTargetPID: pid_t?

    private var lastAction: (action: WindowAction, at: Date, step: Int)?
    /// Frames captured just before we first moved a window, so ⌥⌃⌫ can undo.
    private var originalFrames: [String: CGRect] = [:]

    // MARK: - Screen geometry

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// A screen's usable area in AX coordinates, inset by the configured gap.
    private func axFrame(of screen: NSScreen) -> CGRect {
        let v = screen.visibleFrame
        let gap = CGFloat(Prefs.shared.windowGap)
        return CGRect(x: v.minX + gap,
                      y: primaryHeight - v.maxY + gap,
                      width: v.width - gap * 2,
                      height: v.height - gap * 2)
    }

    private func screen(containing axRect: CGRect) -> NSScreen {
        let center = CGPoint(x: axRect.midX, y: primaryHeight - axRect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func rect(for pane: Pane, on screen: NSScreen) -> CGRect {
        let f = axFrame(of: screen)
        let gap = CGFloat(Prefs.shared.windowGap)
        // Inner gaps only appear between panes, never doubled at the screen edge.
        let innerX = pane.x > 0 ? gap / 2 : 0
        let innerY = pane.y > 0 ? gap / 2 : 0
        let trimW = (pane.x + pane.w < 0.999 ? gap / 2 : 0) + innerX
        let trimH = (pane.y + pane.h < 0.999 ? gap / 2 : 0) + innerY
        return CGRect(x: (f.minX + f.width * pane.x + innerX).rounded(),
                      y: (f.minY + f.height * pane.y + innerY).rounded(),
                      width: (f.width * pane.w - trimW).rounded(),
                      height: (f.height * pane.h - trimH).rounded())
    }

    private func key(for w: AXWindow) -> String { "\(w.pid)|\(w.title)" }

    /// The screen the target window is on, so a layout applied from the panel
    /// tiles where the user is working rather than wherever the panel opened.
    private var panelTargetScreen: NSScreen? {
        guard let pid = panelTargetPID,
              let frame = AX.focusedWindow(of: pid)?.frame else { return nil }
        return screen(containing: frame)
    }

    // MARK: - Public actions

    func apply(_ action: WindowAction) {
        guard requireAccess(), let win = AX.focusedWindow(), let current = win.frame else { return }

        var step = 0
        if action.cycles, let last = lastAction, last.action == action,
           Date().timeIntervalSince(last.at) < 1.5 {
            step = last.step + 1
        }
        lastAction = (action, Date(), step)

        remember(win, current)
        let target = rect(for: action.unitRect(step: step), on: screen(containing: current))
        move(win, to: target)
    }

    func apply(pane: Pane, to win: AXWindow? = nil) {
        guard requireAccess(), let win = win ?? AX.focusedWindow(), let current = win.frame else { return }
        remember(win, current)
        move(win, to: rect(for: pane, on: screen(containing: current)))
    }

    /// Tiles the most recently used windows into a layout's panes, one each.
    func apply(layout: CustomLayout) {
        guard requireAccess() else { return }
        guard let screen = panelTargetScreen ?? NSScreen.main else { return }
        let windows = orderedWindows().filter { w in
            guard let f = w.frame else { return false }
            return self.screen(containing: f) === screen
        }
        for (pane, win) in zip(layout.panes, windows) {
            if let f = win.frame { remember(win, f) }
            move(win, to: rect(for: pane, on: screen))
        }
    }

    func moveToScreen(next: Bool) {
        guard requireAccess(), let win = AX.focusedWindow(), let current = win.frame else { return }
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }
        let from = screen(containing: current)
        guard let idx = screens.firstIndex(where: { $0 === from }) else { return }
        let target = screens[(idx + (next ? 1 : screens.count - 1)) % screens.count]

        // Keep the window's relative position and proportions on the new screen.
        let a = axFrame(of: from), b = axFrame(of: target)
        let unit = Pane(Double((current.minX - a.minX) / a.width),
                        Double((current.minY - a.minY) / a.height),
                        Double(min(1, current.width / a.width)),
                        Double(min(1, current.height / a.height)))
        remember(win, current)
        move(win, to: CGRect(x: b.minX + b.width * unit.x, y: b.minY + b.height * unit.y,
                             width: b.width * unit.w, height: b.height * unit.h))
    }

    func restore() {
        guard requireAccess(), let win = AX.focusedWindow(),
              let original = originalFrames[key(for: win)] else { return }
        move(win, to: original)
        originalFrames.removeValue(forKey: key(for: win))
    }

    /// Windows in front-to-back order across regular apps, excluding Perch.
    func orderedWindows() -> [AXWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
        var byPid: [pid_t: [AXWindow]] = [:]
        for w in AX.allWindows() { byPid[w.pid, default: []].append(w) }
        // NSWorkspace roughly keeps launch/activation ordering; frontmost first.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let sorted = apps.sorted { a, _ in a.processIdentifier == front }
        return sorted.flatMap { byPid[$0.processIdentifier] ?? [] }
    }

    // MARK: - Internals

    private func remember(_ win: AXWindow, _ frame: CGRect) {
        let k = key(for: win)
        if originalFrames[k] == nil { originalFrames[k] = frame }
    }

    private func move(_ win: AXWindow, to rect: CGRect) {
        guard Prefs.shared.animateWindows, let from = win.frame else {
            win.setFrame(rect); return
        }
        let steps = 8
        for i in 1...steps {
            let t = easeOut(Double(i) / Double(steps))
            let interp = CGRect(x: from.minX + (rect.minX - from.minX) * t,
                                y: from.minY + (rect.minY - from.minY) * t,
                                width: from.width + (rect.width - from.width) * t,
                                height: from.height + (rect.height - from.height) * t)
            win.setFrame(interp)
            usleep(6000)
        }
    }

    private func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    @discardableResult
    private func requireAccess() -> Bool {
        if AX.isTrusted(prompt: false) { return true }
        _ = AX.isTrusted(prompt: true)
        let (title, body) = AX.accessibilityMessage(
            feature: "Window management moves windows through Accessibility.")
        Notifier.show(title, body, duration: 8)
        return false
    }
}
