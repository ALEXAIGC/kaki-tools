import AppKit
import Combine

@MainActor func runPermissionRefreshTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-permission-refresh-" + UUID().uuidString)
    var trusted = false
    var checks: [Bool] = []
    let controller = AppController(directory: directory, testMode: true, accessibilityPermissionCheck: { prompt in
        checks.append(prompt); return trusted
    })
    defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
    try check(!controller.accessibilityTrusted, "permission badge initially reflects denied system state")
    trusted = true
    controller.showSettings(section: "about")
    let window = NSApp.windows.first { $0.title == "Kaki Tools 设置" && $0.isVisible }!
    defer { window.close() }
    try check(controller.accessibilityTrusted, "opening settings replaces a stale denied permission with current authorization")
    trusted = false
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    try check(!controller.accessibilityTrusted, "returning to settings reads revocation even when the app is already active")
    trusted = true
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try check(controller.accessibilityTrusted, "returning from System Settings refreshes granted permission")
    trusted = false
    controller.refreshAccessibilityPermission()
    try check(!controller.accessibilityTrusted, "manual refresh reads the current system permission instead of a cached badge")
    let before = checks.count
    let unrelated = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    unrelated.isReleasedWhenClosed = false
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: unrelated)
    try check(checks.count == before, "unrelated windows do not trigger settings permission checks")
    unrelated.close()
    try check(checks.allSatisfy { !$0 }, "passive permission refresh never requests authorization")
    trusted = true
    controller.requestAccessibility()
    try check(controller.accessibilityTrusted && Array(checks.suffix(2)) == [true, false], "explicit authorization is followed by a fresh non-prompting state check")
    print("Permission refresh tests passed (injected system state, no real authorization changes)")
}

