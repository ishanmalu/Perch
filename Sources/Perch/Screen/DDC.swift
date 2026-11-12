import AppKit
import IOKit

/// Hardware control of external monitors over DDC/CI — the I²C side channel
/// inside every HDMI/DisplayPort/USB-C link that a monitor's own buttons use.
///
/// On Apple Silicon the link is reached through `IOAVService`, a private but
/// long-stable IOKit API (MonitorControl and BetterDisplay rely on it). It is
/// resolved at runtime, so on Intel or a future macOS without it this simply
/// reports no support and brightness falls back to software dimming.
///
/// Not every monitor answers: many TVs, some docks and most DisplayLink
/// adapters drop DDC. The first read decides, per display.
final class DDC {
    static let shared = DDC()

    /// VCP codes from the MCCS standard.
    enum VCP: UInt8 {
        case brightness = 0x10
        case contrast = 0x12
        case volume = 0x62
        case input = 0x60
        case mute = 0x8D
    }

    /// Common MCCS input-source values. Monitors vary; these cover most.
    static let inputs: [(name: String, value: UInt16)] = [
        ("DisplayPort 1", 0x0F), ("DisplayPort 2", 0x10),
        ("HDMI 1", 0x11), ("HDMI 2", 0x12), ("USB-C", 0x1B), ("DVI", 0x03), ("VGA", 0x01),
    ]

    // MARK: - Private IOKit entry points

    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private let create: CreateFn?
    private let readI2C: I2CFn?
    private let writeI2C: I2CFn?

    /// Bus traffic only. All the state below lives on the main thread, so the
    /// UI reading it never waits behind a slow monitor.
    private let queue = DispatchQueue(label: "perch.ddc")
    private var services: [CGDirectDisplayID: CFTypeRef] = [:]
    /// Last value written or read per display and code.
    private var cache: [CGDirectDisplayID: [UInt8: (cur: UInt16, max: UInt16)]] = [:]
    /// Latest pending write per display+code; older ones are dropped. Dragging
    /// a slider fires far faster than a monitor can take commands.
    private var pending: [String: UInt16] = [:]
    private var responsive: Set<CGDirectDisplayID> = []

    var isAvailable: Bool { create != nil && readI2C != nil && writeI2C != nil }

