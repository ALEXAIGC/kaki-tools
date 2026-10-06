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
// Execute fixed argv directly. No shell, inherited stdin, credential logging or
// writes to the CLI credential store; its own OAuth client owns the Keychain.
struct DreaminaProcessRunner: DreaminaRunning {
    private let locator: @Sendable () -> URL?
    init(executable: URL?) { locator = { executable } }
    init(locator: @escaping @Sendable () -> URL?) { self.locator = locator }
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> DreaminaOutput {
        guard let executable = locator(), FileManager.default.isExecutableFile(atPath: executable.path) else { throw DreaminaError.missingCLI }
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
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func checkCancellation() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
    }
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) throws -> DreaminaOutput {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let reader = descriptors[0], writer = descriptors[1]
        defer { close(reader) }
        var writerOpen = true
        defer { if writerOpen { close(writer) } }
        guard fcntl(reader, F_SETFD, FD_CLOEXEC) == 0, fcntl(writer, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let input = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(input) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try Self.check(posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, writer, STDERR_FILENO))
        for descriptor in [reader, writer, input] where descriptor > STDERR_FILENO {
            try Self.check(posix_spawn_file_actions_addclose(&actions, descriptor))
        }
        // Spawn into a new group atomically; descendants inherit only this invocation's
        // group. CLOEXEC_DEFAULT keeps unrelated app descriptors out of the CLI.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        try Self.check(posix_spawnattr_setflags(&attributes, Int16(flags)))
        try Self.check(posix_spawnattr_setpgroup(&attributes, 0))
        // Main handles TERM/INT through DispatchSource and ignores their POSIX
        // dispositions. The CLI must receive ordinary signals and an empty mask.
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults); sigemptyset(&mask)
        for signal in [SIGTERM, SIGINT, SIGPIPE, SIGHUP, SIGCHLD] { sigaddset(&defaults, signal) }
        try Self.check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try Self.check(posix_spawnattr_setsigmask(&attributes, &mask))
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + environment { free(pointer) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        var pid: pid_t = 0
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        let spawned = argv.withUnsafeBufferPointer { pointers in
            environment.withUnsafeBufferPointer { variables in
                posix_spawn(&pid, executable.path, &actions, &attributes, pointers.baseAddress!, variables.baseAddress!)
            }
        }
        lock.unlock()
        try Self.check(spawned)
        close(writer); writerOpen = false
        defer { Self.cleanup(pid) }
        let start = DispatchTime.now().uptimeNanoseconds
        let duration = max(1, timeout.isFinite ? timeout : 1)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var eof = false
        func drain() throws {
            while !eof {
                try checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(reader, $0.baseAddress!, $0.count) }
                if count > 0 {
                    guard data.count + count <= 2 * 1024 * 1024 else { throw DreaminaError.oversized }
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 { eof = true }
                else if errno == EINTR { continue }
                else if errno == EAGAIN { return }
                else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
        while true {
            try checkCancellation()
            if Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000 >= duration { throw DreaminaError.timedOut }
            try drain()
            if let status = try Self.exitStatus(pid) {
                // A final nonblocking drain catches bytes written just before exit.
                // EOF is not required: a descendant may still own the write end.
                try drain(); try checkCancellation()
                return DreaminaOutput(status: status, data: data)
            }
            if eof { usleep(20_000) }
            else {
                var descriptor = pollfd(fd: reader, events: Int16(POLLIN | POLLHUP), revents: 0)
                if poll(&descriptor, 1, 20) < 0 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
    }
    private static func check(_ result: Int32) throws {
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }
    private static func exitStatus(_ pid: pid_t) throws -> Int32? {
        var info = siginfo_t()
        // Keep the child waitable until cleanup has signalled its group. Its PID
        // cannot be reused for an unrelated process between observation and cleanup.
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
            if errno == EINTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return info.si_pid == pid ? info.si_status : nil
    }
    private static func cleanup(_ pid: pid_t) {
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < 200_000_000 {
            if (try? exitStatus(pid)) != nil { break }
            usleep(10_000)
        }
        // Also stop descendants after the parent has exited. No delayed PID-only
        // callbacks remain, and the owning parent is reaped exactly once here.
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
}
