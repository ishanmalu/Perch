import AppKit
import SwiftUI

/// Choosing which window goes in which pane, instead of letting stacking order
/// decide it.
///
/// Tiling by z-order is right when the windows you want are already the ones in
/// front. It is wrong the rest of the time, and there is no way to say so — you
/// tile, then drag things back. This asks first: the frontmost window fills the
/// pane you clicked, and every other pane gets a menu of what is open.
@MainActor
final class LayoutAssignController {
    static let shared = LayoutAssignController()

    private var panel: FloatingPanel?
    private var monitor: Any?

    var isOpen: Bool { panel != nil }

    /// Opens the picker for `layout`. Falls back to tiling by stacking order
    /// when there is nothing to choose between.
    func begin(_ layout: CustomLayout) {
        let candidates = WindowManager.shared.tileCandidates()
        // One pane, or no more windows than panes, means there is no decision
        // to make: the assignment the picker would offer is the only one.
        guard layout.panes.count > 1, candidates.count > layout.panes.count else {
            WindowManager.shared.apply(layout: layout)
            return
        }

        close()
        let model = LayoutAssignModel(layout: layout, candidates: candidates)
        let p = FloatingPanel(size: CGSize(width: 340,
                                           height: CGFloat(196 + 38 * layout.panes.count))) {
            LayoutAssignView(model: model,
                             onApply: { [weak self] in
                                 WindowManager.shared.apply(layout: layout, using: model.chosen)
                                 self?.close()
                             },
                             onCancel: { [weak self] in self?.close() })
        }
        p.showCentered()
        panel = p

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }   // Escape
            return event
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.close()
        panel = nil
    }
}

@MainActor
final class LayoutAssignModel: ObservableObject {
    let layout: CustomLayout
    let candidates: [AXWindow]
    /// One entry per pane, indexing into `candidates`; -1 means leave it empty.
    @Published var picks: [Int]

    init(layout: CustomLayout, candidates: [AXWindow]) {
        self.layout = layout
        self.candidates = candidates
        // Prefill front to back, which is what tiling would have done anyway,
        // so confirming without touching anything matches the old behaviour.
        self.picks = layout.panes.indices.map { $0 < candidates.count ? $0 : -1 }
    }

    var chosen: [AXWindow?] {
        picks.map { $0 >= 0 && $0 < candidates.count ? candidates[$0] : nil }
    }

    func label(_ index: Int) -> String {
        guard index >= 0, index < candidates.count else { return "Leave empty" }
        let w = candidates[index]
        let app = NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "Window"
        let title = w.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? app : "\(app) — \(title)"
    }

    /// Keeps one window in one pane: picking it somewhere clears it elsewhere.
    func choose(_ candidate: Int, for pane: Int) {
        if candidate >= 0 {
            for i in picks.indices where i != pane && picks[i] == candidate { picks[i] = -1 }
        }
        picks[pane] = candidate
    }
}

struct LayoutAssignView: View {
    @ObservedObject var model: LayoutAssignModel
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(Color.accentColor)
                Text("Tile as \(model.layout.name)").font(Theme.Font.title)
                Spacer()
            }

            LayoutPreview(panes: model.layout.panes, compact: false)
                .frame(height: 74)
                .overlay(alignment: .topLeading) { numbers }

            VStack(spacing: 6) {
                ForEach(model.layout.panes.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        Text("\(i + 1)")
                            .font(Theme.Font.numeric)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Picker("", selection: Binding(
                            get: { model.picks[i] },
                            set: { model.choose($0, for: i) }
                        )) {
                            Text("Leave empty").tag(-1)
                            ForEach(model.candidates.indices, id: \.self) { c in
                                Text(model.label(c)).tag(c)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Tile", action: onApply).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Pane numbers drawn over the preview, so the rows below are unambiguous.
    private var numbers: some View {
        GeometryReader { geo in
            ForEach(model.layout.panes.indices, id: \.self) { i in
                let p = model.layout.panes[i]
                Text("\(i + 1)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .position(x: geo.size.width * (p.x + p.w / 2),
                              y: geo.size.height * (p.y + p.h / 2))
            }
        }
    }
}