    private init() {
        let h = dlopen(nil, RTLD_NOW)
        create = dlsym(h, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) }
        readI2C = dlsym(h, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: I2CFn.self) }
        writeI2C = dlsym(h, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: I2CFn.self) }
        rescan()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.rescan()
        }
        // Wake re-creates the display links, so the cached services go stale
        // even though the same monitors are attached.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.scannedFor = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.rescan() }
        }
    }

    /// True once the monitor has actually answered a read. Finding a service
    /// isn't enough: docks and TVs expose one and then ignore every command.
    func supports(_ id: CGDirectDisplayID) -> Bool { responsive.contains(id) }

    /// Cached reading, if one exists. Never touches the bus.
    func cached(_ code: VCP, for id: CGDirectDisplayID) -> (cur: UInt16, max: UInt16)? {
        cache[id]?[code.rawValue]
    }

    /// Normalised 0...1 brightness from cache, for the slider.
    func cachedLevel(_ code: VCP, for id: CGDirectDisplayID) -> Double? {
        guard let c = cached(code, for: id), c.max > 0 else { return nil }
        return Double(c.cur) / Double(c.max)
    }

    // MARK: - Reading / writing

    /// Reads a value off the bus in the background and caches it.
    func read(_ code: VCP, for id: CGDirectDisplayID, completion: @escaping ((UInt16, UInt16)?) -> Void = { _ in }) {
        guard let service = services[id] else { completion(nil); return }
        queue.async { [self] in
            let r = readNow(code.rawValue, service)
            DispatchQueue.main.async { [self] in
                if let r, services[id] != nil {
                    cache[id, default: [:]][code.rawValue] = r
                    responsive.insert(id)
                }
                completion(r)
            }
        }
    }

    /// Writes `value`, coalescing bursts so only the latest reaches the monitor.
    func write(_ code: VCP, _ value: UInt16, for id: CGDirectDisplayID) {
        guard let service = services[id] else { return }
        let key = "\(id)-\(code.rawValue)"
        let first = pending[key] == nil
        pending[key] = value
        cache[id, default: [:]][code.rawValue] = (value, cache[id]?[code.rawValue]?.max ?? 100)
        guard first else { return }
        // Give a dragging slider a beat to settle, then send what's latest.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            guard let v = pending.removeValue(forKey: key) else { return }
            queue.async { [self] in _ = writeNow(code.rawValue, v, service) }
        }
    }

    /// Writes 0...1 against the monitor's own maximum.
    func writeLevel(_ code: VCP, _ level: Double, for id: CGDirectDisplayID) {
        let maxV = cached(code, for: id)?.max ?? 100
        write(code, UInt16((min(1, max(0, level)) * Double(maxV)).rounded()), for: id)
    }

    private func readNow(_ code: UInt8, _ service: CFTypeRef) -> (UInt16, UInt16)? {
        guard let writeI2C, let readI2C else { return nil }
        for _ in 0..<3 {
            var request = Self.readRequest(code)
            guard writeI2C(service, 0x37, 0x51, &request, UInt32(request.count)) == kIOReturnSuccess else {
                usleep(20_000); continue
            }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 12)
            guard readI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess else {
                usleep(20_000); continue
            }
            if let parsed = Self.parseReply(reply, code: code) { return parsed }
            usleep(20_000)
        }
        return nil
    }

    private func writeNow(_ code: UInt8, _ value: UInt16, _ service: CFTypeRef) -> Bool {
        guard let writeI2C else { return false }
        var packet = Self.writePacket(code, value)
        // Monitors occasionally drop a command; send it twice like the
        // monitor's own OSD effectively does by repeating on key-hold.
        var ok = false
        for _ in 0..<2 {
            if writeI2C(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess { ok = true }
            usleep(10_000)
        }
        return ok
    }

    // MARK: - Packets (pure, self-tested)

    /// Host address 0x51 and the display's 0x6E write address both count
    /// towards the checksum even though neither is in the buffer.
    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0x6E ^ 0x51) { $0 ^ $1 }
    }

    static func writePacket(_ code: UInt8, _ value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [checksum(body)]
    }

    static func readRequest(_ code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, code]
        return body + [checksum(body)]
    }

    /// Reply layout: src, len, 0x02, result, code, type, maxHi, maxLo, curHi, curLo, chk.
    static func parseReply(_ r: [UInt8], code: UInt8) -> (UInt16, UInt16)? {
        guard r.count >= 11, r[2] == 0x02, r[3] == 0x00, r[4] == code else { return nil }
        let maxV = UInt16(r[6]) << 8 | UInt16(r[7])
        let cur = UInt16(r[8]) << 8 | UInt16(r[9])
        guard maxV > 0, cur <= maxV else { return nil }
        return (cur, maxV)
    }

    // MARK: - Finding each monitor's service

    /// Walks the IORegistry in order. Each external `DCPAVServiceProxy` comes
    /// after the framebuffer node describing the monitor on that port, so the
    /// most recent product attributes identify which display it belongs to.
    private var scannedFor: Set<CGDirectDisplayID>?

    private func rescan() {
        guard let create else { return }
        let externals = NSScreen.screens.compactMap(\.displayID).filter { CGDisplayIsBuiltin($0) == 0 }
        // Screen-parameter changes fire on every mode switch, wake and
        // rearrangement. The walk below covers the whole registry, so only
        // redo it when the set of external displays actually changed.
        guard scannedFor != Set(externals) else { return }
        scannedFor = Set(externals)
        var found: [(product: Int?, serial: Int?, service: CFTypeRef)] = []

        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }

        var lastProduct: Int?, lastSerial: Int?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuf = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &nameBuf)
            let cls = String(cString: nameBuf)
            if cls == "AppleCLCD2" || cls == "IOMobileFramebufferShim" {
                if let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString,
                                                               kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                   let product = attrs["ProductAttributes"] as? [String: Any] {
                    lastProduct = product["ProductID"] as? Int
                    lastSerial = product["SerialNumber"] as? Int
                }
            } else if cls == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString,
                                                               kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                guard location == "External", let svc = create(kCFAllocatorDefault, entry)?.takeRetainedValue()
                else { continue }
                found.append((lastProduct, lastSerial, svc))
                lastProduct = nil; lastSerial = nil
            }
        }

        var map: [CGDirectDisplayID: CFTypeRef] = [:]
        var unclaimed = found
        for id in externals {
            let model = Int(CGDisplayModelNumber(id)), serial = Int(CGDisplaySerialNumber(id))
            if let i = unclaimed.firstIndex(where: { $0.product == model && ($0.serial == nil || $0.serial == serial || serial == 0) }) {
                map[id] = unclaimed.remove(at: i).service
            }
        }
        // Fall back to port order for whatever didn't identify itself.
        for id in externals where map[id] == nil {
            guard !unclaimed.isEmpty else { break }
            map[id] = unclaimed.removeFirst().service
        }

        services = map
        cache = cache.filter { map[$0.key] != nil }
        responsive = responsive.filter { map[$0] != nil }
        // Prime brightness so sliders open on the monitor's real value.
        for id in map.keys {
            read(.brightness, for: id) { _ in BrightnessController.shared.refresh() }
        }
    }
}