@MainActor func runAppTests() async throws {
    try await runAppearanceUpdateTests()
    try await runConcurrentSettingsTests()
    try await runCacheLocationRollbackTest()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-native-app-test-" + UUID().uuidString)
    let controller = AppController(directory: directory, testMode: true, messageLifetime: 0.12)
    defer { controller.hidePanel(); controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
    controller.start()
    _ = controller.registerShortcuts(allowFallback: true)
    let initialMenu = controller.makeStatusMenu()
    try check(initialMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["打开剪贴板", "打开素材库", "调整窗口", "区域截图", "设置…", "退出 Kaki Tools"], "status menu keeps only common actions and one settings entry")
    try check(initialMenu.item(withTitle: "打开剪贴板")?.keyEquivalent == "v" && initialMenu.item(withTitle: "打开剪贴板")?.keyEquivalentModifierMask == [.command, .shift], "clipboard shortcut is displayed in the native shortcut column")
    try check(initialMenu.item(withTitle: "区域截图")?.keyEquivalent == "2" && initialMenu.item(withTitle: "区域截图")?.keyEquivalentModifierMask == [.command, .shift], "screenshot menu exposes configured global shortcut")
    try check(initialMenu.item(withTitle: "打开素材库")?.keyEquivalent == "b" && initialMenu.item(withTitle: "打开素材库")?.keyEquivalentModifierMask == [.command, .shift], "material library menu exposes Command Shift B")
    let initialLayouts = initialMenu.item(withTitle: "调整窗口")?.submenu
    try check(initialLayouts?.item(withTitle: "左半屏")?.keyEquivalent == String(UnicodeScalar(NSLeftArrowFunctionKey)!) && initialLayouts?.item(withTitle: "左半屏")?.keyEquivalentModifierMask == [.control, .option], "window submenu exposes layout shortcuts")
    try check(Set(initialLayouts?.items.compactMap { $0.representedObject as? String } ?? []) == Set(WindowManager.layouts.map(\.id)), "grouped window menu retains every layout")
    try check(initialLayouts?.items.first?.representedObject as? String == "maximize" && initialLayouts?.items.first?.keyEquivalent == "\r", "fill-window action remains prominent with its return shortcut")
    let negativeScreen = NSRect(x: -1920, y: -180, width: 1920, height: 1057)
    try check(AppController.panelFrame(workArea: negativeScreen) == NSRect(x: -1920, y: -180, width: 1920, height: 332), "panel fills target screen width and rests at work area bottom")
    try check(AppController.panelFrame(workArea: NSRect(x: 400, y: 200, width: 480, height: 240)) == NSRect(x: 400, y: 200, width: 480, height: 240), "small work area bounds panel without minimum width overflow")
    let countItems = [HistoryItem(type: "text", text: "ordinary", pinned: true),
                      HistoryItem(type: "image"), HistoryItem(type: "text", text: "board", pinned: true, board: "favorites")]
    try check(AppController.boardCounts(countItems, board: nil) == [.all: 2, .text: 1, .image: 1, .pinned: 1], "ordinary sidebar counts exclude board copies and include every type")
    try check(AppController.boardCounts(countItems, board: "favorites") == [.all: 1, .text: 1, .image: 0, .pinned: 1], "board sidebar counts include only current board")
    controller.store.addText("first full-text record", html: "<b>formatted</b>", rtf: nil)
    controller.store.addText("second content", html: nil, rtf: nil)
    controller.store.addText("third content", html: nil, rtf: nil)
    try await Task.sleep(nanoseconds: 120_000_000)
    try check(controller.visibleItems.count == 3, "controller publishes ordinary items")
    try check(controller.currentBoardCounts[.all] == 3 && controller.currentBoardCounts[.text] == 3, "controller exposes unfiltered current board counts")
    try check(controller.selectedItem != nil && controller.canPasteSelected && controller.canPasteSelectedAsPlainText, "selected text enables paste and plain footer actions")
    let second = controller.visibleItems[1].id
    controller.store.updateMetadata(id: second, tags: ["needle"], note: "annotation")
    controller.query = "first"; controller.query = "needle"
    try await Task.sleep(nanoseconds: 180_000_000)
    try check(controller.visibleItems.map(\.id) == [second], "latest debounced query wins and searches tags")
    try check(controller.currentBoardCounts[.all] == 3, "sidebar counts remain independent of search")
    controller.filter = .image
    try check(controller.selectedItem == nil && !controller.canPasteSelected && !controller.canPinSelected && !controller.canDeleteSelected, "latest filter immediately disables stale selection before render debounce")
    controller.filter = .all
    controller.query = "annotation"
    try await Task.sleep(nanoseconds: 120_000_000)
    try check(controller.visibleItems.map(\.id) == [second], "controller searches notes")
    _ = controller.store.createBoard("favorites")
    controller.store.addToBoard(id: second, board: "favorites")
    controller.query = ""; controller.board = "favorites"
    try await Task.sleep(nanoseconds: 120_000_000)
    try check(controller.visibleItems.count == 1 && controller.visibleItems[0].board == "favorites", "board isolates independent copy")
    try check(controller.currentBoardCounts[.all] == 1, "sidebar reflects selected board unfiltered count")
    controller.board = nil
    try await Task.sleep(nanoseconds: 120_000_000)
    var panelShownNotifications = 0, panelHiddenNotifications = 0
    let panelShownObserver = NotificationCenter.default.publisher(for: .kakiPanelShown, object: controller).sink { _ in panelShownNotifications += 1 }
    let panelHiddenObserver = NotificationCenter.default.publisher(for: .kakiPanelHidden, object: controller).sink { _ in panelHiddenNotifications += 1 }
    defer { panelShownObserver.cancel(); panelHiddenObserver.cancel() }
    let openingScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first!
    let expectedOpeningFrame = AppController.panelFrame(workArea: openingScreen.visibleFrame)
    controller.showPanel()
    try check(panelShownNotifications == 1, "panel shown notification identifies its controller for visible-only clocks")
    try await Task.sleep(nanoseconds: 20_000_000)
    let openingPanel = NSApp.windows.compactMap { $0 as? ClipboardPanel }.first { $0.controller === controller }
    try check(openingPanel?.frame == expectedOpeningFrame, "first shown native panel keeps full screen-width 332-point frame after SwiftUI layout")
    try await Task.sleep(nanoseconds: 80_000_000)
    let firstID = controller.visibleItems[0].id
    controller.selectedID = firstID
    func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], chars: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: 0, context: nil, characters: chars,
                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }
    try check(controller.handleKey(key(124)), "right arrow navigates while empty search is focused")
    try check(controller.selectedID == controller.visibleItems[1].id, "right arrow selects next card")
    let selected = controller.selectedID!
    let beforeHover = controller.store.item(id: firstID)!.createdAt
    controller.selectItem(firstID)
    try check(controller.panelIsVisible && controller.selectedItem?.id == firstID && controller.store.item(id: firstID)?.createdAt == beforeHover, "hover selection changes footer without activating or touching history")
    controller.selectItem(selected)
    var focusRequests = 0
    let focusObserver = NotificationCenter.default.publisher(for: .kakiFocusSearch, object: controller).sink { _ in focusRequests += 1 }
    defer { focusObserver.cancel() }
    try check(controller.handleKey(key(3, flags: .command, chars: "f")) && focusRequests == 1, "command-F requests search focus through controller-scoped notification")
    try check(controller.handleKey(key(35, flags: .command, chars: "p")), "command-P handled")
    try check(controller.store.item(id: selected)?.pinned == true, "keyboard pin updates only chosen item")
    controller.activateSelected(plainText: true, copyOnly: true)
    try check(!controller.panelIsVisible, "copy closes panel in isolated mode")
    try check(panelHiddenNotifications >= 1, "activation sends controller-scoped panel hidden notification")
    let count = controller.store.items.count
    controller.clipboard.captureNow()
    try check(controller.store.items.count == count, "activation is not recaptured as new history")
    controller.showPanel()
    try check(controller.handleKey(key(53)), "escape handled")
    try check(!controller.panelIsVisible, "escape hides reusable panel")
    let staleID = controller.store.items.first!.id
    let staleTime = controller.store.item(id: staleID)!.createdAt
    controller.query = "does not exist"
    controller.showPanel()
    controller.activate(staleID, copyOnly: true)
    try check(controller.store.item(id: staleID)?.createdAt == staleTime, "stale excluded card cannot be activated during debounce")
    try check(controller.handleKey(key(36)), "enter during new pending query handled")
    try check(controller.panelIsVisible, "empty latest query cannot paste stale selection")
    try check(controller.visibleItems.isEmpty && controller.selectedID == nil, "activation resolves newest search without debounce delay")
    controller.query = "first full-text"
    try check(controller.handleKey(key(36)), "enter resolves latest nonempty search")
    try check(!controller.panelIsVisible, "latest matching item is used immediately")
    try check(controller.store.items.first?.text == "first full-text record", "latest match, rather than old selection, is activated")
    controller.query = "third content"; controller.showPanel()
    try check(controller.handleKey(key(18, flags: .command, chars: "1")), "command digit resolves latest query")
    try check(controller.store.items.first?.text == "third content", "command digit uses latest filtered ordering")
    controller.query = "second content"
    try check(controller.handleKey(key(124)), "navigation resolves latest query")
    try check(controller.visibleItems.count == 1 && controller.visibleItems[0].text == "second content", "navigation cannot retain stale search list")
    controller.query = "missing new query"
    try check(controller.selectedItem == nil && !controller.canPasteSelected, "footer cannot publish a stale excluded record during pending query")
    let pinnedBefore = controller.store.item(id: second)!.pinned
    controller.toggleSelectedPin(); controller.deleteSelected(); controller.activateSelected(copyOnly: true)
    try check(controller.store.item(id: second)?.pinned == pinnedBefore, "stale footer pin does not mutate excluded item")
    try check(controller.store.item(id: second) != nil, "stale footer delete does not remove excluded item")
    controller.query = "first full-text"
    controller.toggleSelectedPin()
    try check(controller.selectedItem?.text == "first full-text record" && controller.selectedItem?.pinned == true, "footer pin resolves latest matching selection immediately")
    controller.query = ""
    controller.resolveCurrentItems()
    let deletingID = controller.visibleItems[1].id, neighborID = controller.visibleItems[2].id
    controller.selectItem(deletingID); controller.deleteSelected()
    try check(controller.store.item(id: deletingID) == nil && controller.selectedID == neighborID, "footer delete selects nearest remaining card at deleted position")
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")!
    try check(controller.store.captureImage(data: png), "pending footer test accepts isolated image")
    let pendingID = controller.store.items.first!.id
    controller.selectItem(pendingID)
    try check(controller.selectedItem?.type == "image" && !controller.canPasteSelected && !controller.canPasteSelectedAsPlainText, "pending image footer remains selected while disabling playback")
    try check(controller.canPinSelected && controller.canDeleteSelected && controller.currentBoardCounts[.image] == 1, "pending image remains counted and can be safely pinned or cancelled")
    controller.activateSelected(plainText: true)
    try check(controller.store.isPending(id: pendingID), "plain text footer cannot activate image")
    controller.deleteSelected()
    try check(!controller.store.isPending(id: pendingID) && controller.store.item(id: pendingID) == nil, "footer deletion cancels pending image without waiting for encoder")
    controller.settings.screenshotHotkey = "Command+Alt+2"
    controller.settings.windowShortcuts["left-half"] = "Control+Alt+X"
    controller.settings.autoPaste = false; controller.saveSettings()
    let editedMenu = controller.makeStatusMenu()
    try check(editedMenu.item(withTitle: "区域截图")?.keyEquivalent == "2" && editedMenu.item(withTitle: "区域截图")?.keyEquivalentModifierMask == [.command, .option], "saved screenshot shortcut updates the menu")
    try check(editedMenu.item(withTitle: "调整窗口")?.submenu?.item(withTitle: "左半屏")?.keyEquivalent == "x" && editedMenu.item(withTitle: "调整窗口")?.submenu?.item(withTitle: "左半屏")?.keyEquivalentModifierMask == [.control, .option], "saved window shortcut updates submenu")
    controller.settings.screenshotHotkey = ""; controller.settings.windowManagerEnabled = false; controller.saveSettings()
    let disabledMenu = controller.makeStatusMenu()
    try check(disabledMenu.item(withTitle: "区域截图")?.keyEquivalent == "" && disabledMenu.item(withTitle: "区域截图")?.isEnabled == true, "disabled screenshot shortcut retains a clean clickable menu action")
    try check(disabledMenu.item(withTitle: "调整窗口")?.submenu?.items.allSatisfy { $0.keyEquivalent.isEmpty } == true, "disabled window shortcuts are omitted while manual layouts remain available")
    controller.settings.screenshotHotkey = "Command+Alt+2"; controller.settings.windowManagerEnabled = true; controller.saveSettings()
    try check(AppSettings(directory: directory).screenshotHotkey == "Command+Alt+2" && AppSettings(directory: directory).windowShortcuts["left-half"] == "Control+Alt+X", "screenshot and layout shortcut edits survive settings reload")
    try check(!AppSettings(directory: directory).autoPaste, "controller saves native settings")
    let savedHotkey = AppSettings(directory: directory).hotkey
    controller.settings.hotkey = "Command+Option+X" // Unsaved Settings draft.
    controller.setAppearance("dark")
    let themedSettings = AppSettings(directory: directory)
    try check(themedSettings.appearance == "dark" && themedSettings.hotkey == savedHotkey, "toolbar appearance saves only persisted state without saving unregistered hotkey draft")
    try check(controller.settings.hotkey == "Command+Option+X", "theme change preserves active Settings draft")
    controller.setDownloadPreferences(askEachTime: false, folder: directory.path)
    let downloadSettings = AppSettings(directory: directory)
    try check(!downloadSettings.downloadAskEachTime && downloadSettings.downloadFolder == directory.path && downloadSettings.hotkey == savedHotkey, "download preferences persist without saving unrelated shortcut drafts")
    try check(controller.settings.hotkey == "Command+Option+X", "download preferences preserve active Settings draft")
    controller.setCachePreferences(limitMB: 512, days: 30)
    let cachedSettings = AppSettings(directory: directory)
    try check(cachedSettings.studioCacheLimitMB == 512 && cachedSettings.studioCacheDays == 30 && cachedSettings.hotkey == savedHotkey, "cache preferences persist without saving unrelated shortcut drafts")
    controller.setAppearance("system")
    let recorderWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 50), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    recorderWindow.isReleasedWhenClosed = false
    let recorder = ShortcutField(frame: NSRect(x: 10, y: 10, width: 190, height: 28))
    var recordingTransitions: [Bool] = []
    recorder.onRecordingChanged = { recordingTransitions.append($0) }
    recorderWindow.contentView?.addSubview(recorder)
    recorderWindow.makeKeyAndOrderFront(nil); recorderWindow.makeFirstResponder(recorder)
    try check(recordingTransitions.last == true, "shortcut field enters recording")
    recorderWindow.close()
    try await Task.sleep(nanoseconds: 40_000_000)
    try check(recordingTransitions == [true, false], "closing settings during recording resumes shortcuts exactly once")
    controller.message = "earlier status"
    try await Task.sleep(nanoseconds: 80_000_000)
    controller.message = "latest status"
    try await Task.sleep(nanoseconds: 80_000_000)
    try check(controller.message == "latest status", "cancelled earlier cleanup cannot clear a newer direct message assignment")
    try await Task.sleep(nanoseconds: 100_000_000)
    try check(controller.message.isEmpty, "temporary message clears after latest assignment lifetime")
    controller.message = "shutdown status"
    controller.shutdown()
    try await Task.sleep(nanoseconds: 160_000_000)
    try check(controller.message == "shutdown status", "shutdown cancels queued message cleanup")
    controller.showSettings(section: "shortcuts")
    try check(controller.settingsSection == "shortcuts", "shortcut recorder remains accessible through unified settings")
    let settingsEntry = controller.makeStatusMenu().item(withTitle: "设置…")!
    try check(NSApp.sendAction(settingsEntry.action!, to: settingsEntry.target, from: settingsEntry) && controller.settingsSection == "shortcuts", "single settings entry preserves the last selected tab")
    controller.showSettings(section: "studio")
    try check(controller.settingsSection == "studio", "account connections remain accessible in settings")
    controller.showSettings(section: "downloads")
    try check(controller.settingsSection == "downloads", "download location preferences are accessible through settings")
    controller.showSettings(section: "universal-control")
    try check(controller.settingsSection == "downloads", "removed guide cannot become the selected settings section")
    controller.showSettings(section: "not-a-settings-section")
    try check(controller.settingsSection == "downloads", "unknown section cannot replace the selected settings tab")
    for window in NSApp.windows where window.title == "Kaki Tools 设置" { window.close() }
    print("Native controller interaction tests passed (private pasteboard, no external window actions)")
}

