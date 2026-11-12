import AppKit
import Metal
import QuartzCore

/// Brightness past 100% on displays with HDR headroom (Liquid Retina XDR,
/// Pro Display XDR, HDR externals).
///
/// macOS reserves that headroom for HDR content. Showing a tiny bit of HDR
/// content unlocks it, and a full-screen layer that multiplies everything
/// beneath it by a value above 1.0 then lifts the whole desktop into it. The
/// layer ignores the mouse and is invisible to screenshots' content (it only
/// scales what's already there), and it costs one Metal clear per second.
final class XDRBoost: ObservableObject {
    static let shared = XDRBoost()

    @Published private(set) var isActive = false
    /// 0...1 of the available headroom.
    @Published var amount: Double = 0.6 { didSet { if isActive { redraw() } } }

    private var overlays: [CGDirectDisplayID: (window: NSWindow, layer: CAMetalLayer)] = [:]
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private var timer: Timer?

    /// Displays that can go above SDR white at all.
    static var capableScreens: [NSScreen] {
        NSScreen.screens.filter { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.05 }
    }

    var isSupported: Bool { device != nil && !Self.capableScreens.isEmpty }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
    }

    /// Displays come and go while boosting: drop overlays for ones that left,
    /// add them for capable ones that arrived.
    private func screensChanged() {
        guard isActive else { return }
        let capable = Set(Self.capableScreens.compactMap(\.displayID))
        for id in overlays.keys where !capable.contains(id) {
            overlays.removeValue(forKey: id)?.window.orderOut(nil)
        }
        for screen in Self.capableScreens { addOverlay(on: screen) }
        if overlays.isEmpty { stop() } else { redraw() }
    }

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard isSupported else {
            Notifier.show("No HDR headroom", "Extra brightness needs an XDR or HDR display.", duration: 3)
            return
        }
        for screen in Self.capableScreens { addOverlay(on: screen) }
        isActive = true
        redraw()
        // Headroom drops when the panel heats up or the battery is low; keep
        // following it rather than clipping.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.redraw() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        overlays.values.forEach { $0.window.orderOut(nil) }
        overlays.removeAll()
        isActive = false
    }

    /// Pure: the multiplier for a given headroom and slider position. Never
    /// below 1 (that would dim) and never past the headroom (that would clip).
    static func gain(headroom: Double, amount: Double) -> Double {
        let h = max(1, headroom)
        return 1 + (h - 1) * min(1, max(0, amount))
    }

    private func addOverlay(on screen: NSScreen) {
        guard let id = screen.displayID, overlays[id] == nil, let device else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered,
                         defer: false, screen: screen)
        w.isReleasedWhenClosed = false
        w.level = .init(Int(CGShieldingWindowLevel()))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.ignoresMouseEvents = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.sharingType = .none

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = true
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.compositingFilter = "multiplyBlendMode"
        layer.drawableSize = CGSize(width: 16, height: 16)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        // Layer-hosting: assign the layer before turning layers on, or AppKit
        // treats it as layer-backed and may replace it.
        view.layer = layer
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        w.contentView = view
        w.setFrame(screen.frame, display: false)
        w.orderFrontRegardless()
        overlays[id] = (w, layer)
    }

    private func redraw() {
        guard let queue else { return }
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let o = overlays[id] else { continue }
            o.window.setFrame(screen.frame, display: false)
            let headroom = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
            let g = Self.gain(headroom: max(headroom, 1.0001), amount: amount)
            guard let drawable = o.layer.nextDrawable(), let cmd = queue.makeCommandBuffer() else { continue }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: g, green: g, blue: g, alpha: 1)
            cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}
