import Foundation
import Darwin

enum DreaminaError: Error, LocalizedError {
    case missingCLI, unsupportedCLI, invalidResponse, failed(String), timedOut, oversized
    case missingOwner, wrongOwner, notLinked, accountChanged, expiredAuthorization
    var errorDescription: String? {
        switch self {
        case .missingCLI: return "未找到即梦 CLI，请先安装后刷新。"
        case .unsupportedCLI: return "当前即梦 CLI 缺少账号核验或授权等待接口，请更新 CLI。"
        case .invalidResponse: return "即梦返回的数据不完整，请刷新后重试。"
        case .failed(let reason):
            switch reason {
            case "auth_dependency_failed": return "即梦授权未完成，请在官方页面确认授权后重试。"
            case "network_timeout", "dns_resolution_failed": return "即梦连接超时，请检查网络后重试。"
            case "credential_store_permission_denied", "credential_store_unavailable", "credential_store_corrupt": return "无法使用即梦凭据存储，请检查钥匙串及系统提示。"
            default: return "即梦操作未完成，请刷新授权状态后重试。"
            }
        case .timedOut: return "即梦操作超时，请重新检查授权状态。"
        case .oversized: return "即梦返回的数据超过处理上限。"
        case .missingOwner: return "请先登录 KAKI 账号，再连接即梦。"
        case .wrongOwner: return "当前 KAKI 账号与关联账号不一致，已停止操作。"
        case .notLinked: return "请先为当前 KAKI 账号连接即梦。"
        case .accountChanged: return "即梦账号与已关联账号不一致，请先解除关联，再授权新账号。"
        case .expiredAuthorization: return "授权链接已过期，请重新连接。"
        }
    }
}

struct DreaminaOutput: Sendable {
    let status: Int32
    let data: Data
}
protocol DreaminaRunning: Sendable {
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> DreaminaOutput
}
struct DreaminaUnavailableRunner: DreaminaRunning {
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> DreaminaOutput { throw DreaminaError.missingCLI }
}

// Execute fixed argv directly. No shell, inherited stdin, credential logging or
// writes to the CLI credential store; its own OAuth client owns the Keychain.
struct DreaminaProcessRunner: DreaminaRunning {
    let executable: URL?
    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".local/bin/dreamina-canvas"),
                URL(fileURLWithPath: "/opt/homebrew/bin/dreamina-canvas"),
                URL(fileURLWithPath: "/usr/local/bin/dreamina-canvas")].first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> DreaminaOutput {
        guard let executable else { throw DreaminaError.missingCLI }
        let invocation = DreaminaInvocation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                try invocation.run(executable, arguments: arguments, timeout: timeout)
            }.value
        }, onCancel: { invocation.cancel() })
    }
}

private final class DreaminaInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var oversized = false
    func cancel() { stop(cancelled: true) }
    private func stop(cancelled: Bool = false, timedOut: Bool = false, oversized: Bool = false) {
        lock.lock()
        self.cancelled = self.cancelled || cancelled
        self.timedOut = self.timedOut || timedOut
        self.oversized = self.oversized || oversized
        let child = process
        lock.unlock()
        guard let child, child.isRunning else { return }
        child.terminate()
        let pid = child.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if child.isRunning && child.processIdentifier == pid { kill(pid, SIGKILL) }
        }
    }
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) throws -> DreaminaOutput {
        let child = Process(), output = Pipe()
        child.executableURL = executable; child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output; child.standardError = output
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        // Close the parent's write descriptor so the reader sees EOF at exit.
        try? output.fileHandleForWriting.close()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + max(1, timeout))
        timer.setEventHandler { [weak self] in self?.stop(timedOut: true) }
        timer.resume()
        defer {
            timer.cancel()
            if child.isRunning { stop(cancelled: true) }
            try? output.fileHandleForReading.close()
        }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if data.count + chunk.count <= 2 * 1024 * 1024 { data.append(chunk) }
            else { stop(oversized: true) }
        }
        child.waitUntilExit()
        lock.lock()
        process = nil
        let wasCancelled = cancelled, wasTimedOut = timedOut, wasOversized = oversized
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        if wasOversized { throw DreaminaError.oversized }
        if wasTimedOut { throw DreaminaError.timedOut }
        return DreaminaOutput(status: child.terminationStatus, data: data)
    }
}

enum DreaminaJSON {
    static func data(_ output: DreaminaOutput) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: output.data) as? [String: Any],
              root["schemaVersion"] as? String == "1" else { throw DreaminaError.invalidResponse }
        guard output.status == 0, root["ok"] as? Bool == true,
              let data = root["data"] as? [String: Any] else {
            let error = root["error"] as? [String: Any]
            throw DreaminaError.failed(error?["reason"] as? String ?? error?["code"] as? String ?? "unknown")
        }
        return data
    }
}
