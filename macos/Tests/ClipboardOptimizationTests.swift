import AppKit
import Foundation

@MainActor func waitForClipboardSearch(_ controller: AppController, timeout: TimeInterval = 3) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !controller.resolveCurrentItems() {
        if ProcessInfo.processInfo.systemUptime >= deadline { throw NativeTestFailure(description: "Clipboard search did not finish") }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

@MainActor func runClipboardOptimizationTests() async throws {
    for text in ["", "  a\t b\n c  ", "中 文 👨‍👩‍👧‍👦 👩🏽‍💻", String(repeating: "word 中文 \n", count: 200), String(repeating: "👩🏽‍💻", count: 200)] {
        let expected = String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(160))
        let value = ClipboardTextPresentation(text)
        try check(value.summary == expected && value.utf16Count == text.utf16.count, "bounded display preserves whitespace and grapheme semantics")
    }
    try check(ClipboardTextPresentation.summary(String(repeating: " ", count: 100_000), scanLimit: 4096).isEmpty, "UI fallback limits whitespace-only work")
    let candidates = ["Command+Option+V", "Command+Alt+B", "Control+Option+X", "Command+Alt+Z", "Cmd+Option+Z", "invalid"]
    let bindings = ["panel": "Command+Shift+V", "studio": "Command+Option+B", "screenshot": "Command+Alt+V", "window:left-half": "Control+Alt+X"]
    try check(AppController.availableFallbacks(candidates, bindings: bindings) == ["Command+Alt+Z"], "fallback skips every enabled action, chord aliases and duplicate candidates")
    var focus = ClipboardFocusContext()
    focus.enter(frontPID: 10, ownPID: 1)
    let earlier = focus.revision
    focus.enter(frontPID: 20, ownPID: 1) // Open Settings directly from another application.
    focus.enter(frontPID: 1, ownPID: 1) // Open the panel inside Settings.
    try check(focus.externalPID == 20 && focus.revision == earlier + 1, "settings-to-panel entry retains the latest external application")
    focus.enter(frontPID: nil, ownPID: 1)
    try check(focus.externalPID == nil, "unknown external focus does not revive an old paste target")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-clipboard-optimization-" + UUID().uuidString)
    let controller = AppController(directory: dir, testMode: true, accessibilityPermissionCheck: { _ in false })
    defer { controller.hidePanel(); controller.shutdown(); try? FileManager.default.removeItem(at: dir) }
    let text = String(repeating: "large body 中文 ", count: 12_000) + " end-needle"
    controller.store.addText(text)
    controller.store.addText("another record")
    controller.query = "end-needle"; controller.query = ""; controller.query = "end-needle"
    try await waitForClipboardSearch(controller)
    try check(controller.visibleItems.count == 1 && !controller.searching, "A-B-A-B query reuse cancels abandoned work and never leaves search stuck")
    let normalizedSelection = controller.selectedID
    controller.query = "  END-NEEDLE  "
    try check(controller.selectedID == normalizedSelection && controller.selectedItem != nil && !controller.searching, "equivalent normalized query keeps its valid selection")
    controller.query = "end-needle"
    controller.query = "another"
    try check(controller.selectedItem == nil, "pending full-text search immediately disables stale footer actions")
    controller.query = "end-needle"
    try await waitForClipboardSearch(controller)
    let id = controller.visibleItems[0].id
    controller.selectItem(id)
    let oldTime = controller.store.items.first(where: { $0.id == id })!.createdAt
    let commandA = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
    try check(!controller.handleKey(commandA) && controller.selectedID == id && !controller.searching, "text editing command passes through without replacing valid search results")
    controller.requestTextPresentation(controller.visibleItems[0])
    for _ in 0..<100 where controller.textCount(for: controller.visibleItems[0]) == nil { try await Task.sleep(nanoseconds: 5_000_000) }
    try check(controller.textCount(for: controller.visibleItems[0]) == text.utf16.count, "display count is prepared once in background")
    try check(controller.summary(for: controller.visibleItems[0]) == String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(160)), "cached summary never truncates copied history")

    controller.query = "another"; controller.activateSelected(copyOnly: true)
    controller.query = "does-not-exist"
    try await waitForClipboardSearch(controller)
    try check(controller.store.items.first(where: { $0.id == id })?.createdAt == oldTime, "new query cancels a pending action from the preceding result generation")
    controller.query = "end-needle"
    controller.showPanel(); controller.activateSelected(copyOnly: true); controller.hidePanel()
    try await waitForClipboardSearch(controller)
    try check(controller.store.items.first(where: { $0.id == id })?.createdAt == oldTime, "closing panel cancels delayed activation before it can copy or touch")
    controller.query = "end-needle"
    controller.filter = .image
    try await waitForClipboardSearch(controller)
    try check(controller.visibleItems.isEmpty && controller.selectedItem == nil, "filter and query generations cannot commit obsolete results")

    let ordered = AppController(directory: dir.appendingPathComponent("ordered-actions"), testMode: true, accessibilityPermissionCheck: { _ in false })
    defer { ordered.shutdown() }
    for name in ["D", "C", "B", "A"] { ordered.store.addText("ordered record " + name) }
    let originals = ordered.store.items
    ordered.query = "ordered"
    ordered.selectRelative(1); ordered.selectRelative(1); ordered.selectRelative(1)
    try await waitForClipboardSearch(ordered)
    try check(ordered.selectedID == originals[3].id, "three navigation keys during pending search preserve their order and all steps")
    ordered.selectItem(originals[2].id)
    ordered.deleteSelected(); ordered.deleteSelected()
    try await waitForClipboardSearch(ordered)
    try check(ordered.store.items.map(\.id) == Array(originals.prefix(2)).map(\.id) && ordered.selectedID == originals[1].id,
              "repeated deletion repairs neighbor selection before the next delete and never removes the first unrelated result")
    ordered.query = "record"
    ordered.deleteSelected(); ordered.toggleSelectedPin(); ordered.activateSelected(copyOnly: true)
    ordered.cancelPendingClipboardActions()
    try await waitForClipboardSearch(ordered)
    try check(ordered.store.items == Array(originals.prefix(2)), "entering a dialog cancels queued delete, pin and copy intents without changing history")

    let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 320, height: 200), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    try check(controller.arrangeLocalWindow(window, key: "maximize"), "own native windows can be arranged without external AX calls")
    try check(window.frame == (window.screen ?? NSScreen.main)!.visibleFrame, "own fill-window uses the full visible work area")
    try check(controller.arrangeLocalWindow(window, key: "top-half") && abs(window.frame.maxY - (window.screen ?? NSScreen.main)!.visibleFrame.maxY) <= 1, "own top-half converts AX fractions to AppKit coordinates")
    print("Clipboard optimization tests passed (isolated data, no external paste or window adjustment)")
}
