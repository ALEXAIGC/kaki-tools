import AppKit
import Carbon

struct HotkeyChord: Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    private static let keyNames: [String: UInt32] = [
        "A": UInt32(kVK_ANSI_A), "B": UInt32(kVK_ANSI_B), "C": UInt32(kVK_ANSI_C),
        "D": UInt32(kVK_ANSI_D), "E": UInt32(kVK_ANSI_E), "F": UInt32(kVK_ANSI_F),
        "G": UInt32(kVK_ANSI_G), "H": UInt32(kVK_ANSI_H), "I": UInt32(kVK_ANSI_I),
        "J": UInt32(kVK_ANSI_J), "K": UInt32(kVK_ANSI_K), "L": UInt32(kVK_ANSI_L),
        "M": UInt32(kVK_ANSI_M), "N": UInt32(kVK_ANSI_N), "O": UInt32(kVK_ANSI_O),
        "P": UInt32(kVK_ANSI_P), "Q": UInt32(kVK_ANSI_Q), "R": UInt32(kVK_ANSI_R),
        "S": UInt32(kVK_ANSI_S), "T": UInt32(kVK_ANSI_T), "U": UInt32(kVK_ANSI_U),
        "V": UInt32(kVK_ANSI_V), "W": UInt32(kVK_ANSI_W), "X": UInt32(kVK_ANSI_X),
        "Y": UInt32(kVK_ANSI_Y), "Z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
        "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
        "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
        "LEFT": UInt32(kVK_LeftArrow), "RIGHT": UInt32(kVK_RightArrow),
        "UP": UInt32(kVK_UpArrow), "DOWN": UInt32(kVK_DownArrow),
        "RETURN": UInt32(kVK_Return), "SPACE": UInt32(kVK_Space), "TAB": UInt32(kVK_Tab),
        "ESCAPE": UInt32(kVK_Escape), "BACKSPACE": UInt32(kVK_Delete),
        "DELETE": UInt32(kVK_ForwardDelete), "HOME": UInt32(kVK_Home), "END": UInt32(kVK_End),
        "PAGEUP": UInt32(kVK_PageUp), "PAGEDOWN": UInt32(kVK_PageDown),
        "MINUS": UInt32(kVK_ANSI_Minus), "EQUAL": UInt32(kVK_ANSI_Equal),
        "COMMA": UInt32(kVK_ANSI_Comma), "PERIOD": UInt32(kVK_ANSI_Period),
        "SLASH": UInt32(kVK_ANSI_Slash), "BACKSLASH": UInt32(kVK_ANSI_Backslash),
        "SEMICOLON": UInt32(kVK_ANSI_Semicolon), "QUOTE": UInt32(kVK_ANSI_Quote),
        "LEFTBRACKET": UInt32(kVK_ANSI_LeftBracket), "RIGHTBRACKET": UInt32(kVK_ANSI_RightBracket),
        "F1": UInt32(kVK_F1), "F2": UInt32(kVK_F2), "F3": UInt32(kVK_F3), "F4": UInt32(kVK_F4),
        "F5": UInt32(kVK_F5), "F6": UInt32(kVK_F6), "F7": UInt32(kVK_F7), "F8": UInt32(kVK_F8),
        "F9": UInt32(kVK_F9), "F10": UInt32(kVK_F10), "F11": UInt32(kVK_F11), "F12": UInt32(kVK_F12),
        "F13": UInt32(kVK_F13), "F14": UInt32(kVK_F14), "F15": UInt32(kVK_F15), "F16": UInt32(kVK_F16),
        "F17": UInt32(kVK_F17), "F18": UInt32(kVK_F18), "F19": UInt32(kVK_F19), "F20": UInt32(kVK_F20),
    ]
    private static let keyAliases = [
        "ENTER": "RETURN", "ESC": "ESCAPE", "DEL": "DELETE", "ARROWLEFT": "LEFT",
        "ARROWRIGHT": "RIGHT", "ARROWUP": "UP", "ARROWDOWN": "DOWN", "SPACEBAR": "SPACE",
        "-": "MINUS", "=": "EQUAL", ",": "COMMA", ".": "PERIOD", "/": "SLASH", "\\": "BACKSLASH",
        ";": "SEMICOLON", "'": "QUOTE", "[": "LEFTBRACKET", "]": "RIGHTBRACKET",
    ]

    static func parse(_ accelerator: String) -> HotkeyChord? {
        let parts = accelerator.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        guard let last = parts.last, !parts.contains(""), !last.isEmpty else { return nil }
        let key = keyAliases[last] ?? last
        guard let code = keyNames[key] else { return nil }
        var flags: UInt32 = 0
        for modifier in parts.dropLast() {
            switch modifier {
            case "COMMANDORCONTROL", "CMDORCTRL", "COMMAND", "CMD", "META", "SUPER": flags |= UInt32(cmdKey)
            case "CONTROL", "CTRL": flags |= UInt32(controlKey)
            case "ALT", "OPTION", "OPT": flags |= UInt32(optionKey)
            case "SHIFT": flags |= UInt32(shiftKey)
            default: return nil
            }
        }
        return HotkeyChord(keyCode: code, modifiers: flags)
    }

    // Resolve the key producing V in the currently selected input source. Some
    // Dvorak variants switch to QWERTY while Command is down; those use key 9.
    // Read each time so changing layouts while Kaki is running stays supported.
    static func pasteKeyCode() -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return 9 }
        var sourceID: String?
        if let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            sourceID = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        }
        if sourceID?.range(of: "Dvorak-QWERTY", options: .caseInsensitive) != nil { return 9 }
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return 9 }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size,
              let bytes = CFDataGetBytePtr(data) else { return 9 }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        return withExtendedLifetime(data) {
            resolvePasteKeyCode(inputSourceID: sourceID) { key in
                var deadKeyState: UInt32 = 0
                var output = [UniChar](repeating: 0, count: 4)
                var outputLength = 0
                let status = output.withUnsafeMutableBufferPointer { buffer in
                    UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                   OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                   buffer.count, &outputLength, buffer.baseAddress!)
                }
                return status == noErr && outputLength > 0 ? output[0] : nil
            }
        }
    }

    // Pure mapping seam for tests; it neither observes keys nor injects events.
    static func resolvePasteKeyCode(inputSourceID: String?, characterForKey: (UInt16) -> UniChar?) -> CGKeyCode {
        if inputSourceID?.range(of: "Dvorak-QWERTY", options: .caseInsensitive) != nil { return 9 }
        for key: UInt16 in 0..<128 {
            if let character = characterForKey(key), character == 118 || character == 86 { return CGKeyCode(key) }
        }
        return 9
    }

    static func from(event: NSEvent) -> HotkeyChord? {
        guard event.type == .keyDown, keyNames.values.contains(UInt32(event.keyCode)) else { return nil }
        var flags: UInt32 = 0
        if event.modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.control) { flags |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
        return HotkeyChord(keyCode: UInt32(event.keyCode), modifiers: flags)
    }

    private var keyName: String {
        Self.keyNames.first(where: { $0.value == keyCode })?.key ?? ""
    }

    var menuKeyEquivalent: String {
        let name = keyName
        if name.count == 1 { return name.lowercased() }
        if name.hasPrefix("F"), let number = Int(name.dropFirst()), (1...20).contains(number) {
            return String(UnicodeScalar(NSF1FunctionKey + number - 1)!)
        }
        let characters = ["LEFT": NSLeftArrowFunctionKey, "RIGHT": NSRightArrowFunctionKey,
                          "UP": NSUpArrowFunctionKey, "DOWN": NSDownArrowFunctionKey,
                          "DELETE": NSDeleteFunctionKey, "HOME": NSHomeFunctionKey,
                          "END": NSEndFunctionKey, "PAGEUP": NSPageUpFunctionKey, "PAGEDOWN": NSPageDownFunctionKey]
        if let character = characters[name] { return String(UnicodeScalar(character)!) }
        let keys = ["RETURN": "\r", "SPACE": " ", "TAB": "\t", "ESCAPE": "\u{1b}", "BACKSPACE": "\u{8}",
                    "MINUS": "-", "EQUAL": "=", "COMMA": ",", "PERIOD": ".", "SLASH": "/",
                    "BACKSLASH": "\\", "SEMICOLON": ";", "QUOTE": "'", "LEFTBRACKET": "[", "RIGHTBRACKET": "]"]
        return keys[name] ?? ""
    }

    var menuModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    var accelerator: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Alt") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        let name = keyName
        let canonical = ["PAGEUP": "PageUp", "PAGEDOWN": "PageDown", "MINUS": "-", "EQUAL": "=",
                         "COMMA": ",", "PERIOD": ".", "SLASH": "/", "BACKSLASH": "\\", "SEMICOLON": ";",
                         "QUOTE": "'", "LEFTBRACKET": "[", "RIGHTBRACKET": "]"]
        parts.append(canonical[name] ?? (name.count == 1 || name.hasPrefix("F") ? name : name.prefix(1) + name.dropFirst().lowercased()))
        return parts.joined(separator: "+")
    }

    var label: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        let labels = ["LEFT": "←", "RIGHT": "→", "UP": "↑", "DOWN": "↓", "RETURN": "↩",
                      "SPACE": "空格", "TAB": "⇥", "ESCAPE": "⎋", "BACKSPACE": "⌫", "DELETE": "⌦",
                      "HOME": "↖", "END": "↘", "PAGEUP": "⇞", "PAGEDOWN": "⇟", "MINUS": "-", "EQUAL": "=",
                      "COMMA": ",", "PERIOD": ".", "SLASH": "/", "BACKSLASH": "\\", "SEMICOLON": ";", "QUOTE": "'",
                      "LEFTBRACKET": "[", "RIGHTBRACKET": "]"]
        return value + (labels[keyName] ?? keyName)
    }
}

