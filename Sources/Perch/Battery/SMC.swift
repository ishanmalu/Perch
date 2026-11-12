import Foundation
import IOKit

/// Minimal AppleSMC client: read key info, read bytes, write bytes.
///
/// The kernel interface takes one 80-byte C struct (`SMCKeyData_t`). It is
/// filled by offset here rather than mirrored as a Swift struct, because Swift
/// packs a field straight after a nested struct's *size* while C pads to its
/// stride — a mirrored struct comes out three bytes off and the SMC rejects it.
/// Reading works for any user; writing needs root.
final class SMC {
    private var conn: io_connect_t = 0

    private enum Off {
        static let key = 0, dataSize = 28, dataType = 32, result = 40, command = 42, bytes = 48
    }
    private enum Cmd { static let readBytes: UInt8 = 5, writeBytes: UInt8 = 6, readKeyInfo: UInt8 = 9 }

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var outSize = 80
        let r = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(conn, 2, inPtr.baseAddress, 80, outPtr.baseAddress, &outSize)
            }
        }
        guard r == kIOReturnSuccess, output[Off.result] == 0 else { return nil }
        return output
    }

    private static func put32(_ v: UInt32, into buf: inout [UInt8], at off: Int) {
        withUnsafeBytes(of: v) { for (i, b) in $0.enumerated() { buf[off + i] = b } }  // native (little) endian
    }

    private static func get32(_ buf: [UInt8], at off: Int) -> UInt32 {
        buf[off..<off + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    /// Size in bytes and four-char type of a key, or nil if it doesn't exist.
    func info(_ key: String) -> (size: Int, type: String)? {
        var input = [UInt8](repeating: 0, count: 80)
        Self.put32(Self.fourCC(key), into: &input, at: Off.key)
        input[Off.command] = Cmd.readKeyInfo
        guard let out = call(input) else { return nil }
        let size = Int(Self.get32(out, at: Off.dataSize))
        let t = Self.get32(out, at: Off.dataType)
        let type = String(bytes: [UInt8(t >> 24), UInt8(t >> 16 & 0xFF), UInt8(t >> 8 & 0xFF), UInt8(t & 0xFF)],
                          encoding: .ascii) ?? "?"
        return size > 0 ? (size, type) : nil
    }

    func read(_ key: String) -> [UInt8]? {
        guard let i = info(key) else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        Self.put32(Self.fourCC(key), into: &input, at: Off.key)
        Self.put32(UInt32(i.size), into: &input, at: Off.dataSize)
        input[Off.command] = Cmd.readBytes
        guard let out = call(input) else { return nil }
        return Array(out[Off.bytes..<Off.bytes + min(32, i.size)])
    }

    /// Every key name, by walking the SMC's index. Only used by the probe.
    func allKeys() -> [String] {
        guard let n = read("#KEY"), n.count == 4 else { return [] }
        let count = Int(UInt32(n[0]) << 24 | UInt32(n[1]) << 16 | UInt32(n[2]) << 8 | UInt32(n[3]))
        var keys: [String] = []
        for i in 0..<count {
            var input = [UInt8](repeating: 0, count: 80)
            input[Off.command] = 8   // read by index
            Self.put32(UInt32(i), into: &input, at: 44)
            guard let out = call(input) else { continue }
            let k = Self.get32(out, at: Off.key)
            keys.append(String(bytes: [UInt8(k >> 24), UInt8(k >> 16 & 0xFF), UInt8(k >> 8 & 0xFF), UInt8(k & 0xFF)],
                               encoding: .ascii) ?? "?")
        }
        return keys
    }

    @discardableResult
    func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard let i = info(key), i.size == bytes.count else { return false }
        var input = [UInt8](repeating: 0, count: 80)
        Self.put32(Self.fourCC(key), into: &input, at: Off.key)
        Self.put32(UInt32(i.size), into: &input, at: Off.dataSize)
        input[Off.command] = Cmd.writeBytes
        for (n, b) in bytes.enumerated() { input[Off.bytes + n] = b }
        return call(input) != nil
    }
}
