import AppKit
import Combine

/// A stable name for a physical display. CGDirectDisplayIDs are reassigned
/// across reconnects, so presets key on vendor, model and serial instead —
/// the same triple macOS itself uses to remember a monitor's arrangement.
struct DisplayKey: Codable, Hashable {
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32

    init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor; self.model = model; self.serial = serial
    }

    init(_ id: CGDirectDisplayID) {
        self.init(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                  serial: CGDisplaySerialNumber(id))
    }

    /// The connected set of displays, order-independent — what decides which
    /// preset or workspace matches "this desk".
    static var connected: Set<DisplayKey> {
        Set(NSScreen.screens.compactMap(\.displayID).map(DisplayKey.init))
    }

    static func id(for key: DisplayKey) -> CGDirectDisplayID? {
        NSScreen.screens.compactMap(\.displayID).first { DisplayKey($0) == key }
    }
}

/// A saved display setup: the mode, brightness and position of every display
/// that was connected when it was saved.
struct DisplayPreset: Codable, Identifiable, Equatable {
    struct Entry: Codable, Equatable {
        var key: DisplayKey
        var name: String
        var mode: DisplayModeController.Mode?
        var brightness: Double
        /// Global origin in CG coordinates; (0, 0) marks the main display.
        var origin: CGPoint
    }

    var id = UUID()
    var name: String
    var entries: [Entry]
    /// Apply automatically when exactly this set of displays connects.
    var autoApply = false

    var keys: Set<DisplayKey> { Set(entries.map(\.key)) }

    /// Pure, so the matching rule can be checked without hardware: a preset
    /// fits only when the same displays are connected, no more and no fewer.
    static func autoMatch(_ presets: [DisplayPreset], connected: Set<DisplayKey>) -> DisplayPreset? {
        presets.first { $0.autoApply && $0.keys == connected }
    }
}

final class DisplayPresets: ObservableObject {
    static let shared = DisplayPresets()

    @Published var presets: [DisplayPreset] = [] { didSet { save() } }

    private let storeKey = "display.presets"
    private var lastConnected: Set<DisplayKey> = []
    private var pendingAuto: DispatchWorkItem?

    init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let v = try? JSONDecoder().decode([DisplayPreset].self, from: data) {
            presets = v
        }
        lastConnected = DisplayKey.connected
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: storeKey)
    }

    // MARK: - Capture / apply

    func saveCurrent(named name: String) {
        DisplayModeController.shared.refresh()
        let entries = NSScreen.screens.compactMap { screen -> DisplayPreset.Entry? in
            guard let id = screen.displayID else { return nil }
            let bounds = CGDisplayBounds(id)
            return .init(key: DisplayKey(id), name: screen.localizedName,
                         mode: DisplayModeController.shared.displays.first { $0.id == id }?.current,
                         brightness: BrightnessController.shared.level(for: id),
                         origin: bounds.origin)
        }
        presets.append(DisplayPreset(name: name, entries: entries))
        Notifier.show("Saved “\(name)”", "\(entries.count) display\(entries.count == 1 ? "" : "s")", duration: 2)
    }

    func apply(_ preset: DisplayPreset, quiet: Bool = false) {
        var missing = 0
        for e in preset.entries {
            guard let id = DisplayKey.id(for: e.key) else { missing += 1; continue }
            if let mode = e.mode { DisplayModeController.shared.applyWithoutConfirm(mode, to: id) }
            BrightnessController.shared.setLevel(e.brightness, for: id)
        }
        // Arrangement last: a mode change resizes the display, which would
        // otherwise shift the origins we are about to set.
        let placements = preset.entries.compactMap { e in DisplayKey.id(for: e.key).map { ($0, e.origin) } }
        if placements.count > 1 { DisplayArrangement.setOrigins(placements) }
        BrightnessController.shared.refresh()
        if !quiet || missing > 0 {
            Notifier.show("Applied “\(preset.name)”",
                          missing > 0 ? "\(missing) display\(missing == 1 ? " isn't" : "s aren't") connected." : nil,
                          duration: 2)
        }
    }

    func delete(_ preset: DisplayPreset) { presets.removeAll { $0.id == preset.id } }

    func setAutoApply(_ on: Bool, for preset: DisplayPreset) {
        guard let i = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[i].autoApply = on
    }

    /// Displays wake in stages; settle for a moment so a preset isn't applied
    /// to a monitor that hasn't finished negotiating its mode yet.
    private func screensChanged() {
        let now = DisplayKey.connected
        guard now != lastConnected else { return }
        lastConnected = now
        pendingAuto?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let match = DisplayPreset.autoMatch(self.presets, connected: DisplayKey.connected)
            else { return }
            self.apply(match, quiet: true)
            Notifier.show("Display preset “\(match.name)”", "Applied because this setup connected.", duration: 2.5)
        }
        pendingAuto = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

/// Main display and placement, done through the same CG configuration
/// transaction System Settings uses.
enum DisplayArrangement {
    enum Side: String, CaseIterable, Identifiable {
        case left, right, above, below
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// Makes `id` the main display (menu bar and Dock move with it) by
    /// shifting every display so it sits at the origin.
    @discardableResult
    static func makeMain(_ id: CGDirectDisplayID) -> Bool {
        let shift = CGDisplayBounds(id).origin
        let all = NSScreen.screens.compactMap(\.displayID)
        return setOrigins(all.map { d in
            let o = CGDisplayBounds(d).origin
            return (d, CGPoint(x: o.x - shift.x, y: o.y - shift.y))
        })
    }

    /// Puts `id` flush against one edge of the main display, centred on it.
    @discardableResult
    static func place(_ id: CGDirectDisplayID, _ side: Side) -> Bool {
        let main = CGMainDisplayID()
        guard id != main else { return false }
        let target = origin(for: CGDisplayBounds(id).size, beside: CGDisplayBounds(main), side)
        return setOrigins([(id, target)])
    }

    /// Pure geometry, self-tested.
    static func origin(for size: CGSize, beside main: CGRect, _ side: Side) -> CGPoint {
        switch side {
        case .left:  return CGPoint(x: main.minX - size.width, y: (main.midY - size.height / 2).rounded())
        case .right: return CGPoint(x: main.maxX, y: (main.midY - size.height / 2).rounded())
        case .above: return CGPoint(x: (main.midX - size.width / 2).rounded(), y: main.minY - size.height)
        case .below: return CGPoint(x: (main.midX - size.width / 2).rounded(), y: main.maxY)
        }
    }

    @discardableResult
    static func setOrigins(_ placements: [(CGDirectDisplayID, CGPoint)]) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        for (id, o) in placements {
            if CGConfigureDisplayOrigin(config, id, Int32(o.x), Int32(o.y)) != .success {
                CGCancelDisplayConfiguration(config)
                return false
            }
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    /// Mirrors every other display onto the main one, or stops mirroring.
    @discardableResult
    static func setMirroring(_ on: Bool) -> Bool {
        let main = CGMainDisplayID()
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        for id in ids.prefix(Int(count)) where id != main {
            CGConfigureDisplayMirrorOfDisplay(config, id, on ? main : kCGNullDirectDisplay)
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    static var isMirroring: Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
    }
}
