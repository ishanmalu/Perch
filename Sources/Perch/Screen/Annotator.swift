import AppKit
import SwiftUI
import CoreImage

/// Mark up a capture before it goes anywhere: arrows, boxes, highlighter, and
/// pixelation for anything private. Opened from the overlay's A mode or from
/// a pinned shot's right-click.
@MainActor
final class Annotator {
    private static var open: [Annotator] = []
    private let window: NSWindow
    private let canvas: AnnotationCanvas

    static func show(_ image: CGImage) {
        open.append(Annotator(image: image))
    }

    private init(image: CGImage) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let fit = min(1, min(screen.width * 0.85 / size.width, (screen.height * 0.85 - 52) / size.height))
        size = NSSize(width: max(360, size.width * fit), height: max(200, size.height * fit))

        canvas = AnnotationCanvas(image: image)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height + 52),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Annotate"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        let root = AnnotatorView(canvas: canvas,
                                 onCopy: { [weak self] in self?.export(copy: true) },
                                 onSave: { [weak self] in self?.export(copy: false) },
                                 onPin: { [weak self] in
                                     guard let self, let img = self.canvas.render() else { return }
                                     PinnedShot.show(img, near: CGRect(x: 80, y: 80, width: 1, height: 1))
                                     self.close()
                                 })
        window.contentView = NSHostingView(rootView: root)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Annotator.open.removeAll { $0 === self }
            }
        }
    }

    private func export(copy: Bool) {
        guard let img = canvas.render() else { return }
        _ = Screenshot.deliver(img, to: .init(toFile: !copy, toClipboard: copy))
        Notifier.show(copy ? "Copied" : "Saved", copy ? nil : Screenshot.saveFolder().path, duration: 2)
        if copy { close() }
    }

    private func close() { window.close() }
}

/// The marks, in image-pixel coordinates so they survive window resizing.
@MainActor
final class AnnotationCanvas: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case arrow, box, highlight, pixelate
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .arrow: return "arrow.up.right"
            case .box: return "rectangle"
            case .highlight: return "highlighter"
            case .pixelate: return "checkerboard.rectangle"
            }
        }
        var title: String { rawValue.capitalized }
    }

    struct Mark: Identifiable {
        let id = UUID()
        var tool: Tool
        var from: CGPoint
        var to: CGPoint
        var color: NSColor
    }

    let image: CGImage
    @Published var tool: Tool = .arrow
    @Published var color: NSColor = .systemRed
    @Published var marks: [Mark] = []
    @Published var draft: Mark?

    init(image: CGImage) { self.image = image }

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    func undo() { if !marks.isEmpty { marks.removeLast() } }

    /// Flattens the image and every mark into a new image at full resolution.
    func render() -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Marks are stored top-left origin; flip once for the whole pass.
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
        let lineScale = max(1, CGFloat(w) / 1000) * 2
        for m in marks { Self.draw(m, in: ctx, image: image, lineScale: lineScale) }
        return ctx.makeImage()
    }

    /// Shared by the live view and the export, so what you see is what you get.
    static func draw(_ m: Mark, in ctx: CGContext, image: CGImage, lineScale: CGFloat) {
        let r = CGRect(x: min(m.from.x, m.to.x), y: min(m.from.y, m.to.y),
                       width: abs(m.to.x - m.from.x), height: abs(m.to.y - m.from.y))
        switch m.tool {
        case .box:
            ctx.setStrokeColor(m.color.cgColor)
            ctx.setLineWidth(3 * lineScale)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4 * lineScale, cornerHeight: 4 * lineScale, transform: nil))
            ctx.strokePath()
        case .highlight:
            ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.38).cgColor)
            ctx.fill(r)
        case .arrow:
            ctx.setStrokeColor(m.color.cgColor)
            ctx.setFillColor(m.color.cgColor)
            ctx.setLineWidth(3.5 * lineScale)
            ctx.setLineCap(.round)
            let angle = atan2(m.to.y - m.from.y, m.to.x - m.from.x)
            let head = 16 * lineScale
            let shaftEnd = CGPoint(x: m.to.x - cos(angle) * head * 0.8, y: m.to.y - sin(angle) * head * 0.8)
            ctx.move(to: m.from); ctx.addLine(to: shaftEnd); ctx.strokePath()
            ctx.move(to: m.to)
            ctx.addLine(to: CGPoint(x: m.to.x - head * cos(angle - .pi / 7), y: m.to.y - head * sin(angle - .pi / 7)))
            ctx.addLine(to: CGPoint(x: m.to.x - head * cos(angle + .pi / 7), y: m.to.y - head * sin(angle + .pi / 7)))
            ctx.closePath(); ctx.fillPath()
        case .pixelate:
            guard r.width > 2, r.height > 2,
                  let px = pixelated(image, rect: r) else { return }
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(px, in: CGRect(origin: .zero, size: r.size))
            ctx.restoreGState()
        }
    }

    /// Mosaic of one region, coarse enough that text can't be read back.
    static func pixelated(_ image: CGImage, rect: CGRect) -> CGImage? {
        guard let crop = image.cropping(to: rect.integral) else { return nil }
        let ci = CIImage(cgImage: crop)
        let f = CIFilter(name: "CIPixellate")
        f?.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        f?.setValue(max(10, min(rect.width, rect.height) / 8), forKey: kCIInputScaleKey)
        guard let out = f?.outputImage?.cropped(to: ci.extent) else { return nil }
        return CIContext().createCGImage(out, from: ci.extent)
    }
}

