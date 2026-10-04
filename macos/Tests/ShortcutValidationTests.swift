import AppKit
import Foundation

@MainActor func runShortcutValidationTests() throws {
    try runPureShortcutValidationTests()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-shortcut-validation-" + UUID().uuidString)
    let controller = AppController(directory: directory, testMode: true, accessibilityPermissionCheck: { _ in false })
    defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("settings.json")

    try check(controller.shortcutIssues.isEmpty, "default enabled shortcut bindings have no local validation issues")
    controller.saveSettings()
    try check(FileManager.default.fileExists(atPath: file.path), "valid shortcut settings establish an isolated saved baseline")
    try check(controller.effectiveHotkey == controller.settings.hotkey, "valid isolated save establishes the effective panel shortcut")

    controller.settings.hotkey = "Command+"
    try checkRejectedShortcutSave(controller, file: file, expectedIssues: ["panel"], context: "invalid panel format")
    try check(controller.settings.hotkey == "Command+", "rejected invalid shortcut remains available as an editable draft")

    controller.settings.hotkey = "cmd+shift+b"
    try checkRejectedShortcutSave(controller, file: file, expectedIssues: ["panel", "studio"], context: "alias duplicate between common actions")
    try check(controller.settings.hotkey == "cmd+shift+b" && controller.settings.studioHotkey == "Command+Shift+B", "rejected duplicate preserves both original shortcut drafts")

    controller.settings.hotkey = "Command+Shift+V"
    controller.settings.windowShortcuts["left-half"] = "Unknown+Left"
    try checkRejectedShortcutSave(controller, file: file, expectedIssues: ["window:left-half"], context: "invalid enabled window shortcut")
    controller.settings.windowManagerEnabled = false
    try check(controller.shortcutIssues.isEmpty, "disabled window manager excludes invalid window drafts from active validation")
    controller.saveSettings()
    let disabledWindowSettings = AppSettings(directory: directory)
    try check(!disabledWindowSettings.windowManagerEnabled && disabledWindowSettings.windowShortcuts["left-half"] == "Unknown+Left", "disabled window shortcut draft is retained without preventing a valid save")
    let disabledMenu = controller.makeStatusMenu().item(withTitle: "调整窗口")?.submenu
    try check(disabledMenu?.items.allSatisfy { $0.keyEquivalent.isEmpty } == true, "saved disabled window manager removes its menu accelerators")

    controller.settings.windowManagerEnabled = true
    try checkRejectedShortcutSave(controller, file: file, expectedIssues: ["window:left-half"], context: "reenabling an invalid window draft")
    controller.settings.windowManagerEnabled = false
    controller.settings.windowShortcuts["left-half"] = "Cmd+Shift+V"
    try check(controller.shortcutIssues.isEmpty, "disabled window manager excludes a conflicting window draft from active validation")
    controller.saveSettings()
    try check(AppSettings(directory: directory).windowShortcuts["left-half"] == "Cmd+Shift+V", "disabled conflicting window draft survives a valid save")
    controller.settings.windowManagerEnabled = true
    try checkRejectedShortcutSave(controller, file: file, expectedIssues: ["panel", "window:left-half"], context: "duplicate between a window and a common action")
    try check(controller.settings.windowManagerEnabled && controller.settings.windowShortcuts["left-half"] == "Cmd+Shift+V", "rejected window conflict retains the enabled state and shortcut draft")

    controller.settings.windowShortcuts["left-half"] = "Control+Option+X"
    try check(controller.shortcutIssues.isEmpty, "correcting the conflicting draft clears local validation issues")
    controller.saveSettings()
    let corrected = AppSettings(directory: directory)
    try check(corrected.windowManagerEnabled && corrected.windowShortcuts["left-half"] == "Control+Option+X", "corrected window shortcut is saved normally")
    let correctedWindowItem = controller.makeStatusMenu().item(withTitle: "调整窗口")?.submenu?.item(withTitle: "左半屏")
    try check(correctedWindowItem?.keyEquivalent == "x" && correctedWindowItem?.keyEquivalentModifierMask == [.control, .option], "corrected save updates the window menu accelerator")

    controller.settings.hotkey = ""
    controller.settings.screenshotHotkey = ""
    controller.settings.windowShortcuts["left-half"] = ""
    try check(controller.shortcutIssues.isEmpty, "empty common and window shortcuts are valid disabled values")
    controller.saveSettings()
    let emptySettings = AppSettings(directory: directory)
    try check(emptySettings.hotkey.isEmpty && emptySettings.screenshotHotkey.isEmpty && emptySettings.windowShortcuts["left-half"] == "", "disabled common and window shortcuts survive settings reload")
    try check(controller.effectiveHotkey.isEmpty, "saving a disabled panel shortcut clears the effective accelerator")
    let emptyMenu = controller.makeStatusMenu()
    try check(emptyMenu.item(withTitle: "打开剪贴板")?.keyEquivalent == "" && emptyMenu.item(withTitle: "区域截图")?.keyEquivalent == "", "disabled common shortcuts have no menu accelerators")
    let emptyWindowItem = emptyMenu.item(withTitle: "调整窗口")?.submenu?.item(withTitle: "左半屏")
    try check(emptyWindowItem?.keyEquivalent == "" && emptyWindowItem?.isEnabled == true, "disabled window shortcut retains the manual menu action")
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    let rawWindow = raw?["windowManager"] as? [String: Any]
    let rawShortcuts = rawWindow?["shortcuts"] as? [String: Any]
    try check(rawShortcuts?["left-half"] is NSNull, "explicit window disable retains its legacy null persistence value")

    controller.settings.hotkey = "Command+Option+V"
    controller.settings.screenshotHotkey = "Command+Option+2"
    controller.saveSettings()
    let finalMenu = controller.makeStatusMenu()
    try check(controller.effectiveHotkey == "Command+Option+V" && AppSettings(directory: directory).hotkey == "Command+Option+V", "reenabling a valid panel shortcut updates both effective and persisted settings")
    try check(finalMenu.item(withTitle: "打开剪贴板")?.keyEquivalent == "v" && finalMenu.item(withTitle: "打开剪贴板")?.keyEquivalentModifierMask == [.command, .option], "reenabling a common shortcut updates its menu accelerator")
    try check(finalMenu.item(withTitle: "区域截图")?.keyEquivalent == "2" && finalMenu.item(withTitle: "区域截图")?.keyEquivalentModifierMask == [.command, .option], "reenabling the screenshot shortcut updates its menu accelerator")
    print("Shortcut validation tests passed (pure checks, private settings, no system hotkey registration)")
}

