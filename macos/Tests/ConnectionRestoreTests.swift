import Foundation
import CryptoKit

private actor RememberedConnectionTransport: StudioTransport {
    var calls: [String] = []
    var failResume = false
    var heldResume: CheckedContinuation<Void, Never>?
    var holdResume = false
    func configure(fail: Bool = false, hold: Bool = false) { failResume = fail; holdResume = hold }
    func release() { holdResume = false; heldResume?.resume(); heldResume = nil }
    func recorded() -> [String] { calls }
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile {
        let path = request.url!.path; calls.append(path)
        var headers = ["Content-Type": "application/json"]
        let user: [String: Any] = ["id": "remembered-user", "email": "fixture@example.invalid", "name": "Fixture"]
        let body: Any
        switch path {
        case "/api/auth/login":
            headers["Set-Cookie"] = "kaki_session=synthetic; Max-Age=3600; Secure; Path=/; HttpOnly"
            body = ["user": user]
        case "/api/me": body = user
        case "/api/workspaces": body = [
            ["id": "personal", "name": "Personal", "kind": "personal", "role": "owner"],
            ["id": "team", "name": "Team", "kind": "team", "role": "owner"]]
        case "/api/assets": body = ["items": [], "total": 0]
        case "/api/local-cli/devices/resume":
            if holdResume { await withCheckedContinuation { heldResume = $0 } }
            if failResume { throw URLError(.notConnectedToInternet) }
            body = [:] as [String: String]
        case "/api/local-cli/devices/claim": body = ["task": NSNull()]
        case "/api/local-cli/devices/heartbeat", "/api/local-cli/devices/pause": body = [:] as [String: String]
        default: throw NativeTestFailure(description: "Unexpected automatic-restore request: " + path)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try JSONSerialization.data(withJSONObject: body).write(to: file)
        return StudioHTTPFile(file: file, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}
private actor RememberedRunner: DreaminaRunning {
    private let base = ClassicFixtureRunner()
    var valid = true
    var calls: [[String]] = []
    func configure(valid: Bool) { self.valid = valid }
    func recorded() -> [[String]] { calls }
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> DreaminaOutput {
        calls.append(arguments)
        if arguments == ["user_credit"], !valid {
            return DreaminaOutput(status: 1, data: Data("未检测到有效登录态，请先执行 dreamina login".utf8))
        }
        return try await base.run(arguments, timeout: timeout)
    }
}
@MainActor func runConnectionRestoreTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-restore-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let api = RememberedConnectionTransport(), runner = RememberedRunner(), credentials = StudioMemoryCredentials()
    let studio = StudioStore(directory: root, credentials: credentials, transport: api)
    await studio.login(email: "fixture@example.invalid", password: "synthetic", code: "")
    await studio.selectWorkspace("team")
    let restarted = StudioStore(directory: root, credentials: credentials, transport: api)
    await restarted.restoreSession()
    try check(restarted.user?.id == "remembered-user" && restarted.workspaceID == "team", "restart restores the verified Studio session and selected workspace")
    let binary = root.appendingPathComponent("dreamina"); try Data("fixture CLI".utf8).write(to: binary)
    let directory = root.appendingPathComponent("classic-cli")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let owner = restarted.environment.baseURL.absoluteString + "|remembered-user|team"
    let key = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
    let file = directory.appendingPathComponent(key + ".json")
    func seed(fingerprint: String? = nil, autoResume: Bool? = nil) throws {
        var object: [String: Any] = ["owner": owner, "fingerprint": try fingerprint ?? ClassicDreaminaCLI.fingerprint(binary),
            "device": ["id": "fixture-device", "epoch": "fixture-epoch", "secret": "synthetic-device-secret"], "profile": "resolution-five"]
        if let autoResume { object["autoResume"] = autoResume }
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }
    func make(retry: UInt64 = 30_000_000_000) -> ClassicCliConnection {
        ClassicCliConnection(studio: restarted, directory: root, enabled: true, locator: { binary }, runnerFactory: { _ in runner }, restoreRetryNanoseconds: retry)
    }
    func settle(_ connection: ClassicCliConnection) async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
        for _ in 0..<100 {
            if !connection.busy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NativeTestFailure(description: "automatic restore did not settle")
    }
    try seed()
    let connection = make(); connection.restoreRememberedConnection(); try await settle(connection)
    try check(connection.connected && connection.loggedIn, "legacy approved device resumes without another login or consent dialog")
    let commands = await runner.recorded(), routes = await api.recorded()
    try check(!commands.contains(where: { $0.first == "login" }), "automatic restore never starts OAuth or asks for a password")
    try check(routes.contains("/api/local-cli/devices/resume") && !routes.contains("/api/local-cli/devices/register"), "restore resumes only the existing approved device")
    try check(routes.filter { $0 == "/api/local-cli/devices/heartbeat" }.count == 1, "connection has one independent heartbeat without a duplicate claim-loop heartbeat")
    connection.disconnect()
    let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    try check(stored["autoResume"] as? Bool == false && !connection.connected, "explicit disconnect is persisted")
    let paused = make(); paused.restoreRememberedConnection(); try await settle(paused)
    try check(!paused.connected, "restart respects explicit disconnection")
    paused.connect(); try await settle(paused)
    let reconnectedRecord = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    try check(paused.connected && reconnectedRecord["autoResume"] as? Bool == true, "explicit reconnect re-enables remembering the approved device")
    paused.shutdown(); connection.shutdown()
    try seed(fingerprint: "changed")
    let changed = make(); changed.restoreRememberedConnection(); try await settle(changed)
    try check(!changed.connected && changed.status.contains("手动确认"), "a changed binary is not silently registered")
    changed.shutdown()
    try seed(); await runner.configure(valid: false)
    let expired = make(); expired.restoreRememberedConnection(); try await settle(expired)
    try check(!expired.connected && !expired.loggedIn && expired.status.contains("请先登录"), "expired CLI authorization requests login without running OAuth automatically")
    expired.shutdown(); await runner.configure(valid: true)
    await api.configure(fail: true)
    let offline = make(retry: 50_000_000); offline.restoreRememberedConnection(); try await settle(offline)
    try check(!offline.connected && FileManager.default.fileExists(atPath: file.path), "network failure retains remembered authorization")
    await api.configure(fail: false)
    for _ in 0..<150 {
        if offline.connected { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try check(offline.connected, "temporary network failure automatically retries the remembered device after recovery")
    offline.shutdown(); await api.configure(hold: true)
    let stale = make(); stale.restoreRememberedConnection()
    try await Task.sleep(nanoseconds: 400_000_000)
    stale.identityChanged(); await api.release(); try await Task.sleep(nanoseconds: 100_000_000)
    try check(!stale.connected, "late resume response cannot restore an invalidated identity")
    stale.shutdown()
    let first = try ClassicDreaminaCLI.fileIdentity(binary)
    try Data("changed fixture CLI".utf8).write(to: binary, options: .atomic)
    let replaced = try ClassicDreaminaCLI.fileIdentity(binary)
    try check(replaced != first, "lightweight identity detects atomic executable replacement")
    studio.shutdown(); restarted.shutdown()
}
