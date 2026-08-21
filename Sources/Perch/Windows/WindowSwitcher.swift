import AppKit
import SwiftUI
import Combine

struct SwitcherEntry: Identifiable {
    let id = UUID()
    let window: AXWindow
    let appName: String
    let icon: NSImage?
    let title: String
    var haystack: String { (appName + " " + title).lowercased() }
}

final class SwitcherModel: ObservableObject {
    @Published var entries: [SwitcherEntry] = []
    @Published var query = ""
    @Published var selection = 0

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
}

/// A Spotlight-style list of every open window, filterable by typing.
final class WindowSwitcher {
    static let shared = WindowSwitcher()

    private let model = SwitcherModel()
    private var panel: FloatingPanel?
    private var monitor: Any?
    /// Set when opened Alt-Tab style: the switcher stays up only while this
    /// modifier is held, and releasing it raises the highlighted window.
    private var holdModifier: NSEvent.ModifierFlags?

    var isOpen: Bool { panel != nil }

    func toggle() { isOpen ? close() : open() }

    /// Classic Alt-Tab: hold the modifier, tap Tab to walk the list, let go to
    /// switch. If the switcher is already up, another press just advances it.
    func holdToSwitch(modifier: NSEvent.ModifierFlags = .option) {
        if isOpen, holdModifier != nil {
            move(by: 1, in: model.filtered)
            return
        }
        holdModifier = modifier
        open()
    }

    func open() {
        guard AX.isTrusted(prompt: true) else {
            Notifier.show("Accessibility access needed", "The window switcher reads window titles through Accessibility.")
            return
        }
        close()

        model.entries = WindowManager.shared.orderedWindows().map { w in
            let app = NSRunningApplication(processIdentifier: w.pid)
            return SwitcherEntry(window: w,
                                 appName: app?.localizedName ?? "Unknown",
                                 icon: app?.icon,
                                 title: w.title.isEmpty ? (app?.localizedName ?? "Untitled") : w.title)
        }
        model.query = ""
        // Start on the second entry: the first is what you're already looking at.
        model.selection = model.entries.count > 1 ? 1 : 0

        let p = FloatingPanel(size: CGSize(width: 620, height: 420)) { [model] in
            SwitcherView(model: model,
                         onPick: { [weak self] in self?.pick($0) },
                         onClose: { [weak self] in self?.close() })
        }
        p.showCentered()
        panel = p

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

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

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        holdModifier = nil
        panel?.close()
        panel = nil
    }

    private func pick(_ entry: SwitcherEntry) {
        close()
        entry.window.raise()
    }

    private func move(by delta: Int, in list: [SwitcherEntry]) {
        guard !list.isEmpty else { model.selection = 0; return }
        model.selection = (model.selection + delta + list.count) % list.count
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        if handleHoldRelease(event) { return true }
        guard event.type == .keyDown else { return false }
        let list = model.filtered

        switch Int(event.keyCode) {
        case 53:                                  // Escape
            close(); return true
        case 36, 76:                              // Return / Enter
            if list.indices.contains(model.selection) { pick(list[model.selection]) }
            return true
        case 125:                                 // Down
            move(by: 1, in: list)
            return true
        case 126:                                 // Up
            move(by: -1, in: list)
            return true
        case 48:                                  // Tab / Shift-Tab
            move(by: event.modifierFlags.contains(.shift) ? -1 : 1, in: list)
            return true
        case 50 where holdModifier != nil:        // ` while holding — walk backwards
            move(by: -1, in: list)
            return true
        case 51:                                  // Delete
            if !model.query.isEmpty { model.query.removeLast(); model.selection = 0 }
            return true
        default:
            guard !event.modifierFlags.contains(.command),
                  let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
                  chars.allSatisfy({ !$0.isNewline }) else { return false }
            model.query += chars
            model.selection = 0
            return true
        }
    }
}

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    var onPick: (SwitcherEntry) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
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
            Divider()

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

            Divider()
            HStack(spacing: 12) {
                hint("↑↓", "move"); hint("⇥", "cycle"); hint("↩", "raise"); hint("⎋", "close")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 4) {
            KeyCap(text: key)
            Text(what).font(.system(size: 9.5)).foregroundStyle(.tertiary)
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
            if selected {
                KeyCap(text: "↩", emphasized: true)
            }
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
}
