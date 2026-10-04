import AppKit
import Carbon

func runSystemTests() throws {
    let settingsOrder = WindowLayout.Group.allCases.flatMap { WindowManager.layouts(in: $0).map(\.id) }
    let menuOrder = WindowManager.menuGroups.flatMap { WindowManager.layouts(in: $0).map(\.id) }
    try check(settingsOrder == ["left-half", "right-half", "top-half", "bottom-half", "top-left", "top-right", "bottom-left", "bottom-right", "left-third", "center-third", "right-third", "left-two-thirds", "right-two-thirds", "maximize", "center"], "shared groups retain settings layout order")
    try check(menuOrder == ["maximize", "center", "left-half", "right-half", "top-half", "bottom-half", "top-left", "top-right", "bottom-left", "bottom-right", "left-third", "center-third", "right-third", "left-two-thirds", "right-two-thirds"], "shared groups retain status menu order")
    try check(WindowLayout.Group.allCases.map(\.settingsTitle) == ["半屏", "四分屏", "三分屏", "其他布局"], "settings grouping labels remain unchanged")
    let maximize = WindowManager.layouts.first { $0.id == "maximize" }!
    try check(maximize.label == "最大化" && maximize.settingsLabel == "铺满窗口" && maximize.defaultShortcut == "Control+Alt+Return", "maximize keeps distinct menu/settings labels and Return default")
    try check(WindowManager.layouts.count == 15, "All fifteen window layouts migrate")
    try check(Set(WindowManager.layouts.map(\.id)) == Set(WindowManager.defaultShortcuts.keys), "Every layout retains its shortcut")
    for layout in WindowManager.layouts {
        try check(HotkeyChord.parse(WindowManager.defaultShortcuts[layout.id] ?? "") != nil, "Parse default shortcut for \(layout.id)")
    }

    let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = CGRect(x: 0, y: 35, width: 1440, height: 842)
    let work = WindowManager.accessibilityRect(visible, primaryScreenFrame: primary)
    try check(work == CGRect(x: 0, y: 23, width: 1440, height: 842), "AX conversion excludes the top menu and bottom Dock")
    let left = WindowManager.layouts.first(where: { $0.id == "left-half" })!
    let right = WindowManager.layouts.first(where: { $0.id == "right-half" })!
    let top = WindowManager.layouts.first(where: { $0.id == "top-half" })!
    let center = WindowManager.layouts.first(where: { $0.id == "center" })!
    try check(WindowManager.targetRect(left, workArea: work) == CGRect(x: 0, y: 23, width: 720, height: 842), "Left half uses available points")
    try check(WindowManager.targetRect(right, workArea: work) == CGRect(x: 720, y: 23, width: 720, height: 842), "Right half retains the work-area origin")
    try check(WindowManager.targetRect(top, workArea: work) == CGRect(x: 0, y: 23, width: 1440, height: 421), "Top refers to AX top-left coordinates")
    try check(WindowManager.targetRect(center, workArea: work) == CGRect(x: 180, y: 107, width: 1080, height: 674), "Centered layout rounds to points")

    let leftAppKit = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let leftAX = WindowManager.accessibilityRect(leftAppKit, primaryScreenFrame: primary)
    let leftWork = WindowManager.accessibilityRect(CGRect(x: -1920, y: 40, width: 1920, height: 1012), primaryScreenFrame: primary)
    try check(leftAX == CGRect(x: -1920, y: -180, width: 1920, height: 1080), "Left display preserves negative origin and independent height")
    try check(leftWork == CGRect(x: -1920, y: -152, width: 1920, height: 1012), "Secondary work area converts with primary height")
    try check(WindowManager.targetRect(right, workArea: leftWork) == CGRect(x: -960, y: -152, width: 960, height: 1012), "Layouts preserve negative display coordinates")
    try check(WindowManager.accessibilityRect(CGRect(x: 0, y: 900, width: 1920, height: 1080), primaryScreenFrame: primary).minY == -1080, "Display above the primary has negative AX y")
    try check(WindowManager.accessibilityRect(CGRect(x: 0, y: -1080, width: 1920, height: 1080), primaryScreenFrame: primary).minY == 900, "Display below the primary has positive AX y")

    let screens = [WindowScreenArea(frame: primary, workArea: work), WindowScreenArea(frame: leftAX, workArea: leftWork)]
    try check(WindowManager.matchingScreen(for: CGRect(x: -500, y: 25, width: 800, height: 600), screens: screens)?.frame == leftAX, "A spanning window chooses its largest intersection")
    try check(WindowManager.matchingScreen(for: CGRect(x: 5000, y: 25, width: 800, height: 600), screens: screens)?.frame == primary, "Offscreen windows choose the nearest display")
    try check(WindowManager.matchingScreen(for: primary, screens: []) == nil, "Missing screens do not produce a move")
    try check(WindowManager.targetRect(WindowLayout(id: "bad", label: "", fractions: []), workArea: work).isNull, "Invalid fractions never index outside the array")
    try check(WindowManager.targetRect(left, workArea: .null).isNull, "Invalid work area cannot produce an AX target")

    var uptime: TimeInterval = 100
    let gate = WindowRequestGate(now: { uptime })
    let first = gate.begin(timeout: 2)
    try check(gate.isCurrent(first), "A fresh request can execute")
    let latest = gate.begin(timeout: 2)
    try check(!gate.isCurrent(first) && gate.isCurrent(latest), "Latest generation invalidates an older queued read")
    gate.cancel()
    try check(!gate.isCurrent(latest), "Cancellation takes effect outside the AX queue")
    let expired = gate.begin(timeout: 2)
    uptime = 102
    try check(!gate.isCurrent(expired), "Request expires at its deadline")
    uptime = 101
    try check(!gate.isCurrent(expired), "An expired request never revives")
    let zeroTimeout = gate.begin(timeout: 0)
    try check(!gate.isCurrent(zeroTimeout), "An expired task is rejected before accessing AX")
    let invalidTimeout = gate.begin(timeout: .nan)
    try check(!gate.isCurrent(invalidTimeout), "Invalid deadlines never allow an operation")

    let old = HotkeyChord.parse("CommandOrControl+Shift+V")!
    try check(old.modifiers == UInt32(cmdKey | shiftKey) && old.keyCode == UInt32(kVK_ANSI_V), "Electron CommandOrControl becomes Command on macOS")
    try check(old == HotkeyChord.parse("cmd+SHIFT+v"), "Shortcut spelling is case insensitive")
    try check(HotkeyChord.parse("Ctrl+Option+Left") == HotkeyChord.parse("Control+Alt+ArrowLeft"), "Control, Option and arrow aliases normalize")
    try check(HotkeyChord.parse("Cmd+Enter") == HotkeyChord.parse("Command+Return"), "Return alias normalizes")
    try check(HotkeyChord.parse("Control+Alt+Left")?.label == "⌃⌥←", "Labels show system modifier glyphs")
    try check(old.label == "⇧⌘V", "Command labels retain the shift modifier")
    try check(HotkeyChord.parse(old.accelerator) == old, "Recording format round trips through the parser")
    try check(HotkeyChord.parse("Alt+PageUp")?.accelerator == "Alt+PageUp", "PageUp retains legacy canonical casing")
    try check(HotkeyChord.parse("Cmd+;")?.accelerator == "Command+;", "Punctuation survives serialization")
    try check(HotkeyChord.parse("Command+1")?.keyCode == UInt32(kVK_ANSI_1), "Number keys parse")
    for n in 1...20 {
        let chord = HotkeyChord.parse("Control+F\(n)")
        try check(chord != nil && HotkeyChord.parse(chord!.accelerator) == chord, "F\(n) parses and round trips")
    }
    for invalid in ["", "Command+", "Unknown+V", "Command+Shift", "Command++V", "Command+F21", "Command+AB"] {
        try check(HotkeyChord.parse(invalid) == nil, "Reject malformed accelerator: \(invalid)")
    }
    try check(Set([HotkeyChord.parse("Cmd+V")!, HotkeyChord.parse("CommandOrControl+V")!]).count == 1, "Aliases are a single registered chord")

    try check(HotkeyChord.resolvePasteKeyCode(inputSourceID: nil, characterForKey: { _ in nil }) == 9,
              "Missing keyboard layout falls back to the standard V key")
    try check(HotkeyChord.resolvePasteKeyCode(inputSourceID: "com.apple.keylayout.US", characterForKey: { $0 == 9 ? 118 : nil }) == 9,
              "QWERTY maps lowercase V to its physical key")
    try check(HotkeyChord.resolvePasteKeyCode(inputSourceID: "com.apple.keylayout.Dvorak", characterForKey: { $0 == 47 ? 118 : nil }) == 47,
              "A non-QWERTY input source uses its mapped V key")
    try check(HotkeyChord.resolvePasteKeyCode(inputSourceID: "test-layout", characterForKey: { $0 == 25 ? 86 : nil }) == 25,
              "Uppercase V mappings are also accepted")
    var translations = 0
    let commandQwerty = HotkeyChord.resolvePasteKeyCode(inputSourceID: "com.apple.keylayout.DVORAK-QWERTYCommand") { _ in
        translations += 1
        return 118
    }
    try check(commandQwerty == 9 && translations == 0, "Command-QWERTY Dvorak bypasses the normal layout mapping")
    try check(HotkeyChord.resolvePasteKeyCode(inputSourceID: "no-V-layout", characterForKey: { _ in 0 }) == 9,
              "Unusable layout mapping retains the safe standard-key fallback")

    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift, .capsLock],
                                timestamp: 0, windowNumber: 0, context: nil, characters: "V",
                                charactersIgnoringModifiers: "v", isARepeat: false, keyCode: UInt16(kVK_ANSI_V))
    try check(event != nil, "Synthetic key event is constructible")
    if let event {
        try check(HotkeyChord.from(event: event) == old, "Recorder uses key code and ignores Caps Lock")
    }
    let keyUp = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [.command], timestamp: 0,
                                windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v",
                                isARepeat: false, keyCode: UInt16(kVK_ANSI_V))
    if let keyUp { try check(HotkeyChord.from(event: keyUp) == nil, "Recorder does not consume release events") }
}
