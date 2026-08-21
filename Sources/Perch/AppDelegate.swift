import AppKit
import SwiftUI
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var statTimer: Timer?
    /// Used when the menu bar item is hidden — behind a notch, or pushed off by
    /// a crowded menu bar. macOS gives apps no control over status item
    /// placement, so the panel needs a way to appear that does not depend on it.
    private var fallbackPanel: FloatingPanel?
    private var panelController: NSViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--regular` gives Perch a Dock icon and makes it visible to tooling
        // that can only address regular apps (screen automation, for one).
        // Normal launches stay accessory: menu bar only, no Dock icon.
        NSApp.setActivationPolicy(
            CommandLine.arguments.contains("--regular") ? .regular : .accessory)

        setupStatusItem()
        setupPopover()
        registerHotkeys()

        SystemMonitor.shared.start()
        NightMode.shared.start()
        ClipboardStore.shared.start()
        // Deliberately not scanning disk targets here: it walks a dozen cache
        // trees and is only needed once the user opens Disk clean.
        Task { @MainActor in Updater.shared.checkInBackgroundIfDue() }

        statTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }
        RunLoop.main.add(statTimer!, forMode: .common)

        // Only mention it; the system prompt appears when a feature actually
        // needs the permission, so launching never nags on its own.
        if !AX.isTrusted(prompt: false) {
            Notifier.show("Perch needs Accessibility access",
                          "Open Settings → General to grant it. Window management, the switcher, and keyboard cleaning stay off until then.",
                          duration: 6)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrightnessController.shared.clearAllDimming()
        NightMode.shared.shutdown()
        PreventSleep.shared.shutdown()
        InputCleaner.shared.stop(reason: "Perch quit")
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        if let icon = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Perch")
            ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Perch") {
            icon.isTemplate = true
            button.image = icon
            button.imagePosition = .imageLeading
        } else {
            // Never leave the item blank — a zero-width status item is invisible.
            button.title = "Perch"
        }
        button.action = #selector(statusClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let s = SystemMonitor.shared.snapshot
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let text: String
        switch Prefs.shared.menuBarStat {
        case "cpu": text = String(format: "%.0f%%", s.cpuUsed)
        case "mem": text = String(format: "%.0f%%", s.memPercent)
        case "net": text = "↓\(SystemMonitor.rate(s.netIn).replacingOccurrences(of: "/s", with: ""))"
        case "bat": text = s.batteryPercent.map { "\($0)%" } ?? ""
        default: text = ""
        }
        button.attributedTitle = NSAttributedString(
            string: text.isEmpty ? "" : " " + text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
    }

    /// The popover must never be taller than the screen it drops out of, or it
    /// runs off the top. Leave room for the menu bar and a little breathing space.
    private func makePanelController(for screen: NSScreen?) -> NSViewController {
        let available = (screen ?? NSScreen.main)?.visibleFrame.height ?? 700
        let panel = MainPanelView(
            maxHeight: max(320, available - 32),
            onOpenSettings: { [weak self] in
                self?.popover.performClose(nil)
                SettingsWindow.shared.show()
            },
            onQuit: { NSApp.terminate(nil) }
        )
        let controller = NSHostingController(rootView: panel)
        // The panel reports a height that does not change with the selected tab,
        // so the popover is sized once and never resizes underneath itself.
        controller.preferredContentSize = NSSize(width: 300, height: panel.panelHeight)
        return controller
    }

    func togglePopover() {
        if let panel = fallbackPanel {
            panel.close()
            fallbackPanel = nil
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        // Remember who was in front before we steal focus, so the window tiles
        // act on the user's window and not on Perch's own panel.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            WindowManager.shared.panelTargetPID = front?.processIdentifier
        }
        BrightnessController.shared.refresh()

        guard let button = statusItem.button, statusItemIsReachable(button) else {
            showFallbackPanel()
            return
        }
        popover.contentViewController = makePanelController(for: button.window?.screen)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// A hidden status item still has a button, but its window sits off the
    /// visible area — anchoring a popover to it puts the panel where nobody
    /// can see it.
    private func statusItemIsReachable(_ button: NSStatusBarButton) -> Bool {
        guard statusItem.isVisible, let window = button.window else { return false }
        let frame = window.frame
        guard frame.width > 1, frame.height > 1 else { return false }
        guard let screen = window.screen ?? NSScreen.main else { return false }
        // Require the item to actually sit inside the screen it claims.
        return screen.frame.intersects(frame) && frame.minX >= screen.frame.minX - 1
    }

    private func showFallbackPanel() {
        let controller = makePanelController(for: NSScreen.main)
        let fitting = controller.view.fittingSize
        let panel = FloatingPanel(size: CGSize(width: max(348, fitting.width),
                                               height: max(320, fitting.height)),
                                  hosting: controller.view)
        panelController = controller   // keep the hosting controller alive
        panel.showTopTrailing()
        fallbackPanel = panel

        Notifier.show("Perch's menu bar icon is hidden",
                      "Your menu bar is full or the notch is covering it. Showing the panel here instead — ⌃⌥Space opens it any time.",
                      duration: 6)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ key: String, _ block: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runBlock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = block
            if let spec = Prefs.shared.hotkey(key) {
                item.keyEquivalent = ""
                item.toolTip = spec.display
            }
            menu.addItem(item)
        }
        add("Clipboard History", "clipboard") { ClipboardPanelController.shared.toggle() }
        add("Window Switcher", "switcher") { WindowSwitcher.shared.toggle() }
        add("Night Mode", "nightMode") { NightMode.shared.toggle() }
        add("Screen Cleaning", "screenClean") { ScreenCleaner.shared.start() }
        add("Keyboard Cleaning", "keyboardClean") { InputCleaner.shared.start(.keyboard) }
        add("Trackpad Cleaning", "trackpadClean") { InputCleaner.shared.start(.trackpad) }
        menu.addItem(.separator())
        add("Check for Updates…", "") { Task { @MainActor in Updater.shared.check() } }
        add("Disk Clean…", "") { SettingsWindow.shared.show(tab: .disk) }
        add("Settings…", "") { SettingsWindow.shared.show() }
        menu.addItem(.separator())
        add("Quit Perch", "") { NSApp.terminate(nil) }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // restore click-to-popover for the next left click
    }

    @objc private func runBlock(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        let hk = HotkeyManager.shared
        hk.register("panel") { [weak self] in self?.togglePopover() }
        hk.register("clipboard") { ClipboardPanelController.shared.toggle() }
        hk.register("switcher") { WindowSwitcher.shared.toggle() }
        hk.register("switcher.altTab") { WindowSwitcher.shared.holdToSwitch(modifier: .option) }
        hk.register("nightMode") { NightMode.shared.toggle() }
        hk.register("screenClean") { ScreenCleaner.shared.toggle() }
        hk.register("keyboardClean") { InputCleaner.shared.toggle(.keyboard) }
        hk.register("trackpadClean") { InputCleaner.shared.toggle(.trackpad) }

        let windowBindings: [(String, WindowAction)] = [
            ("win.left", .left), ("win.right", .right), ("win.top", .top), ("win.bottom", .bottom),
            ("win.maximize", .maximize), ("win.center", .center),
            ("win.thirdL", .thirdLeft), ("win.thirdC", .thirdCenter), ("win.thirdR", .thirdRight),
        ]
        for (id, action) in windowBindings {
            hk.register(id) { WindowManager.shared.apply(action) }
        }
        hk.register("win.restore") { WindowManager.shared.restore() }
        hk.register("win.nextScreen") { WindowManager.shared.moveToScreen(next: true) }
        hk.register("win.prevScreen") { WindowManager.shared.moveToScreen(next: false) }
    }
}
