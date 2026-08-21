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

    var isOpen: Bool { panel != nil }

    func toggle() { isOpen ? close() : open() }

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
            SwitcherView(model: model, onPick: { [weak self] in self?.pick($0) })
        }
        p.showCentered()
        panel = p

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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
        guard isOpen, event.type == .keyDown else { return false }
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "macwindow.on.rectangle").foregroundStyle(.secondary)
                Text(model.query.isEmpty ? "Type to filter windows" : model.query)
                    .font(.system(size: 15))
                    .foregroundStyle(model.query.isEmpty ? .secondary : .primary)
                Spacer()
                Text("\(model.filtered.count)").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
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
        }
    }

    private func row(_ entry: SwitcherEntry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            if let icon = entry.icon {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1).font(.system(size: 13, weight: .medium))
                Text(entry.appName).lineLimit(1).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
