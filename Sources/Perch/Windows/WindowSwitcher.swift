import AppKit
import SwiftUI
import Combine

struct SwitcherEntry: Identifiable {
    let id = UUID()
    let window: AXWindow
    let appName: String
    let icon: NSImage?
    let title: String
    let windowID: CGWindowID?
    var haystack: String { (appName + " " + title).lowercased() }
}

/// How the switcher presents windows.
enum SwitcherStyle: String, CaseIterable, Identifiable {
    case thumbnails, list
    var id: String { rawValue }
    var title: String { self == .thumbnails ? "Thumbnails" : "Titles" }
}

final class SwitcherModel: ObservableObject {
    @Published var entries: [SwitcherEntry] = []
    @Published var query = ""
    @Published var selection = 0
    @Published var style: SwitcherStyle = .thumbnails
    /// True while a modifier is held — letters act as commands, not search.
    @Published var holdMode = false

    var filtered: [SwitcherEntry] {
        guard !query.isEmpty else { return entries }
        let q = query.lowercased()
        // Subsequence match, so "vsc pkg" finds "VS Code — Package.swift".
        return entries.filter { entry in
            var idx = entry.haystack.startIndex
            for ch in q where ch != " " {
                guard let found = entry.haystack[idx...].firstIndex(of: ch) else { return false }
                idx = entry.haystack.index(after: found)
            }
            return true
        }
    }

    /// Fewer windows get bigger thumbnails, the way AltTab sizes itself.
    var columns: Int {
        let n = max(1, filtered.count)
        switch n {
        case 1...3: return n
        case 4...8: return 4
        case 9...15: return 5
        default: return 6
        }
    }
}

/// Window switcher with two presentations: a thumbnail grid on Alt-Tab, and an
/// optional compact title list on its own shortcut.
final class WindowSwitcher {
    static let shared = WindowSwitcher()

    private let model = SwitcherModel()
    private var panel: FloatingPanel?
    private var monitor: Any?
    /// Set when opened Alt-Tab style: the switcher stays up only while this
    /// modifier is held, and releasing it raises the highlighted window.
    private var holdModifier: NSEvent.ModifierFlags?
    private var resignObserver: NSObjectProtocol?
    private var openedAt = Date.distantPast

    var isOpen: Bool { panel != nil }

    // MARK: - Entry points

    /// Classic Alt-Tab: hold the modifier, tap Tab to walk the list, let go to
    /// switch. If the switcher is already up, another press just advances it.
    func holdToSwitch(modifier: NSEvent.ModifierFlags = .option) {
        if isOpen, holdModifier != nil {
            move(by: 1, in: model.filtered)
            return
        }
        holdModifier = modifier
        open(style: Prefs.shared.switcherStyle)
    }

    /// The compact title list, on its own shortcut and switchable off entirely.
    func toggleList() {
        guard Prefs.shared.listSwitcherEnabled else {
            Notifier.show("Title switcher is off",
                          "Turn it back on in Settings → Shortcuts.", duration: 3)
            return
        }
        if isOpen { close() } else { open(style: .list) }
    }

    func toggle() { isOpen ? close() : open(style: Prefs.shared.switcherStyle) }

    func open(style: SwitcherStyle) {
        guard AX.isTrusted(prompt: true) else {
            Notifier.show("Accessibility access needed",
                          "The window switcher reads window titles through Accessibility.")
            return
        }
        // close() clears holdModifier, but holdToSwitch has just set it — carry
        // it across so hold mode survives the reset.
        let hold = holdModifier
        close()
        holdModifier = hold

        model.style = style
        model.entries = WindowManager.shared.orderedWindows().map { w in
            let app = NSRunningApplication(processIdentifier: w.pid)
            return SwitcherEntry(window: w,
                                 appName: app?.localizedName ?? "Unknown",
                                 icon: app?.icon,
                                 title: w.title.isEmpty ? (app?.localizedName ?? "Untitled") : w.title,
                                 windowID: style == .thumbnails ? w.windowID() : nil)
        }
        model.query = ""
        model.holdMode = holdModifier != nil
        // Start on the second entry: the first is what you're already looking at.
        model.selection = model.entries.count > 1 ? 1 : 0

        if style == .thumbnails {
            WindowThumbnails.shared.capture(model.entries.compactMap(\.windowID))
        }

        let size = panelSize(for: style, count: model.entries.count)
        let p = FloatingPanel(size: size) { [model] in
            SwitcherView(model: model,
                         onPick: { [weak self] in self?.pick($0) },
                         onClose: { [weak self] in self?.close() })
        }
        p.showCentered()
        panel = p
        openedAt = Date()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }

