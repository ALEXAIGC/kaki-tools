import Foundation

actor ClassicFixtureRunner: DreaminaRunning {
    var calls: [[String]] = []
    var timeout = false
    var queryStatus = "success"
    var fileAvailable = true
    var creditValid = true
    func configure(timeout: Bool = false, status: String = "success", fileAvailable: Bool = true) { self.timeout = timeout; queryStatus = status; self.fileAvailable = fileAvailable }
    func allCalls() -> [[String]] { calls }
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> DreaminaOutput {
        calls.append(arguments)
        if arguments == ["text2video", "--help"] { return DreaminaOutput(status: 0, data: Data("--prompt --duration --ratio --video_resolution --model_version --poll seedance2.0 seedance2.0fast 720p 4-15 21:9".utf8)) }
        if arguments.count == 2, arguments[1] == "--help", ["image2video", "frames2video", "multiframe2video", "multimodal2video"].contains(arguments[0]) {
            return DreaminaOutput(status: 0, data: Data("--image --first --last --images --video --audio --prompt --duration --video_resolution --model_version --poll --transition-prompt --transition-duration --ratio 720p 1080p".utf8))
        }
        if arguments == ["query_result", "--help"] { return DreaminaOutput(status: 0, data: Data("--submit_id --download_dir".utf8)) }
        if arguments == ["user_credit"] { return DreaminaOutput(status: creditValid ? 0 : 1, data: Data("{\"total_credit\":42,\"user_id\":\"fixture-account\"}".utf8)) }
        if let command = arguments.first, ["text2video", "image2video", "frames2video", "multiframe2video", "multimodal2video"].contains(command) {
            if self.timeout { throw DreaminaError.timedOut }
            return DreaminaOutput(status: 0, data: Data("{\"submit_id\":\"real-fixture-id\"}".utf8))
        }
        guard arguments.count == 5, arguments[0] == "query_result", arguments[1] == "--submit_id", arguments[2] == "real-fixture-id", arguments[3] == "--download_dir" else { throw DreaminaError.invalidResponse }
        if queryStatus == "success", fileAvailable { try Data("validated-fixture-video".utf8).write(to: URL(fileURLWithPath: arguments[4]).appendingPathComponent("result.mp4")) }
        return DreaminaOutput(status: 0, data: try JSONSerialization.data(withJSONObject: ["submit_id":"real-fixture-id", "gen_status":queryStatus, "result_json":["videos":[["video_url":"https://fixture.invalid/result.mp4"]]]] as [String: Any]))
    }
}
actor ClassicFixtureBridge: ClassicCliBridge {
    var events: [String] = []
    var uploads = 0
    var failUpload = false
    var failEvent: String?
    func configure(failUpload: Bool = false, failEvent: String? = nil) { self.failUpload = failUpload; self.failEvent = failEvent }
    func values() -> ([String],Int) { (events,uploads) }
    func event(task: ClassicVideoTask, event: String, submitId: String?) async throws {
        events.append(event)
        if failEvent == event { failEvent = nil; throw DreaminaError.timedOut }
    }
    func upload(task: ClassicVideoTask, submitId: String, file: URL) async throws {
        guard submitId == "real-fixture-id", try Data(contentsOf: file) == Data("validated-fixture-video".utf8) else { throw DreaminaError.invalidResponse }
        uploads += 1
        if failUpload { failUpload = false; throw DreaminaError.timedOut }
    }
}
struct ClassicMalformedBridge: ClassicCliBridge {
    let eventData: Data?
    let uploadData: Data
    func event(task: ClassicVideoTask, event: String, submitId: String?) async throws {
        var object: [String: Any] = ["accepted":true,"jobId":task.id,"payloadHash":task.payloadHash,"event":event,"status":"running"]
        if let submitId { object["submitId"] = submitId }
        try ClassicCliReceipt.event(eventData ?? JSONSerialization.data(withJSONObject: object), task: task, event: event, submitId: submitId)
    }
    func upload(task: ClassicVideoTask, submitId: String, file: URL) async throws { try ClassicCliReceipt.upload(uploadData,task:task,submitId:submitId) }
}
func runClassicCliTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-classic-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = ClassicVideoSnapshot(prompt: "literal $(touch /never) ; `echo x`", model: "seedance2.0fast", duration: 5, aspect: "16:9", resolution: "720p",mode:"text",profile:"resolution-five")
    func task(_ id: String, stage: String = "awaiting-confirmation", submit: String? = nil) -> ClassicVideoTask { ClassicVideoTask(id: id, projectId: "project", nodeId: "node", payloadHash: String(repeating: "a", count: 64), snapshot: snapshot, stage: stage, submitId: submit) }
    let videoValidator: @Sendable (URL) async throws -> Void = { url in guard try Data(contentsOf: url) == Data("validated-fixture-video".utf8) else { throw DreaminaError.invalidResponse } }
    let runner = ClassicFixtureRunner(), bridge = ClassicFixtureBridge(), cli = ClassicDreaminaCLI(runner: runner)
    let models = try await cli.verify(); try check(models == ["seedance2.0", "seedance2.0fast", "dreamina-multiframe"], "classic actual help/capability/login adapter")
    let executor = ClassicCliExecutor(cli: cli, directory: directory)
    let success = task("success")
    await bridge.configure(failUpload: true)
    do { try await executor.step(task: success, owner: "owner|ws", bridge: bridge, authorize: { true }, isCurrent: { true }, validateVideo: videoValidator); throw NativeTestFailure(description: "upload failure expected") } catch DreaminaError.timedOut { }
    let journalURL = directory.appendingPathComponent("success.json")
    let journal = try JSONDecoder().decode(ClassicCliJournal.self, from: Data(contentsOf: journalURL))
    try check(journal.submitId == "real-fixture-id" && journal.stage == "upload-ready", "real submit ID and result persisted before upload failure")
    let mode = try FileManager.default.attributesOfItem(atPath: journalURL.path)[.posixPermissions] as? NSNumber
    try check(mode?.intValue == 0o600, "journal permissions are private")
    let restarted = ClassicCliExecutor(cli: cli, directory: directory)
    try await restarted.step(task: success, owner: "owner|ws", bridge: bridge, authorize: { throw NativeTestFailure(description: "must not reconfirm paid task") }, isCurrent: { true }, validateVideo: videoValidator)
    let successCalls = await runner.allCalls()
    try check(successCalls.filter { $0.first == "text2video" && $0.count > 2 }.count == 1, "restart/upload retry never resubmits")
    try check(successCalls.first { $0.count > 2 && $0[0] == "text2video" } == ["text2video", "--prompt", snapshot.prompt, "--duration", "5", "--video_resolution", "720p", "--model_version", "seedance2.0fast", "--ratio", "16:9", "--poll", "0"], "fixed argv keeps literal shell characters")
    try check(successCalls.filter { $0.first == "query_result" && $0.count > 2 }.count == 1, "upload-ready retries only existing file")
    do { try await restarted.step(task: success, owner: "other|ws", bridge: bridge, authorize: { true }, isCurrent: { true }, validateVideo: videoValidator); throw NativeTestFailure(description: "wrong owner should fail") } catch DreaminaError.wrongOwner { }
    await runner.configure(timeout: true)
    let unknown = task("timeout")
    try await executor.step(task: unknown, owner: "owner|ws", bridge: bridge, authorize: { true }, isCurrent: { true }, validateVideo: videoValidator)
    try await restarted.step(task: unknown, owner: "owner|ws", bridge: bridge, authorize: { true }, isCurrent: { true }, validateVideo: videoValidator)
    let unknownCalls = await runner.allCalls()
    try check(unknownCalls.filter { $0.first == "text2video" && $0.count > 2 }.count == 2, "timeout durable intent has no second dispatch on restart")
    let serverUnknown = task("lost-journal", stage: "dispatch-intent")
    try await restarted.step(task: serverUnknown, owner: "owner|ws", bridge: bridge, authorize: { throw NativeTestFailure(description: "must not ask to resubmit") }, isCurrent: { true }, validateVideo: videoValidator)
    let restoredUnknownCalls = await runner.allCalls(); try check(restoredUnknownCalls == unknownCalls, "lost journal plus server intent never replays")
    await runner.configure()
    await bridge.configure(failEvent: "declined")
    let declined = task("declined")
    do { try await executor.step(task: declined, owner: "owner|ws", bridge: bridge, authorize: { false }, isCurrent: { true }, validateVideo: videoValidator) } catch DreaminaError.timedOut { }
    try await restarted.step(task: declined, owner: "owner|ws", bridge: bridge, authorize: { true }, isCurrent: { true }, validateVideo: videoValidator)
    let declinedEvents = await bridge.values().0
    try check(declinedEvents.filter { $0 == "declined" }.count == 2, "declined terminal receipt retries after disconnect")
    await runner.configure(status: "fail")
    await bridge.configure(failEvent: "failed")
    let failed = task("failed")
    do { try await executor.step(task: failed, owner: "owner|ws", bridge: bridge, authorize: { true }, isCurrent: { true }, validateVideo: videoValidator) } catch DreaminaError.timedOut { }
    try await restarted.step(task: failed, owner: "owner|ws", bridge: bridge, authorize: { true }, isCurrent: { true }, validateVideo: videoValidator)
    let failEvents = await bridge.values().0; try check(failEvents.filter { $0 == "failed" }.count == 2, "actual fail status finalizes and replays terminal receipt only")
    await runner.configure(fileAvailable: false)
    let noFile = task("url-only")
    do { try await executor.step(task: noFile, owner: "owner|ws", bridge: bridge, authorize: { true }, isCurrent: { true }, validateVideo: videoValidator); throw NativeTestFailure(description: "URL alone must fail") } catch DreaminaError.invalidResponse { }
    let noFileJournal = try JSONDecoder().decode(ClassicCliJournal.self, from: Data(contentsOf: directory.appendingPathComponent("url-only.json")))
    try check(noFileJournal.stage != "completed", "exit zero and video URL without actual file cannot succeed")
    await runner.configure(status: "running")
    let resumed = task("switch-back")
    try await executor.step(task: resumed, owner: "owner|ws", bridge: bridge, authorize: { true }, isCurrent: { true }, validateVideo: videoValidator)
    let beforeReturn = await runner.allCalls().filter { $0.first == "text2video" && $0.count > 2 }.count
    do { try await restarted.step(task: resumed, owner: "other|ws", bridge: bridge, authorize: { true }, isCurrent: { false }, validateVideo: videoValidator) } catch DreaminaError.wrongOwner { }
    await runner.configure()
    try await restarted.step(task: resumed, owner: "owner|ws", bridge: bridge, authorize: { throw NativeTestFailure(description: "switch back must query prior submit ID") }, isCurrent: { true }, validateVideo: videoValidator)
    let afterReturn = await runner.allCalls().filter { $0.first == "text2video" && $0.count > 2 }.count
    try check(afterReturn == beforeReturn, "switch away and back resumes query/upload with original submit ID")
    let pulses = ClassicFixtureBridge()
    let heartbeat = ClassicCliHeartbeat(intervalNanoseconds: 1_000_000) { try await pulses.event(task: resumed, event: "heartbeat", submitId: nil) }
    try await Task.sleep(nanoseconds: 20_000_000)
    let pulseCount = await pulses.values().0.count
    try check(pulseCount > 4, "independent heartbeat continues while task confirmation/query waits beyond equivalent presence window")
    heartbeat.stop()
    try await Task.sleep(nanoseconds: 5_000_000)
    let stoppedCount = await pulses.values().0.count
    try await Task.sleep(nanoseconds: 10_000_000)
    let finalCount = await pulses.values().0.count
    try check(stoppedCount == finalCount, "owner invalidation stops future heartbeats")
    let beforeSwitch = await runner.allCalls()
    do { try await executor.step(task: task("wrong-scope"), owner: "owner|ws", bridge: bridge, authorize: { true }, isCurrent: { false }, validateVideo: videoValidator); throw NativeTestFailure(description: "changed scope must fail") } catch DreaminaError.wrongOwner { }
    let callsAfterSwitch = await runner.allCalls(); try check(callsAfterSwitch == beforeSwitch, "account/workspace/CLI identity invalidation never dispatches")
    await bridge.configure(failEvent: "dispatch-intent")
    let lostAck = task("intent-ack-lost")
    do { try await executor.step(task: lostAck, owner: "owner|ws", bridge: bridge, authorize: { true }, isCurrent: { true }, validateVideo: videoValidator) } catch DreaminaError.timedOut { }
    // This fixture records acceptance before losing the acknowledgement;
    // a fresh claim therefore carries the server's dispatch-intent stage.
    try await restarted.step(task: task("intent-ack-lost", stage: "dispatch-intent"), owner: "owner|ws", bridge: bridge, authorize: { true }, isCurrent: { true }, validateVideo: videoValidator)
    let callsAfterLostAck = await runner.allCalls(); try check(callsAfterLostAck.filter {$0 != ["user_credit"]} == beforeSwitch.filter {$0 != ["user_credit"]}, "intent acknowledgement loss never invokes paid command")
    await runner.configure()
    let invalidReceipts = [Data("<html>login</html>".utf8),Data("{}".utf8),Data("{\"accepted\":true,\"jobId\":\"wrong-task\"}".utf8)]
    for (index, data) in invalidReceipts.enumerated() {
        let before = await runner.allCalls()
        do { try await executor.step(task: task("bad-dispatch-" + String(index)), owner:"owner|ws",bridge:ClassicMalformedBridge(eventData:data,uploadData:data),authorize:{true},isCurrent:{true},validateVideo:videoValidator); throw NativeTestFailure(description:"malformed dispatch receipt accepted") } catch { }
        let after = await runner.allCalls()
        try check(after.filter {$0 != ["user_credit"]} == before.filter {$0 != ["user_credit"]}, "200 HTML/empty/wrong-task dispatch receipt never spawns")
        let uploading = task("bad-upload-" + String(index))
        do { try await executor.step(task: uploading,owner:"owner|ws",bridge:ClassicMalformedBridge(eventData:nil,uploadData:data),authorize:{true},isCurrent:{true},validateVideo:videoValidator) } catch { }
        let saved = try JSONDecoder().decode(ClassicCliJournal.self,from:Data(contentsOf:directory.appendingPathComponent(uploading.id + ".json")))
        try check(saved.stage == "upload-ready", "malformed upload receipt cannot complete journal")
    }

}
