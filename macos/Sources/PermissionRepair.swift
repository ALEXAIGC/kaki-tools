import Foundation

enum RepairPermission: String {
    case accessibility = "Accessibility"
    case screenCapture = "ScreenCapture"
    var title: String { self == .accessibility ? "辅助功能" : "截图" }
    var resetArguments: [String] { ["reset", rawValue, "com.openclaw.kakitools"] }
}

protocol PermissionRepairRunning {
    func reset(_ permission: RepairPermission) async -> Bool
}

struct SystemPermissionRepairRunner: PermissionRepairRunning {
    func reset(_ permission: RepairPermission) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = permission.resetArguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                do {
                    try process.run()
                    if finished.wait(timeout: .now() + 8) == .timedOut {
                        if process.isRunning { process.terminate() }
                        continuation.resume(returning: false)
                    } else {
                        continuation.resume(returning: process.terminationStatus == 0)
                    }
                } catch { continuation.resume(returning: false) }
            }
        }
    }
}