@MainActor private func runConcurrentSettingsTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-settings-interleave-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for attempt in 0..<5 {
        let dir = root.appendingPathComponent(String(attempt))
        let target = dir.appendingPathComponent("selected-disk")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["hotkey":"Command+Option+V", "unknownSetting":["keep":true]]).write(to: dir.appendingPathComponent("settings.json"))
        let app = AppController(directory: dir, testMode: true, accessibilityPermissionCheck: { _ in true })
        defer { app.shutdown() }
        let savedHotkey = app.settings.hotkey
        app.settings.hotkey = "Command+Option+X"
        app.setCacheLocation(folder: target.path, volumeUUID: "")
        for _ in 0..<200 { if app.studio.cacheChanging { break }; await Task.yield() }
        try check(app.studio.cacheChanging, "cache switch is suspended before concurrent settings updates")
        app.setDownloadPreferences(askEachTime: false, folder: dir.path)
        app.setAppearance("dark")
        app.setCachePreferences(limitMB: 768, days: 21)
        for _ in 0..<200 { if app.settings.studioCacheFolder == target.path { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let saved = AppSettings(directory: dir)
        try check(saved.studioCacheFolder == target.path && !saved.downloadAskEachTime && saved.downloadFolder == dir.path && saved.appearance == "dark" && saved.studioCacheLimitMB == 768 && saved.studioCacheDays == 21, "cache switch commits location without overwriting concurrent saved settings")
        try check(saved.hotkey == savedHotkey && app.settings.hotkey == "Command+Option+X", "cache switch preserves shortcut draft separately from effective saved binding")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("settings.json"))) as! [String: Any]
        try check((json["unknownSetting"] as? [String: Bool])?["keep"] == true, "field update preserves unknown settings")
        let occupied = dir.appendingPathComponent("occupied/Kaki Tools Cache")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("user-document".utf8).write(to: occupied.appendingPathComponent("keep.txt"))
        app.setCacheLocation(folder: occupied.deletingLastPathComponent().path, volumeUUID: "")
        for _ in 0..<200 { if app.message.contains("切换失败") { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let failed = AppSettings(directory: dir)
        try check(failed.studioCacheFolder == target.path && app.settings.studioCacheFolder == target.path && app.studio.cacheLocation == target.appendingPathComponent("Kaki Tools Cache").path, "failed cache switch leaves saved and active location unchanged")
        try check(failed.appearance == "dark" && failed.studioCacheLimitMB == 768 && !failed.downloadAskEachTime, "failed switch does not pollute independently saved preferences")
    }
}

