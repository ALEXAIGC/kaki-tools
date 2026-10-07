import Foundation

private struct SeedanceHelpRunner: DreaminaRunning {
    let fixture = ClassicFixtureRunner()
    let complete: Bool
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> DreaminaOutput {
        let output = try await fixture.run(arguments, timeout: timeout)
        if arguments.count == 2, arguments[1] == "--help", ["text2video", "image2video", "frames2video", "multimodal2video"].contains(arguments[0]) {
            let models = complete || arguments[0] != "frames2video" ? ClassicVideoModels.supported : Array(ClassicVideoModels.supported.prefix(2))
            return DreaminaOutput(status: output.status, data: output.data + Data((" " + models.joined(separator: ", ")).utf8))
        }
        return output
    }
}
func runSeedanceModelTests() async throws {
    func snapshot(_ model: String, _ resolution: String, _ duration: Double = 5, refs: [ClassicCliReference] = []) -> ClassicVideoSnapshot {
        ClassicVideoSnapshot(prompt: "fixture", model: model, duration: duration, aspect: "16:9", resolution: resolution, mode: refs.isEmpty ? "text" : "omni", profile: "resolution-five", references: refs)
    }
    for model in ClassicVideoModels.supported {
        let resolutions = model == "seedance2.5" ? ["480p", "720p", "1080p"] : model == "seedance2.0_vip" ? ["720p", "1080p", "4k"] : ["720p"]
        for resolution in resolutions {
            let value = snapshot(model, resolution, model == "seedance2.5" ? 30 : 15)
            try value.validateRecovery()
            let args = try ClassicDreaminaCLI.arguments(value, files: [])
            try check(args[args.firstIndex(of: "--model_version")! + 1] == model, "model channel is passed exactly, never replaced")
            try check(args[args.firstIndex(of: "--video_resolution")! + 1] == resolution, "model resolution is passed exactly")
        }
        do { try snapshot(model, "720p", model == "seedance2.5" ? 31 : 16).validate(); throw NativeTestFailure(description: "excess duration accepted") }
        catch DreaminaError.invalidResponse { }
    }
    for (model, resolution) in [("seedance2.0fast_vip", "1080p"), ("seedance2.0mini", "480p"), ("seedance2.5", "4k"), ("seedance2.5_draft", "480p")] {
        do { try snapshot(model, resolution).validate(); throw NativeTestFailure(description: "unsupported model or resolution accepted") }
        catch DreaminaError.invalidResponse { }
    }
    let audio = ClassicCliReference(nodeId: "audio", kind: "audio", source: "/api/private-files/" + String(repeating: "a", count: 36) + ".wav", sha256: String(repeating: "a", count: 64), bytes: 100, mediaType: "audio/wav", extension: "wav", duration: 30)
    try snapshot("seedance2.5", "480p", 30, refs: [audio]).validate()
    do { try snapshot("seedance2.0", "720p", refs: [audio]).validate(); throw NativeTestFailure(description: "2.0 audio-only accepted") }
    catch DreaminaError.invalidResponse { }
    let modern = try await ClassicDreaminaCLI(runner: SeedanceHelpRunner(complete: true)).verify()
    try check(modern == ClassicVideoModels.supported + ["dreamina-multiframe"], "all supported CLI channels advertised")
    let partial = try await ClassicDreaminaCLI(runner: SeedanceHelpRunner(complete: false)).verify()
    try check(partial == ["seedance2.0", "seedance2.0fast", "dreamina-multiframe"], "partial CLI support does not advertise unsupported modes")
    try check(ClassicVideoModels.title("seedance2.0_vip").contains("VIP") && ClassicVideoModels.title("seedance2.5").contains("常规生成"), "channel names distinguish VIP and regular generation")
}
