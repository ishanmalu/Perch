import AppKit
import EventKit
import Combine

/// The next meeting, with a one-click join when it has a call link.
final class CalendarPeek: ObservableObject {
    static let shared = CalendarPeek()

    struct Meeting: Equatable {
        var title: String
        var start: Date
        var end: Date
        var calendarColor: NSColor?
        var joinURL: URL?
    }

    @Published private(set) var next: Meeting?
    @Published private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    private let store = EKEventStore()
    private var timer: Timer?
    private var observing = false

    var hasAccess: Bool { access == .fullAccess }

    func start() {
        guard Prefs.shared.calendarEnabled else { return }
        if hasAccess { refresh() }
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.access = EKEventStore.authorizationStatus(for: .event)
                self?.refresh()
            }
        }
    }

    func refresh() {
        access = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else { next = nil; return }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60),
                                            end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let ev = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .filter { e in
                // Skip ones you've declined.
                !(e.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
            }
            .sorted { $0.startDate < $1.startDate }
            .first
        next = ev.map {
            Meeting(title: $0.title ?? "Untitled", start: $0.startDate, end: $0.endDate,
                    calendarColor: $0.calendar.color,
                    joinURL: Self.joinLink(in: [$0.url?.absoluteString, $0.location, $0.notes]))
        }
    }

    /// Pure, self-tested: the first video-call link in any of the fields.
    static func joinLink(in fields: [String?]) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                     "webex.com", "whereby.com", "around.co", "facetime.apple.com", "slack.com/huddle"]
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for field in fields.compactMap({ $0 }) {
            let range = NSRange(field.startIndex..., in: field)
            for match in detector.matches(in: field, range: range) {
                guard let url = match.url, url.scheme?.hasPrefix("http") == true else { continue }
                let s = url.absoluteString.lowercased()
                if hosts.contains(where: { s.contains($0) }) { return url }
            }
        }
        return nil
    }

    /// "in 12 min", "now", "at 14:30".
    static func when(_ m: Meeting, now: Date = Date()) -> String {
        if m.start <= now { return "now" }
        let mins = Int((m.start.timeIntervalSince(now) / 60).rounded(.up))
        if mins < 60 { return "in \(mins) min" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return "at \(f.string(from: m.start))"
    }
}
