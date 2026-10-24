import Foundation
import CryptoKit

private actor SetupRunner: DreaminaRunning {
    let base = ClassicFixtureRunner()
    var authenticated: Bool
    var networkFailure = false
    var calls: [[String]] = []
    init(authenticated: Bool) { self.authenticated = authenticated }
    func permit() { authenticated = true }
    func failNetwork() { networkFailure = true }
    func recorded() -> [[String]] { calls }
    func run(_ args: [String], timeout: TimeInterval) async throws -> DreaminaOutput {
        calls.append(args)
        if args == ["user_credit"] {
            if networkFailure { throw DreaminaError.timedOut }
            if !authenticated { return DreaminaOutput(status: 1, data: Data("未检测到有效登录态，请先执行 dreamina login".utf8)) }
        }
        if args == ["login", "--help"] { return DreaminaOutput(status: 0, data: Data("--headless".utf8)) }
        if args == ["login", "--headless"] { return DreaminaOutput(status: 0, data: Data("verification_uri: https://jimeng.jianying.com/ai-tool/cli-auth\nuser_code: SETUP-ONLY\ndevice_code: synthetic-setup-device\n".utf8)) }
        if args.first == "login", args.count == 6, args[1] == "checklogin" {
            return DreaminaOutput(status: authenticated ? 0 : 1, data: Data((authenticated ? "授权成功" : "登录尚未完成，请稍后重试或增加 --poll").utf8))
        }
        guard args.last == "--help" || args == ["user_credit"] else { throw NativeTestFailure(description: "setup attempted an unexpected CLI command") }
        return try await base.run(args, timeout: timeout)
    }
}
private actor SetupTransport: StudioTransport {
    var paths: [String] = []
    func recorded() -> [String] { paths }
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile {
        let path = request.url!.path; paths.append(path)
        var headers = ["Content-Type": "application/json"]
        let body: Any
        switch path {
        case "/api/auth/login":
            headers["Set-Cookie"] = "kaki_session=synthetic; Max-Age=3600; Secure; Path=/; HttpOnly"
            body = ["user": ["id": "setup-user", "email": "fixture@example.invalid"]]
        case "/api/workspaces": body = [["id": "personal", "name": "Personal", "kind": "personal", "role": "owner"], ["id": "team", "name": "Team", "kind": "team", "role": "owner"]]
        case "/api/assets": body = ["items": [], "total": 0]
        case "/api/local-cli/devices/register":
            let input = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            body = ["id": "setup-device", "epoch": "setup-epoch", "secret": String(repeating: "a", count: 64), "models": input["models"]!, "profile": "resolution-five", "revision": 0]
        case "/api/local-cli/devices/claim": body = ["task": NSNull()]
        case "/api/local-cli/devices/credit-refresh": body = ["request": NSNull()]
        case "/api/local-cli/devices/resume", "/api/local-cli/devices/heartbeat", "/api/local-cli/devices/pause": body = [:] as [String: String]
        default: throw NativeTestFailure(description: "setup attempted an unexpected server route: " + path)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try JSONSerialization.data(withJSONObject: body).write(to: file)
        return StudioHTTPFile(file: file, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}
@MainActor private struct SetupFixture {
    let root: URL
    let api: SetupTransport
    let runner: SetupRunner
    let studio: StudioStore
    let connection: ClassicCliConnection
    let binary: URL
    init(authenticated: Bool = true, studioLoggedIn: Bool = true) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-setup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        api = SetupTransport(); runner = SetupRunner(authenticated: authenticated)
        studio = StudioStore(directory: root, credentials: StudioMemoryCredentials(), transport: api)
        if studioLoggedIn { await studio.login(email: "fixture@example.invalid", password: "synthetic", code: "") }
        binary = root.appendingPathComponent("dreamina"); try Data("isolated setup binary".utf8).write(to: binary)
        let executable = binary, cliRunner = runner
        connection = ClassicCliConnection(studio: studio, directory: root, enabled: true, locator: { executable }, inspector: { path in
            ClassicCliInstallation(executable: path, version: "fixture", sha256: String(repeating: "a", count: 64))
        }, runnerFactory: { _ in cliRunner }, loginTimeout: 3, pollInterval: 10_000_000, openAuthorization: { _ in true })
    }
    var owner: String { studio.environment.baseURL.absoluteString + "|setup-user|personal" }
    func clean() { connection.shutdown(); try? FileManager.default.removeItem(at: root) }
    func seedOriginal() throws {
        let key = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent("classic-cli")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["owner": owner, "fingerprint": try ClassicDreaminaCLI.fingerprint(binary), "device": ["id": "original-device", "epoch": "original-epoch", "secret": String(repeating: "b", count: 64)], "profile": "resolution-five"]).write(to: directory.appendingPathComponent(key + ".json"))
    }
}
@MainActor private func awaitSetup(_ condition: () -> Bool) async throws {
    for _ in 0..<300 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
    throw NativeTestFailure(description: "one-click setup did not reach the expected state")
}
@MainActor func runClassicSetupFlowTests() async throws {
    do {
        let f = try await SetupFixture(); defer { f.clean() }
        f.connection.setupConnection(); f.connection.setupConnection()
        try await awaitSetup { !f.connection.interactionBusy }
        let paths = await f.api.recorded(), calls = await f.runner.recorded()
        try check(f.connection.connected && paths.filter { $0.hasSuffix("/devices/register") }.count == 1, "one click automatically connects one first association; duplicate clicks never register twice")
        try check(!calls.contains { $0.first == "login" || $0.first == "relogin" }, "valid existing login connects without another authorization or credential reset")
    }
    do {
        let f = try await SetupFixture(authenticated: false); defer { f.clean() }
        f.connection.setupConnection(); try await awaitSetup { f.connection.authorizationQRURL != nil }
        let before = await f.api.recorded()
        try check(f.connection.setupBusy && !before.contains { $0.hasSuffix("/register") }, "setup waits for QR authorization before device registration")
        await f.runner.permit(); try await awaitSetup { !f.connection.interactionBusy }
        let after = await f.api.recorded()
        try check(f.connection.connected && after.filter { $0.hasSuffix("/register") }.count == 1 && f.connection.authorizationQRURL == nil, "QR approval automatically continues into Studio association without a second click")
    }
    do {
        let f = try await SetupFixture(authenticated: false); defer { f.clean() }
        f.connection.setupConnection(); try await awaitSetup { f.connection.authorizationQRURL != nil }
        f.connection.cancelOperation(); await f.runner.permit()
        try await Task.sleep(nanoseconds: 100_000_000)
        let paths = await f.api.recorded()
        try check(!f.connection.interactionBusy && !f.connection.connected && f.connection.authorizationQRURL == nil && !paths.contains { $0.hasSuffix("/register") }, "cancel stops the entire setup chain, clears QR and ignores late authorization")
    }
    do {
        let f = try await SetupFixture(authenticated: false); defer { f.clean() }
        f.connection.setupConnection(); try await awaitSetup { f.connection.authorizationQRURL != nil }
        await f.studio.selectWorkspace("team"); f.connection.identityChanged(); await f.runner.permit()
        try await Task.sleep(nanoseconds: 100_000_000)
        let paths = await f.api.recorded()
        try check(!f.connection.connected && !f.connection.setupBusy && !paths.contains { $0.hasSuffix("/register") }, "workspace change stops old setup without associating either workspace from a stale approval")
    }
    do {
        let f = try await SetupFixture(); defer { f.clean() }
        await f.runner.failNetwork(); f.connection.setupConnection(); try await awaitSetup { !f.connection.interactionBusy }
        let paths = await f.api.recorded(), calls = await f.runner.recorded()
        try check(!f.connection.connected && !paths.contains { $0.hasSuffix("/register") } && !calls.contains { $0.first == "login" || $0.first == "relogin" }, "temporary detection failure stops with a retry state instead of resetting credentials or silently requesting OAuth")
    }
    do {
        let f = try await SetupFixture(); defer { f.clean() }
        let directory = f.root.appendingPathComponent("classic-cli/journal")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = ClassicVideoSnapshot(prompt: "original", model: "seedance2.0", duration: 5, aspect: "16:9", resolution: "720p", mode: "text", profile: "resolution-five")
        let task = ClassicVideoTask(id: "original", projectId: "project", nodeId: "node", payloadHash: String(repeating: "a", count: 64), snapshot: snapshot, stage: "unknown", submitId: nil)
        try JSONEncoder().encode(ClassicCliJournal(task: task, owner: f.owner, stage: "unknown", submitId: nil)).write(to: directory.appendingPathComponent("original.json"))
        f.connection.setupConnection(); try await awaitSetup { !f.connection.interactionBusy }
        let paths = await f.api.recorded()
        try check(!f.connection.connected && f.connection.status.contains("未完成") && !paths.contains { $0.hasSuffix("/register") }, "one-click setup cannot replace the device associated with an unfinished original task")
    }
    do {
        let f = try await SetupFixture(); defer { f.clean() }; try f.seedOriginal()
        f.connection.setupConnection(); try await awaitSetup { !f.connection.interactionBusy }
        let paths = await f.api.recorded()
        try check(f.connection.connected && paths.contains { $0.hasSuffix("/resume") } && !paths.contains { $0.hasSuffix("/register") }, "one-click setup resumes a matching original device instead of creating a replacement")
    }
    do {
        let f = try await SetupFixture(studioLoggedIn: false); defer { f.clean() }
        f.connection.setupConnection()
        let calls = await f.runner.recorded()
        try check(!f.connection.interactionBusy && f.connection.status.contains("Studio") && calls.isEmpty, "missing Studio account blocks setup before installation or CLI authorization")
    }
}