private func runPureShortcutValidationTests() throws {
    try check(ShortcutValidation.issues(in: [:]).isEmpty, "empty shortcut binding set is valid")
    try check(ShortcutValidation.issues(in: ["panel": "", "studio": "", "window:left-half": ""]).isEmpty, "pure shortcut validation treats empty values as disabled")
    try check(ShortcutValidation.issues(in: ["panel": "V", "studio": "Shift+B", "screenshot": "F1"]).isEmpty, "existing bare keys, Shift combinations and function keys remain legal")
    try check(ShortcutValidation.issues(in: ["panel": "Command+Shift+V", "studio": "Command+Shift+B", "screenshot": "Control+Option+Return"]).isEmpty, "distinct valid chords have no validation issues")
    let invalid = ShortcutValidation.issues(in: ["panel": "Command+", "studio": "Unknown+B", "screenshot": "Command++2"])
    try check(Set(invalid.keys) == ["panel", "studio", "screenshot"] && invalid.values.allSatisfy { !$0.isEmpty }, "format errors identify each affected action with a usable message")
    let commandAliases = ShortcutValidation.issues(in: ["panel": "cmd+SHIFT+v", "screenshot": "CommandOrControl+Shift+V", "studio": "Command+Shift+B"])
    try check(Set(commandAliases.keys) == ["panel", "screenshot"], "Command aliases identify both conflicting rows without marking unrelated actions")
    let optionAliases = ShortcutValidation.issues(in: ["studio": "Ctrl+Alt+ArrowLeft", "window:left-half": "Control+Option+Left"])
    try check(Set(optionAliases.keys) == ["studio", "window:left-half"], "Control, Option and arrow aliases conflict across common and window actions")
    let returnAliases = ShortcutValidation.issues(in: ["panel": "Command+Enter", "screenshot": "Command+Return"])
    try check(Set(returnAliases.keys) == ["panel", "screenshot"], "Enter and Return aliases identify the same shortcut")
    let mixed = ShortcutValidation.issues(in: ["panel": "Cmd+B", "studio": "Command+B", "screenshot": "Bad+2", "window:left-half": ""])
    try check(Set(mixed.keys) == ["panel", "studio", "screenshot"], "duplicate and format issues coexist while disabled bindings stay valid")
}

@MainActor private func checkRejectedShortcutSave(_ controller: AppController, file: URL, expectedIssues: Set<String>, context: String) throws {
    try check(Set(controller.shortcutIssues.keys) == expectedIssues, context + " exposes the affected draft actions")
    let beforeData = try Data(contentsOf: file)
    let beforeEffective = controller.effectiveHotkey
    let beforeMenu = shortcutMenuSnapshot(controller.makeStatusMenu())
    controller.saveSettings()
    let afterData = try Data(contentsOf: file)
    try check(afterData == beforeData, context + " leaves settings.json byte-for-byte unchanged")
    try check(controller.effectiveHotkey == beforeEffective, context + " preserves the effective saved panel shortcut")
    try check(shortcutMenuSnapshot(controller.makeStatusMenu()) == beforeMenu, context + " preserves every saved menu accelerator")
}

@MainActor private func shortcutMenuSnapshot(_ menu: NSMenu) -> [String] {
    menu.items.flatMap { item -> [String] in
        let value = [item.title, item.keyEquivalent, String(item.keyEquivalentModifierMask.rawValue), item.toolTip ?? "", item.representedObject as? String ?? ""].joined(separator: "\u{1f}")
        if let submenu = item.submenu { return [value] + shortcutMenuSnapshot(submenu) }
        return [value]
    }
}
