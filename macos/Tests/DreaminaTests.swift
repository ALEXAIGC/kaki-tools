import Foundation

struct DreaminaStudioFixture: StudioTransport {
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile {
        let path = request.url!.path
        var headers = ["Content-Type":"application/json"]
        let data: Data
        switch path {
        case "/api/auth/login":
            let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            let user = payload["email"]!.hasPrefix("alice") ? "alice" : "bob"
            data = try JSONSerialization.data(withJSONObject: ["user":["id":"kaki-" + user, "email":user + "@example.invalid", "name":user]])
            headers["Set-Cookie"] = "kaki_session=synthetic; Max-Age=3600; Secure; Path=/; HttpOnly"
        case "/api/workspaces": data = Data("[]".utf8)
        case "/api/auth/logout": data = Data("{}".utf8)
        default: throw NativeTestFailure(description: "Unexpected KAKI auth fixture route")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-dreamina-auth-response-" + UUID().uuidString)
        try data.write(to: file)
        return StudioHTTPFile(file: file, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

actor DreaminaFixtureRunner: DreaminaRunning {
    var active = false
    var account: Int64 = 1234567890123456789
    var supported = true
    var calls: [[String]] = []
    var pauseWait = false
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func setAccount(_ id: Int64) { account = id }
    func setSupported(_ value: Bool) { supported = value }
    func holdWait() { pauseWait = true }
    func releaseWait() { continuation?.resume(); continuation = nil }
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> DreaminaOutput {
        calls.append(arguments)
        guard arguments.prefix(7) == ["--format", "json", "--non-interactive", "--region", "cn", "--profile", arguments[6]] else { throw NativeTestFailure(description: "CLI globals missing") }
        let profile = arguments[6], command = Array(arguments.dropFirst(7))
        let data: [String: Any]
        switch command.prefix(2).joined(separator: " ") {
        case "version": data = ["version":"fixture", "edition":"public", "distribution":"cn"]
        case "schema": data = ["subcommands":[["name":"auth", "subcommands":(supported ? ["account", "status", "login", "wait", "logout"] : ["status", "login"]).map { ["name":$0] }]]]
        case "auth status": data = ["loggedIn":active, "profile":profile, "region":"cn", "environment":"prod"]
        case "auth account": data = ["userId":NSNumber(value: account)]
        case "auth login":
            let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))
            data = ["status":"authorization_required", "challenge":["deviceCode":"synthetic-device", "verificationUriComplete":"https://jimeng.jianying.com/ai-tool/cli-auth?fixture=1", "expiresAt":expiry]]
        case "auth wait":
            if pauseWait { waiting = true; await withCheckedContinuation { continuation = $0 } }
            active = true; data = ["status":"success", "state":["loggedIn":true]]
        case "auth logout": active = false; data = ["loggedOut":true]
        case "model list": data = ["items":[["model":"fixture-video-a"], ["model":"fixture-video-b"]]]
        default: throw NativeTestFailure(description: "Unexpected fixture command")
        }
        return DreaminaOutput(status: 0, data: try JSONSerialization.data(withJSONObject: ["schemaVersion":"1", "ok":true, "data":data]))
    }
}

@MainActor func runDreaminaTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-dreamina-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let alice = KakiConnectionOwner(environment: "production", userID: "studio-alice")
    let bob = KakiConnectionOwner(environment: "production", userID: "studio-bob")
    let testAlice = KakiConnectionOwner(environment: "test", userID: alice.userID)
    try check(alice.profile != bob.profile && alice.profile != testAlice.profile, "KAKI accounts and environments have separate OAuth profiles")
    try check(alice.profile.hasPrefix("kaki-") && !alice.profile.contains(alice.userID), "OAuth profile never embeds email or raw account ID")
    let runner = DreaminaFixtureRunner(), connector = DreaminaConnector(directory: directory, runner: runner)
    await connector.connect()
    try check(!connector.verified && connector.binding == nil, "anonymous user cannot connect Jimeng")
    let anonymousCalls = await runner.calls
    try check(anonymousCalls.isEmpty, "anonymous connect never invokes CLI")
    connector.setOwner(alice); await connector.connect()
    try check(connector.verified && connector.binding?.owner == alice, "official authorization associates only the current KAKI owner")
    try check(connector.binding?.dreaminaUserID == "1234567890123456789", "server account ID preserved exactly above Double integer precision")
    let commands = await runner.calls
    try check(commands.allSatisfy { $0[6] == alice.profile && !$0.contains("--force") && !$0.contains("--yes") }, "login uses private owner profile and never force-clears default credentials")
    try check(commands.contains { $0.contains("wait") }, "authorization waits on the original challenge")
    let file = directory.appendingPathComponent("dreamina-bindings.json"), bytes = try Data(contentsOf: file)
    let text = String(data: bytes, encoding: .utf8)!
    try check(!text.contains("synthetic-device") && !text.contains("verificationUri") && !text.contains("token"), "binding stores public IDs, not device authorization or credentials")
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    try check(mode?.intValue == 0o600, "local binding record is user-private")
    let count = await runner.calls.count
    do { _ = try await connector.verifyForTask(bob); throw NativeTestFailure(description: "Wrong owner accepted") }
    catch DreaminaError.wrongOwner {}
    let rejectedCount = await runner.calls.count
    try check(rejectedCount == count, "different Studio owner blocked before any CLI call")
    await connector.loadVideoModels()
    try check(connector.videoModels.count == 2 && connector.verified, "video discovery rechecks authenticated bound account")
    connector.setOwner(bob)
    try check(connector.binding == nil && !connector.verified && connector.videoModels.isEmpty, "account switch immediately hides and disables old association")
    connector.setOwner(testAlice)
    try check(connector.binding == nil, "test account cannot use production association")
    connector.setOwner(alice); await connector.refresh()
    try check(connector.verified, "same KAKI owner can revalidate its stored association")
    let restored = DreaminaConnector(directory: directory, runner: runner); restored.setOwner(alice)
    await restored.refresh(); try check(restored.verified, "binding survives relaunch and requires server account verification")
    await runner.setAccount(999999)
    await connector.refresh()
    try check(!connector.verified && connector.message.contains("不一致"), "externally switched Jimeng identity is rejected")
    await connector.connect()
    try check(!connector.verified && connector.binding?.dreaminaUserID == "1234567890123456789", "connect cannot silently overwrite a linked external identity")
    await connector.disconnect()
    try check(connector.binding == nil && !connector.verified, "explicit disconnect logs out only this profile and removes association")
    let disconnectedCalls = await runner.calls
    try check(disconnectedCalls.last?.suffix(2) == ["auth", "logout"], "disconnect invokes scoped CLI logout")

    let raceDir = directory.appendingPathComponent("race"), raceRunner = DreaminaFixtureRunner()
    await raceRunner.holdWait()
    let racing = DreaminaConnector(directory: raceDir, runner: raceRunner); racing.setOwner(alice)
    let login = Task { await racing.connect() }
    for _ in 0..<200 { if await raceRunner.waiting { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let reachedWait = await raceRunner.waiting
    try check(reachedWait && racing.authorization != nil, "pending OAuth displays authorization UI")
    racing.setOwner(bob); await raceRunner.releaseWait(); await login.value
    try check(racing.owner == bob && racing.binding == nil && racing.authorization == nil && !racing.busy, "late authorization cannot bind a newly logged-in KAKI owner")
    try check(!FileManager.default.fileExists(atPath: raceDir.appendingPathComponent("dreamina-bindings.json").path), "cancelled account switch does not write an association")

    let oldRunner = DreaminaFixtureRunner(); await oldRunner.setSupported(false)
    let unsupported = DreaminaConnector(directory: directory.appendingPathComponent("old"), runner: oldRunner)
    unsupported.setOwner(alice); await unsupported.connect()
    try check(!unsupported.verified && unsupported.message.contains("更新"), "CLI without server identity check fails closed")
    let corruptDir = directory.appendingPathComponent("corrupt")
    try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
    let corrupt = corruptDir.appendingPathComponent("dreamina-bindings.json")
    try Data("preserve-unrecognized-file".utf8).write(to: corrupt)
    let damaged = DreaminaConnector(directory: corruptDir, runner: runner); damaged.setOwner(alice); await damaged.connect()
    let preserved = try Data(contentsOf: corrupt)
    try check(preserved == Data("preserve-unrecognized-file".utf8), "invalid binding record is preserved rather than overwritten")
    let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
    for url in ["http://jimeng.jianying.com/ai-tool/cli-auth", "https://example.invalid/ai-tool/cli-auth", "https://jimeng.jianying.com/other", "https://attacker@jimeng.jianying.com/ai-tool/cli-auth"] {
        do { _ = try DreaminaAuthorization.read(["verificationUri":url, "expiresAt":future]); throw NativeTestFailure(description: "Unsafe authorization URL accepted") }
        catch DreaminaError.invalidResponse {}
    }
    try check(true, "only the exact official HTTPS authorization page can appear as QR or link")

    let script = directory.appendingPathComponent("echo-argv.sh")
    try Data("#!/bin/sh\nprintf '%s' \"$1\"\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: script.path)
    let literal = "literal; $(touch must-not-exist)"
    let process = DreaminaProcessRunner(executable: script)
    let result = try await process.run([literal], timeout: 2)
    try check(String(data: result.data, encoding: .utf8) == literal, "CLI argv never executes shell syntax from data")
    let sleeper = directory.appendingPathComponent("wait.py")
    try Data("#!/usr/bin/python3\nimport signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nwhile True: time.sleep(.05)\n".utf8).write(to: sleeper)
    try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: sleeper.path)
    let waitingProcess = DreaminaProcessRunner(executable: sleeper)
    let waitTask = Task { try await waitingProcess.run([], timeout: 10) }
    try await Task.sleep(nanoseconds: 200_000_000); waitTask.cancel()
    do { _ = try await waitTask.value; throw NativeTestFailure(description: "Process ignored cancellation") }
    catch is CancellationError { try check(true, "cancelling authorization terminates even an uncooperative owned CLI child") }
    do { _ = try await waitingProcess.run([], timeout: 1); throw NativeTestFailure(description: "Process ignored deadline") }
    catch DreaminaError.timedOut { try check(true, "CLI process deadline bounds a stalled authorization") }
    let flooding = directory.appendingPathComponent("flood.py")
    try Data("#!/usr/bin/python3\nimport sys\nsys.stdout.write('x'*(3*1024*1024))\n".utf8).write(to: flooding)
    try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: flooding.path)
    do { _ = try await DreaminaProcessRunner(executable: flooding).run([], timeout: 5); throw NativeTestFailure(description: "Oversized CLI output accepted") }
    catch DreaminaError.oversized { try check(true, "CLI output cannot exceed bounded memory budget") }

    let app = AppController(directory: directory.appendingPathComponent("app"), testMode: true, studioTransport: DreaminaStudioFixture(), dreaminaRunner: DreaminaFixtureRunner())
    await app.studio.login(email: "alice@example.invalid", password: "fixture", code: "")
    try check(app.dreamina.owner == KakiConnectionOwner(environment: "test", userID: "kaki-alice"), "Tools connection owner comes from the authenticated Studio user")
    await app.dreamina.connect()
    try check(app.dreamina.verified, "native controller associates the authenticated KAKI owner")
    await app.studio.login(email: "bob@example.invalid", password: "fixture", code: "")
    try check(app.dreamina.owner?.userID == "kaki-bob" && app.dreamina.binding == nil && !app.dreamina.verified, "real Studio login switch immediately invalidates previous native connection")
    await app.studio.logout()
    try check(app.dreamina.owner == nil && !app.dreamina.verified, "Studio logout disables Jimeng connection even while settings are closed")
    app.shutdown()
    connector.shutdown(); restored.shutdown(); racing.shutdown(); unsupported.shutdown(); damaged.shutdown()
    print("Dreamina binding tests passed (synthetic OAuth, private IDs, no real CLI credentials)")
}
