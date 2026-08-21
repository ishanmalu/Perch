import AppKit
import SwiftUI

/// Keyboard-driven clipboard history window.
final class ClipboardPanelController {
    static let shared = ClipboardPanelController()

    private var panel: FloatingPanel?
    private var monitor: Any?
    private let model = ClipboardPanelModel()
    /// Whoever was frontmost before we stole focus — we hand it back before pasting.
    private var previousApp: NSRunningApplication?

    var isOpen: Bool { panel != nil }

    func toggle() { isOpen ? close() : open() }

    func open() {
        close()
        previousApp = NSWorkspace.shared.frontmostApplication
        model.query = ""
        model.selection = 0

        let p = FloatingPanel(size: CGSize(width: 660, height: 460)) { [model] in
            ClipboardView(model: model,
                          onPick: { [weak self] in self?.pick($0) },
                          onClose: { [weak self] in self?.close() })
        }
        p.showCentered()
        panel = p

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.close()
        panel = nil
    }

    private func pick(_ item: ClipItem) {
        close()
        let app = previousApp
        // Give focus back first, otherwise the synthesized ⌘V lands on Perch.
        app?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            ClipboardStore.shared.paste(item)
        }
    }

    private func move(by delta: Int, in list: [ClipItem]) {
        guard !list.isEmpty else { model.selection = 0; return }
        model.selection = (model.selection + delta + list.count) % list.count
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        let list = model.filtered

        // ⌘1…⌘9 grabs an entry directly.
        if event.modifierFlags.contains(.command), let ch = event.charactersIgnoringModifiers,
           let n = Int(ch), (1...9).contains(n) {
            if list.indices.contains(n - 1) { pick(list[n - 1]) }
            return true
        }

        switch Int(event.keyCode) {
        case 53: close(); return true
        case 36, 76:
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
        case 51:
            if event.modifierFlags.contains(.command) {          // ⌘⌫ deletes
                if list.indices.contains(model.selection) {
                    ClipboardStore.shared.delete(list[model.selection])
                    model.selection = max(0, model.selection - 1)
                }
            } else if !model.query.isEmpty {
                model.query.removeLast(); model.selection = 0
            }
            return true
        case 35 where event.modifierFlags.contains(.command):     // ⌘P pins
            if list.indices.contains(model.selection) { ClipboardStore.shared.togglePin(list[model.selection]) }
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

final class ClipboardPanelModel: ObservableObject {
    @Published var query = ""
    @Published var selection = 0

    var filtered: [ClipItem] {
        let all = ClipboardStore.shared.items
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.text.lowercased().contains(q) || ($0.sourceName ?? "").lowercased().contains(q) }
    }
}

private struct ClipboardView: View {
    @ObservedObject var model: ClipboardPanelModel
    @ObservedObject var store = ClipboardStore.shared
    var onPick: (ClipItem) -> Void
    var onClose: () -> Void

    var body: some View {
        let list = model.filtered
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(model.query.isEmpty ? "Search clipboard history" : model.query)
                    .foregroundStyle(model.query.isEmpty ? .secondary : .primary)
                Spacer()
                Text("\(list.count)").font(.caption).foregroundStyle(.tertiary)
            }
            .font(.system(size: 15))
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            if list.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(model.query.isEmpty ? "Nothing copied yet" : "No matches")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                HSplitView {
                    listColumn(list)
                    detailColumn(list)
                }
            }

            Divider()
            HStack(spacing: 14) {
                hint("↩", "paste"); hint("⌘1–9", "quick paste")
                hint("⌘P", "pin"); hint("⌘⌫", "delete"); hint("⎋", "close")
                Spacer()
                Button("Clear") { store.clearAll(keepPinned: true) }
                    .buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func listColumn(_ list: [ClipItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index, selected: index == model.selection)
                            .id(index)
                            .onTapGesture { onPick(item) }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selection) { _, new in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .frame(minWidth: 280, idealWidth: 320)
    }

    @ViewBuilder
    private func detailColumn(_ list: [ClipItem]) -> some View {
        let item = list.indices.contains(model.selection) ? list[model.selection] : nil
        VStack(alignment: .leading, spacing: 10) {
            if let item {
                if item.kind == .image, let img = store.image(for: item) {
                    Image(nsImage: img).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 220)
                } else {
                    ScrollView {
                        Text(item.text)
                            .font(.system(size: 12, design: item.kind == .text ? .default : .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                metadata(item)
            } else {
                Spacer()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(minWidth: 240)
    }

    private func metadata(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let src = item.sourceName { label("From", src) }
            label("Copied", item.date.formatted(date: .abbreviated, time: .shortened))
            if item.kind != .image { label("Length", "\(item.text.count) chars · \(item.text.split(separator: " ").count) words") }
            if item.kind == .color { label("Color", item.text) }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func label(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(k).frame(width: 52, alignment: .leading).foregroundStyle(.tertiary)
            Text(v).foregroundStyle(.secondary)
        }
    }

    private func row(_ item: ClipItem, index: Int, selected: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: item.symbol)
                .frame(width: 16).foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.preview.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1).font(.system(size: 12.5))
                Text(item.sourceName ?? "").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if item.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange) }
            if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            Text(what).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
