import AppKit
import Combine
import CoreAudio
import Darwin
import Foundation

/// Output volume, the output device, and which apps are making noise.
///
/// A note on what is missing, because it is the obvious question: macOS has no
/// per-application volume. Windows exposes one, which is what EarTrumpet is
/// built on; CoreAudio does not. Probing a process object for a level control
/// returns `kAudioHardwareUnknownPropertyError`, and there is no private
/// selector standing in for it either.
///
/// The only way to get per-app volume on a Mac is to install a virtual audio
/// device, make it the system output, and mix in your own process — which is
/// what Background Music and SoundSource do. That means a driver, an installer
/// and an approval prompt, and it takes over the machine's audio path. This
/// does none of that: it reports which apps are playing and controls the
/// output they share.
@MainActor
final class AudioControl: ObservableObject {
    static let shared = AudioControl()

    struct Player: Identifiable {
        let id: pid_t
        let name: String
        let icon: NSImage?
    }

    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
    }

    @Published private(set) var volume: Double = 0
    @Published private(set) var muted = false
    @Published private(set) var players: [Player] = []
    @Published private(set) var devices: [Device] = []
    @Published private(set) var currentDevice: Device?
    /// False on a device with no software volume, such as some HDMI outputs.
    @Published private(set) var volumeSettable = false

    private var timer: Timer?

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let device = Self.defaultOutput()
        currentDevice = device.map { Device(id: $0, name: Self.name(of: $0)) }
        devices = Self.outputDevices()
        if let device {
            volume = Double(Self.volume(of: device) ?? 0)
            volumeSettable = Self.volumeIsSettable(device)
            muted = Self.muted(device)
        }
        players = RenderMode.isActive
            // Distinct ids: Player is identified by pid, and ForEach needs
            // them unique.
            ? RenderMode.demoAudio.enumerated().map {
                Player(id: pid_t(900 + $0.offset), name: $0.element,
                       icon: RenderMode.icon(forBundleID: Self.bundleID(for: $0.element)))
              }
            : Self.playingApps()
    }

    // MARK: - Control

    func setVolume(_ value: Double) {
        guard let device = Self.defaultOutput(), volumeSettable else { return }
        var v = Float32(max(0, min(1, value)))
        var a = Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        let size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectSetPropertyData(device, &a, 0, nil, size, &v) == noErr else { return }
        volume = Double(v)
    }

    func toggleMute() {
        guard let device = Self.defaultOutput() else { return }
        var value: UInt32 = muted ? 0 : 1
        var a = Self.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectSetPropertyData(device, &a, 0, nil, size, &value) == noErr else { return }
        muted = value == 1
    }

    func select(_ device: Device) {
        var id = device.id
        var a = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &a, 0, nil, size, &id) == noErr else { return }
        refresh()
    }

    /// Bundle ids for the demo names, so the images show real icons.
    private static func bundleID(for name: String) -> String {
        switch name {
        case "Music":   return "com.apple.Music"
        case "Safari":  return "com.apple.Safari"
        case "Discord": return "com.hnc.Discord"
        default:        return ""
        }
    }

    // MARK: - Reading

    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func name(of id: AudioObjectID) -> String {
        // The property hands back a +1 CFString, so it is taken as retained
        // rather than bridged through an Optional the compiler would rather
        // not have a raw pointer formed to.
        let box = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        defer { box.deallocate() }
        box.pointee = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var a = address(kAudioObjectPropertyName)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, box) == noErr,
              let value = box.pointee?.takeRetainedValue() else { return "Output" }
        return value as String
    }

    private static func volume(of device: AudioDeviceID) -> Float32? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func volumeIsSettable(_ device: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &a, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func muted(_ device: AudioDeviceID) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var a = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { return false }
        return value == 1
    }

    private static func outputDevices() -> [Device] {
        var size: UInt32 = 0
        var a = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            // A device with no output channels is an input, and does not belong
            // in a list of places sound can come out of.
            var cfgSize: UInt32 = 0
            var cfg = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)
            guard AudioObjectGetPropertyDataSize(id, &cfg, 0, nil, &cfgSize) == noErr, cfgSize > 0
            else { return nil }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(cfgSize), alignment: 16)
            defer { buffer.deallocate() }
            guard AudioObjectGetPropertyData(id, &cfg, 0, nil, &cfgSize, buffer) == noErr else { return nil }
            let list = UnsafeMutableAudioBufferListPointer(
                buffer.assumingMemoryBound(to: AudioBufferList.self))
            guard list.reduce(0, { $0 + Int($1.mNumberChannels) }) > 0 else { return nil }
            return Device(id: id, name: name(of: id))
        }
    }

    /// Apps with audio running right now.
    ///
    /// macOS 14.4 gave every process that touches audio an object of its own,
    /// which is what makes this possible without a driver. Helpers are folded
    /// into the app that owns them, so a browser playing in a tab reads as the
    /// browser rather than as a renderer process.
    private static func playingApps() -> [Player] {
        var size: UInt32 = 0
        var a = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }

        var seen = Set<pid_t>()
        var out: [Player] = []
        for id in ids {
            var pid: pid_t = 0
            var s = UInt32(MemoryLayout<pid_t>.size)
            var p = address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(id, &p, 0, nil, &s, &pid) == noErr else { continue }

            var running: UInt32 = 0
            s = UInt32(MemoryLayout<UInt32>.size)
            var r = address(kAudioProcessPropertyIsRunningOutput)
            guard AudioObjectGetPropertyData(id, &r, 0, nil, &s, &running) == noErr, running == 1
            else { continue }

            // Anything audible is worth showing. An app is folded into its
            // bundle so a browser reads as the browser; something without one,
            // a command line player or a daemon, keeps its own name rather
            // than vanishing from a list of what is making noise.
            if let owner = owningApp(of: pid) {
                guard !seen.contains(owner.processIdentifier) else { continue }
                seen.insert(owner.processIdentifier)
                out.append(Player(id: owner.processIdentifier,
                                  name: owner.localizedName ?? "Unknown",
                                  icon: owner.icon))
            } else {
                guard !seen.contains(pid) else { continue }
                seen.insert(pid)
                out.append(Player(id: pid, name: processName(of: pid), icon: nil))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The kernel's short name, for anything without a bundle.
    private static func processName(of pid: pid_t) -> String {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return "pid \(pid)" }
        return withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? "pid \(pid)"
        }
    }

    /// The app a process belongs to, walking up from a helper if need be.
    private static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        if let direct = NSRunningApplication(processIdentifier: pid),
           direct.activationPolicy == .regular {
            return direct
        }
        // Helpers live inside the parent's bundle, so match on the outermost
        // .app in their executable path.
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let full = String(cString: path)
        guard let range = full.range(of: ".app/") else { return nil }
        let bundle = String(full[full.startIndex..<range.upperBound]).dropLast()
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.path == String(bundle)
        }
    }
}
