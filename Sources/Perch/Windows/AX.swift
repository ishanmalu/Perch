import AppKit
import ApplicationServices

/// Thin wrapper around an AXUIElement representing a window.
struct AXWindow {
    let element: AXUIElement
    let pid: pid_t

    var title: String { AX.string(element, kAXTitleAttribute) ?? "" }
    var role: String { AX.string(element, kAXSubroleAttribute) ?? "" }
    var isMinimized: Bool { AX.bool(element, kAXMinimizedAttribute) ?? false }

    var frame: CGRect? {
        guard let pos = AX.point(element, kAXPositionAttribute),
              let size = AX.size(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// Sets size first, then position, then size again — many apps clamp one against the other.
    @discardableResult
    func setFrame(_ rect: CGRect) -> Bool {
        AX.setSize(element, rect.size)
        AX.setPoint(element, rect.origin)
        AX.setSize(element, rect.size)
        return true
    }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}

enum AX {
    static func isTrusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// True when Perch appears in the Accessibility list but macOS still refuses
    /// it — the state you land in after an update changes the code identity.
    ///
    /// The toggle looks switched on, so "enable Perch in Accessibility" is
    /// useless advice; the entry has to be removed and re-added. There is no
    /// API to read the list, so this infers it: an ad-hoc signature means the
    /// identity changes with every build, which is exactly when this happens.
    static var trustLikelyStale: Bool {
        guard !isTrusted(prompt: false) else { return false }
        return !hasStableSigningIdentity
    }

    /// Whether this build is signed with a certificate rather than ad-hoc.
    /// An ad-hoc signature is derived from the binary, so it changes every build.
    static let hasStableSigningIdentity: Bool = {
        var codeRef: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &codeRef) == errSecSuccess,
              let codeRef else { return false }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(codeRef, SecCSFlags(), &staticRef) == errSecSuccess,
              let staticRef else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticRef, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        // Ad-hoc signatures carry no certificate chain.
        let certs = dict[kSecCodeInfoCertificates as String] as? [Any]
        return (certs?.isEmpty == false)
    }()

    /// One message that tells the truth for whichever state we are in.
    static func accessibilityMessage(feature: String) -> (String, String) {
        if trustLikelyStale {
            return ("Accessibility needs re-granting",
                    "Perch was updated, which macOS treats as a new app. Remove Perch under "
                    + "System Settings → Privacy & Security → Accessibility with the − button, "
                    + "then add it again. The toggle may already look switched on.")
        }
        return ("Accessibility access needed",
                "\(feature) Enable Perch under System Settings → Privacy & Security → Accessibility.")
    }

    static func copyValue(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? { copyValue(el, attr) as? String }
    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? { copyValue(el, attr) as? Bool }

    static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        guard let v = copyValue(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
        return p
    }

    static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        guard let v = copyValue(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
        return s
    }

    static func setPoint(_ el: AXUIElement, _ p: CGPoint) {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return }
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
    }

    static func setSize(_ el: AXUIElement, _ s: CGSize) {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
    }

    /// The frontmost window of the frontmost app.
    ///
    /// When Perch's own panel is open, Perch *is* frontmost — acting on that
    /// would resize the popover instead of the user's window. In that case we
    /// fall back to whichever app was in front when the panel opened.
    static func focusedWindow() -> AXWindow? {
        var pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if pid == nil || pid == ProcessInfo.processInfo.processIdentifier {
            pid = WindowManager.shared.panelTargetPID
        }
        if let pid, let window = focusedWindow(of: pid) { return window }
        // Perch was already frontmost when the panel opened (so nothing was
        // recorded). Fall back to the most recently used non-Perch window.
        return WindowManager.shared.orderedWindows().first
    }

    static func focusedWindow(of pid: pid_t) -> AXWindow? {
        installGlobalTimeout
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, appTimeout)
        guard let w = copyValue(axApp, kAXFocusedWindowAttribute),
              CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        return AXWindow(element: w as! AXUIElement, pid: pid)
    }

    /// Every on-screen, non-minimized standard window across all regular apps.
    ///
    /// Apps are queried in parallel with a short messaging timeout, so one busy
    /// or hung app costs at most `appTimeout` instead of freezing the caller
    /// (the default AX timeout is ~6 s per call, on the main thread).
    static func allWindows() -> [AXWindow] {
        installGlobalTimeout
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .map(\.processIdentifier)

        var perApp = [[AXWindow]](repeating: [], count: pids.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            let pid = pids[i]
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, appTimeout)
            guard let raw = copyValue(axApp, kAXWindowsAttribute) as? [AXUIElement] else { return }
            var found: [AXWindow] = []
            for el in raw {
                AXUIElementSetMessagingTimeout(el, appTimeout)
                let w = AXWindow(element: el, pid: pid)
                guard !w.isMinimized, let f = w.frame, f.width > 80, f.height > 80 else { continue }
                found.append(w)
            }
            lock.lock(); perApp[i] = found; lock.unlock()
        }
        return perApp.flatMap { $0 }
    }

    /// Per-call ceiling for talking to another app over Accessibility.
    static let appTimeout: Float = 0.25

    /// Caps every AX call process-wide, so stray calls elsewhere (focused
    /// window, raise, titles) can't stall the UI on an unresponsive app either.
    private static let installGlobalTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
    }()
}
