import AppKit
import AVFoundation
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

/// Records a region of the screen to an MP4, or a GIF for pasting into
/// chats and pull requests.
///
/// Started from the screenshot overlay (R, then drag). While it runs, the
/// menu bar icon turns into a red dot with the elapsed time; clicking it, or
/// the screenshot shortcut, stops it. GIFs are made from the MP4 afterwards
/// at 12 fps and at most 960 pt wide, which keeps them small enough to share.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    static let shared = ScreenRecorder()

    enum Format: String, CaseIterable, Identifiable { case mp4, gif; var id: String { rawValue } }

    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var outputURL: URL?
    private var format: Format = .mp4
    private var frameBox: RegionFrame?

    var elapsedLabel: String? {
        guard isRecording, let startedAt else { return nil }
        let s = Int(Date().timeIntervalSince(startedAt))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// `rect` in global top-left coordinates, as the overlay reports it.
    func start(rect: CGRect, format: Format) {
        guard !isRecording else { return }
        self.format = format
        Task { await begin(rect) }
    }

    /// `completion` runs once the file is written — quitting waits on it, or
    /// the MP4 is left without its index and won't play.
    func stop(completion: (() -> Void)? = nil) {
        guard isRecording, let stream else { completion?(); return }
        isRecording = false
        frameBox?.close(); frameBox = nil
        Task {
            try? await stream.stopCapture()
            self.stream = nil
            await finish()
            completion?()
        }
    }

    /// Capture can end without us: the display is unplugged, the Mac sleeps,
    /// or permission is revoked. Save what was recorded instead of leaving the
    /// red dot counting forever over a file that never gets written.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.isRecording else { return }
            self.isRecording = false
            self.frameBox?.close(); self.frameBox = nil
            self.stream = nil
            Notifier.show("Recording stopped", error.localizedDescription, duration: 3)
            await self.finish()
        }
    }

    private func begin(_ rect: CGRect) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) ?? content.displays.first,
                  let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else { return }
            let scale = screen.backingScaleFactor
            let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                .intersection(CGRect(origin: .zero, size: display.frame.size))
            guard local.width >= 8, local.height >= 8 else { return }

            // Don't record our own border around the region.
            let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingWindows: own)
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = local
            // Even dimensions: H.264 refuses odd ones.
            cfg.width = Int(local.width * scale) & ~1
            cfg.height = Int(local.height * scale) & ~1
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            cfg.showsCursor = true
            cfg.queueDepth = 6

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("perch-recording-\(UUID().uuidString).mp4")
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: cfg.width, AVVideoHeightKey: cfg.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: cfg.width * cfg.height * 6],
            ])
            i.expectsMediaDataInRealTime = true
            w.add(i)
            guard w.startWriting() else { throw w.error ?? CocoaError(.fileWriteUnknown) }

            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            writer = w; input = i; outputURL = url; sessionStarted = false
            stream = s
            try await s.startCapture()
            isRecording = true
            startedAt = Date()
            // Show the region being recorded, in AppKit coordinates.
            frameBox = RegionFrame(rect: NSRect(x: rect.minX, y: primaryH - rect.maxY,
                                                width: rect.width, height: rect.height))
            Notifier.show("Recording", "Click the red dot in the menu bar to stop.", duration: 2)
        } catch {
            writer?.cancelWriting(); writer = nil; input = nil
            Notifier.show("Couldn't start recording",
                          "Perch needs Screen Recording access in System Settings.", duration: 4)
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        // Only complete frames carry pixels; idle/blank ones are skipped.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else { return }
        MainActor.assumeIsolated {
            guard let writer, let input else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: sb.presentationTimeStamp)
                sessionStarted = true
            }
            if input.isReadyForMoreMediaData { input.append(sb) }
        }
    }

    private func finish() async {
        guard let writer, let input, let url = outputURL else { return }
        input.markAsFinished()
        await writer.finishWriting()
        self.writer = nil; self.input = nil; startedAt = nil
        guard writer.status == .completed, sessionStarted else {
            Notifier.show("Recording failed", writer.error?.localizedDescription ?? "No frames were captured.")
            return
        }
        let folder = Screenshot.saveFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = folder.appendingPathComponent("Perch Recording \(f.string(from: Date()))")

        if format == .gif {
            Notifier.show("Making the GIF…", nil, duration: 2)
            let gifURL = base.appendingPathExtension("gif")
            let ok = await Self.makeGIF(from: url, to: gifURL)
            try? FileManager.default.removeItem(at: url)
            if ok { reveal(gifURL) } else { Notifier.show("GIF conversion failed") }
        } else {
            let dest = base.appendingPathExtension("mp4")
            do {
                try FileManager.default.moveItem(at: url, to: dest)
                reveal(dest)
            } catch {
                Notifier.show("Couldn't save the recording", error.localizedDescription)
            }
        }
    }

    private func reveal(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        NSWorkspace.shared.activateFileViewerSelecting([url])
        Notifier.show("Recording saved", "Copied to the clipboard, ready to paste.", duration: 3)
    }

    /// Samples the video at 12 fps, scaled to ≤ 960 px wide, into a looping GIF.
    static func makeGIF(from video: URL, to out: URL, fps: Double = 12, maxWidth: CGFloat = 960) async -> Bool {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return false }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)

        let count = max(1, Int(duration.seconds * fps))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { return false }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for n in 0..<count {
            let t = CMTime(seconds: Double(n) / fps, preferredTimescale: 600)
            if let img = try? await gen.image(at: t).image {
                CGImageDestinationAddImage(dest, img, frameProps)
            }
        }
        return CGImageDestinationFinalize(dest)
    }
}

/// A thin red outline around the region being recorded, outside it so it
/// never ends up in the video.
@MainActor
private final class RegionFrame {
    private let window: NSWindow

    init(rect: NSRect) {
        let pad: CGFloat = 3
        window = NSWindow(contentRect: rect.insetBy(dx: -pad, dy: -pad), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        v.layer?.borderWidth = 2
        v.layer?.cornerRadius = 4
        window.contentView = v
        window.orderFrontRegardless()
    }

    func close() { window.orderOut(nil) }
}
