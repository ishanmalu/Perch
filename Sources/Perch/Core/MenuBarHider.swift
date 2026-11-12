import AppKit
import Combine

/// Tucks rarely used menu bar icons out of sight, Bartender/Ice-style.
///
/// Perch adds two items to the right of whatever you want hidden: a small
/// chevron that toggles, and an invisible divider. Collapsing stretches the
/// divider to 10,000 points wide, which pushes every item to its left off
/// the screen; expanding shrinks it back. You choose what hides by ⌘-dragging
/// icons to the left of the divider — macOS remembers those positions.
///
/// No private API and no screen recording; the cost is that it can't hide
/// items Apple pins to the far right (Control Centre, clock).
final class MenuBarHider: ObservableObject {
    static let shared = MenuBarHider()

    @Published private(set) var isCollapsed = false

    private var toggle: NSStatusItem?
    private var divider: NSStatusItem?
    private var autoCollapse: DispatchWorkItem?
    private static let expandedWidth: CGFloat = 10
    private static let collapsedWidth: CGFloat = 10_000

    var isEnabled: Bool { toggle != nil }

    func sync() { Prefs.shared.menuHiderEnabled ? enable() : disable() }

    func enable() {
        guard toggle == nil else { return }
        // Status items stack leftwards in creation order, so the toggle is
        // made first and the divider lands immediately to its left — what
        // the divider pushes away is everything left of *it*, never the toggle.
        let t = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        t.autosaveName = "PerchMenuToggle"
        t.button?.target = self
        t.button?.action = #selector(clicked)
        toggle = t

        let d = NSStatusBar.system.statusItem(withLength: Self.expandedWidth)
        d.autosaveName = "PerchMenuDivider"
        if let b = d.button {
            b.image = NSImage(systemSymbolName: "poweron", accessibilityDescription: "Hidden icons start here")
            b.image?.isTemplate = true
            b.appearsDisabled = true
            b.alphaValue = 0.45
        }
        divider = d
        setCollapsed(Prefs.shared.menuHiderStartCollapsed)
    }

    func disable() {
        autoCollapse?.cancel()
        [toggle, divider].compactMap { $0 }.forEach(NSStatusBar.system.removeStatusItem)
        toggle = nil; divider = nil
        isCollapsed = false
    }

    @objc private func clicked() { setCollapsed(!isCollapsed) }

    func setCollapsed(_ collapse: Bool) {
        guard let divider, let toggle else { return }
        autoCollapse?.cancel()
        isCollapsed = collapse
        divider.length = collapse ? Self.collapsedWidth : Self.expandedWidth
        // While collapsed the divider has no business being seen or clicked.
        divider.button?.isHidden = collapse
        toggle.button?.image = NSImage(systemSymbolName: collapse ? "chevron.left" : "chevron.right",
                                       accessibilityDescription: collapse ? "Show hidden icons" : "Hide icons")
        toggle.button?.image?.isTemplate = true
        toggle.button?.toolTip = collapse
            ? "Show hidden menu bar icons"
            : "Hide icons left of the divider  (⌘-drag icons to choose)"

        let delay = Prefs.shared.menuHiderAutoCollapse
        if !collapse, delay > 0 {
            let work = DispatchWorkItem { [weak self] in self?.setCollapsed(true) }
            autoCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
        }
    }
}
