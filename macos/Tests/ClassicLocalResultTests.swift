import Foundation
private actor LocalResultRunner: DreaminaRunning {
    let receiptPath: String?
    var queries = 0
    init(path: String? = nil) { receiptPath = path }
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> DreaminaOutput {
        guard arguments.count == 5, arguments[0] == "query_result", arguments[2] == "original-submit" else { throw NativeTestFailure(description: "recovery must never invoke generation") }
        queries += 1
        let directory = URL(fileURLWithPath: arguments[4]), file = directory.appendingPathComponent("original.mp4")
        try Data("original-video".utf8).write(to: file)
        return DreaminaOutput(status: 0, data: try JSONSerialization.data(withJSONObject: ["submit_id":"original-submit", "gen_status":"success", "result_json":["videos":[["path":receiptPath ?? file.path,"duration":5]]]]))
    }
}
private actor LocalResultBridge: ClassicCliBridge {
    var uploaded = false
    func event(task: ClassicVideoTask, event: String, submitId: String?) async throws {
        guard ["submitted", "upload-ready"].contains(event), submitId == "original-submit" else { throw NativeTestFailure(description: "original task must not fail or redispatch") }
    }
    func upload(task: ClassicVideoTask, submitId: String, file: URL) async throws {
        let bytes = try Data(contentsOf: file)
        try check(submitId == "original-submit" && bytes == Data("original-video".utf8), "recover original downloaded bytes and submit ID")
        uploaded = true
    }
    func didUpload() -> Bool { uploaded }
}
func runClassicLocalResultTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-result-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = ClassicVideoSnapshot(prompt: "fixture", model: "seedance2.5", duration: 5, aspect: "16:9", resolution: "480p", mode: "text", profile: "resolution-five")
    let task = ClassicVideoTask(id: "original-task", projectId: "project", nodeId: "node", payloadHash: String(repeating: "a", count: 64), snapshot: snapshot, stage: "submitted", submitId: "original-submit")
    let runner = LocalResultRunner(), bridge = LocalResultBridge(), executor = ClassicCliExecutor(cli: ClassicDreaminaCLI(runner: runner), directory: root)
    try await executor.step(task: task, owner: "fixture-owner", bridge: bridge, isCurrent: { true }, validateVideo: { _ in })
    let uploaded = await bridge.didUpload()
    try check(uploaded, "success with local path reaches upload on original task")
    let journal = try JSONDecoder().decode(ClassicCliJournal.self, from: Data(contentsOf: root.appendingPathComponent("original-task.json")))
    try check(journal.stage == "completed" && journal.submitId == "original-submit", "original recovery completed without new submission")
    for value in ["../escape.mp4", "/tmp/outside.mp4", "missing.mp4", "original.txt"] {
        do { _ = try await ClassicDreaminaCLI(runner: LocalResultRunner(path: value)).query("original-submit", directory: root); throw NativeTestFailure(description: "invalid local path accepted") }
        catch is NativeTestFailure { throw NativeTestFailure(description: "invalid local path accepted") }
        catch { }
    }
    let relative = try await ClassicDreaminaCLI(runner: LocalResultRunner(path: "original.mp4")).query("original-submit", directory: root)
    try check(relative == "success", "relative local result stays in private task directory")
    let link = root.appendingPathComponent("link.mp4")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("original.mp4"))
    do { _ = try await ClassicDreaminaCLI(runner: LocalResultRunner(path: "link.mp4")).query("original-submit", directory: root); throw NativeTestFailure(description: "symlink accepted") }
    catch DreaminaError.invalidResponse { }
}
