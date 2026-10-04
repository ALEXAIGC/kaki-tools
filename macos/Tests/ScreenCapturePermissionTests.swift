import AppKit

@MainActor private final class FakeScreenCaptureRunner: ScreenCaptureRunning {
    var calls = 0
    var cancellations = 0
    var completion: ((ScreenCaptureResult) -> Void)?
    func capture(completion: @escaping (ScreenCaptureResult) -> Void) { calls += 1; self.completion = completion }
    func cancel() { cancellations += 1 }
    func finish(_ result: ScreenCaptureResult) { let action = completion; completion = nil; action?(result) }
}

@MainActor func runScreenCapturePermissionTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-screen-permission-" + UUID().uuidString)
    let runner = FakeScreenCaptureRunner()
    var trusted = false
    let requestGranted = false
    var checks: [Bool] = []
    let controller = AppController(directory: directory, testMode: true, accessibilityPermissionCheck: { _ in true },
        screenCapturePermissionCheck: { prompt in checks.append(prompt); return prompt ? requestGranted : trusted }, screenshotRunner: runner)
    defer {
        controller.shutdown()
        NSApp.windows.filter { $0.title == "Kaki Tools 设置" }.forEach { $0.close() }
        try? FileManager.default.removeItem(at: directory)
    }
    try check(!controller.screenCaptureTrusted && checks == [false], "screen permission starts with a non-prompting system check")
    trusted = true
    controller.showSettings(section: "about")
    let window = NSApp.windows.first { $0.title == "Kaki Tools 设置" && $0.isVisible }!
    try check(controller.screenCaptureTrusted, "opening settings rechecks current screen permission")
    trusted = false
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    try check(!controller.screenCaptureTrusted, "returning to settings observes a revoked screen permission")
    trusted = true
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try check(controller.screenCaptureTrusted, "app activation reads a grant without restarting settings")
    let beforeUnrelated = checks.count
    let unrelated = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    unrelated.isReleasedWhenClosed = false
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: unrelated)
    unrelated.close()
    try check(checks.count == beforeUnrelated && !checks.contains(true), "passive updates never prompt and ignore unrelated windows")

    trusted = false
    controller.requestScreenCapturePermission()
    try check(controller.screenCapturePermissionRequested && !controller.screenCaptureTrusted && checks.filter { $0 }.count == 1, "explicit request can leave the current process unconfirmed")
    controller.requestScreenCapturePermission()
    try check(checks.filter { $0 }.count == 1, "unconfirmed explicit requests do not repeatedly launch a system authorization dialog")
    try check(controller.message.contains("完全退出"), "an unchanged grant shows restart instructions instead of claiming the settings switch is off")

    controller.takeScreenshot()
    try check(runner.calls == 1 && controller.screenshotBusy, "false preflight alone does not block the actual system capture")
    controller.takeScreenshot(); controller.requestScreenCapturePermission()
    try check(runner.calls == 1 && checks.filter { $0 }.count == 1, "busy screenshot cannot start another capture or permission dialog")
    runner.finish(.cancelled)
    try check(!controller.screenshotBusy && !controller.screenshotPermissionIssue && controller.store.items.isEmpty, "cancel leaves clipboard history and permission intact")
    controller.takeScreenshot()
    runner.finish(.failed(ScreenCaptureFailure(reason: .commandFailed, exitStatus: 1, diagnostic: "could not create image from display")))
    try check(!controller.screenshotPermissionIssue && controller.store.items.isEmpty, "ambiguous tool failures are not mislabeled as denied permission")
    controller.takeScreenshot()
    try check(runner.calls == 3, "generic command failure does not prevent another capture")
    runner.finish(.failed(ScreenCaptureFailure(reason: .permissionDenied, exitStatus: 1, diagnostic: "not authorized to capture screen")))
    try check(controller.screenshotPermissionIssue && !controller.screenshotBusy && controller.settingsSection == "about", "actual denial brings the user to focused permission help")
    controller.takeScreenshot()
    try check(runner.calls == 3 && !controller.screenshotBusy, "an actual repeated denial uses settings help without re-triggering the system prompt")
    controller.takeScreenshot(retryPermissionFailure: true)
    try check(runner.calls == 4 && controller.screenshotBusy, "user can explicitly retry capture despite a stale permission preflight")
    runner.finish(.cancelled)
    trusted = true
    controller.refreshScreenCapturePermission()
    try check(controller.screenCaptureTrusted && !controller.screenshotPermissionIssue, "a later system grant clears the denied retry state")
    controller.takeScreenshot()
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.orange.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 12, height: 8)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    runner.finish(.captured(png))
    for _ in 0..<100 {
        if controller.store.items.first?.hash != nil { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try check(!controller.screenshotBusy && controller.store.items.first?.type == "image" && controller.store.items.first?.hash != nil, "accepted screenshot reaches persisted history and clears busy state")
    try check(!controller.screenshotPermissionIssue && controller.screenshotDiagnostics.contains("最近截图失败：无记录"), "successful screenshot clears a previous failure diagnostic")
    controller.copyScreenshotDiagnostics()
    try check(controller.message == "截图诊断已复制。" && controller.screenshotDiagnostics.contains("运行位置：") && controller.screenshotDiagnostics.contains("签名标识："), "diagnostic copy includes runtime identity through the private test clipboard")
    controller.clipboard.captureNow()
    try check(controller.store.items.count == 1, "clipboard polling ignores the app's own diagnostic copy instead of adding it to history")

    controller.takeScreenshot()
    let late = runner.completion
    controller.shutdown()
    late?(.captured(png))
    try check(runner.cancellations == 1 && !controller.screenshotBusy && controller.store.items.count == 1, "shutdown cancels capture and rejects an already queued completion")
    controller.takeScreenshot(); controller.requestScreenCapturePermission()
    try check(runner.calls == 6 && checks.filter { $0 }.count == 1, "shutdown does not restart capture or request authorization")

    let immediate = AppController(directory: directory.appendingPathComponent("immediate"), testMode: true,
        screenCapturePermissionCheck: { prompt in prompt ? true : false })
    defer { immediate.shutdown() }
    immediate.requestScreenCapturePermission()
    try check(immediate.screenCaptureTrusted, "a successful request return is honored even before the preflight refresh catches up")
    try check(!requestGranted, "all permission tests use injected state without touching macOS grants")

    let conflictingRunner = FakeScreenCaptureRunner()
    var conflictingPreflight = true
    let conflicting = AppController(directory: directory.appendingPathComponent("conflicting-preflight"), testMode: true,
        screenCapturePermissionCheck: { _ in conflictingPreflight }, screenshotRunner: conflictingRunner)
    defer { conflicting.shutdown() }
    conflicting.takeScreenshot()
    conflictingRunner.finish(.failed(ScreenCaptureFailure(reason: .permissionDenied, exitStatus: 1, diagnostic: "screen recording access denied")))
    try check(conflicting.screenCaptureTrusted && conflicting.screenshotPermissionIssue, "a still-true preflight does not erase an actual capture denial on opening settings")
    conflicting.takeScreenshot()
    try check(conflictingRunner.calls == 1, "actual tool denial suppresses repeated hotkeys even when preflight disagrees")
    conflicting.takeScreenshot(retryPermissionFailure: true)
    conflictingRunner.finish(.captured(png))
    try check(!conflicting.screenshotPermissionIssue && conflictingRunner.calls == 2, "successful explicit retry resolves a contradictory permission check")
    conflicting.takeScreenshot()
    conflictingRunner.finish(.failed(ScreenCaptureFailure(reason: .permissionDenied, exitStatus: 1, diagnostic: "screen recording access denied")))
    conflictingPreflight = false; conflicting.refreshScreenCapturePermission()
    conflictingPreflight = true; conflicting.refreshScreenCapturePermission()
    try check(!conflicting.screenshotPermissionIssue, "a real revoke-then-grant transition clears a previous actual denial")
    controller.log.flush()
    let log = try String(contentsOf: directory.appendingPathComponent("native.log"), encoding: .utf8)
    try check(log.contains("退出码=1") && log.contains("not authorized to capture screen") && log.contains("截图完成"), "failed and successful captures have actionable bounded diagnostic records")
    print("Screen capture permission tests passed (injected grants and runner, no system permission changes)")
}
