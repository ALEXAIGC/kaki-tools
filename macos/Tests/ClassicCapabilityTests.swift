import Foundation
import CryptoKit

private actor CapabilityTransport: StudioTransport {
    var requests: [URLRequest] = []
    var models = ["seedance2.0"]
    var revision = 0
    var failAfterUpdate = false
    var conflict = false
    var wrongDevice = false
    var holdUpdate = false
    var continuation: CheckedContinuation<Void, Never>?
    func configure(lost: Bool = false, conflict: Bool = false, wrong: Bool = false, hold: Bool = false) {
        failAfterUpdate = lost; self.conflict = conflict; wrongDevice = wrong; holdUpdate = hold
    }
    func release() { holdUpdate = false; continuation?.resume(); continuation = nil }
    func recorded() -> [URLRequest] { requests }
    func addModel(_ model: String) { models.append(model); revision += 1 }
    func publicDevice() -> [String: Any] {
        ["id": wrongDevice ? "other-device" : "fixture-device", "epoch": "fixture-epoch", "models": models, "revision": revision, "profile": "resolution-five"]
    }
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile {
        requests.append(request)
        let path = request.url!.path
        var status = 200
        var headers = ["Content-Type": "application/json"]
        let body: Any
        switch path {
        case "/api/auth/login":
            headers["Set-Cookie"] = "kaki_session=synthetic; Max-Age=3600; Secure; Path=/; HttpOnly"
            body = ["user": ["id": "fixture-user", "email": "fixture@example.invalid"]]
        case "/api/workspaces": body = [["id": "personal", "name": "Personal", "kind": "personal", "role": "owner"], ["id": "team", "name": "Team", "kind": "team", "role": "owner"]]
        case "/api/auth/logout": body = [:] as [String: String]
        case "/api/assets": body = ["items": [], "total": 0]
        case "/api/local-cli/catalog": body = ["device": publicDevice()]
        case "/api/local-cli/devices/capabilities":
            let payload = try JSONDecoder().decode(ClassicCliCapabilityPayload.self, from: request.httpBody!)
            if holdUpdate { await withCheckedContinuation { continuation = $0 } }
            if conflict {
                revision += 1; models = ["seedance2.0fast"]; status = 409; body = ["message": "fixture conflict"]; self.conflict = false
            } else {
                guard payload.expectedRevision == revision || (payload.expectedRevision + 1 == revision && payload.models == models) else {
                    throw NativeTestFailure(description: "retry changed the original revision")
                }
                if models != payload.models { revision += 1; models = payload.models }
                if failAfterUpdate { failAfterUpdate = false; throw URLError(.networkConnectionLost) }
                body = publicDevice()
            }
        case "/api/local-cli/devices/resume", "/api/local-cli/devices/heartbeat", "/api/local-cli/devices/pause": body = [:] as [String: String]
        case "/api/local-cli/devices/claim": body = ["task": NSNull()]
        default: throw NativeTestFailure(description: "unexpected capability route " + path)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try JSONSerialization.data(withJSONObject: body).write(to: file)
        return StudioHTTPFile(file: file, response: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}
@MainActor func runClassicCapabilityTests() async throws {
    let device = ClassicCliDevice(id: "fixture-device", epoch: "fixture-epoch", secret: "synthetic")
    let old = try JSONDecoder().decode(ClassicCliPublicDevice.self, from: Data(#"{"id":"fixture-device","epoch":"fixture-epoch","models":["seedance2.0"],"profile":"resolution-five"}"#.utf8))
    try check(old.effectiveRevision == 0, "legacy public revision defaults to zero")
    let payload = try ClassicCliCapabilityPayload(current: old, models: ["seedance2.5", "seedance2.0", "seedance2.5"])
    try check(payload.models == ["seedance2.0", "seedance2.5"], "capabilities use unique sorted exact model IDs")
    let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
    try check(Set(fields.keys) == Set(["expectedRevision", "profile", "models"]), "strict update payload carries no registration or credential fields")
    for bad in [
        ClassicCliPublicDevice(id: "other", epoch: device.epoch, models: payload.models, revision: 1, profile: payload.profile),
        ClassicCliPublicDevice(id: device.id, epoch: "old", models: payload.models, revision: 1, profile: payload.profile),
        ClassicCliPublicDevice(id: device.id, epoch: device.epoch, models: payload.models, revision: 2, profile: payload.profile),
        ClassicCliPublicDevice(id: device.id, epoch: device.epoch, models: ["alias"], revision: 1, profile: payload.profile)
    ] {
        do { try payload.validateReceipt(bad, device: device); throw NativeTestFailure(description: "invalid receipt accepted") }
        catch is NativeTestFailure { throw NativeTestFailure(description: "invalid capability receipt accepted") }
        catch { try check(true, "wrong device, epoch, later revision and alias receipts rejected") }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-capability-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = CapabilityTransport(), runner = ClassicFixtureRunner()
    let studio = StudioStore(directory: root, credentials: StudioMemoryCredentials(), transport: transport)
    await studio.login(email: "fixture@example.invalid", password: "synthetic", code: "")
    let binary = root.appendingPathComponent("dreamina"); try Data("synthetic CLI".utf8).write(to: binary)
    let owner = studio.environment.baseURL.absoluteString + "|fixture-user|personal"
    let directory = root.appendingPathComponent("classic-cli")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let key = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
    let file = directory.appendingPathComponent(key + ".json")
    let secret = "synthetic-device-secret"
    try JSONSerialization.data(withJSONObject: ["owner": owner, "fingerprint": ClassicDreaminaCLI.fingerprint(binary), "device": ["id": device.id, "epoch": device.epoch, "secret": secret], "profile": "resolution-five"]).write(to: file)
    let journal = directory.appendingPathComponent("journal")
    try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
    let receiptFile = journal.appendingPathComponent("original.json"), receiptBytes = Data("synthetic original signed task/token/submitId".utf8)
    try receiptBytes.write(to: receiptFile)
    func make() -> ClassicCliConnection { ClassicCliConnection(studio: studio, directory: root, enabled: true, locator: { binary }, runnerFactory: { _ in runner }) }
    func settle(_ connection: ClassicCliConnection) async throws {
        for _ in 0..<200 { if !connection.busy { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw NativeTestFailure(description: "capability operation did not settle")
    }
    func record() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any] }
    let connection = make(); connection.connect(automatically: true); try await settle(connection)
    try check(connection.connected, "fixture restores only originally approved device")
    let before = await transport.recorded().count
    connection.detectCapabilities(); try await settle(connection)
    try check(Set(connection.capabilityPreview?.added ?? []) == Set(["seedance2.0fast", "dreamina-multiframe"]), "detection presents current and added models without writing")
    let detectRequests = Array((await transport.recorded()).dropFirst(before))
    try check(detectRequests.allSatisfy { !["/api/local-cli/devices/capabilities", "/api/local-cli/devices/resume", "/api/local-cli/devices/register"].contains($0.url!.path) }, "explicit detection performs no resume, registration or update")
    await transport.configure(lost: true)
    connection.confirmCapabilities(); try await settle(connection)
    let pendingRecord = try record()
    try check(pendingRecord["pendingCapabilities"] != nil, "lost response retains exact pending payload")
    connection.shutdown()
    let restarted = make(); restarted.connect(automatically: true); try await settle(restarted)
    restarted.detectCapabilities(); try await settle(restarted)
    try check(restarted.capabilityPreview?.retry == true && restarted.capabilityPreview?.payload.expectedRevision == 0, "restart offers exact original CAS retry after lost response")
    restarted.confirmCapabilities(); try await settle(restarted)
    let requests = (await transport.recorded()).filter { $0.url!.path == "/api/local-cli/devices/capabilities" }
    try check(requests.count == 2 && requests[0].httpBody == requests[1].httpBody, "lost response retry preserves identical encoded payload and revision")
    try check(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Local-CLI-Device") == device.id && $0.value(forHTTPHeaderField: "X-Local-CLI-Secret") == secret && $0.value(forHTTPHeaderField: "X-Workspace-Id") == "personal" }, "capability writes bind original private device and exact workspace")
    var saved = try record()
    try check(saved["pendingCapabilities"] == nil && (saved["capabilities"] as? [String: Any])?["revision"] as? Int == 1, "idempotent receipt persists public revision and clears pending request")
    let unchangedJournal = try Data(contentsOf: receiptFile)
    try check((saved["device"] as? [String: String]) == ["id": device.id, "epoch": device.epoch, "secret": secret] && unchangedJournal == receiptBytes, "update preserves device identity, credential and journal bytes")
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    try check(mode?.intValue == 0o600, "capability authorization cache stays private")
    restarted.detectCapabilities(); try await settle(restarted); await transport.configure(conflict: true)
    restarted.confirmCapabilities(); try await settle(restarted)
    try check(restarted.capabilityPreview == nil && restarted.capabilityStatus.contains("冲突"), "409 re-reads current device and requires fresh detection and confirmation")
    saved = try record()
    try check((saved["capabilities"] as? [String: Any])?["revision"] as? Int == 2 && saved["pendingCapabilities"] == nil, "409 refreshes authoritative revision without automatically retrying")
    let countAfterConflict = (await transport.recorded()).filter { $0.url!.path == "/api/local-cli/devices/capabilities" }.count
    try check(countAfterConflict == 3, "409 sends exactly one update attempt")
    await transport.addModel("seedance2.5")
    restarted.detectCapabilities(); try await settle(restarted)
    try check(restarted.capabilityPreview?.removed == ["seedance2.5"], "capability reduction explicitly previews the exact removed model")
    await transport.configure(wrong: true)
    restarted.detectCapabilities(); try await settle(restarted)
    try check(restarted.capabilityPreview == nil, "catalog for another device cannot be approved")
    await transport.configure()
    restarted.detectCapabilities(); try await settle(restarted)
    try Data("changed CLI bytes".utf8).write(to: binary, options: .atomic)
    restarted.confirmCapabilities(); try await settle(restarted)
    let afterChange = (await transport.recorded()).filter { $0.url!.path == "/api/local-cli/devices/capabilities" }.count
    try check(afterChange == countAfterConflict && restarted.capabilityPreview == nil, "CLI replacement invalidates old detection before writing")
    try Data("synthetic CLI".utf8).write(to: binary, options: .atomic)
    restarted.detectCapabilities(); try await settle(restarted)
    await transport.configure(hold: true)
    restarted.confirmCapabilities()
    for _ in 0..<100 {
        let writes = (await transport.recorded()).filter { $0.url!.path == "/api/local-cli/devices/capabilities" }.count
        if writes > countAfterConflict { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    restarted.identityChanged(); await transport.release()
    try await Task.sleep(nanoseconds: 50_000_000)
    let lateRecord = try record()
    try check(!restarted.connected && restarted.capabilityPreview == nil && lateRecord["pendingCapabilities"] != nil && (lateRecord["capabilities"] as? [String: Any])?["revision"] as? Int == 2, "late capability response after account context invalidation cannot replace cached revision")
    restarted.disconnect(); let pausedBefore = await transport.recorded().count
    restarted.detectCapabilities(); try await settle(restarted)
    let pausedRecord = try record(), pausedRequests = await transport.recorded()
    try check(!restarted.connected && pausedRecord["autoResume"] as? Bool == false && pausedRequests.count == pausedBefore, "detecting paused device never restores or expands authorization")
    restarted.shutdown(); studio.shutdown()
    try await runCapabilityHashRaceTests()
}

// A deliberately non-cancellable hash wait reproduces detached-task completion after invalidation.
private actor CapabilityHashGate {
    private var calls = 0
    private var target: Int?
    private var held: CheckedContinuation<Void, Never>?
    func arm(after count: Int) { target = calls + count }
    func isHeld() -> Bool { held != nil }
    func release() { target = nil; held?.resume(); held = nil }
    func fingerprint(_ url: URL) async throws -> String {
        calls += 1
        let result = try ClassicDreaminaCLI.fingerprint(url)
        if calls == target { await withCheckedContinuation { held = $0 } }
        return result
    }
}
@MainActor private func runCapabilityHashRaceTests() async throws {
    let phases = [("preview", 5), ("send", 2), ("receipt", 3), ("409-entry", 3), ("409-cache", 6)]
    for (phase, pauseAt) in phases {
        for action in ["environment", "account", "workspace", "disconnect", "cancel"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-hash-race-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let transport = CapabilityTransport(), runner = ClassicFixtureRunner(), gate = CapabilityHashGate()
            let studio = StudioStore(directory: root, credentials: StudioMemoryCredentials(), transport: transport)
            await studio.login(email: "fixture@example.invalid", password: "synthetic", code: "")
            let binary = root.appendingPathComponent("dreamina"); try Data("hash-race CLI".utf8).write(to: binary)
            let owner = studio.environment.baseURL.absoluteString + "|fixture-user|personal"
            let directory = root.appendingPathComponent("classic-cli")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let key = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
            let file = directory.appendingPathComponent(key + ".json")
            let cached: [String: Any] = ["id": "fixture-device", "epoch": "fixture-epoch", "models": ["seedance2.0"], "revision": 0, "profile": "resolution-five"]
            try JSONSerialization.data(withJSONObject: ["owner": owner, "fingerprint": ClassicDreaminaCLI.fingerprint(binary), "device": ["id": "fixture-device", "epoch": "fixture-epoch", "secret": "synthetic"], "profile": "resolution-five", "capabilities": cached]).write(to: file)
            let journal = directory.appendingPathComponent("journal")
            try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
            let journalFile = journal.appendingPathComponent("original.json"), journalBytes = Data("original task signature/token/submitId".utf8)
            try journalBytes.write(to: journalFile)
            let connection = ClassicCliConnection(studio: studio, directory: root, enabled: true, locator: { binary }, runnerFactory: { _ in runner }, capabilityFingerprint: { try await gate.fingerprint($0) })
            func settle() async throws {
                for _ in 0..<200 { if !connection.busy { return }; try await Task.sleep(nanoseconds: 5_000_000) }
                throw NativeTestFailure(description: "hash-race setup did not settle")
            }
            connection.connect(automatically: true); try await settle()
            try check(connection.connected, "hash-race fixture restores exact approved device")
            if phase != "preview" { connection.detectCapabilities(); try await settle(); try check(connection.capabilityPreview != nil, "hash-race fixture has approved preview") }
            if phase.hasPrefix("409") { await transport.configure(conflict: true) }
            await gate.arm(after: pauseAt)
            if phase == "preview" { connection.detectCapabilities() } else { connection.confirmCapabilities() }
            for _ in 0..<200 { if await gate.isHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            let held = await gate.isHeld()
            try check(held, "controlled hash suspended at " + phase)
            let before = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            switch action {
            case "environment": await studio.changeEnvironment(.production); connection.identityChanged()
            case "account": await studio.logout(); connection.identityChanged()
            case "workspace": await studio.selectWorkspace("team"); connection.identityChanged()
            case "disconnect": connection.disconnect()
            default: connection.cancelOperation()
            }
            let invalidatedBytes = try Data(contentsOf: file)
            await gate.release()
            try await Task.sleep(nanoseconds: 50_000_000)
            let afterBytes = try Data(contentsOf: file), after = try JSONSerialization.jsonObject(with: afterBytes) as! [String: Any]
            let writes = (await transport.recorded()).filter { $0.url!.path == "/api/local-cli/devices/capabilities" }
            try check(writes.count == (["preview", "send"].contains(phase) ? 0 : 1), "hash completion after " + action + " cannot send a stale update at " + phase)
            try check(afterBytes == invalidatedBytes, "hash completion after " + action + " cannot persist a stale receipt or 409 cache at " + phase)
            let caps = after["capabilities"] as? [String: Any]
            try check(caps?["revision"] as? Int == 0 && connection.capabilityPreview == nil, "invalidation preserves original revision and clears preview at " + phase)
            try check((before["pendingCapabilities"] == nil) == (after["pendingCapabilities"] == nil), "hash invalidation preserves uncertain pending request at " + phase)
            let unchangedJournal = try Data(contentsOf: journalFile)
            try check(unchangedJournal == journalBytes && (after["device"] as? [String: String])?["id"] == "fixture-device", "hash invalidation preserves journal and device at " + phase)
            connection.shutdown(); studio.shutdown()
        }
    }
}
