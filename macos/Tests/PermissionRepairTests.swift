import Foundation

@MainActor final class RepairTestRunner: PermissionRepairRunning {
    var calls: [RepairPermission] = []
    var result = true
    var continuation: CheckedContinuation<Bool, Never>?
    var suspend = false
    func reset(_ permission: RepairPermission) async -> Bool {
        calls.append(permission)
        if suspend { return await withCheckedContinuation { continuation = $0 } }
        return result
    }
}

@MainActor func runPermissionRepairTests() async throws {
    try check(RepairPermission.accessibility.resetArguments == ["reset", "Accessibility", "com.openclaw.kakitools"], "accessibility repair never resets other apps or services")
    try check(RepairPermission.screenCapture.resetArguments == ["reset", "ScreenCapture", "com.openclaw.kakitools"], "screenshot repair is scoped independently")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-repair-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = RepairTestRunner()
    let controller = AppController(directory: directory, testMode: true, accessibilityPermissionCheck: { _ in true }, screenCapturePermissionCheck: { _ in true }, permissionRepairRunner: runner)
    try check(runner.calls.isEmpty, "startup never resets permissions automatically")
    controller.screenshotBusy = true
    await controller.performPermissionRepair(.screenCapture)
    try check(runner.calls.isEmpty, "an active screenshot cannot have its permission reset")
    controller.screenshotBusy = false
    await controller.performPermissionRepair(.accessibility)
    try check(runner.calls == [.accessibility] && !controller.permissionRepairBusy && controller.accessibilityTrusted, "successful repair refreshes status and completes")
    try check(controller.permissionRepairMessage.contains("旧授权已移除"), "repair retains next steps on the permission page")
    runner.result = false
    await controller.performPermissionRepair(.screenCapture)
    try check(controller.permissionRepairMessage.contains("未完成") && !controller.permissionRepairBusy, "reset failure does not claim success")
    runner.suspend = true
    let task = Task { await controller.performPermissionRepair(.accessibility) }
    while runner.continuation == nil { await Task.yield() }
    let count = runner.calls.count
    await controller.performPermissionRepair(.screenCapture)
    try check(runner.calls.count == count, "overlapping repairs are rejected")
    controller.shutdown()
    let message = controller.permissionRepairMessage
    runner.continuation?.resume(returning: true)
    await task.value
    try check(controller.permissionRepairMessage == message && !controller.permissionRepairBusy, "shutdown ignores late repair results")
    await controller.performPermissionRepair(.screenCapture)
    try check(runner.calls.count == count, "shutdown cannot start another reset")
    let qa = AppController(directory: directory.appendingPathComponent("qa"), testMode: true,
        qaProfile: NativeQAProfile(directory: directory.appendingPathComponent("qa"), sessionNamespace: "kaki-private-qa-test"), permissionRepairRunner: runner)
    await qa.performPermissionRepair(.accessibility)
    try check(runner.calls.count == count && qa.message.contains("QA"), "QA profile cannot reset production permissions even with an injected runner")
    qa.shutdown()
    print("Permission repair tests passed (mock runner; no real permissions reset)")
}