        // The key monitor only sees events aimed at Perch, so if anything else
        // takes focus the switcher would sit there unclosable except by its own
        // close button. Dismiss when focus leaves, as a switcher should.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
                guard let self, self.isOpen else { return }
                // A panel can bounce key state while it is still being shown;
                // closing on that would make the switcher never appear.
                guard Date().timeIntervalSince(self.openedAt) > 0.6 else { return }
                self.close()
            }
    }

    private func panelSize(for style: SwitcherStyle, count: Int) -> CGSize {
        guard style == .thumbnails else { return CGSize(width: 620, height: 420) }
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let columns = model.columns
        let card: CGFloat = count <= 3 ? 260 : (count <= 8 ? 220 : 180)
        let width = min(visible.width * 0.92, CGFloat(columns) * (card + 12) + 28)
        let rows = ceil(Double(max(1, count)) / Double(columns))
        let height = min(visible.height * 0.85, CGFloat(rows) * (card * 0.78 + 12) + 108)
        return CGSize(width: max(420, width), height: max(240, height))
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        holdModifier = nil
        model.holdMode = false
        panel?.close()
        panel = nil
        WindowThumbnails.shared.clear()
    }

    private func pick(_ entry: SwitcherEntry) {
        close()
        entry.window.raise()
    }

    private func move(by delta: Int, in list: [SwitcherEntry]) {
        guard !list.isEmpty else { model.selection = 0; return }
        model.selection = (model.selection + delta + list.count) % list.count
    }

    // MARK: - Keyboard

    /// True when the event was a hold-modifier release that we acted on.
    private func handleHoldRelease(_ event: NSEvent) -> Bool {
        guard let holdModifier, event.type == .flagsChanged else { return false }
        guard !event.modifierFlags.contains(holdModifier) else { return false }
        let list = model.filtered
        if list.indices.contains(model.selection) {
            pick(list[model.selection])
        } else {
            close()
        }
        return true
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        if handleHoldRelease(event) { return true }
        guard event.type == .keyDown else { return false }

        let list = model.filtered
        let columns = model.style == .thumbnails ? model.columns : 1

        switch Int(event.keyCode) {
        case 53:                                  // Escape
            close(); return true
        case 36, 76:                              // Return / Enter
            if list.indices.contains(model.selection) { pick(list[model.selection]) }
            return true
        case 48:                                  // Tab / Shift-Tab
            move(by: event.modifierFlags.contains(.shift) ? -1 : 1, in: list)
            return true
        case 124: move(by: 1, in: list); return true         // →
        case 123: move(by: -1, in: list); return true        // ←
        case 125: move(by: columns, in: list); return true   // ↓
        case 126: move(by: -columns, in: list); return true  // ↑
        case 50 where holdModifier != nil:        // ` while holding — walk back
            move(by: -1, in: list); return true
        case 51:                                  // Delete
            if !model.query.isEmpty { model.query.removeLast(); model.selection = 0 }
            return true
        default:
            break
        }

        // While a modifier is held, plain letters are commands rather than
        // search text — there is no way to type a query one-handed anyway.
        if holdModifier != nil, let chars = event.charactersIgnoringModifiers?.lowercased() {
            guard list.indices.contains(model.selection) else { return true }
            let entry = list[model.selection]
            switch chars {
            case "w":
                entry.window.close()
                refreshAfterAction()
                return true
            case "m":
                entry.window.minimize()
                refreshAfterAction()
                return true
            case "q":
                NSRunningApplication(processIdentifier: entry.window.pid)?.terminate()
                refreshAfterAction()
                return true
            default:
                return true
            }
        }

        guard !event.modifierFlags.contains(.command),
              let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
              chars.allSatisfy({ !$0.isNewline }) else { return false }
        model.query += chars
        model.selection = 0
        return true
    }

    /// Drops the acted-on window from the list without closing the switcher.
    private func refreshAfterAction() {
        let removed = model.selection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isOpen else { return }
            self.model.entries = WindowManager.shared.orderedWindows().map { w in
                let app = NSRunningApplication(processIdentifier: w.pid)
                return SwitcherEntry(window: w,
                                     appName: app?.localizedName ?? "Unknown",
                                     icon: app?.icon,
                                     title: w.title.isEmpty ? (app?.localizedName ?? "Untitled") : w.title,
                                     windowID: self.model.style == .thumbnails ? w.windowID() : nil)
            }
            self.model.selection = min(removed, max(0, self.model.entries.count - 1))
            if self.model.entries.isEmpty { self.close() }
        }
    }
}

