import Foundation
import CryptoKit

private actor CreditMockRunner: DreaminaRunning {
    var calls = 0
    var output = #"{"total_credit":12.5,"user_id":123,"user_name":"private","vip_level":"private"}"#
    var continuation: CheckedContinuation<Void, Never>?
    var held = false
    func configure(_ output: String, hold: Bool = false) { self.output = output; held = hold }
    func release() { held = false; continuation?.resume(); continuation = nil }
    func count() -> Int { calls }
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> DreaminaOutput {
        guard arguments == ["user_credit"], timeout <= 20 else { throw NativeTestFailure(description: "credit runner accepts only fixed readonly query") }
        calls += 1
        if held { await withCheckedContinuation { continuation = $0 } }
        return DreaminaOutput(status: 0, data: Data(output.utf8))
    }
}
private actor CreditMockBridge: ClassicCreditBridge {
    var submitted: [ClassicCreditPayload] = []
    var lost = false
    var conflict = false
    var wrong = false
    func configure(lost: Bool = false, conflict: Bool = false, wrong: Bool = false) { self.lost = lost; self.conflict = conflict; self.wrong = wrong }
    func records() -> [ClassicCreditPayload] { submitted }
    func bootstrap() async throws -> ClassicCreditSnapshot {
        ClassicCreditSnapshot(status: "unknown", deviceId: "device", epoch: "epoch", capabilityRevision: 1, snapshotSequence: nil, totalCredit: nil, queriedAt: nil, receivedAt: nil, expiresAt: nil, sequenceMeta: .init(lastSequence: 4), requestId: nil)
    }
    func submit(_ payload: ClassicCreditPayload) async throws -> ClassicCreditSnapshot {
        submitted.append(payload)
        if lost { lost = false; throw URLError(.networkConnectionLost) }
        if conflict { throw StudioError.http(409, "synthetic") }
        return ClassicCreditSnapshot(status: payload.status == "ok" ? "available" : "error", deviceId: wrong ? "other" : "device", epoch: "epoch", capabilityRevision: payload.capabilityRevision, snapshotSequence: payload.sequence, totalCredit: payload.totalCredit, queriedAt: payload.queriedAt, receivedAt: payload.queriedAt, expiresAt: ClassicCreditRefresh.timestamp(Date().addingTimeInterval(120)), sequenceMeta: .init(lastSequence: payload.sequence), requestId: payload.requestId)
    }
}
@MainActor func runClassicCreditTests() async throws {
    let root = URL(fileURLWithPath: "/tmp/kaki-credit-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let device = ClassicCliDevice(id: "device", epoch: "epoch", secret: "synthetic-secret")
    let runner = CreditMockRunner(), bridge = CreditMockBridge()
    var current = true, confirmation = true, confirmations = [Bool]()
    let ledger = try ClassicCreditLedger(directory: root, binding: "synthetic-owner|origin|workspace|device|epoch")
    func request(_ id: String, expires: Date = Date().addingTimeInterval(60), revision: Int = 1) -> ClassicCreditRequest {
        ClassicCreditRequest(requestId: id, deviceId: "device", epoch: "epoch", capabilityRevision: revision, status: "pending", requestedAt: ClassicCreditRefresh.timestamp(Date()), expiresAt: ClassicCreditRefresh.timestamp(expires))
    }
    func make() -> ClassicCreditRefresh {
        ClassicCreditRefresh(ledger: ledger, device: device, bridge: bridge, runner: runner, current: { current }, hashCurrent: { current }, confirm: { changed in confirmations.append(changed); return confirmation })
    }
    let first = request("first")
    let initial = try await make().run(first)
    try check(initial?.totalCredit == 12.5 && initial?.snapshotSequence == 5, "fractional balance uses bootstrap highwater and actual successful result")
    try check(confirmations == [false], "first account requires Tools consent")
    let state = try ledger.read()
    try check(state.reserved == 5 && state.pending == nil && state.identityHMAC?.count == 64 && state.reservations?["first"] != nil, "durable reservation and HMAC survive successful result")
    let bytes = try Data(contentsOf: ledger.file), text = String(decoding: bytes, as: UTF8.self)
    try check(!text.contains("private") && !text.contains("user_id") && !text.contains("user_name") && !text.contains("vip_level"), "ledger contains no raw account fields")
    let attrs = try FileManager.default.attributesOfItem(atPath: ledger.file.path)
    try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "durable ledger stays 0600")
    _ = try await make().run(first)
    let once = await runner.count()
    try check(once == 1, "duplicate request does not query again after module restart")
    let second = request("second")
    await bridge.configure(lost: true)
    do { _ = try await make().run(second); throw NativeTestFailure(description: "lost response expected") }
    catch is URLError { }
    let pending = try ledger.read().pending
    try check(pending?.sequence == 6 && pending?.requestId == "second", "lost response keeps exact original payload and request ID")
    _ = try await make().run(second)
    let calls = await runner.count(), bodies = await bridge.records()
    try check(calls == 2 && bodies[bodies.count - 1] == bodies[bodies.count - 2], "restart retries same body without running CLI twice")
    try check(confirmations == [false], "approved same identity avoids repeated confirmation")
    await runner.configure(#"{"total_credit":0,"user_id":456,"user_name":"hidden","vip_level":"hidden"}"#)
    confirmation = false
    let declined = request("changed-declined")
    let declinedResult = try await make().run(declined)
    let countBeforeDuplicate = await runner.count()
    _ = try await make().run(declined)
    let countAfterDuplicate = await runner.count(), afterDecline = await bridge.records().count
    try check(declinedResult == nil && countAfterDuplicate == countBeforeDuplicate && afterDecline == bodies.count, "changed account denial neither uploads nor re-queries the same request")
    try check(confirmations == [false, true], "changed identity prompts without exposing raw identity")
    confirmation = true
    let zero = try await make().run(request("changed-accepted"))
    try check(zero?.totalCredit == 0 && zero?.status == "available", "real successful zero remains available")
    await runner.configure(#"{"total_credit":true,"user_id":456}"#)
    let malformed = try await make().run(request("malformed"))
    let failureBody = (await bridge.records()).last!
    let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(failureBody)) as! [String: Any]
    try check(malformed?.totalCredit == nil && failureBody.status == "error" && fields["totalCredit"] == nil && fields["user_id"] == nil, "invalid balance sends only fixed error without amount or identity")
    try check(Set(fields.keys) == Set(["epoch", "capabilityRevision", "sequence", "queriedAt", "status", "requestId"]), "strict failure payload contains no arbitrary fields")
    let reservedRequest = request("reserved-before-crash")
    _ = try ledger.reserve(highwater: 0, request: reservedRequest, now: Date())
    let beforeCrash = await runner.count()
    _ = try await make().run(reservedRequest)
    let afterCrash = await runner.count()
    try check(beforeCrash == afterCrash, "restart after reservation before CLI cannot re-query same request")
    await runner.configure(#"{"total_credit":42,"user_id":456}"#, hold: true)
    let service = make(), heldRequest = request("held-context")
    let task = Task { try await service.run(heldRequest) }
    for _ in 0..<100 { if await runner.count() > afterCrash { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let priorWrites = await bridge.records().count
    current = false; await runner.release()
    do { _ = try await task.value; throw NativeTestFailure(description: "late query expected to fail") } catch DreaminaError.wrongOwner { }
    let lateWrites = await bridge.records().count
    try check(lateWrites == priorWrites, "late CLI response after identity change cannot upload")
    current = true
    let expired = try await make().run(request("expired", expires: Date().addingTimeInterval(-1)))
    try check(expired == nil, "expired request never queries")
    await bridge.configure(conflict: true)
    do { _ = try await make().run(request("revision-conflict")); throw NativeTestFailure(description: "409 expected") } catch StudioError.http(409, _) { }
    let after409 = try ledger.read()
    try check(after409.pending == nil && after409.handledRequest == "revision-conflict", "revision conflict drops pending and requires a new explicit request")
    await bridge.configure(wrong: true)
    do { _ = try await make().run(request("wrong-receipt")); throw NativeTestFailure(description: "wrong owner ack expected") } catch DreaminaError.wrongOwner { }
    let wrongPending = try ledger.read().pending
    try check(wrongPending != nil, "unverified ack cannot clear pending or confirm account")
    let independent = try ClassicCreditLedger(directory: root, binding: "different-owner|origin|workspace|device|epoch")
    let independentState = try independent.read()
    try check(independentState.reserved == 0 && independent.file != ledger.file, "owner/workspace/origin/device/epoch isolate counters")
    try await runCreditLoopIntegrationTests()
}

private actor CreditLoopTransport: StudioTransport {
    var pending = true
    var loseFirstAcknowledgement = true
    var writes: [ClassicCreditPayload] = []
    func recorded() -> [ClassicCreditPayload] { writes }
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile {
        let path = request.url!.path
        var headers = ["Content-Type": "application/json"]
        let body: Data
        switch path {
        case "/api/auth/login":
            headers["Set-Cookie"] = "kaki_session=synthetic; Max-Age=3600; Secure; Path=/; HttpOnly"
            body = Data(#"{"user":{"id":"credit-user","email":"fixture@example.invalid"}}"#.utf8)
        case "/api/workspaces": body = Data(#"[{"id":"personal","name":"Personal","kind":"personal","role":"owner"}]"#.utf8)
        case "/api/assets": body = Data(#"{"items":[],"total":0}"#.utf8)
        case "/api/local-cli/devices/resume", "/api/local-cli/devices/pause", "/api/local-cli/devices/heartbeat": body = Data("{}".utf8)
        case "/api/local-cli/devices/claim": body = Data(#"{"task":null}"#.utf8)
        case "/api/local-cli/devices/credit-refresh":
            try check(request.httpMethod == "GET" && request.value(forHTTPHeaderField: "X-Local-CLI-Device") == "device" && request.value(forHTTPHeaderField: "X-Local-CLI-Secret") == "synthetic-secret", "credit poll uses GET and private original device headers")
            if pending {
                let refresh = ClassicCreditRequest(requestId: "loop-request", deviceId: "device", epoch: "epoch", capabilityRevision: 1, status: "pending", requestedAt: ClassicCreditRefresh.timestamp(Date()), expiresAt: ClassicCreditRefresh.timestamp(Date().addingTimeInterval(60)))
                body = try JSONSerialization.data(withJSONObject: ["request": JSONSerialization.jsonObject(with: JSONEncoder().encode(refresh))])
            } else { body = Data(#"{"request":null}"#.utf8) }
        case "/api/local-cli/credit-snapshot":
            try check(request.httpMethod == "GET" && request.value(forHTTPHeaderField: "X-Local-CLI-Secret") == "synthetic-secret", "bootstrap never falls back to browser auth projection")
            body = try JSONEncoder().encode(ClassicCreditSnapshot(status: "unknown", deviceId: "device", epoch: "epoch", capabilityRevision: 1, snapshotSequence: nil, totalCredit: nil, queriedAt: nil, receivedAt: nil, expiresAt: nil, sequenceMeta: .init(lastSequence: 0), requestId: nil))
        case "/api/local-cli/devices/credit-snapshot":
            try check(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "X-Workspace-Id") == "personal", "snapshot write retains exact workspace")
            let payload = try JSONDecoder().decode(ClassicCreditPayload.self, from: request.httpBody!)
            writes.append(payload); pending = false
            if loseFirstAcknowledgement { loseFirstAcknowledgement = false; throw URLError(.networkConnectionLost) }
            body = try JSONEncoder().encode(ClassicCreditSnapshot(status: "available", deviceId: "device", epoch: "epoch", capabilityRevision: payload.capabilityRevision, snapshotSequence: payload.sequence, totalCredit: payload.totalCredit, queriedAt: payload.queriedAt, receivedAt: payload.queriedAt, expiresAt: ClassicCreditRefresh.timestamp(Date().addingTimeInterval(120)), sequenceMeta: .init(lastSequence: payload.sequence), requestId: payload.requestId))
        default: throw NativeTestFailure(description: "unexpected credit integration route")
        }
        let file = URL(fileURLWithPath: "/tmp/kaki-credit-http-" + UUID().uuidString)
        try body.write(to: file)
        return StudioHTTPFile(file: file, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}
@MainActor private func runCreditLoopIntegrationTests() async throws {
    let root = URL(fileURLWithPath: "/tmp/kaki-credit-loop-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let api = CreditLoopTransport(), creditRunner = CreditMockRunner(), classicRunner = ClassicFixtureRunner()
    let studio = StudioStore(directory: root, credentials: StudioMemoryCredentials(), transport: api)
    await studio.login(email: "fixture@example.invalid", password: "synthetic", code: "")
    let binary = root.appendingPathComponent("dreamina"); try Data("synthetic executable".utf8).write(to: binary)
    let owner = studio.environment.baseURL.absoluteString + "|credit-user|personal"
    let directory = root.appendingPathComponent("classic-cli")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let key = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
    let auth = directory.appendingPathComponent(key + ".json")
    try JSONSerialization.data(withJSONObject: ["owner": owner, "fingerprint": ClassicDreaminaCLI.fingerprint(binary), "device": ["id": "device", "epoch": "epoch", "secret": "synthetic-secret"], "profile": "resolution-five"]).write(to: auth)
    let connection = ClassicCliConnection(studio: studio, directory: root, enabled: true, locator: { binary }, runnerFactory: { _ in classicRunner }, creditRunnerFactory: { _ in creditRunner }, creditConfirmation: { _ in true }, creditPollingNanoseconds: 10_000_000)
    connection.connect(automatically: true)
    for _ in 0..<200 { if connection.creditTotal != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    try check(connection.connected && connection.creditTotal == 12.5 && connection.creditQueriedAt != nil, "connected Tools fulfills a Studio request and displays recent balance")
    try await Task.sleep(nanoseconds: 30_000_000)
    let queries = await creditRunner.count(), writes = await api.recorded()
    try check(queries == 1 && writes.count == 2 && writes[0] == writes[1] && writes[0].requestId == "loop-request", "completed slot with lost ack retries identical pending payload without querying again")
    connection.disconnect()
    try check(connection.creditTotal == nil && connection.creditQueriedAt == nil, "disconnect clears local balance immediately")
    connection.shutdown(); studio.shutdown()
}
