import AppKit

/// Blanks every display so you can wipe the glass and see the dust.
/// Doubles as a dead-pixel test by cycling flat colors.
final class ScreenCleaner {
    static let shared = ScreenCleaner()

    private var windows: [NSWindow] = []
    private var monitors: [Any] = []
    private var colorIndex = 0

    private let testColors: [NSColor] = [.black, .white, .systemRed, .systemGreen, .systemBlue, .darkGray]

    var isActive: Bool { !windows.isEmpty }

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive else { return }
        colorIndex = Prefs.shared.screenCleanColor == "white" ? 1 : 0

        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false, screen: screen)
            w.isReleasedWhenClosed = false
            w.level = .init(Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.backgroundColor = testColors[colorIndex]
            w.isOpaque = true
            w.hasShadow = false
            w.setFrame(screen.frame, display: true)

            let hint = NSTextField(labelWithString: "Wipe away.   Space cycles colors  ·  Esc or click to exit")
            hint.font = .systemFont(ofSize: 12, weight: .medium)
            hint.textColor = NSColor.white.withAlphaComponent(0.28)
            hint.sizeToFit()
            hint.frame.origin = CGPoint(x: (screen.frame.width - hint.frame.width) / 2, y: 60)
            hint.autoresizingMask = [.minXMargin, .maxXMargin]
            w.contentView?.addSubview(hint)
            w.hint = hint

            w.orderFrontRegardless()
            windows.append(w)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()

        // Any key or click anywhere over the overlay ends the session.
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self else { return e }
            if e.type == .keyDown, e.keyCode == 49 { self.cycleColor(); return nil }  // Space
            self.stop()
            return nil
        }
        if let local { monitors.append(local) }

        // If something steals focus, local events stop reaching us — a global
        // monitor makes sure a click or key still gets the user out.
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.stop()
        }
        if let global { monitors.append(global) }

        // Last-resort watchdog so the overlay can never become permanent.
        let session = windows.first
        DispatchQueue.main.asyncAfter(deadline: .now() + 900) { [weak self] in
            guard let self, self.windows.first === session else { return }
            self.stop()
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    private func cycleColor() {
        colorIndex = (colorIndex + 1) % testColors.count
        let c = testColors[colorIndex]
        for w in windows {
            w.backgroundColor = c
            if let hint = (w as? OverlayWindow)?.hint {
                // Keep the hint readable against white and light backgrounds.
                let light = c == .white || c == .systemGreen
                hint.textColor = (light ? NSColor.black : NSColor.white).withAlphaComponent(0.28)
            }
        }
    }
}

/// Borderless windows can't become key by default, which we need for Esc.
final class OverlayWindow: NSWindow {
    var hint: NSTextField?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
