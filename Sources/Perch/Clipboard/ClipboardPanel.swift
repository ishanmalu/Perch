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

        let p = FloatingPanel(size: CGSize(width: 420, height: 460)) { [model] in
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
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(model.query.isEmpty ? "Select a clip to paste" : model.query)
                    .font(.system(size: 13))
                    .foregroundStyle(model.query.isEmpty ? .tertiary : .primary)
                Spacer()
                Text("\(list.count)")
                    .font(Theme.Font.numeric)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.cardFill, in: Capsule())
                CloseButton(action: onClose)
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            Divider()

            if list.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(model.query.isEmpty ? "Nothing copied yet" : "No matches")
                        .font(Theme.Font.body).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                                row(item, index: index, selected: index == model.selection)
                                    .id(index)
                                    .onTapGesture { onPick(item) }
                            }
                        }
                        .padding(5)
                    }
                    .onChange(of: model.selection) { _, new in
                        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
                    }
                }
            }

            Divider()
            HStack(spacing: 11) {
                hint("↩", "paste"); hint("⌘1–9", "quick"); hint("⌘P", "pin"); hint("⌘⌫", "delete")
                Spacer()
                Button("Clear") { store.clearAll(keepPinned: true) }
                    .buttonStyle(.borderless).font(Theme.Font.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    private func row(_ item: ClipItem, index: Int, selected: Bool) -> some View {
        HStack(spacing: 9) {
            if item.kind == .image, let img = store.image(for: item) {
                Image(nsImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: item.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(tint(for: item.kind))
                    .frame(width: 20)
            }

            Text(item.preview.replacingOccurrences(of: "\n", with: " "))
                .lineLimit(1)
                .font(.system(size: 12.5))

            Spacer(minLength: 6)

            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 8.5)).foregroundStyle(.orange)
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(selected ? .secondary : .tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.85) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .contentShape(Rectangle())
    }

    private func tint(for kind: ClipItem.Kind) -> Color {
        switch kind {
        case .text: return .blue
        case .url: return .teal
        case .color: return .pink
        case .image: return .purple
        case .file: return .orange
        }
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 4) {
            KeyCap(text: key)
            Text(what).font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
    }
}
