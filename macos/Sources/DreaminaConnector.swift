import Foundation
import Combine
import CryptoKit
import CoreFoundation

struct KakiConnectionOwner: Codable, Hashable, Sendable {
    let environment: String
    let userID: String
    var profile: String {
        let data = try! JSONEncoder().encode([environment, userID])
        return "kaki-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
struct DreaminaBinding: Codable, Equatable {
    let owner: KakiConnectionOwner
    let dreaminaUserID: String
}
struct DreaminaAuthorization: Identifiable {
    let id = UUID()
    let url: URL
    let expiresAt: Date
    static func read(_ challenge: [String: Any]) throws -> Self {
        guard let raw = challenge["verificationUriComplete"] as? String ?? challenge["verificationUri"] as? String,
              raw.utf8.count <= 4096, let url = URL(string: raw),
              url.scheme == "https", url.host == "jimeng.jianying.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.path == "/ai-tool/cli-auth",
              let expiry = challenge["expiresAt"] as? String else { throw DreaminaError.invalidResponse }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: expiry) ?? ISO8601DateFormatter().date(from: expiry) else { throw DreaminaError.invalidResponse }
        guard date > Date() else { throw DreaminaError.expiredAuthorization }
        return Self(url: url, expiresAt: date)
    }
}

@MainActor final class DreaminaConnector: ObservableObject {
    @Published private(set) var owner: KakiConnectionOwner?
    @Published private(set) var version = ""
    @Published private(set) var busy = false
    @Published private(set) var verified = false
    @Published private(set) var binding: DreaminaBinding?
    @Published private(set) var authorization: DreaminaAuthorization?
    @Published private(set) var message = ""
    @Published private(set) var videoModels: [String] = []
    private let runner: DreaminaRunning
    private let file: URL
    private var records: [DreaminaBinding] = []
    private var loadFailed = false
    private var supportsAccount = false
    private var generation = 0
    private var operation: Task<Void, Never>?

