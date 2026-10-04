import AppKit

@MainActor private final class ShortcutRecorderMenuProbe: NSObject {
    var calls = 0
    @objc func invoke(_ sender: Any?) { calls += 1 }
}

@MainActor func runShortcutRecorderTests() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let otherWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; otherWindow.isReleasedWhenClosed = false
    let field = ShortcutField(frame: NSRect(x: 10, y: 10, width: 232, height: 42))
    let next = NSTextField(frame: NSRect(x: 10, y: 60, width: 232, height: 22))
    window.contentView?.addSubview(field); window.contentView?.addSubview(next)
    field.nextKeyView = next; next.nextKeyView = field
    defer { field.cancelRecording(); window.close(); otherWindow.close() }
    var transitions: [Bool] = []
    var recorded: [String] = []
    field.onRecordingChanged = { transitions.append($0) }
    field.onRecord = { recorded.append($0) }
    func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], characters: String = "",
             in eventWindow: NSWindow? = nil, type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: (eventWindow ?? window).windowNumber, context: nil,
                        characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: code)!
    }
    func begin() throws {
        transitions.removeAll()
        try check(window.makeFirstResponder(field) && field.isRecording, "hidden private window starts keyboard shortcut recording")
        try check(transitions == [true] && field.stringValue == "按下组合键…", "recording shows a clear prompt and pauses shortcuts once")
    }
    func ended(_ message: String) throws {
        try check(!field.isRecording && transitions == [true, false], message)
        field.cancelRecording()
        try check(transitions == [true, false], "repeat cancellation does not resume shortcuts twice")
    }

    try check(!window.isVisible && !otherWindow.isVisible, "recorder fixtures never display windows or target other applications")
    try check(field.stringValue == "点击设置" && field.intrinsicContentSize.height == 40 && field.font?.pointSize == 18,
              "empty shortcut has a readable action and native forty-point height")
    field.accelerator = "CommandOrControl+Shift+V"
    try check(field.stringValue == "⇧ ⌘ V", "modifier symbols and main key have readable separation")
    try check(field.accessibilityRole() == .button && field.accessibilityHelp()?.contains("按下组合键") == true,
              "accessibility identifies an actionable recorder and explains how to record")

    try begin()
    _ = field.becomeFirstResponder()
    try check(transitions == [true], "repeated focus does not pause shortcuts twice")
    field.keyDown(with: key(0, characters: "a"))
    try check(field.isRecording && recorded.isEmpty && field.accelerator == "CommandOrControl+Shift+V"
              && field.stringValue.contains("请同时按"), "unmodified letters remain unbound and show visible guidance")
    field.keyDown(with: key(0, flags: .shift, characters: "A"))
    try check(field.isRecording && recorded.isEmpty, "Shift with a letter cannot become a new modifier-only shortcut")
    field.keyDown(with: key(56, flags: .shift, type: .flagsChanged))
    try check(field.isRecording && recorded.isEmpty, "modifier changes alone never commit a shortcut")
    field.keyDown(with: key(53, characters: "\u{1b}"))
    try ended("Esc restores shortcuts exactly once and ends recording")
    try check(field.accelerator == "CommandOrControl+Shift+V" && field.stringValue == "⇧ ⌘ V" && recorded.isEmpty,
              "Esc preserves the original setting after rejected input")

    try begin()
    try check(field.performKeyEquivalent(with: key(12, flags: .command, characters: "q")),
              "recording consumes the key-equivalent path before menu commands")
    try ended("a menu-like key equivalent ends recording exactly once")
    try check(recorded.last == "Command+Q" && field.accelerator == "Command+Q", "key-equivalent capture preserves the actual key and modifiers")
    try check(!field.performKeyEquivalent(with: key(12, flags: .command, characters: "q")),
              "inactive recording leaves normal menu equivalents available")

    let originalMenu = NSApp.mainMenu
    let menu = NSMenu()
    let menuTarget = ShortcutRecorderMenuProbe()
    let item = NSMenuItem(title: "Recorder fixture", action: #selector(ShortcutRecorderMenuProbe.invoke(_:)), keyEquivalent: "b")
    item.target = menuTarget; item.keyEquivalentModifierMask = .command
    menu.addItem(item); NSApp.mainMenu = menu
    defer { NSApp.mainMenu = originalMenu }
    try begin()
    NSApp.sendEvent(key(11, flags: .command, characters: "b"))
    try ended("private application event dispatch balances recording callbacks")
    try check(recorded.last == "Command+B" && menuTarget.calls == 0,
              "the temporary local monitor captures a private-window key before the menu action")

    try begin()
    try check(!field.performKeyEquivalent(with: key(9, flags: .command, characters: "v", in: otherWindow))
              && field.isRecording, "unrelated window events cannot be captured")
    field.keyDown(with: key(9, flags: [.shift, .command, .capsLock], characters: "V"))
    try ended("normal chord capture resumes shortcuts exactly once")
    try check(recorded.last == "Shift+Command+V" && field.stringValue == "⇧ ⌘ V", "captured chords ignore caps lock and retain Shift")

    for code: UInt16 in [51, 117] {
        try begin()
        field.keyDown(with: key(code))
        try ended("bare Backspace and Delete clear recording and resume shortcuts once")
        try check(field.accelerator.isEmpty && recorded.last == "" && field.stringValue == "点击设置",
                  "clear key publishes an empty shortcut with an actionable placeholder")
        field.accelerator = "Command+V"
    }
    field.accelerator = ""
    try begin()
    ShortcutField.cancelRecording(in: window)
    field.accelerator = ""
    try ended("Disable finishes recording even when the binding was already empty")
    field.accelerator = "Command+V"
    try begin()
    field.keyDown(with: key(51, flags: .command))
    try ended("modified Backspace records a chord instead of clearing it")
    try check(recorded.last == "Command+Backspace", "only unmodified deletion keys disable the shortcut")

    try begin()
    field.keyDown(with: key(105))
    try ended("a standalone function key remains supported")
    try check(recorded.last == "F13", "existing modifier-free function-key support is retained")

    try begin()
    let beforeUnsupported = recorded.count
    field.keyDown(with: key(63, flags: .command))
    try check(field.isRecording && field.stringValue.contains("暂不支持") && recorded.count == beforeUnsupported,
              "unsupported keys show a visible retry prompt without binding a modifier")
    field.cancelRecording()
    try ended("canceling unsupported input has one balanced recording callback")

    try begin()
    field.accelerator = "Command+Option+B"
    try ended("external Disable or Restore edits end recording exactly once")
    try check(field.accelerator == "Command+Option+B" && field.stringValue == "⌥ ⌘ B",
              "external edits cannot be overwritten by a pending recording")
    let beforeInactive = recorded.count
    field.keyDown(with: key(9, flags: .command, characters: "v"))
    try check(recorded.count == beforeInactive && field.accelerator == "Command+Option+B", "late keys after cancellation never commit")

    try begin()
    field.isEnabled = false
    try ended("disabling the control resumes shortcuts exactly once")
    _ = window.makeFirstResponder(field)
    try check(!field.isRecording && !field.acceptsFirstResponder && !field.accessibilityPerformPress(),
              "disabled shortcut controls cannot start recording")
    field.isEnabled = true

    try begin()
    ShortcutField.cancelRecording(in: window)
    try ended("Save and Disable can synchronously finish recording before their actions")
    try begin()
    ShortcutField.cancelRecording(in: otherWindow)
    try check(field.isRecording && transitions == [true], "cleanup in another window cannot cancel this recorder")
    _ = window.makeFirstResponder(next)
    try ended("keyboard focus leaving the field resumes shortcuts exactly once")

    try begin()
    field.keyDown(with: key(48, characters: "\t"))
    try ended("Tab leaves recording without creating a shortcut")
    try check(window.firstResponder !== field && field.accelerator == "Command+Option+B", "Tab keeps the previous binding and permits keyboard navigation")

    transitions.removeAll()
    try check(field.accessibilityPerformPress() && field.isRecording && transitions == [true], "an accessibility press starts recording")
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: otherWindow)
    try check(field.isRecording && transitions == [true], "another window's focus notification is ignored")
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    try ended("window focus loss synchronously resumes shortcuts once")

    try begin()
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    try ended("hiding the settings window ends recording without waiting for view teardown")
    try begin()
    field.removeFromSuperview()
    try ended("leaving the shortcut page resumes shortcuts during native view removal")
    window.contentView?.addSubview(field)
    try begin()
    window.close()
    try ended("closing a private settings window has one balanced callback")
}
