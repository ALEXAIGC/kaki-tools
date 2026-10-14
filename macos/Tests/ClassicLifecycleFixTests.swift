import Foundation
import CryptoKit

private actor ClassicLifecycleTransport: StudioTransport {
    private var calls: [String] = []
    private var pauseHeld: CheckedContinuation<Void, Never>?
    private var resumeHeld: CheckedContinuation<Void, Never>?
    private var holdPause = false
    private var holdResumeAfter = Int.max
    private var resumeCount = 0
    private var pauseFailure = false
    private var resumeFailure = false
    private var conflictPath: String?
    private var claimTask: ClassicVideoTask?
    private var pollingHint: Int?
    private var claimTimes: [TimeInterval] = []
    func setPollingHint(_ milliseconds: Int?) { pollingHint = milliseconds }
    func claimTimestamps() -> [TimeInterval] { claimTimes }
    func setTask(_ task: ClassicVideoTask?) { claimTask = task }
    func configure(holdPause: Bool = false, pauseFailure: Bool = false, resumeFailure: Bool = false, holdResumeAfter: Int = Int.max, conflictPath: String? = nil) {
        self.holdPause = holdPause; self.pauseFailure = pauseFailure; self.resumeFailure = resumeFailure
        self.holdResumeAfter = holdResumeAfter; self.conflictPath = conflictPath
    }
    func releasePause() { holdPause = false; pauseHeld?.resume(); pauseHeld = nil }
    func releaseResume() { holdResumeAfter = Int.max; resumeHeld?.resume(); resumeHeld = nil }
    func recorded() -> [String] { calls }
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile {
        let path = request.url!.path
        let workspace = request.value(forHTTPHeaderField: "X-Workspace-Id") ?? ""
        calls.append(path + "|" + workspace)
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var body: Any
        switch path {
        case "/api/auth/login":
            headers["Set-Cookie"] = "kaki_session=synthetic; Max-Age=3600; Secure; Path=/; HttpOnly"
            body = ["user": ["id": "lifecycle-user", "email": "fixture@example.invalid"]]
        case "/api/workspaces": body = [
            ["id": "personal", "name": "Personal", "kind": "personal", "role": "owner"],
            ["id": "team", "name": "Team", "kind": "team", "role": "owner"]]
        case "/api/assets": body = ["items": [], "total": 0]
        case "/api/local-cli/devices/pause":
            if holdPause { await withCheckedContinuation { pauseHeld = $0 } }
            if pauseFailure { throw URLError(.networkConnectionLost) }
            calls.append("pause-confirmed|" + workspace); body = [:] as [String: String]
        case "/api/local-cli/devices/resume":
            resumeCount += 1
            if resumeCount >= holdResumeAfter { await withCheckedContinuation { resumeHeld = $0 } }
            if resumeFailure { status = 409; body = ["error": "device_not_current"] }
            else { body = [:] as [String: String] }
        case "/api/local-cli/devices/claim", "/api/local-cli/devices/heartbeat":
            if path.hasSuffix("claim") { claimTimes.append(Date().timeIntervalSince1970) }
            if path == conflictPath {
                conflictPath = nil; status = 409; body = ["error": "device_paused"]
                calls.append("conflict-confirmed|" + workspace)
            } else if path.hasSuffix("claim"), let claimTask {
                body = ["task": try JSONSerialization.jsonObject(with: JSONEncoder().encode(claimTask))]
            } else { body = path.hasSuffix("claim") ? ["task": NSNull()] : [:] as [String: String] }
        case "/api/local-cli/devices/credit-refresh", "/api/local-cli/tasks/original-task/events":
            if path == conflictPath {
                conflictPath = nil; status = 409; body = ["error": "fixture_slot_conflict"]
                calls.append("conflict-confirmed|" + workspace)
            } else { body = ["request": NSNull()] }
        case "/api/local-cli/devices/register": throw NativeTestFailure(description: "lifecycle safety check allowed a replacement registration")
        default: throw NativeTestFailure(description: "unexpected lifecycle fixture request: " + path)
        }
        if path.hasSuffix("devices/claim"), let pollingHint, var fields = body as? [String: Any] {
            fields["pollAfterMs"] = pollingHint; body = fields
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try JSONSerialization.data(withJSONObject: body).write(to: file)
        return StudioHTTPFile(file: file, response: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}
@MainActor private struct ClassicLifecycleFixture {
    let root: URL
    let api = ClassicLifecycleTransport()
    let runner = ClassicFixtureRunner()
    let studio: StudioStore
    let binary: URL
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        studio = StudioStore(directory: root, credentials: StudioMemoryCredentials(), transport: api)
        await studio.login(email: "fixture@example.invalid", password: "synthetic", code: "")
        binary = root.appendingPathComponent("dreamina"); try Data("lifecycle fixture CLI".utf8).write(to: binary)
    }
    var owner: String { studio.environment.baseURL.absoluteString + "|lifecycle-user|" + studio.workspaceID }
    var journal: URL { root.appendingPathComponent("classic-cli/journal", isDirectory: true) }
    func authorization(workspace: String = "personal") -> URL {
        let owner = studio.environment.baseURL.absoluteString + "|lifecycle-user|" + workspace
        let key = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("classic-cli/" + key + ".json")
    }
    func seed(workspace: String = "personal", fingerprint: String? = nil) throws {
        let directory = root.appendingPathComponent("classic-cli", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let owner = studio.environment.baseURL.absoluteString + "|lifecycle-user|" + workspace
        try JSONSerialization.data(withJSONObject: ["owner": owner, "fingerprint": try fingerprint ?? ClassicDreaminaCLI.fingerprint(binary),
            "profile": "resolution-five", "device": ["id": "fixture-" + workspace, "epoch": "fixture-epoch", "secret": "synthetic"]]).write(to: authorization(workspace: workspace))
    }
    func seedTask(stage: String, owner: String? = nil) throws {
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let snapshot = ClassicVideoSnapshot(prompt: "fixture", model: "seedance2.0", duration: 5, aspect: "16:9", resolution: "720p", mode: "text", profile: "resolution-five")
        let task = ClassicVideoTask(id: "original-task", projectId: "fixture-project", nodeId: "fixture-node", payloadHash: String(repeating: "a", count: 64), snapshot: snapshot, stage: stage, submitId: "original-submit")
        try JSONEncoder().encode(ClassicCliJournal(task: task, owner: owner ?? self.owner, stage: stage, submitId: task.submitId)).write(to: journal.appendingPathComponent("original-task.json"))
    }
    func connection() -> ClassicCliConnection {
        ClassicCliConnection(studio: studio, directory: root, enabled: true, locator: { [binary] in binary }, runnerFactory: { [runner] _ in runner })
    }
    func cleanup() { studio.shutdown(); try? FileManager.default.removeItem(at: root) }
}
@MainActor private func lifecycleSettle(_ connection: ClassicCliConnection) async throws {
    for _ in 0..<300 {
        if !connection.busy { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw NativeTestFailure(description: "lifecycle fixture operation did not settle")
}
@MainActor func runClassicLifecycleFixTests() async throws {
    let decoder = JSONDecoder()
    for (literal, expected) in [("200", UInt64(200_000_000)), ("10000", UInt64(10_000_000_000)), ("1250", UInt64(1_250_000_000))] {
        let response = try decoder.decode(ClassicCliClaimResponse.self, from: Data(("{\"task\":null,\"pollAfterMs\":" + literal + "}").utf8))
        try check(response.task == nil && response.pollNanoseconds == expected, "valid server scheduling hint \(literal) preserves idle claim")
    }
    for literal in ["null", "true", "false", "\"200\"", "200.5", "0", "199", "10001", "-1", "9223372036854775807", "{}", "[]"] {
        let response = try decoder.decode(ClassicCliClaimResponse.self, from: Data(("{\"task\":null,\"pollAfterMs\":" + literal + "}").utf8))
        try check(response.pollNanoseconds == ClassicCliClaimResponse.defaultPollNanoseconds, "invalid scheduling hint \(literal) retains legacy ten-second delay")
    }
    let legacy = try decoder.decode(ClassicCliClaimResponse.self, from: Data("{\"task\":null}".utf8))
    try check(legacy.pollNanoseconds == ClassicCliClaimResponse.defaultPollNanoseconds, "legacy claim without hint remains backward compatible")
    let snapshot = ClassicVideoSnapshot(prompt: "fixture", model: "seedance2.0", duration: 5, aspect: "16:9", resolution: "720p", mode: "text", profile: "resolution-five")
    let task = ClassicVideoTask(id: "original-task", projectId: "fixture-project", nodeId: "fixture-node", payloadHash: String(repeating: "a", count: 64), snapshot: snapshot, stage: "awaiting-confirmation", submitId: nil)
    let payload = try JSONSerialization.data(withJSONObject: ["task": JSONSerialization.jsonObject(with: JSONEncoder().encode(task)), "pollAfterMs": "malformed"])
    let preserved = try decoder.decode(ClassicCliClaimResponse.self, from: payload)
    try check(preserved.task?.id == task.id && preserved.pollNanoseconds == ClassicCliClaimResponse.defaultPollNanoseconds, "malformed optional hint never discards a legitimate original task")
    // Successful idle claims honour a bounded hint rather than waiting ten seconds
    // before filling another available remote slot. Local work stays sequential.
    do {
        let fixture = try await ClassicLifecycleFixture(); defer { fixture.cleanup() }
        try fixture.seed(); await fixture.api.setPollingHint(200)
        let connection = fixture.connection(); defer { connection.shutdown() }
        connection.connect(automatically: true); try await lifecycleSettle(connection)
        for _ in 0..<200 {
            if (await fixture.api.claimTimestamps()).count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let times = await fixture.api.claimTimestamps()
        try check(times.count >= 2 && times[1] - times[0] >= 0.18, "successful idle claim uses the safe minimum scheduling interval")
    }
    for failure in [false, true] {
        let fixture = try await ClassicLifecycleFixture(); defer { fixture.cleanup() }
        try fixture.seed(); await fixture.api.setPollingHint(failure ? 200 : 0)
        if failure {
            await fixture.api.setTask(task)
            await fixture.api.configure(conflictPath: "/api/local-cli/tasks/original-task/events")
        }
        let connection = fixture.connection(); defer { connection.shutdown() }
        connection.connect(automatically: true); try await lifecycleSettle(connection)
        try await Task.sleep(nanoseconds: 650_000_000)
        let times = await fixture.api.claimTimestamps(), routes = await fixture.api.recorded()
        try check(times.count == 1 && connection.connected, failure ? "failed serial task step ignores fast hint and keeps ten-second backoff" : "out-of-range zero hint cannot cause a rapid polling loop")
        if failure { try check(routes.contains("conflict-confirmed|personal"), "backoff test reached the actual original task event failure") }
    }
    // Pause A remains in-flight across A -> B -> A. The cancelled B operation must
    // never resume, and A's next resume must wait for the old pause receipt.
    do {
        let fixture = try await ClassicLifecycleFixture(); defer { fixture.cleanup() }
        try fixture.seed(); try fixture.seed(workspace: "team")
        let connection = fixture.connection(); defer { connection.shutdown() }
        connection.connect(automatically: true); try await lifecycleSettle(connection)
        try check(connection.connected, "lifecycle fixture connects the original approved device")
        await fixture.api.configure(holdPause: true)
        await fixture.studio.selectWorkspace("team"); connection.identityChanged(); connection.connect(automatically: true)
        for _ in 0..<100 {
            if (await fixture.api.recorded()).contains("/api/local-cli/devices/pause|personal") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await fixture.studio.selectWorkspace("personal"); connection.identityChanged(); connection.connect(automatically: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        let blocked = await fixture.api.recorded()
        try check(blocked.filter { $0.hasPrefix("/api/local-cli/devices/resume|") }.count == 1 && !connection.connected,
                  "A to B to A never sends a new resume while the old A pause is in-flight")
        await fixture.api.releasePause(); try await lifecycleSettle(connection)
        let routes = await fixture.api.recorded()
        let lastResume = routes.lastIndex(of: "/api/local-cli/devices/resume|personal")!
        try check(routes.firstIndex(of: "pause-confirmed|personal")! < lastResume && connection.connected,
                  "new A resume is ordered after confirmed old pause")
        try check(!routes.contains("/api/local-cli/devices/resume|team"), "cancelled B resume sends no lifecycle side effect")
    }
    // A resume request that ignores parent cancellation may still reach the server.
    // Its receipt must precede the compensating old pause and the next workspace resume.
    do {
        let fixture = try await ClassicLifecycleFixture(); defer { fixture.cleanup() }
        try fixture.seed(); try fixture.seed(workspace: "team")
        await fixture.api.configure(holdResumeAfter: 1)
        let connection = fixture.connection(); defer { connection.shutdown() }
        connection.connect(automatically: true)
        for _ in 0..<100 {
            if (await fixture.api.recorded()).contains("/api/local-cli/devices/resume|personal") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await fixture.studio.selectWorkspace("team"); connection.identityChanged(); connection.connect(automatically: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        let blocked = await fixture.api.recorded()
        try check(!blocked.contains("/api/local-cli/devices/pause|personal") && !blocked.contains("/api/local-cli/devices/resume|team"),
                  "cancelling an in-flight resume cannot race a compensating pause or newer workspace resume")
        await fixture.api.releaseResume(); try await lifecycleSettle(connection)
        let routes = await fixture.api.recorded()
        try check(routes.firstIndex(of: "pause-confirmed|personal")! < routes.firstIndex(of: "/api/local-cli/devices/resume|team")! && connection.connected,
                  "late original resume is followed by confirmed old pause before connecting the new workspace")
    }
    // Ambiguous pause failures cannot be ignored in favour of a newer resume.
    do {
        let fixture = try await ClassicLifecycleFixture(); defer { fixture.cleanup() }
        try fixture.seed()
        let connection = fixture.connection(); defer { connection.shutdown() }
        connection.connect(automatically: true); try await lifecycleSettle(connection)
        await fixture.api.configure(pauseFailure: true)
        connection.identityChanged(); connection.connect(automatically: true); try await lifecycleSettle(connection)
        let routes = await fixture.api.recorded()
        try check(!connection.connected && connection.status.contains("断开尚未确认") && routes.filter { $0.hasPrefix("/api/local-cli/devices/resume|") }.count == 1,
                  "lost pause receipt fails closed without racing a new resume")
    }
    // A local binary replacement or refused resume must not revoke paid original tasks.
    for stage in ["submitted", "dispatch-intent", "upload-ready", "unknown"] {
        let fixture = try await ClassicLifecycleFixture(); defer { fixture.cleanup() }
        try fixture.seed(fingerprint: "original-binary"); try fixture.seedTask(stage: stage)
        let original = try Data(contentsOf: fixture.authorization())
        let connection = fixture.connection(); defer { connection.shutdown() }
        connection.connect(); try await lifecycleSettle(connection)
        let routes = await fixture.api.recorded(), after = try Data(contentsOf: fixture.authorization())
        try check(!connection.connected && connection.status.contains("未完成任务") && !routes.contains(where: { $0.contains("devices/register") }) && original == after,
                  "unfinished \(stage) task blocks fingerprint replacement before consent and preserves original authorization")
    }
    do {
        let fixture = try await ClassicLifecycleFixture(); defer { fixture.cleanup() }
        try fixture.seed(); try fixture.seedTask(stage: "submitted")
        let connection = fixture.connection(); defer { connection.shutdown() }
        await fixture.api.configure(resumeFailure: true)
        connection.connect(); try await lifecycleSettle(connection)
        try check(!connection.connected && connection.status.contains("未完成任务"), "failed manual resume cannot replace a device with original unfinished jobs")
    }
    do {
        let fixture = try await ClassicLifecycleFixture(); defer { fixture.cleanup() }
        try fixture.seed(); try fixture.seedTask(stage: "submitted", owner: "another-account|workspace")
        let connection = fixture.connection(); defer { connection.shutdown() }
        connection.upgrade()
        let routes = await fixture.api.recorded()
        try check(!connection.busy && connection.status.contains("未完成任务") && !routes.contains(where: { $0.contains("local-cli") }),
                  "CLI upgrade checks unfinished journals across every account without executing an installer")
    }
    do {
        let fixture = try await ClassicLifecycleFixture(); defer { fixture.cleanup() }
        try fixture.seed(fingerprint: "original-binary")
        try FileManager.default.createDirectory(at: fixture.journal, withIntermediateDirectories: true)
        let corrupt = fixture.journal.appendingPathComponent("unreadable.json")
        let bytes = Data("not a decodable task journal".utf8); try bytes.write(to: corrupt)
        let connection = fixture.connection(); defer { connection.shutdown() }
        connection.connect(); try await lifecycleSettle(connection)
        try check(!connection.connected && connection.status.contains("记录无法核对"), "unreadable journal fails closed before replacement registration")
        connection.upgrade()
        let after = try Data(contentsOf: corrupt)
        try check(!connection.busy && connection.status.contains("记录无法核对") && after == bytes,
                  "corrupt original journals block CLI upgrade and are retained byte-for-byte")
    }
    // A task/CAS conflict is distinct from a device lifecycle conflict. Do not
    // interrupt a healthy connection or silently change the account binding.
    for endpoint in ["/api/local-cli/devices/credit-refresh", "/api/local-cli/tasks/original-task/events"] {
        let fixture = try await ClassicLifecycleFixture(); defer { fixture.cleanup() }
        try fixture.seed()
        if endpoint.contains("/tasks/") {
            let snapshot = ClassicVideoSnapshot(prompt: "fixture", model: "seedance2.0", duration: 5, aspect: "16:9", resolution: "720p", mode: "text", profile: "resolution-five")
            await fixture.api.setTask(ClassicVideoTask(id: "original-task", projectId: "fixture-project", nodeId: "fixture-node", payloadHash: String(repeating: "a", count: 64), snapshot: snapshot, stage: "awaiting-confirmation", submitId: nil))
        }
        await fixture.api.configure(conflictPath: endpoint)
        let connection = fixture.connection(); defer { connection.shutdown() }
        connection.connect(automatically: true); try await lifecycleSettle(connection)
        for _ in 0..<200 {
            if (await fixture.api.recorded()).contains("conflict-confirmed|personal") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let routes = await fixture.api.recorded(), commands = await fixture.runner.allCalls()
        try check(routes.contains("conflict-confirmed|personal") && connection.connected && !routes.contains(where: { $0.contains("devices/pause") }),
                  "non-lifecycle \(endpoint) 409 preserves the healthy original connection")
        try check(!commands.contains(where: { $0.first == "text2video" && $0.count > 2 }),
                  "task or credit conflict invokes no paid command")
    }
    // Either lifecycle polling endpoint can invalidate a nominally connected UI.
    for endpoint in ["claim", "heartbeat"] {
        let fixture = try await ClassicLifecycleFixture(); defer { fixture.cleanup() }
        try fixture.seed()
        await fixture.api.configure(holdResumeAfter: 2, conflictPath: "/api/local-cli/devices/" + endpoint)
        let connection = fixture.connection(); defer { connection.shutdown() }
        connection.connect(automatically: true)
        for _ in 0..<200 {
            if (await fixture.api.recorded()).contains("conflict-confirmed|personal") && !connection.connected { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        let routes = await fixture.api.recorded()
        try check(!connection.connected && !routes.contains(where: { $0.contains("devices/register") }),
                  "\(endpoint) 409 clears connected state and never registers a replacement")
        await fixture.api.releaseResume(); try await lifecycleSettle(connection)
        try check(connection.connected, "\(endpoint) 409 restores only the original remembered device after pause completion")
    }
}
