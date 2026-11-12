import SwiftUI

struct WorkspaceSection: View {
    @ObservedObject var store = Workspaces.shared
    @State private var name = ""

    var body: some View {
        Section("Workspaces") {
            ForEach(store.all) { ws in
                HStack(spacing: 10) {
                    GlyphBadge(symbol: "square.stack.3d.up", tint: .indigo, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ws.name)
                        Text(ws.apps.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Toggle("Open apps", isOn: Binding(get: { ws.launchApps },
                                                      set: { var w = ws; w.launchApps = $0; store.update(w) }))
                        .toggleStyle(.checkbox)
                    Toggle("Auto", isOn: Binding(get: { ws.autoRestore },
                                                 set: { var w = ws; w.autoRestore = $0; store.update(w) }))
                        .toggleStyle(.checkbox)
                        .help("Restore whenever the same displays are connected as when it was saved")
                    Button("Restore") { store.restore(ws) }
                        .disabled(store.restoring)
                    Button(role: .destructive) { store.delete(ws) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Workspace name", text: $name, prompt: Text("Workspace name, e.g. Coding"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save open windows", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Saves every open window's app and position. Restoring opens any of those apps that "
               + "aren't running and puts each window back. With Auto on, docking at the same displays "
               + "restores it on its own — a per-app layout for that desk.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        store.captureCurrent(named: n)
        name = ""
    }
}
