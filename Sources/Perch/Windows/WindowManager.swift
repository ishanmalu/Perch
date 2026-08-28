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

    /// Windows that a layout could tile, front to back, on the screen the panel
    /// is targeting. The picker offers these; the caller decides which pane
    /// each one lands in.
    func tileCandidates() -> [AXWindow] {
        guard requireAccess() else { return [] }
        guard let screen = panelTargetScreen ?? NSScreen.main else { return [] }
        return orderedWindows().filter { w in
            guard let f = w.frame, !w.isMinimized else { return false }
            return self.screen(containing: f) === screen
        }
    }

    /// Applies a layout to windows chosen by the user rather than to whatever
    /// happened to be in front. Entries line up with `layout.panes`; a nil
    /// leaves that pane empty.
    func apply(layout: CustomLayout, using windows: [AXWindow?]) {
        guard requireAccess() else { return }
        guard let screen = panelTargetScreen ?? NSScreen.main else { return }
        var vanished = 0
        for (pane, win) in zip(layout.panes, windows) {
            guard let win else { continue }
            // The picker can sit open for a while, and a chosen window may be
            // gone by the time Tile is pressed. A dead element still accepts
            // the calls and reports nothing, so an unreadable frame is the
            // liveness test — otherwise the pane silently stays empty.
            guard let current = win.frame else { vanished += 1; continue }
            remember(win, current)
            move(win, to: rect(for: pane, on: screen))
        }
        if vanished > 0 {
            Notifier.show(vanished == 1 ? "One window had closed" : "\(vanished) windows had closed",
                          "Their panes were left empty.", duration: 3)
        }
    }

    /// Fills the screen with every window on it, one on top of another. This is
    /// not macOS full screen: no Space is created, the menu bar stays, and the
    /// windows remain ordinary windows you can Alt-Tab between.
    func maximizeAll() {
        guard requireAccess() else { return }
        guard let screen = panelTargetScreen ?? NSScreen.main else { return }
        let full = rect(for: Pane(0, 0, 1, 1), on: screen)
        for win in tileCandidates() {
            if let f = win.frame { remember(win, f) }
            move(win, to: full)
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

    /// Windows in true front-to-back order across regular apps, excluding Perch.
    ///
    /// The previous ordering sorted running applications with a comparator that
    /// ignored its second argument — not a strict weak ordering, so the result
    /// was undefined — and `runningApplications` is not in recency order
    /// regardless. "Tile your frontmost windows" was therefore tiling whichever
    /// windows happened to come out first.
    ///
    /// The window server does know the z-order, and `CGWindowListCopyWindowInfo`
    /// returns it front to back, so that is what decides the order now.
    func orderedWindows() -> [AXWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = AX.allWindows().filter { $0.pid != ownPID }

        // Front-to-back z-order, as the window server sees it.
        var zOrder: [CGWindowID: Int] = [:]
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] {
            for (index, entry) in info.enumerated() {
                guard let number = entry[kCGWindowNumber as String] as? CGWindowID,
                      (entry[kCGWindowLayer as String] as? Int) == 0 else { continue }
                zOrder[number] = index
            }
        }

        return windows
            .map { ($0, $0.windowID().flatMap { zOrder[$0] } ?? Int.max) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
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