// MARK: - Views

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var thumbs = WindowThumbnails.shared
    var onPick: (SwitcherEntry) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.style == .thumbnails { grid } else { list }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text(model.query.isEmpty ? "Type to filter windows" : model.query)
                .font(.system(size: 14))
                .foregroundStyle(model.query.isEmpty ? .tertiary : .primary)
            Spacer()
            Text("\(model.filtered.count)")
                .font(Theme.Font.numeric)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.cardFill, in: Capsule())
            CloseButton(action: onClose)
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
    }

    // MARK: Thumbnail grid

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                        count: model.columns), spacing: 10) {
                    ForEach(Array(model.filtered.enumerated()), id: \.element.id) { index, entry in
                        card(entry, selected: index == model.selection)
                            .id(index)
                            .onTapGesture { onPick(entry) }
                    }
                }
                .padding(14)
            }
            .onChange(of: model.selection) { _, new in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func card(_ entry: SwitcherEntry, selected: Bool) -> some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07))
                if let id = entry.windowID, let shot = thumbs.image(for: id) {
                    Image(nsImage: shot)
                        .resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else if let icon = entry.icon {
                    // No preview available — the app icon still identifies it.
                    Image(nsImage: icon).resizable().scaledToFit()
                        .frame(width: 52, height: 52)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1.45, contentMode: .fit)
            .padding(6)

            HStack(spacing: 6) {
                if let icon = entry.icon {
                    Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.title).lineLimit(1).font(.system(size: 11.5, weight: .medium))
                    Text(entry.appName).lineLimit(1).font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .background(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }

    // MARK: Title list

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.filtered.enumerated()), id: \.element.id) { index, entry in
                        row(entry, selected: index == model.selection)
                            .id(index)
                            .onTapGesture { onPick(entry) }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selection) { _, new in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func row(_ entry: SwitcherEntry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            if let icon = entry.icon {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            } else {
                GlyphBadge(symbol: "macwindow", tint: .gray, size: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1).font(.system(size: 13, weight: .medium))
                Text(entry.appName).lineLimit(1).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if selected { KeyCap(text: "↩", emphasized: true) }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(selected ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↑↓←→", "move"); hint("⇥", "cycle"); hint("↩", "raise")
            if model.holdMode {
                hint("W", "close"); hint("M", "minimise"); hint("Q", "quit app")
            }
            hint("⎋", "close")
            Spacer()
            if model.style == .thumbnails && !thumbs.isAuthorized {
                Button("Enable previews") { thumbs.requestAuthorization() }
                    .buttonStyle(.borderless).font(.system(size: 10))
                    .help("Thumbnails need Screen Recording permission")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 4) {
            KeyCap(text: key)
            Text(what).font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
    }
}
