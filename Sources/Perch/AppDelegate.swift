import AppKit
import SwiftUI
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var statTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        registerHotkeys()

        SystemMonitor.shared.start()
        ClipboardStore.shared.start()
        DiskCleaner.shared.scan()

        statTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }
        RunLoop.main.add(statTimer!, forMode: .common)

        if !AX.isTrusted(prompt: false) {
            Notifier.show("Perch needs Accessibility access",
                          "System Settings → Privacy & Security → Accessibility. Window management and the switcher stay disabled until then.",
                          duration: 8)
            _ = AX.isTrusted(prompt: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrightnessController.shared.clearAllDimming()
        KeyboardCleaner.shared.stop(reason: "Perch quit")
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Perch")
            ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Perch")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
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
        popover.contentViewController = NSHostingController(rootView: MainPanelView(
            onOpenSettings: { [weak self] in
                self?.popover.performClose(nil)
                SettingsWindow.shared.show()
            },
            onQuit: { NSApp.terminate(nil) }
        ))
    }

    func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            BrightnessController.shared.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
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
        add("Screen Cleaning", "screenClean") { ScreenCleaner.shared.start() }
        add("Keyboard Cleaning", "keyboardClean") { KeyboardCleaner.shared.start() }
        menu.addItem(.separator())
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
        hk.register("screenClean") { ScreenCleaner.shared.toggle() }
        hk.register("keyboardClean") { KeyboardCleaner.shared.toggle() }

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
