import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var statTimer: Timer?
    private var titleWatchers: Set<AnyCancellable> = []
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

        EnergySaver.shared.start()
        SystemMonitor.shared.start()
        NightMode.shared.start()
        ClipboardStore.shared.start()
        // Presets and workspaces listen for displays connecting from launch,
        // or auto-apply would only work after the panel had been opened.
        _ = DisplayPresets.shared
        _ = Workspaces.shared
        _ = DDC.shared
        WindowSnapping.shared.sync()
        MenuBarHider.shared.sync()
        SnippetStore.shared.sync()
        CalendarPeek.shared.start()
        // Deliberately not scanning disk targets here: it walks a dozen cache
        // trees and is only needed once the user opens Disk clean.
        Task { @MainActor in Updater.shared.checkInBackgroundIfDue() }

        // The title redraws only when what it shows changes: a new sample,
        // a focus tick, or a recording second. No always-on 1 s timer.
        SystemMonitor.shared.$snapshot
            .merge(with: FocusTimer.shared.objectWillChange.map { _ in SystemMonitor.shared.snapshot })
            .merge(with: EnergySaver.shared.$isActive.map { _ in SystemMonitor.shared.snapshot })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateStatusTitle() } }
            .store(in: &titleWatchers)
        ScreenRecorder.shared.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] recording in MainActor.assumeIsolated { self?.recordingClock(recording) } }
            .store(in: &titleWatchers)

        // `--settings <tab>` opens Settings on launch — for checking the window
        // without clicking through the menu bar.
        if let i = CommandLine.arguments.firstIndex(of: "--appearance"),
           CommandLine.arguments.indices.contains(i + 1) {
            NSApp.appearance = NSAppearance(named: CommandLine.arguments[i + 1] == "light" ? .aqua : .darkAqua)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--settings") {
            let name = CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : ""
            SettingsWindow.shared.show(tab: SettingsTab(rawValue: name) ?? .general)
        }

        // First launch gets a proper welcome with live permission rows. After
        // that, only mention a missing permission; the system prompt appears
        // when a feature actually needs it, so launching never nags.
        // Someone upgrading already has Accessibility granted; the welcome is
        // for new installs, so mark it seen instead of popping it up.
        if !Prefs.shared.onboardingDone, AX.isTrusted(prompt: false) {
            Prefs.shared.onboardingDone = true
        }
        if !Prefs.shared.onboardingDone {
            OnboardingWindow.shared.show()
        } else if !AX.isTrusted(prompt: false) {
            Notifier.needsPermission("Perch needs Accessibility access",
                                     "Window management, the switcher, and keyboard cleaning stay off until it is granted.",
                                     pane: "Privacy_Accessibility")
        }

        // Excluded apps (games, VMs, remote desktops) get their keys back
        // while they are in front.
        exclusionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
                AppDelegate.syncExclusions()
            }
        AppDelegate.syncExclusions()   // an excluded app may already be in front
    }

    /// A recording in progress has to finish writing before the process
    /// exits, so quitting waits for it rather than cutting the file off.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ScreenRecorder.shared.isRecording else { return .terminateNow }
        ScreenRecorder.shared.stop { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        BrightnessController.shared.clearAllDimming()
        XDRBoost.shared.stop()
        FocusTimer.shared.stop()
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

    /// The recording clock is the one title that needs a per-second tick.
    @MainActor private func recordingClock(_ on: Bool) {
        statTimer?.invalidate(); statTimer = nil
        if on {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusTitle() }
            }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            statTimer = t
        }
        updateStatusTitle()
    }

    @MainActor private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let s = SystemMonitor.shared.snapshot
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let text: String
        // Battery saver pauses these in the background; a frozen number would mislead.
        let saverHides = EnergySaver.shared.isActive && ["cpu", "mem", "net"].contains(Prefs.shared.menuBarStat)
        switch saverHides ? "none" : Prefs.shared.menuBarStat {
        case "cpu": text = String(format: "%.0f%%", s.cpuUsed)
        case "mem": text = String(format: "%.0f%%", s.memPercent)
        case "net": text = "↓\(SystemMonitor.rate(s.netIn).replacingOccurrences(of: "/s", with: ""))"
        case "bat": text = s.batteryPercent.map { "\($0)%" } ?? ""
        default: text = ""
        }
        // A recording or focus block outranks the chosen stat: it's the thing
        // with a deadline, and the icon is where people look for it.
        let title = NSMutableAttributedString()
        if let rec = ScreenRecorder.shared.elapsedLabel {
            title.append(NSAttributedString(string: " ● ", attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
            title.append(NSAttributedString(string: rec, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        } else if let focus = FocusTimer.shared.label {
            let resting = FocusTimer.shared.phase == .rest
            title.append(NSAttributedString(string: resting ? " ☕︎ " : " ◉ ",
                                            attributes: [.font: font, .foregroundColor: resting ? NSColor.systemGreen : NSColor.systemOrange]))
            title.append(NSAttributedString(string: focus + (FocusTimer.shared.paused != nil ? " ❚❚" : ""),
                                            attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        } else if !text.isEmpty {
            title.append(NSAttributedString(string: " " + text,
                                            attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        button.attributedTitle = title
    }

    @MainActor @objc private func statusClicked(_ sender: NSStatusBarButton) {
        // While recording, the icon is the stop button — the one place that's
        // always on screen and never in the recording's way.
        if ScreenRecorder.shared.isRecording, NSApp.currentEvent?.type != .rightMouseUp {
            ScreenRecorder.shared.stop()
            return
        }
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
            onQuit: { NSApp.terminate(nil) },
            onDismiss: { [weak self] in self?.popover.performClose(nil) }
        )
        let controller = NSHostingController(rootView: panel)
        // Let AppKit track the SwiftUI content size instead of being handed one
        // up front. Each tab is a different height, and a size set once goes
        // stale the moment the tab changes — which is what previously left the
        // popover clipping its own header off the top of the screen.
        controller.sizingOptions = [.preferredContentSize]
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
                item.keyEquivalent = spec.menuKeyEquivalent
                item.keyEquivalentModifierMask = spec.cocoaFlags.intersection([.command, .option, .control, .shift])
            }
            menu.addItem(item)
        }
        add("Clipboard History", "clipboard") { ClipboardPanelController.shared.toggle() }
        add("Window Switcher", "switcher") { WindowSwitcher.shared.toggleList() }
        add("Night Mode", "nightMode") { NightMode.shared.toggle() }
        menu.addItem(.separator())
        if FocusTimer.shared.phase == .idle {
            add("Start Focus (\(Prefs.shared.focusMinutes) min)", "focus") { FocusTimer.shared.startWork() }
        } else {
            add(FocusTimer.shared.paused == nil ? "Pause Focus" : "Resume Focus", "") { FocusTimer.shared.togglePause() }
            add("Stop Focus", "focus") { FocusTimer.shared.stop() }
        }
        if !DisplayPresets.shared.presets.isEmpty {
            let sub = NSMenu()
            for p in DisplayPresets.shared.presets {
                let item = NSMenuItem(title: p.name, action: #selector(runBlock(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = { DisplayPresets.shared.apply(p) } as () -> Void
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: "Display Preset", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        if !Workspaces.shared.all.isEmpty {
            let sub = NSMenu()
            for w in Workspaces.shared.all {
                let item = NSMenuItem(title: w.name, action: #selector(runBlock(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = { Workspaces.shared.restore(w) } as () -> Void
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        add("Screen Cleaning", "screenClean") { ScreenCleaner.shared.start() }
        add("Keyboard Cleaning", "keyboardClean") { InputCleaner.shared.start(.keyboard) }
        add("Trackpad Cleaning", "trackpadClean") { InputCleaner.shared.start(.trackpad) }
        add("Disk Clean…", "") { SettingsWindow.shared.show(tab: .disk) }
        menu.addItem(.separator())
        add("Check for Updates…", "") { Task { @MainActor in Updater.shared.check() } }
        add("Welcome & Permissions…", "") { OnboardingWindow.shared.show() }
        add("Settings…", "") { SettingsWindow.shared.show() }
        menu.items.last?.keyEquivalent = ","
        menu.items.last?.keyEquivalentModifierMask = .command
        menu.addItem(.separator())
        add("Quit Perch", "") { NSApp.terminate(nil) }
        menu.items.last?.keyEquivalent = "q"
        menu.items.last?.keyEquivalentModifierMask = .command

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // restore click-to-popover for the next left click
    }

    @objc private func runBlock(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    // MARK: - Hotkeys

    private var exclusionObserver: Any?

    /// Shortcuts released while an excluded app is frontmost.
    static let excludableHotkeys = ["switcher.altTab", "win.left", "win.right", "win.top", "win.bottom",
        "win.maximize", "win.center", "win.thirdL", "win.thirdC", "win.thirdR", "win.topLeft", "win.topRight",
        "win.bottomLeft", "win.bottomRight", "win.restore", "win.nextScreen", "win.prevScreen"]

    static func syncExclusions() {
        HotkeyManager.shared.setSuspended(excludableHotkeys, Prefs.shared.frontmostIsExcluded)
    }

    private func registerHotkeys() {
        let hk = HotkeyManager.shared
        hk.register("panel") { [weak self] in self?.togglePopover() }
        hk.register("clipboard") { ClipboardPanelController.shared.toggle() }
        hk.register("switcher") { WindowSwitcher.shared.toggleList() }
        hk.register("switcher.altTab") { WindowSwitcher.shared.holdToSwitch(modifier: .option) }
        // Carbon delivers hotkeys on the main thread, so this is safe.
        hk.register("screenshot") { MainActor.assumeIsolated { ScreenshotOverlay.shared.toggle() } }
        hk.register("nightMode") { NightMode.shared.toggle() }
        hk.register("screenClean") { ScreenCleaner.shared.toggle() }
        hk.register("keyboardClean") { InputCleaner.shared.toggle(.keyboard) }
        hk.register("trackpadClean") { InputCleaner.shared.toggle(.trackpad) }

        let windowBindings: [(String, WindowAction)] = [
            ("win.left", .left), ("win.right", .right), ("win.top", .top), ("win.bottom", .bottom),
            ("win.maximize", .maximize), ("win.center", .center),
            ("win.thirdL", .thirdLeft), ("win.thirdC", .thirdCenter), ("win.thirdR", .thirdRight),
            ("win.topLeft", .topLeft), ("win.topRight", .topRight),
            ("win.bottomLeft", .bottomLeft), ("win.bottomRight", .bottomRight),
        ]
        for (id, action) in windowBindings {
            hk.register(id) {
                guard !Prefs.shared.frontmostIsExcluded else { return }
                WindowManager.shared.apply(action)
            }
        }
        hk.register("win.restore") { WindowManager.shared.restore() }
        hk.register("win.nextScreen") { WindowManager.shared.moveToScreen(next: true) }
        hk.register("win.prevScreen") { WindowManager.shared.moveToScreen(next: false) }
        let step = BrightnessController.stepSize
        hk.register("brightness.up") { BrightnessController.shared.nudgeAll(by: step) }
        hk.register("brightness.down") { BrightnessController.shared.nudgeAll(by: -step) }
        hk.register("focus") {
            FocusTimer.shared.phase == .idle ? FocusTimer.shared.startWork() : FocusTimer.shared.stop()
        }
        hk.register("menuHider") { MenuBarHider.shared.setCollapsed(!MenuBarHider.shared.isCollapsed) }
    }
}
