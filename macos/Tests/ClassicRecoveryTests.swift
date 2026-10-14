import Foundation

private actor RecoveryRunner: DreaminaRunning {
    enum Receipt: Sendable { case exact, exactWithExtra, legacy, legacyWithoutFile, pending }
    var receipt: Receipt
    var paid = 0, queries = 0
    let original = Data("original-recovery-video".utf8)
    init(_ receipt: Receipt = .exact) { self.receipt = receipt }
    func counts() -> (Int, Int) { (paid, queries) }
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> DreaminaOutput {
        if arguments.first == "text2video" {
            paid += 1
            return DreaminaOutput(status: 0, data: Data("{\"submit_id\":\"original-submit\"}".utf8))
        }
        guard arguments.count == 5, arguments[0] == "query_result", arguments[2] == "original-submit" else { throw NativeTestFailure(description: "recovery runner only accepts the original query ID") }
        queries += 1
        if receipt == .pending { return DreaminaOutput(status: 0, data: Data("{\"submit_id\":\"original-submit\",\"gen_status\":\"running\"}".utf8)) }
        let folder = URL(fileURLWithPath: arguments[4]), file = folder.appendingPathComponent("exact.mp4")
        if receipt != .legacyWithoutFile { try original.write(to: file) }
        if receipt == .exactWithExtra { try Data("wrong-extra-video".utf8).write(to: folder.appendingPathComponent("extra.mp4")) }
        let video = receipt == .legacy || receipt == .legacyWithoutFile ? ["video_url": "https://fixture.invalid/original.mp4"] : ["path": file.path]
        return DreaminaOutput(status: 0, data: try JSONSerialization.data(withJSONObject: ["submit_id":"original-submit", "gen_status":"success", "result_json":["videos":[video]]]))
    }
}
private actor RecoveryBridge: ClassicCliBridge {
    enum Preparation: Sendable { case ready, network, cancelled, wrongOwner, http(Int), invalid }
    enum Dispatch: Sendable { case ready, unsentOnce, conflict }
    var preparation: Preparation
    var dispatch: Dispatch
    var events: [String] = [], uploads = 0
    var terminalFailure = false
    var bytes: Data?
    init(preparation: Preparation = .ready, dispatch: Dispatch = .ready) { self.preparation = preparation; self.dispatch = dispatch }
    func values() -> ([String], Int, Data?) { (events, uploads, bytes) }
    func configure(_ value: Preparation) { preparation = value }
    func failTerminalOnce() { terminalFailure = true }
    func prepareReferences(task: ClassicVideoTask, directory: URL) async throws -> [URL] {
        switch preparation {
        case .ready: return []
        case .network: throw URLError(.timedOut)
        case .cancelled: throw CancellationError()
        case .wrongOwner: throw DreaminaError.wrongOwner
        case .http(let status): throw StudioError.mediaHTTP(status)
        case .invalid: throw StudioError.invalidResponse
        }
    }
    func event(task: ClassicVideoTask, event: String, submitId: String?) async throws {
        if event == "dispatch-intent" {
            if dispatch == .unsentOnce { dispatch = .ready; throw URLError(.notConnectedToInternet) }
            if dispatch == .conflict { throw StudioError.http(409, "conflict") }
        }
        if terminalFailure, ["declined", "failed", "preparation-failed"].contains(event) {
            terminalFailure = false; throw URLError(.notConnectedToInternet)
        }
        events.append(event)
    }
    func upload(task: ClassicVideoTask, submitId: String, file: URL) async throws {
        try check(submitId == "original-submit", "recovery uploads original submit ID only")
        bytes = try Data(contentsOf: file); uploads += 1
    }
}
private actor MultiTaskRecoveryRunner: DreaminaRunning {
    var submissions: [String: Int] = [:], queries: [String: Int] = [:]
    func counts() -> ([String: Int], [String: Int]) { (submissions, queries) }
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> DreaminaOutput {
        if arguments.first == "text2video", let prompt = arguments.firstIndex(of: "--prompt"), prompt + 1 < arguments.count {
            let id = arguments[prompt + 1]
            submissions[id, default: 0] += 1
            return DreaminaOutput(status: 0, data: try JSONSerialization.data(withJSONObject: ["submit_id": "submit-" + id]))
        }
        guard arguments.count == 5, arguments[0] == "query_result", arguments[2].hasPrefix("submit-video-") else { throw NativeTestFailure(description: "multi-task query lacks its exact submit ID") }
        let id = arguments[2]
        queries[id, default: 0] += 1
        if id == "submit-video-4", queries[id] == 2 { throw URLError(.timedOut) }
        if queries[id] == 1 { return DreaminaOutput(status: 0, data: try JSONSerialization.data(withJSONObject: ["submit_id": id, "gen_status": "running"])) }
        let file = URL(fileURLWithPath: arguments[4]).appendingPathComponent("result.mp4")
        try Data(id.utf8).write(to: file)
        return DreaminaOutput(status: 0, data: try JSONSerialization.data(withJSONObject: ["submit_id": id, "gen_status": "success", "result_json": ["videos": [["path": file.path]]]]))
    }
}
private actor MultiTaskRecoveryBridge: ClassicCliBridge {
    var uploads: [String: String] = [:]
    func values() -> [String: String] { uploads }
    func event(task: ClassicVideoTask, event: String, submitId: String?) async throws { }
    func upload(task: ClassicVideoTask, submitId: String, file: URL) async throws {
        try check(submitId == "submit-" + task.id && task.nodeId == "node-" + task.id && task.projectId == "canvas-" + task.id, "multi-task result retains original canvas/node/submit binding")
        let received = try Data(contentsOf: file)
        try check(received == Data(submitId.utf8), "same output filename in ten private task directories never mixes video bytes")
        try check(uploads[task.id] == nil, "each original result uploads only once")
        uploads[task.id] = submitId
    }
}
private actor RecoveryIdentity { var calls = 0; func current() -> Bool { calls += 1; return calls <= 1 } }
private actor RecoveryReferenceTransport: StudioTransport {
    let status: Int
    init(_ status: Int) { self.status = status }
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reference-response-" + UUID().uuidString)
        try Data("temporary server response".utf8).write(to: file)
        return StudioHTTPFile(file: file, response: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"text/html"])!)
    }
}

func runClassicRecoveryTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("classic-recovery-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = ClassicVideoSnapshot(prompt: "fixture", model: "seedance2.5", duration: 5, aspect: "16:9", resolution: "480p", mode: "text", profile: "resolution-five")
    func task(_ id: String, stage: String = "awaiting-confirmation", submit: String? = nil) -> ClassicVideoTask {
        ClassicVideoTask(id: id, projectId: "project", nodeId: "node", payloadHash: String(repeating: "a", count: 64), snapshot: snapshot, stage: stage, submitId: submit)
    }
    func read(_ id: String, folder: URL) throws -> ClassicCliJournal {
        try JSONDecoder().decode(ClassicCliJournal.self, from: Data(contentsOf: folder.appendingPathComponent(id + ".json")))
    }
    func seed(_ journal: ClassicCliJournal, folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: folder.appendingPathComponent(journal.task.id + ".json"))
    }
    do {
        let folder = root.appendingPathComponent("ten-canvases"), runner = MultiTaskRecoveryRunner(), bridge = MultiTaskRecoveryBridge()
        let executor = ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: folder)
        let tasks = (0..<10).map { index -> ClassicVideoTask in
            let id = "video-\(index)"
            let specification = ClassicVideoSnapshot(prompt: id, model: "seedance2.5", duration: 5, aspect: "16:9", resolution: "480p", mode: "text", profile: "resolution-five")
            return ClassicVideoTask(id: id, projectId: "canvas-" + id, nodeId: "node-" + id, payloadHash: String(repeating: "a", count: 64), snapshot: specification, stage: "awaiting-confirmation", submitId: nil)
        }
        for original in tasks {
            try await executor.step(task: original, owner: "one-account", bridge: bridge, authorize: { true }, isCurrent: { true }, validateVideo: { _ in })
        }
        let initial = await runner.counts(), beforeUploads = await bridge.values()
        try check(initial.0.count == 10 && initial.0.values.allSatisfy { $0 == 1 } && beforeUploads.isEmpty, "one account submits ten independent upstream jobs without waiting for the first remote completion")
        for index in [8, 4, 1, 9, 0, 7, 3, 6, 2, 5] {
            let original = tasks[index]
            let claimed = ClassicVideoTask(id: original.id, projectId: original.projectId, nodeId: original.nodeId, payloadHash: original.payloadHash, snapshot: original.snapshot, stage: "submitted", submitId: "submit-" + original.id)
            do {
                try await executor.step(task: claimed, owner: "one-account", bridge: bridge, authorize: { throw NativeTestFailure(description: "existing jobs must not reauthorize or regenerate") }, isCurrent: { true }, validateVideo: { _ in })
            } catch is URLError {
                let interrupted = try read(original.id, folder: folder)
                try check(index == 4 && interrupted.stage == "submitted", "one transient query failure preserves its original submitted journal")
            }
        }
        let partial = await bridge.values()
        try check(partial.count == 9 && partial["video-4"] == nil, "one interrupted download never blocks the other nine original results")
        let failed = tasks[4]
        let retry = ClassicVideoTask(id: failed.id, projectId: failed.projectId, nodeId: failed.nodeId, payloadHash: failed.payloadHash, snapshot: failed.snapshot, stage: "submitted", submitId: "submit-" + failed.id)
        try await executor.step(task: retry, owner: "one-account", bridge: bridge, authorize: { throw NativeTestFailure(description: "query retry must not regenerate") }, isCurrent: { true }, validateVideo: { _ in })
        for original in tasks {
            try await executor.step(task: original, owner: "one-account", bridge: bridge, authorize: { throw NativeTestFailure(description: "completed task cannot charge again") }, isCurrent: { true }, validateVideo: { _ in })
            let completed = try read(original.id, folder: folder)
            try check(completed.stage == "completed", "ten interleaved tasks each keep their own completed journal")
        }
        let final = await runner.counts(), uploads = await bridge.values()
        try check(uploads.count == 10 && final.0.values.allSatisfy { $0 == 1 } && final.1["submit-video-4"] == 3, "ten results complete with precisely one paid submission per original task including the retried download")
    }
    let transient: [RecoveryBridge.Preparation] = [.network, .cancelled, .wrongOwner, .http(401), .http(403), .http(408), .http(429), .http(500), .http(503)]
    for (index, error) in transient.enumerated() {
        let folder = root.appendingPathComponent("transient-\(index)"), runner = RecoveryRunner(), bridge = RecoveryBridge(preparation: error), currentTask = task("retry")
        let executor = ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: folder)
        do {
            try await executor.step(task: currentTask, owner: "owner", bridge: bridge, authorize: { throw NativeTestFailure(description: "no confirmation while reference unavailable") }, isCurrent: { true }, validateVideo: { _ in })
            throw NativeTestFailure(description: "temporary preparation must propagate")
        } catch is NativeTestFailure { throw NativeTestFailure(description: "temporary preparation did not stop before consent") }
        catch { }
        let journal = try read(currentTask.id, folder: folder), values = await bridge.values(), counts = await runner.counts()
        try check(journal.stage == "awaiting-confirmation" && values.0.isEmpty && counts.0 == 0, "temporary/cancel/auth/HTTP failures preserve original pending task without terminal event or charge")
        await bridge.configure(.ready)
        try await executor.step(task: currentTask, owner: "owner", bridge: bridge, authorize: { true }, isCurrent: { true }, validateVideo: { _ in })
        let completed = try read(currentTask.id, folder: folder), recovered = await runner.counts()
        try check(completed.stage == "completed" && recovered.0 == 1, "recovered preparation uses one original paid submission")
    }
    for (index, error) in [RecoveryBridge.Preparation.invalid, .http(404), .http(410)].enumerated() {
        let folder = root.appendingPathComponent("permanent-\(index)"), bridge = RecoveryBridge(preparation: error), runner = RecoveryRunner(), currentTask = task("invalid")
        try await ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: folder).step(task: currentTask, owner: "owner", bridge: bridge, isCurrent: { true }, validateVideo: { _ in })
        let journal = try read(currentTask.id, folder: folder), counts = await runner.counts()
        try check(journal.stage == "preparation-failed" && counts.0 == 0, "definitive corrupt or gone reference safely terminates before paid submission")
    }
    do {
        let folder = root.appendingPathComponent("identity"), identity = RecoveryIdentity(), bridge = RecoveryBridge(preparation: .invalid), currentTask = task("changed")
        do {
            try await ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: RecoveryRunner()), directory: folder).step(task: currentTask, owner: "owner", bridge: bridge, isCurrent: { await identity.current() }, validateVideo: { _ in })
            throw NativeTestFailure(description: "changed identity accepted")
        } catch DreaminaError.wrongOwner { }
        let journal = try read(currentTask.id, folder: folder), events = await bridge.values().0
        try check(journal.stage == "awaiting-confirmation" && events.isEmpty, "stale preparation cannot mark the old owner failed")
    }
    do {
        let folder = root.appendingPathComponent("unsent"), runner = RecoveryRunner(), bridge = RecoveryBridge(dispatch: .unsentOnce), currentTask = task("original")
        do { try await ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: folder).step(task: currentTask, owner: "owner", bridge: bridge, isCurrent: { true }, validateVideo: { _ in }); throw NativeTestFailure(description: "unsent dispatch unexpectedly accepted") }
        catch is URLError { }
        let waiting = try read(currentTask.id, folder: folder), before = await runner.counts()
        try check(waiting.stage == "dispatch-intent" && before.0 == 0, "unsent event leaves a durable intent without charge")
        try await ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: folder).step(task: currentTask, owner: "owner", bridge: bridge, isCurrent: { true }, validateVideo: { _ in })
        let after = await runner.counts(), final = try read(currentTask.id, folder: folder)
        try check(final.stage == "completed" && after.0 == 1, "authoritative awaiting original task recovers through unique dispatch permission without regeneration")
    }
    do {
        let folder = root.appendingPathComponent("late-intent"), currentTask = task("original"), runner = RecoveryRunner(), bridge = RecoveryBridge(dispatch: .conflict)
        try seed(ClassicCliJournal(task: currentTask, owner: "owner", stage: "dispatch-intent", submitId: nil), folder: folder)
        do { try await ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: folder).step(task: currentTask, owner: "owner", bridge: bridge, isCurrent: { true }, validateVideo: { _ in }); throw NativeTestFailure(description: "server CAS conflict accepted") }
        catch StudioError.http(409, _) { }
        let counts = await runner.counts(), journal = try read(currentTask.id, folder: folder)
        try check(counts == (0, 0) && journal.stage == "dispatch-intent", "late original dispatch beats retry CAS without a second paid invocation")
    }
    for stage in ["dispatch-intent", "unknown"] {
        let folder = root.appendingPathComponent("ambiguous-" + stage), currentTask = task("original", stage: stage), runner = RecoveryRunner(), bridge = RecoveryBridge()
        try seed(ClassicCliJournal(task: currentTask, owner: "owner", stage: "dispatch-intent", submitId: nil), folder: folder)
        try await ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: folder).step(task: currentTask, owner: "owner", bridge: bridge, authorize: { throw NativeTestFailure(description: "ambiguous dispatch must never reauthorize") }, isCurrent: { true }, validateVideo: { _ in })
        let counts = await runner.counts(), values = await bridge.values(), journal = try read(currentTask.id, folder: folder)
        try check(counts == (0, 0) && values.0 == ["unknown"] && journal.stage == "unknown", "server marker prevents paid replay and preserves uncertain receipt")
    }
    do {
        let folder = root.appendingPathComponent("unknown-awaiting"), currentTask = task("original"), runner = RecoveryRunner(), bridge = RecoveryBridge()
        try seed(ClassicCliJournal(task: currentTask, owner: "owner", stage: "unknown", submitId: nil), folder: folder)
        try await ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: folder).step(task: currentTask, owner: "owner", bridge: bridge, authorize: { throw NativeTestFailure(description: "local unknown must never replay") }, isCurrent: { true }, validateVideo: { _ in })
        let counts = await runner.counts()
        try check(counts == (0, 0), "authoritative awaiting cannot erase a local ambiguous paid attempt")
    }
    for receipt in [RecoveryRunner.Receipt.exactWithExtra, .legacy] {
        let folder = root.appendingPathComponent(UUID().uuidString), currentTask = task("original", stage: "submitted", submit: "original-submit"), runner = RecoveryRunner(receipt), bridge = RecoveryBridge()
        let old = folder.appendingPathComponent(currentTask.id + "-video")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("stale-old-video".utf8).write(to: old.appendingPathComponent("stale.mp4"))
        try await ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: folder).step(task: currentTask, owner: "owner", bridge: bridge, isCurrent: { true }, validateVideo: { _ in })
        let values = await bridge.values(), journal = try read(currentTask.id, folder: folder), counts = await runner.counts()
        try check(values.2 == Data("original-recovery-video".utf8) && counts == (0, 1), "structured exact path and legacy new-attempt file ignore residual videos")
        let parent = URL(fileURLWithPath: journal.file!).deletingLastPathComponent()
        try check(parent.deletingLastPathComponent().path == old.path && UUID(uuidString: parent.lastPathComponent) != nil, "download attempt has fresh unique private directory")
    }
    do {
        let folder = root.appendingPathComponent("legacy-stale")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("stale-old-video".utf8).write(to: folder.appendingPathComponent("stale.mp4"))
        do { _ = try await ClassicDreaminaCLI(runner: RecoveryRunner(.legacyWithoutFile)).queryResult("original-submit", directory: folder); throw NativeTestFailure(description: "legacy stale download accepted") }
        catch DreaminaError.invalidResponse { }
        try check(true, "legacy URL cannot claim a file left by an earlier attempt")
    }
    for localMissing in [false, true] {
        let folder = root.appendingPathComponent("upload-ready-\(localMissing)"), currentTask = task("original", stage: "upload-ready", submit: "original-submit"), runner = RecoveryRunner(), bridge = RecoveryBridge()
        if localMissing { try seed(ClassicCliJournal(task: currentTask, owner: "owner", stage: "upload-ready", submitId: "original-submit", file: folder.appendingPathComponent("original-video/missing.mp4").path), folder: folder) }
        // Keep the old direct directory naming used by existing installed journals.
        if localMissing {
            var journal = try read(currentTask.id, folder: folder)
            journal.file = folder.appendingPathComponent(currentTask.id + "-video/missing.mp4").path
            try seed(journal, folder: folder)
        }
        try await ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: folder).step(task: currentTask, owner: "owner", bridge: bridge, authorize: { throw NativeTestFailure(description: "upload-ready must not authorize") }, isCurrent: { true }, validateVideo: { _ in })
        let counts = await runner.counts(), values = await bridge.values(), journal = try read(currentTask.id, folder: folder)
        try check(counts == (0, 1) && values.0 == ["upload-ready"] && values.1 == 1 && journal.stage == "completed", "upload-ready without journal or cached file re-downloads original ID without submitted stage regression")
    }
    for bytes in [Data(), Data("truncated-bad-video".utf8)] {
        let folder = root.appendingPathComponent("bad-cache-" + UUID().uuidString), currentTask = task("original", stage: "upload-ready", submit: "original-submit"), runner = RecoveryRunner(), bridge = RecoveryBridge()
        let cache = folder.appendingPathComponent(currentTask.id + "-video", isDirectory: true), original = cache.appendingPathComponent("cached.mp4")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try bytes.write(to: original)
        try seed(ClassicCliJournal(task: currentTask, owner: "owner", stage: "upload-ready", submitId: "original-submit", file: original.path), folder: folder)
        try await ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: folder).step(task: currentTask, owner: "owner", bridge: bridge, isCurrent: { true }, validateVideo: { file in
            guard try Data(contentsOf: file) == Data("original-recovery-video".utf8) else { throw DreaminaError.invalidResponse }
        })
        let counts = await runner.counts(), values = await bridge.values(), previousBytes = try Data(contentsOf: original)
        try check(counts == (0, 1) && values.0 == ["upload-ready"] && values.1 == 1 && previousBytes == bytes, "zero/truncated/unplayable cache re-downloads original result without deleting old bytes or regressing server stage")
    }
    do {
        let folder = root.appendingPathComponent("cancel-cache"), currentTask = task("original", stage: "upload-ready", submit: "original-submit"), runner = RecoveryRunner(), bridge = RecoveryBridge()
        let cache = folder.appendingPathComponent(currentTask.id + "-video", isDirectory: true), original = cache.appendingPathComponent("cached.mp4")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("cached-video".utf8).write(to: original)
        try seed(ClassicCliJournal(task: currentTask, owner: "owner", stage: "upload-ready", submitId: "original-submit", file: original.path), folder: folder)
        do { try await ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: folder).step(task: currentTask, owner: "owner", bridge: bridge, isCurrent: { true }, validateVideo: { _ in throw CancellationError() }); throw NativeTestFailure(description: "cancelled cache validation accepted") }
        catch is CancellationError { }
        let counts = await runner.counts(), values = await bridge.values()
        try check(counts == (0, 0) && values.0.isEmpty, "cache playback validation cancellation never downloads, uploads or changes terminal state")
    }
    do {
        let folder = root.appendingPathComponent("scan"), currentTask = task("original"), missing = root.appendingPathComponent("does-not-exist")
        let absent = try ClassicCliExecutor.hasUnfinishedTasks(directory: missing)
        try check(!absent, "absent journal directory does not invent unfinished tasks")
        try seed(ClassicCliJournal(task: currentTask, owner: "owner", stage: "completed", submitId: "original-submit"), folder: folder)
        let terminal = try ClassicCliExecutor.hasUnfinishedTasks(directory: folder)
        try check(!terminal, "terminal journal permits safe new device association")
        try seed(ClassicCliJournal(task: currentTask, owner: "owner", stage: "unknown", submitId: nil), folder: folder)
        let unknown = try ClassicCliExecutor.hasUnfinishedTasks(directory: folder, owner: "owner")
        let other = try ClassicCliExecutor.hasUnfinishedTasks(directory: folder, owner: "other")
        try check(unknown, "unknown paid receipt conservatively blocks identity replacement")
        try check(!other, "valid owner isolation does not block unrelated identity")
        try Data("corrupt".utf8).write(to: folder.appendingPathComponent("bad.json"))
        do { _ = try ClassicCliExecutor.hasUnfinishedTasks(directory: folder, owner: "other"); throw NativeTestFailure(description: "corrupt journal did not fail closed") }
        catch is NativeTestFailure { throw NativeTestFailure(description: "corrupt journal did not fail closed") }
        catch { }
        try check(true, "invalid journal blocks replacement even if another valid owner's record is terminal")
    }
    do {
        let folder = root.appendingPathComponent("terminal-ack"), currentTask = task("invalid"), bridge = RecoveryBridge(preparation: .invalid), runner = RecoveryRunner()
        await bridge.failTerminalOnce()
        do { try await ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: folder).step(task: currentTask, owner: "owner", bridge: bridge, isCurrent: { true }, validateVideo: { _ in }); throw NativeTestFailure(description: "lost terminal ACK was accepted") }
        catch is URLError { }
        let before = try read(currentTask.id, folder: folder), unresolved = try ClassicCliExecutor.hasUnfinishedTasks(directory: folder)
        try check(before.stage == "preparation-failed" && before.terminalAcknowledged == false && unresolved, "new failed journal without server receipt blocks device replacement")
        try await ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: folder).step(task: currentTask, owner: "owner", bridge: bridge, isCurrent: { true }, validateVideo: { _ in })
        let after = try read(currentTask.id, folder: folder), resolved = try ClassicCliExecutor.hasUnfinishedTasks(directory: folder), counts = await runner.counts()
        try check(after.terminalAcknowledged == true && !resolved && counts == (0, 0), "retrying original failure receipt resolves identity guard without paid CLI")
        try seed(ClassicCliJournal(task: currentTask, owner: "owner", stage: "failed", submitId: "original-submit"), folder: folder)
        let legacy = try ClassicCliExecutor.hasUnfinishedTasks(directory: folder)
        try check(!legacy, "legacy terminal nil keeps compatibility; authoritative server registration still gates unresolved old-device tasks")
    }
    for code in [401, 429, 503, 404] {
        let reference = ClassicCliReference(nodeId: "ref", kind: "image", source: "/api/private-files/00000000-0000-4000-8000-000000000001.png", sha256: String(repeating: "a", count: 64), bytes: 100, mediaType: "image/png", extension: "png", duration: nil)
        let imageSnapshot = ClassicVideoSnapshot(prompt: "fixture", model: "seedance2.5", duration: 5, aspect: "source", resolution: "480p", mode: "image", profile: "resolution-five", references: [reference])
        let imageTask = ClassicVideoTask(id: "http-reference", projectId: "project", nodeId: "node", payloadHash: String(repeating: "a", count: 64), snapshot: imageSnapshot, stage: "awaiting-confirmation", submitId: nil)
        let bridge = ClassicStudioBridge(client: StudioClient(environment: .test, transport: RecoveryReferenceTransport(code)), session: StudioSession(value: "fixture", expiresAt: Date().addingTimeInterval(600)), workspace: "fixture", device: ClassicCliDevice(id: "fixture", epoch: "fixture", secret: "fixture"), current: { true })
        do { _ = try await bridge.prepareReferences(task: imageTask, directory: root); throw NativeTestFailure(description: "reference HTTP error accepted") }
        catch StudioError.mediaHTTP(let actual) { try check(actual == code, "protected download preserves HTTP status instead of treating HTML 5xx as corrupt image") }
    }
}