@MainActor private func runCacheLocationRollbackTest() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-settings-rollback-" + UUID().uuidString)
    let target = dir.appendingPathComponent("new-disk")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let app = AppController(directory: dir, testMode: true, accessibilityPermissionCheck: { _ in true })
    defer { app.shutdown(); try? FileManager.default.removeItem(at: dir) }
    try app.settings.save()
    app.setCacheLocation(folder: target.path, volumeUUID: "")
    for _ in 0..<200 { if app.studio.cacheChanging { break }; await Task.yield() }
    try check(app.studio.cacheChanging, "rollback fixture overlaps the asynchronous cache move")
    let damaged = Data("preserve-invalid-settings".utf8)
    try damaged.write(to: dir.appendingPathComponent("settings.json"), options: .atomic)
    for _ in 0..<200 { if app.message.contains("切换失败") && !app.studio.cacheChanging { break }; try await Task.sleep(nanoseconds: 1_000_000) }
    try check(app.message.contains("切换失败") && app.settings.studioCacheFolder.isEmpty && app.studio.cacheLocation == dir.appendingPathComponent("studio-cache").path, "failed post-move settings commit rolls active location back")
    try check((try? Data(contentsOf: dir.appendingPathComponent("settings.json"))) == damaged, "fresh settings read failure preserves the newly damaged file rather than overwriting it with old snapshot")
    try app.settings.save()
    app.message = ""
    app.setCacheLocation(folder: target.path, volumeUUID: "not-the-selected-volume")
    for _ in 0..<200 { if app.message.contains("切换失败") { break }; try await Task.sleep(nanoseconds: 1_000_000) }
    try check(AppSettings(directory: dir).studioCacheFolder.isEmpty && app.studio.cacheLocation == dir.appendingPathComponent("studio-cache").path, "wrong volume identity cannot be committed as a cache location")
}

@MainActor private func runAppearanceUpdateTests() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-theme-events-" + UUID().uuidString)
    let app = AppController(directory: dir, testMode: true, accessibilityPermissionCheck: { _ in true })
    defer { app.shutdown(); try? FileManager.default.removeItem(at: dir) }
    var writes = 0
    let observation = NSApp.observe(\.appearance, options: .new) { _, _ in writes += 1 }
    defer { observation.invalidate() }
    app.settings.appearance = "dark"
    try check(NSApp.appearance?.name == .darkAqua && writes == 1, "Published appearance callback applies its new value exactly once")
    app.settings.autoPaste.toggle(); app.settings.hotkey = "draft"; app.settings.studioCacheDays = 30
    app.settings.appearance = "dark"
    try await Task.sleep(nanoseconds: 10_000_000)
    try check(writes == 1, "unrelated settings and duplicate theme value do not reapply NSApp appearance")
    app.setAppearance("light")
    try check(NSApp.appearance?.name == .aqua && writes == 2, "toolbar theme update applies once without a second explicit update")
    app.settings.appearance = "system"
    try check(NSApp.appearance == nil && writes == 3, "system appearance clears the override using the emitted new value")
}
