import AppKit
import Combine

@MainActor func runAppTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-native-app-test-" + UUID().uuidString)
    let controller = AppController(directory: directory, testMode: true, messageLifetime: 0.12)
    defer { controller.hidePanel(); controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
    controller.start()
    _ = controller.registerShortcuts(allowFallback: true)
    let initialMenu = controller.makeStatusMenu()
    try check(initialMenu.items.contains { $0.title.hasPrefix("区域截图") && $0.title.contains("⇧⌘2") }, "screenshot menu exposes configured global shortcut")
    let initialLayouts = initialMenu.item(withTitle: "调整窗口")?.submenu
    try check(initialLayouts?.items.contains { $0.title.hasPrefix("左半屏") && $0.title.contains("⌃⌥←") } == true, "window submenu exposes layout shortcuts")
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
    try check(editedMenu.items.contains { $0.title.hasPrefix("区域截图") && $0.title.contains("⌥⌘2") }, "saved screenshot shortcut updates the menu")
    try check(editedMenu.item(withTitle: "调整窗口")?.submenu?.items.contains { $0.title.hasPrefix("左半屏") && $0.title.contains("⌃⌥X") } == true, "saved window shortcut updates submenu")
    try check(AppSettings(directory: directory).screenshotHotkey == "Command+Alt+2" && AppSettings(directory: directory).windowShortcuts["left-half"] == "Control+Alt+X", "screenshot and layout shortcut edits survive settings reload")
    try check(!AppSettings(directory: directory).autoPaste, "controller saves native settings")
    let savedHotkey = AppSettings(directory: directory).hotkey
    controller.settings.hotkey = "Command+Option+X" // Unsaved Settings draft.
    controller.setAppearance("dark")
    let themedSettings = AppSettings(directory: directory)
    try check(themedSettings.appearance == "dark" && themedSettings.hotkey == savedHotkey, "toolbar appearance saves only persisted state without saving unregistered hotkey draft")
    try check(controller.settings.hotkey == "Command+Option+X", "theme change preserves active Settings draft")
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
    let shortcutEntry = controller.makeStatusMenu().item(withTitle: "快捷键设置…")!
    try check(NSApp.sendAction(shortcutEntry.action!, to: shortcutEntry.target, from: shortcutEntry) && controller.settingsSection == "shortcuts", "menu shortcut settings action opens the unified recorder page")
    for window in NSApp.windows where window.title == "Kaki Tools 设置" { window.close() }
    print("Native controller interaction tests passed (private pasteboard, no external window actions)")
}
