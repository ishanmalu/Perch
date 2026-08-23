import Foundation
import AppKit
import CryptoKit

/// Checks GitHub Releases for a newer build.
///
/// This is the only part of Perch that touches the network, and it only ever
/// talks to api.github.com and objects.githubusercontent.com. It is manual by
/// default. Perch deliberately does not install updates itself: it downloads
/// the DMG, verifies it against the release's published SHA256SUMS, and hands
/// it to you in Finder. Replacing a running app's own bundle from the network
/// is exactly the capability you don't want a utility to have.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release {
        let version: String
        let notes: String
        let pageURL: URL
        let dmgURL: URL?
        let checksumURL: URL?
    }

    /// Everything the updater fetches or opens has to live on one of these.
    /// The release JSON is attacker-controlled if GitHub is ever compromised,
    /// so URLs taken from it are checked rather than trusted.
    private static let allowedHosts: Set<String> = [
        "github.com", "www.github.com", "api.github.com",
        "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading(progress: Double)
        case ready(path: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private(set) var release: Release?

    private let repo = "ishanmalu/Perch"

    var currentVersion: String {
        if RenderMode.isActive { return RenderMode.version }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var lastChecked: Date? {
        get { UserDefaults.standard.object(forKey: "update.lastChecked") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "update.lastChecked") }
    }

    // MARK: - Checking

    /// `silent` suppresses the "you're up to date" HUD for background checks.
    func check(silent: Bool = false) {
        guard state != .checking else { return }
        state = .checking

        Task {
            do {
                let found = try await fetchLatest()
                release = found
                lastChecked = Date()

                if Self.isNewer(found.version, than: currentVersion) {
                    state = .available(version: found.version)
                    if silent {
                        Notifier.show("Perch \(found.version) is available",
                                      "Open the Perch panel to download it.", duration: 6)
                    }
                } else {
                    state = .upToDate
                    if !silent {
                        Notifier.show("Perch is up to date", "You're on \(currentVersion).", duration: 2)
                    }
                }
            } catch {
                state = .failed(error.localizedDescription)
                if !silent {
                    Notifier.show("Could not check for updates", error.localizedDescription)
                }
            }
        }
    }

    /// Runs at most once a day, and only when the user has opted in.
    func checkInBackgroundIfDue() {
        guard Prefs.shared.autoCheckUpdates else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 86400 { return }
        check(silent: true)
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Perch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        if http.statusCode == 404 { throw UpdateError.noReleases }
        guard http.statusCode == 200 else { throw UpdateError.status(http.statusCode) }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { throw UpdateError.badResponse }

        let assets = json["assets"] as? [[String: Any]] ?? []
        func asset(matching test: (String) -> Bool) -> URL? {
            assets.first { test(($0["name"] as? String ?? "").lowercased()) }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }

        guard Self.isTrusted(page) else { throw UpdateError.untrustedURL }
        return Release(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            notes: (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            pageURL: page,
            dmgURL: asset { $0.hasSuffix(".dmg") }.flatMap { Self.isTrusted($0) ? $0 : nil },
            checksumURL: asset { $0.contains("sha256") }.flatMap { Self.isTrusted($0) ? $0 : nil }
        )
    }

    // MARK: - Downloading

    func downloadLatest() {
        guard let release, let dmgURL = release.dmgURL, Self.isTrusted(dmgURL) else {
            openReleasePage()
            return
        }
        state = .downloading(progress: 0)

        Task {
            do {
                let (tempURL, response) = try await URLSession.shared.download(from: dmgURL)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw UpdateError.badResponse
                }

                let data = try Data(contentsOf: tempURL)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

                // A published checksum is the only thing standing between a
                // download and whatever a compromised CDN handed back, so a
                // release without one is refused rather than trusted.
                guard let checksumURL = release.checksumURL else { throw UpdateError.checksumMissing }
                guard let expected = try await expectedChecksum(from: checksumURL,
                                                                dmgName: dmgURL.lastPathComponent)
                else { throw UpdateError.checksumMissing }
                guard expected.caseInsensitiveCompare(digest) == .orderedSame else {
                    throw UpdateError.checksumMismatch
                }

                let downloads = FileManager.default
                    .urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                let destination = downloads.appendingPathComponent(dmgURL.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tempURL, to: destination)

                state = .ready(path: destination.path)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
                Notifier.show("Perch \(release.version) downloaded",
                              "Verified and revealed in Finder. Open it and drag Perch to Applications.",
                              duration: 6)
            } catch {
                state = .failed(error.localizedDescription)
                Notifier.show("Download failed", error.localizedDescription)
            }
        }
    }

    private func expectedChecksum(from url: URL, dmgName: String) async throws -> String? {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ").filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            if parts[1].hasSuffix(dmgName) { return String(parts[0]) }
        }
        return nil
    }

    func openReleasePage() {
        let fallback = URL(string: "https://github.com/\(repo)/releases/latest")!
        let target = release?.pageURL ?? fallback
        NSWorkspace.shared.open(Self.isTrusted(target) ? target : fallback)
    }

    // MARK: - Version comparison

    /// Numeric, component-wise. "1.10.0" is newer than "1.9.0".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { $0 == "." || $0 == "-" })
                .compactMap { Int($0.prefix(while: \.isNumber)) }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    enum UpdateError: LocalizedError {
        case badResponse, noReleases, status(Int), checksumMismatch, checksumMissing, untrustedURL

        var errorDescription: String? {
            switch self {
            case .badResponse: return "GitHub returned something unexpected."
            case .noReleases: return "No releases published yet."
            case .status(let code): return "GitHub returned HTTP \(code)."
            case .checksumMissing:
                return "That release publishes no checksum for this file, so the download was refused."
            case .untrustedURL:
                return "The release pointed somewhere other than GitHub. Nothing was downloaded."
            case .checksumMismatch: return "The download did not match its published checksum. It was discarded."
            }
        }
    }
}
