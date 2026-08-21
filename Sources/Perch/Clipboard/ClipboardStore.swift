import AppKit
import Combine
import CryptoKit

struct ClipItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, url, color, image, file }

    var id = UUID()
    var kind: Kind
    var text: String            // preview / payload for text kinds
    var imageFile: String?      // filename inside the images directory
    var sourceApp: String?      // bundle id
    var sourceName: String?
    var date: Date
    var pinned: Bool = false
    var hash: String

    var preview: String {
        switch kind {
        case .image: return "Image"
        default: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var symbol: String {
        switch kind {
        case .text: return "text.alignleft"
        case .url: return "link"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}

/// Polls NSPasteboard and keeps a persisted, de-duplicated history.
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var items: [ClipItem] = []

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    /// Set when we write to the pasteboard ourselves so we don't re-record it.
    private var selfCopyHash: String?

    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Perch", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base.appendingPathComponent("images"),
            withIntermediateDirectories: true,
            // Clipboard history is plaintext by nature; keep it owner-only.
            attributes: [.posixPermissions: 0o700])
        for dir in [base, base.appendingPathComponent("images")] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        return base
    }()
    private var storeURL: URL { dir.appendingPathComponent("clipboard.json") }
    private var imagesDir: URL { dir.appendingPathComponent("images", isDirectory: true) }

    private init() {
        load()
        pruneExpired()
        tightenExistingPermissions()
    }

    /// Images written before permissions were enforced are still on disk at
    /// 0644; bring them in line rather than leaving a mixed store.
    private func tightenExistingPermissions() {
        let fm = FileManager.default
        for dir in [dir, imagesDir] {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        guard let files = try? fm.contentsOfDirectory(atPath: imagesDir.path) else { return }
        for file in files {
            try? fm.setAttributes([.posixPermissions: 0o600],
                                  ofItemAtPath: imagesDir.appendingPathComponent(file).path)
        }
    }

    // MARK: - Lifecycle

    func start() {
        stop()
        guard Prefs.shared.clipboardEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() { timer?.invalidate(); timer = nil }

    // MARK: - Capture

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        // Respect the community convention for "don't record this".
        if pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true { return }
        if pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true { return }

        let front = NSWorkspace.shared.frontmostApplication
        if let bid = front?.bundleIdentifier, Prefs.shared.clipboardIgnoredApps.contains(bid) { return }

        guard var item = read(pb) else { return }
        if Prefs.shared.clipboardSkipSecrets, item.kind != .image, Self.looksSecret(item.text) {
            Notifier.show("Skipped a copied secret", "It looked like a key or token, so Perch did not store it.", duration: 2)
            return
        }
        if item.hash == selfCopyHash { selfCopyHash = nil; return }

        item.sourceApp = front?.bundleIdentifier
        item.sourceName = front?.localizedName
        insert(item)
    }

    private func read(_ pb: NSPasteboard) -> ClipItem? {
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], let first = urls.first, first.isFileURL {
            let text = urls.map(\.path).joined(separator: "\n")
            return ClipItem(kind: .file, text: text, date: Date(), hash: Self.digest(text))
        }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            var kind = ClipItem.Kind.text
            if let u = URL(string: trimmed), u.scheme?.hasPrefix("http") == true, !trimmed.contains(" ") { kind = .url }
            else if Self.isColor(trimmed) { kind = .color }
            return ClipItem(kind: kind, text: s, date: Date(), hash: Self.digest(s))
        }
        if Prefs.shared.clipboardStoreImages,
           let data = pb.data(forType: .tiff) ?? pb.data(forType: .png) {
            let h = Self.digest(data)
            let name = "\(h).png"
            let url = imagesDir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                if let rep = NSBitmapImageRep(data: data),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                    // Match the history file: clipboard images are user data.
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                           ofItemAtPath: url.path)
                } else { return nil }
            }
            return ClipItem(kind: .image, text: "Image", imageFile: name, date: Date(), hash: h)
        }
        return nil
    }

    /// Content that is almost certainly a credential. Cheap, deliberately narrow
    /// patterns — this is a safety net, not a DLP engine.
    static func looksSecret(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 8000 else { return false }
        if t.contains("-----BEGIN") && t.contains("PRIVATE KEY") { return true }
        let prefixes = ["sk-", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "xoxb-", "xoxp-",
                        "AKIA", "ASIA", "AIza", "SG.", "sk_live_", "pk_live_", "rk_live_",
                        "npm_", "glpat-", "dop_v1_", "shpat_", "hf_"]
        if prefixes.contains(where: { t.hasPrefix($0) }) && !t.contains(" ") { return true }
        // Bare JWTs.
        if t.hasPrefix("eyJ"), t.split(separator: ".").count == 3, !t.contains(" ") { return true }
        return false
    }

    private static func isColor(_ s: String) -> Bool {
        let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        return (hex.count == 6 || hex.count == 8) && hex.allSatisfy { $0.isHexDigit }
            && s.hasPrefix("#")
    }

    private func insert(_ item: ClipItem) {
        DispatchQueue.main.async {
            var list = self.items
            // Re-copying something already in history floats it to the top.
            if let idx = list.firstIndex(where: { $0.hash == item.hash }) {
                var existing = list.remove(at: idx)
                existing.date = Date()
                list.insert(existing, at: 0)
            } else {
                list.insert(item, at: 0)
            }
            self.items = self.trim(list)
            self.save()
        }
    }

    private func trim(_ list: [ClipItem]) -> [ClipItem] {
        let pinned = list.filter(\.pinned)
        var unpinned = list.filter { !$0.pinned }
        let limit = max(10, Prefs.shared.clipboardLimit)
        if unpinned.count > limit {
            let dropped = unpinned[limit...]
            dropped.forEach(deleteImage)
            unpinned = Array(unpinned[..<limit])
        }
        // Pinned entries keep their position in the merged, date-sorted list.
        return (pinned + unpinned).sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.date > b.date
        }
    }

    // MARK: - Mutation

    func paste(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .image:
            if let f = item.imageFile, let img = NSImage(contentsOf: imagesDir.appendingPathComponent(f)) {
                pb.writeObjects([img])
            }
        case .file:
            let urls = item.text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL }
            pb.writeObjects(urls)
        default:
            pb.setString(item.text, forType: .string)
        }
        selfCopyHash = item.hash
        lastChangeCount = pb.changeCount

        guard Prefs.shared.clipboardPasteOnPick else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Self.sendCommandV() }
    }

    /// Synthesizes ⌘V into whatever app is now frontmost.
    static func sendCommandV() {
        guard AX.isTrusted(prompt: false) else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(of: item) else { return }
        items[i].pinned.toggle()
        items = trim(items)
        save()
    }

    func delete(_ item: ClipItem) {
        deleteImage(item)
        items.removeAll { $0.id == item.id }
        save()
    }

    func clearAll(keepPinned: Bool = true) {
        items.filter { !keepPinned || !$0.pinned }.forEach(deleteImage)
        items = keepPinned ? items.filter(\.pinned) : []
        save()
    }

    func image(for item: ClipItem) -> NSImage? {
        guard let f = item.imageFile else { return nil }
        return NSImage(contentsOf: imagesDir.appendingPathComponent(f))
    }

    private func deleteImage(_ item: ClipItem) {
        guard let f = item.imageFile else { return }
        // Another entry may share the file (same hash); only remove if unreferenced.
        guard !items.contains(where: { $0.id != item.id && $0.imageFile == f }) else { return }
        try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(f))
    }

    private func pruneExpired() {
        let days = Prefs.shared.clipboardKeepDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let expired = items.filter { !$0.pinned && $0.date < cutoff }
        guard !expired.isEmpty else { return }
        expired.forEach(deleteImage)
        items.removeAll { !$0.pinned && $0.date < cutoff }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let v = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = v
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: storeURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }

    private static func digest(_ s: String) -> String { digest(Data(s.utf8)) }
    private static func digest(_ d: Data) -> String {
        SHA256.hash(data: d).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
