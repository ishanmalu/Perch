import AppKit
import ScreenCaptureKit
import Vision
import UniformTypeIdentifiers

/// Capturing the screen, and deciding what to do with the result.
///
/// macOS already takes screenshots, so the reason to have this is what it does
/// after one: the selection stays armed. Grabbing six things from a page with
/// the built-in tool means pressing the shortcut six times and re-aiming from
/// cold each time.
enum Screenshot {
    /// Why the last capture failed, for `--probe-shot`. ScreenCaptureKit's
    /// errors are the only way to tell a permission problem from a real fault.
    nonisolated(unsafe) static var lastError: Error?

    /// Where a capture ends up. Both can be on at once.
    struct Destination {
        var toFile: Bool
        var toClipboard: Bool
    }

    /// Captures `rect` in global screen coordinates, top-left origin.
    static func capture(rect: CGRect) async -> CGImage? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            // Capture the display the selection starts on, then crop; a filter
            // cannot express an arbitrary rectangle on its own.
            guard let display = content.displays.first(where: {
                CGRect(x: 0, y: 0, width: $0.width, height: $0.height)
                    .offsetBy(dx: displayOrigin($0).x, dy: displayOrigin($0).y)
                    .intersects(rect)
            }) ?? content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = backingScale(for: display)
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            config.captureResolution = .best

            let full = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)

            // Translate the selection into the captured image's pixel space.
            let origin = displayOrigin(display)
            let local = CGRect(x: (rect.minX - origin.x) * scale,
                               y: (rect.minY - origin.y) * scale,
                               width: rect.width * scale,
                               height: rect.height * scale)
            let clamped = local.intersection(
                CGRect(x: 0, y: 0, width: CGFloat(full.width), height: CGFloat(full.height)))
            guard clamped.width >= 1, clamped.height >= 1 else { return nil }
            return full.cropping(to: clamped) ?? full
        } catch {
            lastError = error
            return nil
        }
    }

    /// A window under a point, topmost first, skipping Perch's own overlay.
    /// Returned in global top-left coordinates, matching `capture(rect:)`.
    static func window(at point: CGPoint) -> (id: CGWindowID, frame: CGRect, owner: String)? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"]
            else { continue }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            if frame.contains(point) {
                let owner = entry[kCGWindowOwnerName as String] as? String ?? "Window"
                return (id, frame, owner)
            }
        }
        return nil
    }

    /// Captures one window on its own, without whatever sits behind it.
    static func captureWindow(id: CGWindowID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            config.width = max(1, Int(window.frame.width * scale))
            config.height = max(1, Int(window.frame.height * scale))
            config.showsCursor = false
            config.captureResolution = .best
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch {
            lastError = error
            return nil
        }
    }

    /// Reads the text out of a capture.
    ///
    /// Vision normalises a double hyphen to an em dash, which quietly breaks
    /// any command line you OCR, so that one substitution is undone. The rest
    /// is left alone; guessing further would do more harm than good.
    static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").replacingOccurrences(of: "\u{2014}-", with: "--")
    }

    /// The colour of a single pixel, for the eyedropper.
    static func colour(at point: CGPoint) async -> NSColor? {
        guard let image = await capture(rect: CGRect(x: point.x, y: point.y, width: 1, height: 1)),
              let rep = NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)
        else { return nil }
        return rep.usingColorSpace(.sRGB) ?? rep
    }

    /// `#RRGGBB`, which is what a colour is usually wanted as.
    static func hex(_ colour: NSColor) -> String {
        let c = colour.usingColorSpace(.sRGB) ?? colour
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    /// Converts a selection in a window's own coordinates — AppKit's
    /// bottom-left origin — into the top-left space CoreGraphics captures in.
    ///
    /// This is where a screenshot tool goes wrong: pick the flip incorrectly
    /// and every capture is mirrored vertically about the screen, which looks
    /// plausible on the main display and obviously broken on a second one.
    static func globalRect(local: CGRect, windowFrame: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: windowFrame.minX + local.minX,
               y: (primaryMaxY - windowFrame.maxY) + (windowFrame.height - local.maxY),
               width: local.width,
               height: local.height)
    }

    /// Top-left origin of a display in the global coordinate space.
    private static func displayOrigin(_ display: SCDisplay) -> CGPoint {
        let bounds = CGDisplayBounds(display.displayID)
        return CGPoint(x: bounds.minX, y: bounds.minY)
    }

    private static func backingScale(for display: SCDisplay) -> CGFloat {
        let bounds = CGDisplayBounds(display.displayID)
        let screen = NSScreen.screens.first {
            $0.frame.origin.x == bounds.minX && $0.frame.width == bounds.width
        }
        return screen?.backingScaleFactor ?? 2
    }

    /// Writes a PNG and/or puts the image on the pasteboard. Returns the file
    /// it wrote, when it wrote one.
    @discardableResult
    static func deliver(_ image: CGImage, to destination: Destination) -> URL? {
        if destination.toClipboard {
            let rep = NSBitmapImageRep(cgImage: image)
            if let png = rep.representation(using: .png, properties: [:]) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(png, forType: .png)
            }
        }
        guard destination.toFile else { return nil }

        let folder = saveFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Self.stamp.string(from: Date())
        var url = folder.appendingPathComponent("Perch \(stamp).png")
        // A burst can produce several inside the same second.
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Perch \(stamp) (\(n)).png")
            n += 1
        }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            Notifier.show("Could not save the screenshot", error.localizedDescription)
            return nil
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        // Colons are legal in a file name but show as slashes in Finder.
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    /// Where captures are written. Falls back through Pictures to Desktop so a
    /// missing folder never loses a capture.
    static func saveFolder() -> URL {
        let fm = FileManager.default
        if let custom = Prefs.shared.screenshotFolder, !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        if let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first {
            return pictures.appendingPathComponent("Perch")
        }
        return fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
    }
}
