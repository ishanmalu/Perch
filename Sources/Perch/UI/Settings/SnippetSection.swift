import SwiftUI

struct SnippetSection: View {
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var store = SnippetStore.shared
    @State private var trigger = ""
    @State private var text = ""

    var body: some View {
        Section("Snippets") {
            Toggle("Expand snippets as I type", isOn: Binding(
                get: { prefs.snippetsEnabled },
                set: { prefs.snippetsEnabled = $0; store.sync() }))
            ForEach($store.snippets) { $s in
                HStack(spacing: 8) {
                    TextField("Trigger", text: $s.trigger).labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 110)
                    TextField("Expands to", text: $s.text, axis: .vertical).labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    Button(role: .destructive) { store.snippets.removeAll { $0.id == s.id } } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 8) {
                TextField("Trigger", text: $trigger, prompt: Text(";trigger")).labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 110)
                TextField("Text", text: $text, prompt: Text("Text to insert"), axis: .vertical).labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button("Add") {
                    store.snippets.append(Snippet(trigger: trigger, text: text))
                    trigger = ""; text = ""
                }
                .disabled(trigger.count < 2 || text.isEmpty
                          || store.snippets.contains { $0.trigger == trigger })
            }
            Text("Type a trigger anywhere and it's replaced with its text. {date}, {time} and {clipboard} "
               + "fill themselves in. Start triggers with a character you don't otherwise type, like ; — "
               + "Perch never watches password fields or anything else using Secure Input.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
