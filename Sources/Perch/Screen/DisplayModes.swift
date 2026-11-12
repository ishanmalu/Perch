import AppKit
import Combine

/// Resolution and refresh-rate switching per display, BetterDisplay-style.
///
/// Everything goes through public CoreGraphics. The one trick is
/// `kCGDisplayShowDuplicateLowResolutionModes`: without it macOS hides the
/// HiDPI ("looks like") variants and only lists raw pixel modes, which is why
/// System Settings and the plain API disagree about what a display can do.
///
/// A switch is applied permanently and then has to be confirmed within
/// `confirmSeconds`, otherwise it reverts — a mode the panel claims but can't
/// actually show would otherwise leave the user staring at a black screen.
final class DisplayModeController: ObservableObject {
    static let shared = DisplayModeController()
    static let confirmSeconds = 15

    /// A plain snapshot of a CGDisplayMode, so the grouping logic below can be
    /// exercised in `--selftest` without a display attached.
    struct Mode: Hashable, Codable {
        var width: Int          // points ("looks like")
        var height: Int
        var pixelWidth: Int
        var pixelHeight: Int
        var refresh: Double     // Hz; 0 when the display doesn't report one
        var isNative = false

        var isHiDPI: Bool { pixelWidth > width }
        var resolution: Resolution { .init(width: width, height: height, hiDPI: isHiDPI) }
    }

    struct Resolution: Hashable, Identifiable {
        var width: Int
        var height: Int
        var hiDPI: Bool
        var id: String { "\(width)x\(height)\(hiDPI ? "@2x" : "")" }
        var label: String { "\(width) × \(height)" }
    }

    struct Display: Identifiable {
        var id: CGDirectDisplayID
        var name: String
        var isBuiltin: Bool
        var current: Mode?
        var modes: [Mode]
        var resolutions: [Resolution] { DisplayModeController.resolutions(in: modes, keeping: current?.resolution) }
        var nativeResolution: Resolution? { DisplayModeController.nativeResolution(in: modes) }
        var refreshRates: [Double] {
            guard let current else { return [] }
            return DisplayModeController.refreshRates(in: modes, for: current.resolution)
        }
    }

    @Published private(set) var displays: [Display] = []

    private var cgModes: [CGDirectDisplayID: [Mode: CGDisplayMode]] = [:]

    init() {
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Reading

    func refresh() {
        var list: [Display] = []
        cgModes = [:]
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let all = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
            var table: [Mode: CGDisplayMode] = [:]
            for m in all where m.isUsableForDesktopGUI() {
                let mode = Self.snapshot(m)
                // Several CG modes can share a snapshot (differing only in bit
                // depth); the first one listed is the one macOS prefers.
                if table[mode] == nil { table[mode] = m }
            }
            cgModes[id] = table
            let current = CGDisplayCopyDisplayMode(id).map(Self.snapshot)
            list.append(Display(id: id, name: screen.localizedName,
                                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                                current: current, modes: Array(table.keys)))
        }
        displays = list
    }

    private static func snapshot(_ m: CGDisplayMode) -> Mode {
        // 0x0200_0000 is kDisplayModeNativeFlag from IOGraphicsTypes.
        Mode(width: m.width, height: m.height,
             pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight,
             refresh: (m.refreshRate * 100).rounded() / 100,
             isNative: m.ioFlags & 0x0200_0000 != 0)
    }

    // MARK: - Grouping (pure, self-tested)

