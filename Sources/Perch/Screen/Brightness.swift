import AppKit
import Combine

/// Brightness control per display.
///
/// The built-in panel is driven through DisplayServices (the same private
/// framework the brightness keys use, resolved at runtime so a future macOS
/// that drops it degrades to software dimming instead of crashing).
/// External displays get a black overlay whose opacity is the "dim" amount,
/// which works over any cable without DDC/CI support.
final class BrightnessController: ObservableObject {
    static let shared = BrightnessController()

    struct Display: Identifiable {
        var id: CGDirectDisplayID
        var name: String
        var isBuiltin: Bool
        var level: Double     // 0...1 — real backlight, or 1 - overlay opacity
    }

    @Published private(set) var displays: [Display] = []

    private var overlays: [CGDirectDisplayID: NSWindow] = [:]
    private var dimAmount: [CGDirectDisplayID: Double] = [:]

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private lazy var handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private lazy var getBrightness: GetFn? = handle
        .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFn.self) }
    private lazy var setBrightness: SetFn? = handle
        .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFn.self) }

    var supportsHardwareBrightness: Bool { getBrightness != nil && setBrightness != nil }

    init() {
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        var list: [Display] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let builtin = CGDisplayIsBuiltin(id) != 0
            list.append(Display(id: id, name: screen.localizedName, isBuiltin: builtin, level: level(for: id)))
        }
        displays = list
    }

    func level(for id: CGDirectDisplayID) -> Double {
        if CGDisplayIsBuiltin(id) != 0, let get = getBrightness {
            var v: Float = 0
            if get(id, &v) == 0 { return Double(v) }
        }
        return 1 - (dimAmount[id] ?? 0)
    }

    func setLevel(_ value: Double, for id: CGDirectDisplayID) {
        let v = min(1, max(0, value))
        if CGDisplayIsBuiltin(id) != 0, let set = setBrightness, set(id, Float(v)) == 0 {
            updateCache(id, v)
            return
        }
        // Never dim to fully black — the user would have no way to see the slider.
        setOverlayDim(1 - v, for: id)
        updateCache(id, v)
    }

    func setAll(_ value: Double) {
        for d in displays { setLevel(value, for: d.id) }
    }

    func nudgeAll(by delta: Double) {
        for d in displays { setLevel(level(for: d.id) + delta, for: d.id) }
        Notifier.show("Brightness \(Int(level(for: displays.first?.id ?? 0) * 100))%", duration: 1)
    }

    func clearAllDimming() {
        for (id, _) in overlays { setOverlayDim(0, for: id) }
        refresh()
    }

    private func updateCache(_ id: CGDirectDisplayID, _ v: Double) {
        if let i = displays.firstIndex(where: { $0.id == id }) { displays[i].level = v }
    }

    // MARK: - Software dimming

    private func setOverlayDim(_ amount: Double, for id: CGDirectDisplayID) {
        let clamped = min(0.85, max(0, amount))
        dimAmount[id] = clamped

        guard clamped > 0.001 else {
            overlays.removeValue(forKey: id)?.close()
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }

        let window = overlays[id] ?? {
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                             backing: .buffered, defer: false, screen: screen)
            w.isReleasedWhenClosed = false
            w.level = .init(Int(CGShieldingWindowLevel()) - 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.isOpaque = false
            w.backgroundColor = .black
            w.orderFrontRegardless()
            overlays[id] = w
            return w
        }()
        window.setFrame(screen.frame, display: false)
        window.alphaValue = clamped
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