private final class HotkeyEventContext {
    weak var owner: HotkeyManager?
    init(owner: HotkeyManager) { self.owner = owner }
}

// Carbon delivers only the registered combinations. No event tap or keyboard
// interception is needed, so ordinary typing does not depend on this app.
final class HotkeyManager {
    private static let signature: OSType = 0x4B414B49 // KAKI
    private var eventHandler: EventHandlerRef?
    private var eventContext: UnsafeMutableRawPointer?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: String] = [:]
    private static var nextID: UInt32 = 0 // Allocated on main, unique across manager instances.
    private var handler: ((String) -> Void)?

    private func onMain<T>(_ operation: () -> T) -> T {
        if Thread.isMainThread { return operation() }
        return DispatchQueue.main.sync(execute: operation)
    }

    func register(bindings: [String: String], handler: @escaping (String) -> Void) -> [String] {
        onMain {
            unregisterAll()
            self.handler = handler
            guard installHandler() else { return bindings.keys.sorted() }
            var failed: [String] = []
            var registeredChords = Set<HotkeyChord>()
            for action in bindings.keys.sorted() {
                guard let accelerator = bindings[action], !accelerator.isEmpty else { continue }
                guard let chord = HotkeyChord.parse(accelerator), !registeredChords.contains(chord) else {
                    failed.append(action)
                    continue
                }
                Self.nextID &+= 1
                let id = Self.nextID
                let identifier = EventHotKeyID(signature: Self.signature, id: id)
                var reference: EventHotKeyRef?
                let status = RegisterEventHotKey(chord.keyCode, chord.modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
                if status == noErr, let reference {
                    registrations[id] = reference
                    actions[id] = action
                    registeredChords.insert(chord)
                } else {
                    if let reference { UnregisterEventHotKey(reference) }
                    failed.append(action)
                }
            }
            return failed
        }
    }

    func unregisterAll() {
        onMain {
            for reference in registrations.values { UnregisterEventHotKey(reference) }
            registrations.removeAll()
            actions.removeAll()
            handler = nil
        }
    }

    private func installHandler() -> Bool {
        if eventHandler != nil { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == HotkeyManager.signature else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyEventContext>.fromOpaque(context).takeUnretainedValue().owner
            return manager?.deliver(identifier.id) == true ? noErr : OSStatus(eventNotHandledErr)
        }
        let context = Unmanaged.passRetained(HotkeyEventContext(owner: self)).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &type, context, &eventHandler)
        guard status == noErr else {
            Unmanaged<HotkeyEventContext>.fromOpaque(context).release()
            return false
        }
        eventContext = context
        return true
    }

    private func deliver(_ identifier: UInt32) -> Bool {
        onMain {
            guard let action = actions[identifier], let handler else { return false }
            handler(action)
            return true
        }
    }

    deinit {
        // The retained callback context holds its owner weakly. Detach before
        // releasing it, including when cleanup originates off-main.
        let refs = Array(registrations.values)
        let installed = eventHandler
        let context = eventContext
        onMain {
            if let installed { RemoveEventHandler(installed) }
            for reference in refs { UnregisterEventHotKey(reference) }
            if let context { Unmanaged<HotkeyEventContext>.fromOpaque(context).release() }
        }
    }
}
