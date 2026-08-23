import AppKit
import ScreenCaptureKit
import ApplicationServices

/// Captures live previews of other apps' windows for the thumbnail switcher.
///
/// Thumbnails need Screen Recording permission — there is no way around it, and
/// AltTab has the same requirement. Everything degrades to large app icons when
/// permission is absent, so the switcher stays usable either way.
final class WindowThumbnails: ObservableObject {
    static let shared = WindowThumbnails()

    /// Keyed by CGWindowID.
    @Published private(set) var images: [CGWindowID: NSImage] = [:]

    private var cache: [CGWindowID: (image: NSImage, at: Date)] = [:]
    private var inFlight: Set<CGWindowID> = []

    /// Screen Recording is granted. Checked without prompting.
    var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for Screen Recording.
    ///
    /// The system prompt only ever appears once per app identity — after that
    /// the call silently does nothing — so if permission is still missing a
    /// moment later, open the settings pane instead of leaving the user with a
    /// button that appears to do nothing.
    func requestAuthorization() {
        guard !isAuthorized else { return }
        CGRequestScreenCaptureAccess()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.isAuthorized else { return }
            Notifier.show("Add Perch to Screen Recording",
                          "Live window previews need it. Switch Perch on in the list, then reopen the switcher.",
                          duration: 7)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func image(for id: CGWindowID) -> NSImage? { images[id] }

    /// Captures the given windows, newest requests first. Cached briefly so
    /// re-opening the switcher is instant.
    func capture(_ ids: [CGWindowID]) {
        guard isAuthorized else { return }
        let fresh = Date().addingTimeInterval(-4)

        for id in ids {
            if let hit = cache[id], hit.at > fresh {
                images[id] = hit.image
                continue
            }
            guard !inFlight.contains(id) else { continue }
            inFlight.insert(id)

            Task { @MainActor [weak self] in
                let shot = await Self.screenshot(windowID: id)
                guard let self else { return }
                self.inFlight.remove(id)
                guard let shot else { return }
                self.cache[id] = (shot, Date())
                self.images[id] = shot
            }
        }
    }

    func clear() {
        images.removeAll()
        // Keep `cache` — it is what makes a re-open feel instant.
    }

    private static func screenshot(windowID: CGWindowID) async -> NSImage? {
        do {
            // onScreenWindowsOnly would drop anything on another Space, which
            // is exactly the window you are most likely reaching for.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)

            let config = SCStreamConfiguration()
            // Cap the long edge; a full-resolution grab of a 6K window is waste.
            let scale = min(1, 480 / max(window.frame.width, window.frame.height))
            config.width = max(1, Int(window.frame.width * scale * 2))
            config.height = max(1, Int(window.frame.height * scale * 2))
            config.showsCursor = false
            config.scalesToFit = true

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            return NSImage(cgImage: cgImage,
                           size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
        } catch {
            return nil
        }
    }
}

extension AXWindow {
    /// The CGWindowID behind this Accessibility element.
    ///
    /// AX exposes no public way to get one, so this matches the element against
    /// the window server's list by owning process, title, and frame. Matching on
    /// all three keeps documents with identical titles apart.
    func windowID() -> CGWindowID? {
        // Not .optionOnScreenOnly: that hides windows on other Spaces, which
        // would leave exactly those entries without a preview.
        guard let infoList = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        let myTitle = title
        let myFrame = frame

        var titleMatch: CGWindowID?
        for info in infoList {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }

            let name = info[kCGWindowName as String] as? String ?? ""

            if let myFrame, let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
               let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
               abs(rect.origin.x - myFrame.origin.x) < 2, abs(rect.origin.y - myFrame.origin.y) < 2,
               abs(rect.width - myFrame.width) < 2, abs(rect.height - myFrame.height) < 2 {
                return number
            }
            if !name.isEmpty, name == myTitle, titleMatch == nil {
                titleMatch = number
            }
        }
        // Frames can lag a moving window; the title is a decent second choice.
        return titleMatch
    }

    /// Closes the window through its close button, as clicking it would.
    @discardableResult
    func close() -> Bool {
        guard let button = AX.copyValue(element, kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    @discardableResult
    func minimize() -> Bool {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                     kCFBooleanTrue) == .success
    }
}
