import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Menu bar & focus

struct MenuBarSettings: View {
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var hider = MenuBarHider.shared
    @ObservedObject var focus = FocusTimer.shared
    @ObservedObject var calendar = CalendarPeek.shared
    @State private var hasShortcuts = false

    var body: some View {
        Form {
            Section("Hide menu bar icons") {
                Toggle("Tuck icons behind a toggle", isOn: Binding(
                    get: { prefs.menuHiderEnabled },
                    set: { prefs.menuHiderEnabled = $0; hider.sync() }))
                if prefs.menuHiderEnabled {
                    Picker("Hide again after", selection: Binding(
                        get: { prefs.menuHiderAutoCollapse }, set: { prefs.menuHiderAutoCollapse = $0 })) {
                        Text("Never").tag(0)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                    }
                    Toggle("Start hidden", isOn: Binding(
                        get: { prefs.menuHiderStartCollapsed }, set: { prefs.menuHiderStartCollapsed = $0 }))
                }
                Text("Perch adds a chevron and a faint divider. Hold ⌘ and drag any icon to the left of the "
                   + "divider; clicking the chevron hides or shows everything there. Icons macOS pins to the "
                   + "right edge (Control Centre, the clock) can't be moved.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Focus timer") {
                Stepper("Focus for \(prefs.focusMinutes) minutes", value: Binding(
                    get: { prefs.focusMinutes }, set: { prefs.focusMinutes = $0 }), in: 5...120, step: 5)
                Stepper("Break for \(prefs.breakMinutes) minutes", value: Binding(
                    get: { prefs.breakMinutes }, set: { prefs.breakMinutes = $0 }), in: 1...30)
                Toggle("Turn on Do Not Disturb while focusing", isOn: Binding(
                    get: { prefs.focusUsesShortcuts }, set: { prefs.focusUsesShortcuts = $0 }))
                if prefs.focusUsesShortcuts {
                    LabeledContent("Shortcuts") {
                        HStack {
                            Text(hasShortcuts ? "Found" : "Not set up")
                                .foregroundStyle(hasShortcuts ? .green : .orange)
                            Button("Open Shortcuts") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
                            }
                        }
                    }
                    Text("macOS only lets Shortcuts switch Focus. Make two shortcuts, “\(FocusTimer.onShortcut)” "
                       + "(Set Focus → Do Not Disturb → On) and “\(FocusTimer.offShortcut)” (… → Off), "
                       + "and Perch runs them when a block starts and ends.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("The time left shows next to Perch's menu bar icon. \(focus.completedToday) block\(focus.completedToday == 1 ? "" : "s") done today.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Next meeting") {
                Toggle("Show my next meeting in the panel", isOn: Binding(
                    get: { prefs.calendarEnabled },
                    set: { on in
                        prefs.calendarEnabled = on
                        if on {
                            if !calendar.hasAccess { calendar.requestAccess() }
                            calendar.start()
                        }
                    }))
                if prefs.calendarEnabled && !calendar.hasAccess {
                    LabeledContent("Calendar access") {
                        HStack {
                            Text(calendar.access == .notDetermined ? "Not asked yet" : "Denied")
                                .foregroundStyle(.orange)
                            Button(calendar.access == .notDetermined ? "Allow…" : "Open Settings") {
                                if calendar.access == .notDetermined { calendar.requestAccess() }
                                else {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                                }
                            }
                        }
                    }
                }
                Text("Read on this Mac only, from the calendars already in the Calendar app. A Join button "
                   + "appears when the event has a Zoom, Meet, Teams or Webex link.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            hasShortcuts = await Task.detached { FocusTimer.hasShortcuts }.value
        }
    }
}

// MARK: - Battery

struct BatterySettings: View {
    @ObservedObject var model = BatteryModel.shared

    var body: some View {
        Form {
            if let b = model.info {
                Section("Health") {
                    LabeledContent("Charge", value: "\(b.percent)%" + (b.charging ? " — charging" : b.pluggedIn ? " — plugged in" : ""))
                    LabeledContent("Health") {
                        HStack(spacing: 8) {
                            ProgressView(value: b.health).frame(width: 120)
                                .tint(b.health > 0.8 ? .green : b.health > 0.6 ? .orange : .red)
                            Text("\(Int(b.health * 100))%").monospacedDigit()
                        }
                    }
                    LabeledContent("Capacity", value: "\(b.maxCapacity) of \(b.designCapacity) mAh")
                    LabeledContent("Cycle count", value: "\(b.cycleCount)")
                    if let t = b.temperature { LabeledContent("Temperature", value: String(format: "%.1f °C", t)) }
                    LabeledContent("Condition", value: b.condition ?? "Normal")
                }

                Section("Charge limit") {
                    if model.supported {
                        Toggle("Stop charging at a set level", isOn: Binding(
                            get: { model.helperInstalled },
                            set: { $0 ? model.install() : model.remove() }))
                        if model.helperInstalled {
                            Stepper("Stop at \(model.limit)%", value: $model.limit, in: 50...100, step: 5)
                        }
                        Text("Keeping a battery below full slows its wear — useful on a Mac that's plugged in all day. "
                           + "Turning this on installs a small helper that needs your password once. Turning it off "
                           + "removes the helper and restores normal charging.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("This Mac's firmware doesn't expose a charging switch Perch knows how to use safely, "
                           + "so the limit is unavailable. macOS's own Optimised Battery Charging (System Settings → "
                           + "Battery) still applies.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No battery in this Mac.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
    }
}

// MARK: - Apps

struct AppsSettings: View {
    @ObservedObject var un = AppUninstaller.shared
    @State private var dropTargeted = false
    @State private var confirming = false

    var body: some View {
        Form {
            Section("Uninstall an app") {
                if let app = un.app {
                    HStack(spacing: 12) {
                        Image(nsImage: app.icon).resizable().frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.headline)
                            Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { un.clear() }
                    }
                    if un.scanning {
                        HStack { ProgressView().controlSize(.small); Text("Looking for leftovers…").foregroundStyle(.secondary) }
                    } else if un.leftovers.isEmpty {
                        Text("No leftovers found in your Library.").foregroundStyle(.secondary)
                    } else {
                        ForEach($un.leftovers) { $item in
                            Toggle(isOn: $item.selected) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                        Text(item.kind).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(SystemMonitor.bytes(UInt64(item.size)))
                                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    HStack {
                        Text("Frees \(SystemMonitor.bytes(UInt64(un.totalSelected)))").foregroundStyle(.secondary)
                        Spacer()
                        Button("Move to Trash", role: .destructive) { confirming = true }
                            .buttonStyle(.borderedProminent).tint(.red)
                            .disabled(un.scanning)
                    }
                    .confirmationDialog("Move \(app.name) and the selected items to the Trash?",
                                        isPresented: $confirming) {
                        Button("Move to Trash", role: .destructive) { un.uninstall() }
                    } message: {
                        Text("If it's running it will be quit. You can put everything back from the Trash.")
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "trash.square").font(.system(size: 30)).foregroundStyle(.secondary)
                        Text("Drop an app here").font(.headline)
                        Button("Choose an app…") { un.choose() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 130)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                        .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
                    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                        _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                            if let url { DispatchQueue.main.async { un.load(url) } }
                        }
                        return true
                    }
                }
                Text("Finds what the app leaves in ~/Library — caches, preferences, saved state, containers — "
                   + "by its exact bundle identifier. Everything goes to the Trash, so it can be put back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