private struct AnnotatorView: View {
    @ObservedObject var canvas: AnnotationCanvas
    var onCopy: () -> Void
    var onSave: () -> Void
    var onPin: () -> Void

    private let swatches: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .white, .black]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(AnnotationCanvas.Tool.allCases) { t in
                    HoverButton(action: { canvas.tool = t }) {
                        Image(systemName: t.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(canvas.tool == t ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            .frame(width: 28, height: 22)
                    }
                    .help(t.title)
                }
                Divider().frame(height: 16)
                ForEach(swatches, id: \.self) { c in
                    Circle().fill(Color(nsColor: c))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: canvas.color == c ? 2 : 0).padding(-3))
                        .frame(width: 14, height: 14)
                        .onTapGesture { canvas.color = c }
                }
                Spacer()
                HoverButton(action: canvas.undo) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
                        .foregroundStyle(.secondary).frame(width: 26, height: 22)
                }
                .help("Undo  (⌘Z)")
                .keyboardShortcut("z", modifiers: .command)
                .disabled(canvas.marks.isEmpty)
                HoverButton(action: onPin) {
                    Label("Pin", systemImage: "pin").font(Theme.Font.caption).padding(.horizontal, 8).frame(height: 22)
                }
                HoverButton(action: onSave) {
                    Label("Save", systemImage: "square.and.arrow.down").font(Theme.Font.caption).padding(.horizontal, 8).frame(height: 22)
                }
                .keyboardShortcut("s", modifiers: .command)
                Button(action: onCopy) {
                    Label("Copy", systemImage: "doc.on.doc").font(Theme.Font.caption)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .keyboardShortcut("c", modifiers: .command)
            }
            .padding(.horizontal, 12).padding(.top, 26).padding(.bottom, 8)
            CanvasView(canvas: canvas)
        }
        .background(.regularMaterial)
    }
}

/// Draws the capture and the marks, and turns drags into marks.
private struct CanvasView: View {
    @ObservedObject var canvas: AnnotationCanvas

    var body: some View {
        GeometryReader { geo in
            let s = scale(in: geo.size)
            let shown = CGSize(width: canvas.pixelSize.width * s, height: canvas.pixelSize.height * s)
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2, y: (geo.size.height - shown.height) / 2)
            Canvas { ctx, _ in
                ctx.withCGContext { cg in
                    cg.translateBy(x: origin.x, y: origin.y)
                    cg.scaleBy(x: s, y: s)
                    cg.saveGState()
                    cg.translateBy(x: 0, y: canvas.pixelSize.height); cg.scaleBy(x: 1, y: -1)
                    cg.draw(canvas.image, in: CGRect(origin: .zero, size: canvas.pixelSize))
                    cg.restoreGState()
                    let lineScale = max(1, canvas.pixelSize.width / 1000) * 2
                    for m in canvas.marks + (canvas.draft.map { [$0] } ?? []) {
                        AnnotationCanvas.draw(m, in: cg, image: canvas.image, lineScale: lineScale)
                    }
                }
            }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in
                    let a = toImage(v.startLocation, origin, s), b = toImage(v.location, origin, s)
                    canvas.draft = .init(tool: canvas.tool, from: a, to: b, color: canvas.color)
                }
                .onEnded { _ in
                    if let d = canvas.draft { canvas.marks.append(d) }
                    canvas.draft = nil
                })
            // A cursor set, not pushed: a push left unpopped when the window
            // closes under the pointer keeps the crosshair in other apps.
            .onContinuousHover { phase in
                if case .active = phase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
            }
        }
        .padding(10)
    }

    private func scale(in size: CGSize) -> CGFloat {
        min(size.width / canvas.pixelSize.width, size.height / canvas.pixelSize.height)
    }

    private func toImage(_ p: CGPoint, _ origin: CGPoint, _ s: CGFloat) -> CGPoint {
        CGPoint(x: min(canvas.pixelSize.width, max(0, (p.x - origin.x) / s)),
                y: min(canvas.pixelSize.height, max(0, (p.y - origin.y) / s)))
    }
}
