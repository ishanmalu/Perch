import AppKit

/// Swallows input for a timed session so a keyboard or trackpad can be wiped
/// without launching apps, typing into whatever was focused, or clicking things.
///
/// One event tap serves all three modes; what differs is which event types are
/// suppressed and how you get out:
///
/// - `.keyboard`  keys and clicks blocked — hold Esc to finish early.
/// - `.trackpad`  pointer blocked, keyboard still live — press Esc or the
///                shortcut to finish. This is the one you want while cleaning a
///                trackpad, since your hands are nowhere near the keys.
/// - `.both`      everything blocked — hold Esc to finish early.
final class InputCleaner {
    static let shared = InputCleaner()

    enum Mode: String {
        case keyboard, trackpad, both

        var title: String {
            switch self {
            case .keyboard: return "Keyboard locked — clean away"
            case .trackpad: return "Trackpad locked — clean away"
            case .both: return "Input locked — clean away"
            }
        }

        var hint: String {
            switch self {
            case .trackpad: return "Press Esc to finish early"
            default: return "Hold Esc for a second to finish early"
            }
        }

        /// Keyboard stays live in trackpad mode — that is how you unlock it.
        var blocksKeyboard: Bool { self != .trackpad }

        var eventMask: CGEventMask {
            var mask: UInt64 = 0
            func add(_ type: CGEventType) { mask |= (1 << type.rawValue) }

            // Keyboard events are always tapped: even when they pass through,
            // the tap is how Esc is detected.
            add(.keyDown); add(.keyUp); add(.flagsChanged)

            add(.mouseMoved)
            add(.leftMouseDown); add(.leftMouseUp); add(.leftMouseDragged)
            add(.rightMouseDown); add(.rightMouseUp); add(.rightMouseDragged)
            add(.otherMouseDown); add(.otherMouseUp); add(.otherMouseDragged)
            add(.scrollWheel)
            return CGEventMask(mask)
        }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var windows: [NSWindow] = []
    private var countdownLabel: NSTextField?
    private var timer: Timer?
    private var remaining = 0
    private var escDownSince: Date?
    private(set) var mode: Mode = .keyboard
    /// Events swallowed during the session, so we can report what we caught.
    private(set) var blockedCount = 0

    var isActive: Bool { tap != nil }

    func toggle(_ mode: Mode) {
        if isActive {
            stop(reason: "Input unlocked")
        } else {
            start(mode)
        }
    }

    func start(_ mode: Mode) {
        guard !isActive else { return }
        guard AX.isTrusted(prompt: true) else {
            let (title, body) = AX.accessibilityMessage(
                feature: "Cleaning mode has to intercept input.")
            Notifier.show(title, body, duration: 8)
            return
        }
        self.mode = mode

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mode.eventMask,
                                          callback: { _, type, event, _ in
                                              InputCleaner.shared.handle(type: type, event: event)
                                          }, userInfo: nil) else {
            Notifier.show("Could not lock input", "macOS refused the event tap.")
            return
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        blockedCount = 0
        remaining = max(5, Prefs.shared.keyboardCleanSeconds)
        showOverlay()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)

        // Independent failsafe: even if the timer is starved or the UI wedges,
        // input is never swallowed for longer than the session plus a grace period.
        let session = tap
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(remaining) + 15) { [weak self] in
            guard let self, self.tap === session, self.isActive else { return }
            self.stop(reason: "Input unlocked")
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
        escDownSince = nil
        windows.forEach { $0.close() }
        windows.removeAll()
        countdownLabel = nil

        let what = mode == .trackpad ? "pointer events" : "key presses"
        Notifier.show(reason, blockedCount > 0 ? "Blocked \(blockedCount) \(what) while you cleaned." : nil)
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that runs long or is user-cancelled; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        let isKeyboard = (type == .keyDown || type == .keyUp || type == .flagsChanged)

        if type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == 53 {                                   // Escape
                if mode == .trackpad {
                    // Keyboard is live here, so a single press is enough and
                    // there is no risk of it being an accidental brush.
                    DispatchQueue.main.async { self.stop(reason: "Trackpad unlocked") }
                    return nil
                }
                if escDownSince == nil {
                    escDownSince = Date()
                } else if Date().timeIntervalSince(escDownSince!) > 1.0 {
                    DispatchQueue.main.async { self.stop(reason: "Input unlocked") }
                }
            }
        }
        if type == .keyUp, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
            escDownSince = nil
        }

        // In trackpad mode the keyboard passes through untouched — that is what
        // lets the shortcut and Esc reach us in the first place.
        if isKeyboard && !mode.blocksKeyboard {
            return Unmanaged.passUnretained(event)
        }

        blockedCount += 1
        return nil
    }

    private func tick() {
        remaining -= 1
        countdownLabel?.stringValue = "\(remaining)"
        if remaining <= 0 { stop(reason: mode == .trackpad ? "Trackpad unlocked" : "Input unlocked") }
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
                let icon = NSImageView(image: NSImage(
                    systemSymbolName: mode == .trackpad ? "rectangle.and.hand.point.up.left" : "keyboard",
                    accessibilityDescription: nil) ?? NSImage())
                icon.contentTintColor = NSColor.white.withAlphaComponent(0.75)
                icon.symbolConfiguration = .init(pointSize: 34, weight: .light)

                let title = NSTextField(labelWithString: mode.title)
                title.font = .systemFont(ofSize: 26, weight: .semibold)
                title.textColor = .white

                let count = NSTextField(labelWithString: "\(remaining)")
                count.font = .monospacedDigitSystemFont(ofSize: 84, weight: .thin)
                count.textColor = NSColor.white.withAlphaComponent(0.85)
                countdownLabel = count

                let hint = NSTextField(labelWithString: mode.hint)
                hint.font = .systemFont(ofSize: 12)
                hint.textColor = NSColor.white.withAlphaComponent(0.45)

                let stack = NSStackView(views: [icon, title, count, hint])
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