    /// Distinct "looks like" sizes, largest first. When a size exists both
    /// HiDPI and not, both are listed — the HiDPI one first, since that's
    /// the sharp one people almost always want.
    ///
    /// Sizes whose best refresh rate is under half the display's top rate are
    /// left out. A 1080p/144 Hz monitor also advertises a "1920 × 1080 HiDPI"
    /// mode that only runs at 30 Hz (rendered at 4K, scaled down): it would sort
    /// to the top of the list and look like an upgrade, when it's a trap.
    /// `keeping` is the mode the display is in now: it always stays listed,
    /// even if it would be filtered, so the picker can show where you are.
    static func resolutions(in modes: [Mode], keeping current: Resolution? = nil) -> [Resolution] {
        let top = modes.map(\.refresh).max() ?? 0
        let best = Dictionary(grouping: modes, by: \.resolution).mapValues { $0.map(\.refresh).max() ?? 0 }
        let usable = best.filter { top == 0 || $0.value == 0 || $0.value >= top / 2 || $0.key == current }.keys
        return usable.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.hiDPI && !$1.hiDPI
        }
    }

    /// The one resolution to label "native". macOS flags every mode that
    /// drives the panel's full pixel grid — both the raw low-res mode and the
    /// pixel-doubled HiDPI one — so prefer HiDPI, the sharp one people mean.
    static func nativeResolution(in modes: [Mode]) -> Resolution? {
        let flagged = Set(modes.filter(\.isNative).map(\.resolution))
        return flagged.first(where: \.hiDPI) ?? flagged.max { $0.width < $1.width }
    }

    static func refreshRates(in modes: [Mode], for res: Resolution) -> [Double] {
        Set(modes.filter { $0.resolution == res }.map(\.refresh)).sorted(by: >)
    }

    /// The mode to switch to for a resolution and (optionally) a rate. Keeps
    /// the requested rate when that resolution offers it, otherwise takes the
    /// fastest; among equal candidates prefers the one using the most pixels.
    static func best(in modes: [Mode], resolution: Resolution, refresh: Double?) -> Mode? {
        let candidates = modes.filter { $0.resolution == resolution }
        let rate = refresh.flatMap { r in candidates.contains { $0.refresh == r } ? r : nil }
            ?? candidates.map(\.refresh).max()
        return candidates
            .filter { $0.refresh == rate }
            .max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
    }

    static func rateLabel(_ hz: Double) -> String {
        if hz == 0 { return "Default" }
        return hz == hz.rounded() ? "\(Int(hz)) Hz" : String(format: "%.2f Hz", hz)
    }

    // MARK: - Switching

    func setResolution(_ res: Resolution, for id: CGDirectDisplayID) {
        guard let d = displays.first(where: { $0.id == id }),
              let target = Self.best(in: d.modes, resolution: res, refresh: d.current?.refresh) else { return }
        apply(target, to: d)
    }

    func setRefresh(_ hz: Double, for id: CGDirectDisplayID) {
        guard let d = displays.first(where: { $0.id == id }), let cur = d.current,
              let target = Self.best(in: d.modes, resolution: cur.resolution, refresh: hz) else { return }
        apply(target, to: d)
    }

    /// Switches without the keep-or-revert prompt. Presets use this: the user
    /// built them from modes that were already showing, so they're known good.
    @discardableResult
    func applyWithoutConfirm(_ target: Mode, to id: CGDirectDisplayID) -> Bool {
        guard let d = displays.first(where: { $0.id == id }) else { return false }
        guard target != d.current else { return true }
        guard let mode = cgModes[id]?[target], set(mode, on: id) else { return false }
        refresh()
        return true
    }

    private func apply(_ target: Mode, to d: Display) {
        guard target != d.current, let mode = cgModes[d.id]?[target] else { return }
        let previous = CGDisplayCopyDisplayMode(d.id)
        guard set(mode, on: d.id) else {
            Notifier.show("Couldn't switch \(d.name)", "macOS refused that mode.")
            return
        }
        refresh()
        // Let the display settle before asking, or the alert lands mid-flash.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if !self.confirmKeep(d.name), let previous {
                self.set(previous, on: d.id)
                self.refresh()
            }
        }
    }

    @discardableResult
    private func set(_ mode: CGDisplayMode, on id: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    /// "Keep this display mode?" with a countdown that reverts on its own.
    private func confirmKeep(_ name: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Keep this display mode?"
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Revert")
        alert.window.level = .floating

        var remaining = Self.confirmSeconds
        let update = { alert.informativeText = "\(name) reverts in \(remaining) s." }
        update()
        let timer = Timer(timeInterval: 1, repeats: true) { t in
            remaining -= 1
            update()
            if remaining <= 0 { t.invalidate(); NSApp.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let response = alert.runModal()
        timer.invalidate()
        return response == .alertFirstButtonReturn
    }
}
