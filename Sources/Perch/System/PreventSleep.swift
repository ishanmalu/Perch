import Foundation
import IOKit.pwr_mgt
import Combine

/// Holds a power assertion so the display and system stay awake — the
/// equivalent of leaving `caffeinate` running, without spawning a process.
final class PreventSleep: ObservableObject {
    static let shared = PreventSleep()

    @Published private(set) var isActive = false
    private var assertionID: IOPMAssertionID = 0

    func toggle() {
        setActive(!isActive)
        Notifier.show(isActive ? "Sleep prevented" : "Sleep allowed",
                      isActive ? "Your Mac and display stay awake until you turn this off." : nil,
                      duration: 2)
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if active {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Perch — sleep prevented by the user" as CFString,
                &id)
            guard result == kIOReturnSuccess else {
                Notifier.show("Could not prevent sleep", "macOS refused the power assertion.")
                return
            }
            assertionID = id
            isActive = true
        } else {
            if assertionID != 0 { IOPMAssertionRelease(assertionID) }
            assertionID = 0
            isActive = false
        }
    }

    /// Released automatically on quit; assertions do not outlive the process,
    /// but being explicit keeps the state readable.
    func shutdown() { setActive(false) }
}
