import AppKit
import Carbon.HIToolbox
import Combine

/// Text expansion: type a trigger like `;sig` anywhere and it's replaced with
/// the saved text.
///
/// Watching keystrokes is sensitive, so this is deliberately narrow: only a
/// rolling buffer of the last few characters is kept (never written anywhere),
/// it's cleared on every click, arrow key or app switch, and nothing is
/// watched while macOS has Secure Input on — which every password field,
/// Terminal's secure keyboard entry and password managers turn on.
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var text: String
}

final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    @Published var snippets: [Snippet] = [] { didSet { save() } }

    private let key = "snippets"
    private var monitors: [Any] = []
    private var activation: NSObjectProtocol?
    private var buffer = ""
    private var expanding = false

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = v
        } else {
            snippets = [Snippet(trigger: ";date", text: "{date}"),
                        Snippet(trigger: ";shrug", text: "¯\\_(ツ)_/¯")]
        }
    }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(snippets), forKey: key) }

    func sync() { Prefs.shared.snippetsEnabled ? start() : stop() }

    func start() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in self?.key(e) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown],
                                                     handler: { [weak self] _ in self?.buffer = "" }) {
            monitors.append(m)
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.buffer = ""
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        buffer = ""
    }

    private func key(_ e: NSEvent) {
        guard !expanding, !IsSecureEventInputEnabled() else { buffer = ""; return }
        // Shortcuts and navigation end whatever was being typed.
        if !e.modifierFlags.intersection([.command, .control]).isEmpty { buffer = ""; return }
        switch Int(e.keyCode) {
        case kVK_Delete:
            if !buffer.isEmpty { buffer.removeLast() }
            return
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Return, kVK_Tab, kVK_Escape:
            buffer = ""; return
        default: break
        }
        guard let chars = e.characters, !chars.isEmpty else { return }
        buffer += chars
        if buffer.count > 48 { buffer.removeFirst(buffer.count - 48) }
        if let s = Self.match(buffer, in: snippets) { expand(s) }
    }

    /// Pure, self-tested. The longest trigger the typed text ends with, so
    /// `;sig2` wins over `;sig` once the 2 is typed.
    static func match(_ typed: String, in list: [Snippet]) -> Snippet? {
        list.filter { !$0.trigger.isEmpty && typed.hasSuffix($0.trigger) }
            .max { $0.trigger.count < $1.trigger.count }
    }

    /// Pure, self-tested. `{date}`, `{time}` and `{clipboard}` placeholders.
    static func render(_ text: String, now: Date = Date(), clipboard: String? = nil) -> String {
        let d = DateFormatter(); d.dateStyle = .medium; d.timeStyle = .none
        let t = DateFormatter(); t.dateStyle = .none; t.timeStyle = .short
        return text
            .replacingOccurrences(of: "{date}", with: d.string(from: now))
            .replacingOccurrences(of: "{time}", with: t.string(from: now))
            .replacingOccurrences(of: "{clipboard}", with: clipboard ?? "")
    }

    private func expand(_ s: Snippet) {
        buffer = ""
        expanding = true
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        } ?? []
        let text = Self.render(s.text, clipboard: pb.string(forType: .string))

        // Let the trigger's last key land before erasing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            let src = CGEventSource(stateID: .combinedSessionState)
            for _ in 0..<s.trigger.count { Self.tap(CGKeyCode(kVK_Delete), source: src) }

            pb.clearContents()
            pb.setString(text, forType: .string)
            let ours = pb.changeCount
            // Marked transient so Perch's own clipboard history skips it.
            pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            Self.tap(CGKeyCode(kVK_ANSI_V), flags: .maskCommand, source: src)

            // Put back whatever the user had copied.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                // Only if the expansion is still what's there: anything copied
                // since then is the user's and must not be overwritten.
                if pb.changeCount == ours {
                    pb.clearContents()
                    if !saved.isEmpty { pb.writeObjects(saved) }
                    // Transient, so history doesn't log the old item a second time.
                    pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
                }
                self.expanding = false
            }
        }
    }

    private static func tap(_ key: CGKeyCode, flags: CGEventFlags = [], source: CGEventSource?) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}
