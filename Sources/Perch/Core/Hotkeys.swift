import AppKit
import Carbon.HIToolbox

struct HotkeySpec: Codable, Equatable {
    var keyCode: UInt32
    /// Cocoa modifier flags raw value.
    var modifiers: UInt

    var cocoaFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        let f = cocoaFlags
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var display: String {
        var s = ""
        let f = cocoaFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }

    static let defaults: [String: HotkeySpec] = [
        "panel":          .init(keyCode: UInt32(kVK_Space),      modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "clipboard":      .init(keyCode: UInt32(kVK_ANSI_V),     modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue),
        "switcher":       .init(keyCode: UInt32(kVK_ANSI_Grave), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "switcher.altTab": .init(keyCode: UInt32(kVK_Tab),       modifiers: NSEvent.ModifierFlags([.option]).rawValue),
        "screenshot":     .init(keyCode: UInt32(kVK_ANSI_4),     modifiers: NSEvent.ModifierFlags([.control, .option, .shift]).rawValue),
        "nightMode":      .init(keyCode: UInt32(kVK_ANSI_N),     modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "screenClean":    .init(keyCode: UInt32(kVK_ANSI_S),     modifiers: NSEvent.ModifierFlags([.control, .option, .shift]).rawValue),
        "keyboardClean":  .init(keyCode: UInt32(kVK_ANSI_L),     modifiers: NSEvent.ModifierFlags([.control, .option, .shift]).rawValue),
        "trackpadClean":  .init(keyCode: UInt32(kVK_ANSI_T),     modifiers: NSEvent.ModifierFlags([.control, .option, .shift]).rawValue),
        "win.left":       .init(keyCode: UInt32(kVK_LeftArrow),  modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "win.right":      .init(keyCode: UInt32(kVK_RightArrow), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "win.top":        .init(keyCode: UInt32(kVK_UpArrow),    modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "win.bottom":     .init(keyCode: UInt32(kVK_DownArrow),  modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "win.maximize":   .init(keyCode: UInt32(kVK_Return),     modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "win.center":     .init(keyCode: UInt32(kVK_ANSI_C),     modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "win.restore":    .init(keyCode: UInt32(kVK_Delete),     modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "win.nextScreen": .init(keyCode: UInt32(kVK_RightArrow), modifiers: NSEvent.ModifierFlags([.control, .option, .shift]).rawValue),
        "win.prevScreen": .init(keyCode: UInt32(kVK_LeftArrow),  modifiers: NSEvent.ModifierFlags([.control, .option, .shift]).rawValue),
        // Corners follow the layout Rectangle and Magnet use, so the muscle
        // memory transfers. Screen Clean moved off ⌃⌥K to make room.
        "win.topLeft":     .init(keyCode: UInt32(kVK_ANSI_U),    modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "win.topRight":    .init(keyCode: UInt32(kVK_ANSI_I),    modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "win.bottomLeft":  .init(keyCode: UInt32(kVK_ANSI_J),    modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "win.bottomRight": .init(keyCode: UInt32(kVK_ANSI_K),    modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "win.thirdL":     .init(keyCode: UInt32(kVK_ANSI_D),     modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "win.thirdC":     .init(keyCode: UInt32(kVK_ANSI_F),     modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "win.thirdR":     .init(keyCode: UInt32(kVK_ANSI_G),     modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        // The Mac's own brightness keys only reach the built-in panel. These
        // move every display, external ones included, which is the whole point
        // of having them.
        "brightness.up":   .init(keyCode: UInt32(kVK_ANSI_Equal), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
        "brightness.down": .init(keyCode: UInt32(kVK_ANSI_Minus), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
    ]
}

enum KeyNames {
    private static let map: [UInt32: String] = [
        UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_Escape): "⎋", UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_ANSI_Grave): "`", UInt32(kVK_ANSI_Equal): "=", UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
    ]
    static func name(for code: UInt32) -> String {
        if let n = map[code] { return n }
        // Ask the current keyboard layout what this key produces.
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "Key\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Registers global hotkeys through Carbon and dispatches them by string id.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var handlers: [String: () -> Void] = [:]
    private var refs: [String: EventHotKeyRef] = [:]
    private var idToName: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    func register(_ name: String, _ handler: @escaping () -> Void) {
        handlers[name] = handler
        rebind(name)
    }

    /// Re-reads the spec from Prefs and re-registers. Call after the user edits a shortcut.
    func rebind(_ name: String) {
        installHandlerIfNeeded()
        if let existing = refs.removeValue(forKey: name) { UnregisterEventHotKey(existing) }
        idToName = idToName.filter { $0.value != name }
        guard let spec = Prefs.shared.hotkey(name), handlers[name] != nil else { return }

        let id = nextID; nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x50524348 /* 'PRCH' */), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        _ = hotKeyID
        if status == noErr, let ref {
            refs[name] = ref
            idToName[id] = name
        } else {
            NSLog("Perch: could not register hotkey \(name) (\(spec.display)) — likely taken by another app")
        }
    }

    func rebindAll() { for name in handlers.keys { rebind(name) } }

    fileprivate func fire(_ id: UInt32) {
        guard let name = idToName[id], let h = handlers[name] else { return }
        h()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            HotkeyManager.shared.fire(hkID.id)
            return noErr
        }, 1, &spec, nil, nil)
    }
}
