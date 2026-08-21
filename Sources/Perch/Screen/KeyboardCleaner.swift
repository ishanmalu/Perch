import AppKit

/// Swallows all keyboard and trackpad input for a timed window so the keys can
/// be wiped without launching apps or typing into whatever was focused.
final class KeyboardCleaner {
    static let shared = KeyboardCleaner()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var windows: [NSWindow] = []
    private var countdownLabel: NSTextField?
    private var timer: Timer?
    private var remaining = 0
    private var escDownSince: Date?
    /// Keys pressed during the session, so we can show which ones we caught.
    private(set) var pressCount = 0

    var isActive: Bool { tap != nil }

    func toggle() { isActive ? stop(reason: "Ended") : start() }

    func start() {
        guard !isActive else { return }
        guard AX.isTrusted(prompt: true) else {
            Notifier.show("Accessibility access needed",
                          "Keyboard cleaning has to intercept input. Enable Perch in System Settings → Privacy & Security → Accessibility.")
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.scrollWheel.rawValue)

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: { _, type, event, _ in
                                              KeyboardCleaner.shared.handle(type: type, event: event)
                                          }, userInfo: nil) else {
            Notifier.show("Could not lock the keyboard", "macOS refused the event tap.")
            return
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        pressCount = 0
        remaining = max(5, Prefs.shared.keyboardCleanSeconds)
        showOverlay()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)

        // Independent failsafe: even if the timer is starved or the UI wedges,
        // input is never swallowed for longer than the session plus a grace period.
        let session = tap
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(remaining) + 15) { [weak self] in
            guard let self, self.tap === session, self.isActive else { return }
            self.stop(reason: "Keyboard unlocked")
        }
    }

    func stop(reason: String) {
        timer?.invalidate(); timer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        windows.forEach { $0.close() }
        windows.removeAll()
        countdownLabel = nil
        Notifier.show(reason, pressCount > 0 ? "Blocked \(pressCount) key presses while you cleaned." : nil)
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that runs long or is user-cancelled; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        if type == .keyDown {
            pressCount += 1
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == 53 {   // Escape — hold to bail out early
                if escDownSince == nil { escDownSince = Date() }
                else if Date().timeIntervalSince(escDownSince!) > 1.0 {
                    DispatchQueue.main.async { self.stop(reason: "Keyboard unlocked") }
                }
            }
        }
        if type == .keyUp, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
            escDownSince = nil
        }
        return nil   // swallow everything
    }

    private func tick() {
        remaining -= 1
        countdownLabel?.stringValue = "\(remaining)"
        if remaining <= 0 { stop(reason: "Keyboard unlocked") }
    }

    // MARK: - Overlay

    private func showOverlay() {
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                             backing: .buffered, defer: false, screen: screen)
            w.isReleasedWhenClosed = false
            w.level = .init(Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.backgroundColor = NSColor.black.withAlphaComponent(0.92)
            w.isOpaque = false
            w.ignoresMouseEvents = false

            if screen === NSScreen.main {
                let title = NSTextField(labelWithString: "Keyboard locked — clean away")
                title.font = .systemFont(ofSize: 26, weight: .semibold)
                title.textColor = .white

                let count = NSTextField(labelWithString: "\(remaining)")
                count.font = .monospacedDigitSystemFont(ofSize: 84, weight: .thin)
                count.textColor = NSColor.white.withAlphaComponent(0.85)
                countdownLabel = count

                let hint = NSTextField(labelWithString: "Hold Esc for a second to finish early")
                hint.font = .systemFont(ofSize: 12)
                hint.textColor = NSColor.white.withAlphaComponent(0.45)

                let stack = NSStackView(views: [title, count, hint])
                stack.orientation = .vertical
                stack.alignment = .centerX
                stack.spacing = 12
                stack.frame = CGRect(origin: .zero, size: stack.fittingSize)
                stack.setFrameOrigin(CGPoint(x: (screen.frame.width - stack.frame.width) / 2,
                                             y: (screen.frame.height - stack.frame.height) / 2))
                stack.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
                w.contentView?.addSubview(stack)
            }

            w.orderFrontRegardless()
            windows.append(w)
        }
    }
}
