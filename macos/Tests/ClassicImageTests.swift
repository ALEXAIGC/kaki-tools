import Foundation
import AppKit

private actor ImageFixtureRunner: DreaminaRunning {
    let bytes: Data
    var submits = 0
    var loseSubmit = false
    init(bytes: Data, loseSubmit: Bool = false) { self.bytes = bytes; self.loseSubmit = loseSubmit }
    func count() -> Int { submits }
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> DreaminaOutput {
        if arguments.first == "text2image" {
            submits += 1
            if loseSubmit { throw DreaminaError.timedOut }
            return DreaminaOutput(status: 0, data: Data("{\"submit_id\":\"image-test-submit\"}".utf8))
        }
        guard arguments.count == 5, arguments[0] == "query_result", arguments[2] == "image-test-submit" else { throw DreaminaError.invalidResponse }
        let file = URL(fileURLWithPath: arguments[4]).appendingPathComponent("result.png")
        try bytes.write(to: file)
        return DreaminaOutput(status: 0, data: try JSONSerialization.data(withJSONObject: ["submit_id":"image-test-submit", "gen_status":"success", "result_json":["images":[["path":file.path]]]]))
    }
}
private actor ImageFixtureBridge: ClassicCliBridge {
    var uploads = 0
    var failUpload = true
    func count() -> Int { uploads }
    func event(task: ClassicVideoTask, event: String, submitId: String?) async throws {}
    func upload(task: ClassicVideoTask, submitId: String, file: URL) async throws {
        try ClassicImageModels.validateResult(file)
        guard submitId == "image-test-submit" else { throw DreaminaError.invalidResponse }
        uploads += 1
        if failUpload { failUpload = false; throw DreaminaError.timedOut }
    }
}
@MainActor func runClassicImageTests() async throws {
    let snapshot = ClassicVideoSnapshot(prompt:"literal $(not-a-shell)",model:"seedream-5.0",duration:0,aspect:"1:1",resolution:"2k",mode:"text2image",profile:"resolution-five")
    try snapshot.validate(); try snapshot.validateRecovery()
    let argv = try ClassicDreaminaCLI.arguments(snapshot, files: [])
    try check(argv == ["text2image","--prompt",snapshot.prompt,"--model_version","5.0","--resolution_type","2k","--ratio","1:1","--generate_num","1","--poll","0"], "image argv is explicit, single-result and uses no shell/video arguments")
    let help = DreaminaOutput(status:0,data:Data("--images --prompt --model_version --resolution_type --ratio --generate_num --poll 2k 4k 4.0 5.0 5.0Pro".utf8))
    try check(ClassicImageModels.detected(textHelp:help,imageHelp:help) == ["seedream-4.0","seedream-5.0","seedream-5.0Pro"],"only exact model tokens advertised")
    try check(ClassicImageModels.detected(textHelp:help,imageHelp:DreaminaOutput(status:1,data:Data())).isEmpty,"old CLI never advertises images")
    let invalid = ClassicVideoSnapshot(prompt:"p",model:"seedream-5.0",duration:5,aspect:"1:1",resolution:"2k",mode:"text2image",profile:"resolution-five")
    do { try invalid.validate(); throw NativeTestFailure(description:"image accepted video duration") } catch DreaminaError.invalidResponse {}
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX:x, y:y) } }
    let bytes = bitmap.representation(using:.png,properties:[:])!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-image-tests-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let runner = ImageFixtureRunner(bytes:bytes), bridge = ImageFixtureBridge()
    let task = ClassicVideoTask(id:"image-fixture",projectId:"project",nodeId:"image",payloadHash:String(repeating:"a",count:64),snapshot:snapshot,stage:"awaiting-confirmation",submitId:nil)
    let validator: @Sendable (URL) async throws -> Void = { try ClassicImageModels.validateResult($0) }
    let executor = ClassicCliExecutor(cli:ClassicDreaminaCLI(runner:runner),directory:directory)
    do { try await executor.step(task:task,owner:"owner",bridge:bridge,isCurrent:{true},validateVideo:validator); throw NativeTestFailure(description:"upload should interrupt") } catch DreaminaError.timedOut {}
    let restarted = ClassicCliExecutor(cli:ClassicDreaminaCLI(runner:runner),directory:directory)
    try await restarted.step(task:task,owner:"owner",bridge:bridge,isCurrent:{true},validateVideo:validator)
    let submitted = await runner.count(), uploaded = await bridge.count()
    try check(submitted == 1 && uploaded == 2,"image upload recovery does not regenerate")
    let uncertain = ImageFixtureRunner(bytes:bytes,loseSubmit:true)
    let uncertainExecutor = ClassicCliExecutor(cli:ClassicDreaminaCLI(runner:uncertain),directory:directory.appendingPathComponent("unknown"))
    try await uncertainExecutor.step(task:task,owner:"owner",bridge:bridge,isCurrent:{true},validateVideo:validator)
    try await uncertainExecutor.step(task:task,owner:"owner",bridge:bridge,isCurrent:{true},validateVideo:validator)
    let uncertainCount = await uncertain.count()
    try check(uncertainCount == 1,"ambiguous image submission is never retried")
}