    init(directory: URL, runner: DreaminaRunning? = nil) {
        self.runner = runner ?? DreaminaProcessRunner()
        file = directory.appendingPathComponent("dreamina-bindings.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                guard data.count <= 256 * 1024 else { throw DreaminaError.invalidResponse }
                records = try JSONDecoder().decode([DreaminaBinding].self, from: data)
                guard records.count <= 256, Set(records.map { $0.owner }).count == records.count,
                      records.allSatisfy({ Self.validID($0.dreaminaUserID) && !$0.owner.userID.isEmpty && ["test", "production"].contains($0.owner.environment) }) else { throw DreaminaError.invalidResponse }
            } catch { records = []; loadFailed = true }
        }
    }
    private static func validID(_ value: String) -> Bool { !value.isEmpty && value.count <= 30 && value.allSatisfy { $0.isASCII && $0.isNumber } }
    func setOwner(_ value: KakiConnectionOwner?) {
        if let value, (value.userID.isEmpty || value.userID.utf8.count > 512 || !["test", "production"].contains(value.environment)) { setOwner(nil); return }
        guard value != owner else { return }
        cancel(); owner = value
        binding = records.first { $0.owner == value }
        message = loadFailed ? "关联记录无法读取，已保留原文件，请先检查记录。" : ""
    }
    func cancel() {
        generation += 1; operation?.cancel(); operation = nil
        busy = false; verified = false; authorization = nil; videoModels = []
    }
    func shutdown() { cancel() }
    private func check(_ revision: Int, owner expected: KakiConnectionOwner?) throws {
        try Task.checkCancellation()
        guard generation == revision, owner == expected else { throw CancellationError() }
    }
    private func command(_ args: [String], owner: KakiConnectionOwner?, timeout: TimeInterval = 30) async throws -> [String: Any] {
        let prefix = ["--format", "json", "--non-interactive", "--region", "cn", "--profile", owner?.profile ?? "kaki-unlinked-check"]
        let revision = generation
        do { return try DreaminaJSON.data(await runner.run(prefix + args, timeout: timeout)) }
        catch {
            if generation == revision, self.owner == owner, case DreaminaError.missingCLI = error {
                supportsAccount = false; version = ""; videoModels = []
            }
            throw error
        }
    }
    private func discover(_ revision: Int, _ expected: KakiConnectionOwner?, force: Bool = false) async throws {
        if supportsAccount && !force { return }
        supportsAccount = false; version = ""
        let info = try await command(["version"], owner: expected)
        try check(revision, owner: expected)
        guard info["edition"] as? String == "public", info["distribution"] as? String == "cn",
              let value = info["version"] as? String else { throw DreaminaError.unsupportedCLI }
        let schema = try await command(["schema"], owner: expected)
        try check(revision, owner: expected)
        let commands = schema["subcommands"] as? [[String: Any]] ?? []
        let auth = commands.first { $0["name"] as? String == "auth" }
        let names = Set((auth?["subcommands"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        guard ["account", "status", "login", "wait", "logout"].allSatisfy({ names.contains($0) }) else { throw DreaminaError.unsupportedCLI }
        version = value; supportsAccount = true
    }
    private func loggedIn(_ expected: KakiConnectionOwner) async throws -> Bool {
        let result = try await command(["auth", "status"], owner: expected)
        guard result["profile"] as? String == expected.profile, result["region"] as? String == "cn",
              result["environment"] as? String == "prod", let loggedIn = result["loggedIn"] as? Bool else { throw DreaminaError.invalidResponse }
        return loggedIn
    }
    private func accountID(_ expected: KakiConnectionOwner) async throws -> String {
        let result = try await command(["auth", "account"], owner: expected)
        // Preserve the integer exactly; never compare a rounded Double user ID.
        guard let number = result["userId"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)), number.int64Value > 0 else { throw DreaminaError.invalidResponse }
        return number.stringValue
    }
    private func save(_ values: [DreaminaBinding]) throws {
        guard !loadFailed, values.count <= 256 else { throw DreaminaError.invalidResponse }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        records = values
    }
    private func perform(_ body: @escaping (Int, KakiConnectionOwner?) async throws -> Void) async {
        guard !busy else { return }
        busy = true; message = ""; verified = false
        let revision = generation, expected = owner
        let task = Task { [weak self] in
            guard let self else { return }
            do { try await body(revision, expected) }
            catch {
                if self.generation == revision && self.owner == expected && !(error is CancellationError) { self.message = error.localizedDescription }
            }
            if self.generation == revision && self.owner == expected { self.busy = false; self.authorization = nil }
        }
        operation = task; await task.value
        if generation == revision { operation = nil }
    }
    func refresh() async {
        await perform { [self] revision, expected in
            videoModels = []
            try await discover(revision, expected, force: true)
            guard let expected else { return }
            guard try await loggedIn(expected) else { try check(revision, owner: expected); message = binding == nil ? "" : "即梦授权已失效，请重新连接。"; return }
            try check(revision, owner: expected)
            guard let existing = binding else { return }
            let id = try await accountID(expected); try check(revision, owner: expected)
            guard id == existing.dreaminaUserID else { throw DreaminaError.accountChanged }
            verified = true
        }
    }
    func connect() async {
        await perform { [self] revision, expected in
            guard let expected else { throw DreaminaError.missingOwner }
            guard !loadFailed else { throw DreaminaError.invalidResponse }
            try await discover(revision, expected)
            let active = try await loggedIn(expected); try check(revision, owner: expected)
            if !active {
                let result = try await command(["auth", "login"], owner: expected)
                try check(revision, owner: expected)
                if let challenge = result["challenge"] as? [String: Any] {
                    let display = try DreaminaAuthorization.read(challenge)
                    guard let device = challenge["deviceCode"] as? String, !device.isEmpty, device.count <= 512 else { throw DreaminaError.invalidResponse }
                    authorization = display
                    let seconds = max(1, min(600, Int(display.expiresAt.timeIntervalSinceNow)))
                    _ = try await command(["auth", "wait", "--device-code", device, "--timeout", "\(seconds)s"], owner: expected, timeout: TimeInterval(seconds + 5))
                    try check(revision, owner: expected)
                }
                guard try await loggedIn(expected) else { throw DreaminaError.notLinked }
                try check(revision, owner: expected)
            }
            let id = try await accountID(expected); try check(revision, owner: expected)
            if let existing = binding, existing.dreaminaUserID != id { throw DreaminaError.accountChanged }
            let value = DreaminaBinding(owner: expected, dreaminaUserID: id)
            try save(records.filter { $0.owner != expected } + [value])
            binding = value; verified = true; authorization = nil; message = "已关联当前 KAKI 账号。"
        }
    }
    // A future Studio task executor must pass the server-authenticated task owner
    // and call this before each action. UI state alone never grants an operation.
    func verifyForTask(_ taskOwner: KakiConnectionOwner) async throws -> DreaminaBinding {
        guard owner == taskOwner else { throw DreaminaError.wrongOwner }
        guard let value = binding, value.owner == taskOwner else { throw DreaminaError.notLinked }
        verified = false
        let revision = generation
        guard try await loggedIn(taskOwner) else { throw DreaminaError.notLinked }
        try check(revision, owner: taskOwner)
        let id = try await accountID(taskOwner); try check(revision, owner: taskOwner)
        guard id == value.dreaminaUserID else { verified = false; throw DreaminaError.accountChanged }
        verified = true
        return value
    }
    func loadVideoModels() async {
        await perform { [self] revision, expected in
            guard let expected else { throw DreaminaError.missingOwner }
            _ = try await verifyForTask(expected)
            let result = try await command(["model", "list", "--type", "video"], owner: expected)
            try check(revision, owner: expected)
            guard let items = result["items"] as? [[String: Any]], items.count <= 256 else { throw DreaminaError.invalidResponse }
            videoModels = items.compactMap { $0["model"] as? String }
            verified = true
            message = videoModels.isEmpty ? "当前账号暂无可查询的视频模型。" : "已读取 \(videoModels.count) 个视频模型。"
        }
    }
    func disconnect() async {
        await perform { [self] revision, expected in
            guard let expected else { throw DreaminaError.missingOwner }
            guard !loadFailed else { throw DreaminaError.invalidResponse }
            _ = try await command(["auth", "logout"], owner: expected)
            try check(revision, owner: expected)
            try save(records.filter { $0.owner != expected })
            binding = nil; videoModels = []; message = "已解除当前账号的本机关联。"
        }
    }
}
