import Foundation
import Darwin
import CoreFoundation
import CryptoKit

struct ClassicCliReference: Codable, Equatable, Sendable {
    let nodeId: String
    let kind: String
    let source: String
    let sha256: String
    let bytes: Int
    let mediaType: String
    let `extension`: String
    let duration: Double?
}
struct ClassicCliTransition: Codable, Equatable, Sendable { let prompt: String; let duration: Double }
enum ClassicVideoModels {
    static let supported = ["seedance2.0", "seedance2.0fast", "seedance2.0_vip", "seedance2.0fast_vip", "seedance2.0mini", "seedance2.5"]
    static func title(_ model: String) -> String {
        switch model {
        case "seedance2.0": return "Seedance 2.0 · 普通"
        case "seedance2.0fast": return "Seedance 2.0 Fast · 普通"
        case "seedance2.0_vip": return "Seedance 2.0 · VIP"
        case "seedance2.0fast_vip": return "Seedance 2.0 Fast · VIP"
        case "seedance2.0mini": return "Seedance 2.0 Mini"
        case "seedance2.5": return "Seedance 2.5 · VIP · 常规生成"
        default: return model
        }
    }
    static func valid(model: String, duration: Double, resolution: String) -> Bool {
        let resolutions = model == "seedance2.5" ? ["480p", "720p", "1080p"] : model == "seedance2.0_vip" ? ["720p", "1080p", "4k"] : ["720p"]
        return supported.contains(model) && duration.isFinite && duration.rounded() == duration && (4...(model == "seedance2.5" ? 30.0 : 15.0)).contains(duration) && resolutions.contains(resolution)
    }
}
struct ClassicVideoSnapshot: Codable, Equatable, Sendable {
    let prompt: String
    let model: String
    let duration: Double
    let aspect: String
    let resolution: String
    var mode: String? = nil
    var profile: String? = nil
    var references: [ClassicCliReference]? = nil
    var transitions: [ClassicCliTransition]? = nil
    var effectiveMode: String { mode ?? "text" }
    func validate() throws {
        let refs = references ?? [], images = refs.filter {$0.kind == "image"}, videos = refs.filter {$0.kind == "video"}, audios = refs.filter {$0.kind == "audio"}
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 10000,
              ["text", "image", "firstlast", "imageref", "omni"].contains(effectiveMode),
              refs.count <= (model == "seedance2.5" ? 50 : 20), Set(refs.map {$0.kind + ":" + $0.nodeId}).count == refs.count,
              refs.allSatisfy({["image", "video", "audio"].contains($0.kind) && $0.bytes > 0 && $0.bytes <= ($0.kind == "video" ? 100 : 30) * 1024 * 1024 && $0.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil && $0.source.range(of: "^/api/private-files/[a-f0-9-]{36}\\.[a-z0-9]{1,5}$", options: .regularExpression) != nil}) else { throw DreaminaError.invalidResponse }
        guard profile == "resolution-five" else {throw ClassicCliUpgradeError.required}
        if effectiveMode == "imageref" {
            let segments = transitions ?? [], min = 1.0
            guard model == "dreamina-multiframe", aspect == "source", images.count >= 2, images.count == refs.count,
                  segments.count == images.count - 1, segments.allSatisfy({!$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.prompt.count <= 10000 && $0.duration.isFinite && $0.duration >= min && $0.duration <= 8}),
                  duration >= 2, abs(segments.reduce(0) {$0 + $1.duration} - duration) < 0.000001,
                  ["720p", "1080p"].contains(resolution) else {throw DreaminaError.invalidResponse}
            return
        }
        guard ClassicVideoModels.valid(model: model, duration: duration, resolution: resolution), transitions?.isEmpty != false else {throw DreaminaError.invalidResponse}
        switch effectiveMode {
        case "text": guard refs.isEmpty else {throw DreaminaError.invalidResponse}
        case "image": guard images.count == 1, refs.count == 1, aspect == "source" else {throw DreaminaError.invalidResponse}
        case "firstlast": guard images.count == 2, refs.count == 2, aspect == "source" else {throw DreaminaError.invalidResponse}
        case "omni":
            guard (model == "seedance2.5" ? !refs.isEmpty : images.count + videos.count > 0), images.count <= (model == "seedance2.5" ? 30 : 9), videos.count <= (model == "seedance2.5" ? 10 : 3), audios.count <= (model == "seedance2.5" ? 10 : 3), refs.count <= (model == "seedance2.5" ? 50 : 12) else {throw DreaminaError.invalidResponse}
            for kind in ["video", "audio"] {
                let media = refs.filter {$0.kind == kind}
                guard media.allSatisfy({$0.duration?.isFinite == true && $0.duration! >= 2 && $0.duration! <= (model == "seedance2.5" ? 30 : 15)}), media.reduce(0, {$0 + ($1.duration ?? 0)}) <= (model == "seedance2.5" ? 30 : 15) else {throw DreaminaError.invalidResponse}
            }
        default: throw DreaminaError.invalidResponse
        }
        if ["text", "omni"].contains(effectiveMode) { guard ["1:1", "3:4", "16:9", "4:3", "9:16", "21:9"].contains(aspect) else {throw DreaminaError.invalidResponse} }
    }
    // Signed original receipts only; this validator is never used to build paid argv.
    func validateRecovery() throws {
        let refs = references ?? [], images = refs.filter {$0.kind == "image"}, videos = refs.filter {$0.kind == "video"}, audios = refs.filter {$0.kind == "audio"}
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 10000,
              ["text", "image", "firstlast", "imageref", "omni"].contains(effectiveMode),
              refs.count <= (model == "seedance2.5" ? 50 : 20), Set(refs.map {$0.kind + ":" + $0.nodeId}).count == refs.count,
              refs.allSatisfy({["image", "video", "audio"].contains($0.kind) && $0.bytes > 0 && $0.bytes <= ($0.kind == "video" ? 100 : 30) * 1024 * 1024 && $0.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil && $0.source.range(of: "^/api/private-files/[a-f0-9-]{36}\\.[a-z0-9]{1,5}$", options: .regularExpression) != nil}) else { throw DreaminaError.invalidResponse }
        if effectiveMode != "text" { guard ["legacy-five", "resolution-five"].contains(profile ?? "") else {throw DreaminaError.unsupportedCLI} }
        if effectiveMode == "imageref" {
            let segments = transitions ?? [], min = profile == "resolution-five" ? 1.0 : 0.5
            guard model == "dreamina-multiframe", aspect == "source", images.count >= 2, images.count == refs.count,
                  segments.count == images.count - 1, segments.allSatisfy({!$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.prompt.count <= 10000 && $0.duration.isFinite && $0.duration >= min && $0.duration <= 8}),
                  duration >= 2, abs(segments.reduce(0) {$0 + $1.duration} - duration) < 0.000001,
                  profile == "resolution-five" ? ["720p", "1080p"].contains(resolution) : resolution == "default" else {throw DreaminaError.invalidResponse}
            return
        }
        guard ClassicVideoModels.valid(model: model, duration: duration, resolution: resolution), transitions?.isEmpty != false else {throw DreaminaError.invalidResponse}
        switch effectiveMode {
        case "text": guard refs.isEmpty else {throw DreaminaError.invalidResponse}
        case "image": guard images.count == 1, refs.count == 1, aspect == "source" else {throw DreaminaError.invalidResponse}
        case "firstlast": guard images.count == 2, refs.count == 2, aspect == "source" else {throw DreaminaError.invalidResponse}
        case "omni":
            guard (model == "seedance2.5" ? !refs.isEmpty : images.count + videos.count > 0), images.count <= (model == "seedance2.5" ? 30 : 9), videos.count <= (model == "seedance2.5" ? 10 : 3), audios.count <= (model == "seedance2.5" ? 10 : 3), refs.count <= (model == "seedance2.5" ? 50 : 12) else {throw DreaminaError.invalidResponse}
            for kind in ["video", "audio"] {
                let media = refs.filter {$0.kind == kind}
                guard media.allSatisfy({$0.duration?.isFinite == true && $0.duration! >= 2 && $0.duration! <= (model == "seedance2.5" ? 30 : 15)}), media.reduce(0, {$0 + ($1.duration ?? 0)}) <= (model == "seedance2.5" ? 30 : 15) else {throw DreaminaError.invalidResponse}
            }
        default: throw DreaminaError.invalidResponse
        }
        if ["text", "omni"].contains(effectiveMode) { guard ["1:1", "3:4", "16:9", "4:3", "9:16", "21:9"].contains(aspect) else {throw DreaminaError.invalidResponse} }
    }
}
struct ClassicVideoTask: Codable, Sendable {
    let id: String
    let projectId: String
    let nodeId: String
    let payloadHash: String
    let snapshot: ClassicVideoSnapshot
    let stage: String
    let submitId: String?
}
struct ClassicCliDevice: Codable, Sendable {
    let id: String
    let epoch: String
    let secret: String
}
struct ClassicCliJournal: Codable {
    let task: ClassicVideoTask
    let owner: String
    var stage: String
    var submitId: String?
    var file: String?
    var failureCode: String? = nil
    // nil preserves old journal compatibility; new terminal records remain
    // unresolved until the original server accepts their failure receipt.
    var terminalAcknowledged: Bool? = nil
}
protocol ClassicCliBridge: Sendable {
    func prepareReferences(task: ClassicVideoTask, directory: URL) async throws -> [URL]
    func event(task: ClassicVideoTask, event: String, submitId: String?) async throws
    func upload(task: ClassicVideoTask, submitId: String, file: URL) async throws
    func failure(task: ClassicVideoTask, event: String, code: String) async throws
}
extension ClassicCliBridge {
    func failure(task: ClassicVideoTask, event: String, code: String) async throws { try await self.event(task:task,event:event,submitId:nil) }
    func prepareReferences(task: ClassicVideoTask, directory: URL) async throws -> [URL] {
        guard task.snapshot.references?.isEmpty != false else {throw DreaminaError.unsupportedCLI}
        return []
    }
}
enum ClassicCliLoginError: Error { case unverifiedIdentity }

struct ClassicDreaminaCLI: Sendable {
    let runner: DreaminaRunning
    static func locate() -> URL? {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/dreamina"), URL(fileURLWithPath: "/opt/homebrew/bin/dreamina"), URL(fileURLWithPath: "/usr/local/bin/dreamina")].first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    struct FileIdentity: Equatable, Sendable {
        let path: String
        let device: Int32
        let inode: UInt64
        let bytes: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }
    static func fileIdentity(_ executable: URL) throws -> FileIdentity {
        let path = executable.resolvingSymlinksInPath().path
        var value = stat()
        guard stat(path, &value) == 0 else { throw POSIXError(.ENOENT) }
        return FileIdentity(path: path, device: value.st_dev, inode: value.st_ino, bytes: value.st_size,
                            modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanoseconds: value.st_mtimespec.tv_nsec,
                            changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec)
    }
    static func fingerprint(_ executable: URL) throws -> String {
        // Bind the actual executable bytes. Replacing an executable invalidates authorization.
        let data = try Data(contentsOf: executable.resolvingSymlinksInPath(), options: .mappedIfSafe)
        return executable.resolvingSymlinksInPath().path + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func detectedCapabilities() async throws -> (profile: String, models: [String]) {
        let contracts: [(String, [String])] = [
            ("text2video", ["--prompt", "--duration", "--ratio", "--video_resolution", "--model_version", "--poll", "seedance2.0", "seedance2.0fast", "720p", "21:9"]),
            ("image2video", ["--image", "--prompt", "--duration", "--video_resolution", "--model_version", "--poll"]),
            ("frames2video", ["--first", "--last", "--prompt", "--duration", "--video_resolution", "--model_version", "--poll"]),
            ("multiframe2video", ["--images", "--transition-prompt", "--transition-duration", "--poll", "--video_resolution", "720p", "1080p"]),
            ("multimodal2video", ["--image", "--video", "--audio", "--prompt", "--duration", "--ratio", "--video_resolution", "--model_version", "--poll"]),
            ("query_result", ["--submit_id", "--download_dir"])
        ]
        let profile = "resolution-five"
        var models = Set(ClassicVideoModels.supported)
        for (command, flags) in contracts {
            let output = try await runner.run([command, "--help"], timeout: 15)
            let text = String(decoding: output.data, as: UTF8.self)
            guard output.status == 0, output.data.count < 128000, flags.allSatisfy(text.contains) else {throw ClassicCliUpgradeError.required}
            if ["text2video", "image2video", "frames2video", "multimodal2video"].contains(command) {
                let tokens = Set(text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._")).inverted))
                // Existing CLIs may list model names only in text2video help.
                if command == "text2video" { models.formIntersection(tokens) }
                else { for model in ClassicVideoModels.supported.dropFirst(2) where !tokens.contains(model) { models.remove(model) } }
            }
        }
        return (profile, ClassicVideoModels.supported.filter(models.contains) + ["dreamina-multiframe"])
    }
    func detectedProfile() async throws -> String { try await detectedCapabilities().profile }
    func verify(confirmedSession: Bool = false) async throws -> [String] {
        let capabilities = try await detectedCapabilities()
        guard try await loginState(confirmedSession: confirmedSession) else {throw DreaminaError.notLinked}
        return capabilities.models
    }
    func loginState(confirmedSession: Bool = false) async throws -> Bool {
        let output=try await runner.run(["user_credit"],timeout:15)
        if output.status != 0 {
            let text=String(decoding:output.data,as:UTF8.self)
            if text.contains("未检测到有效登录态") || text.contains("请先执行 dreamina login") {return false}
            throw DreaminaError.invalidResponse
        }
        let object=try Self.object(output)
        guard let credit=object["total_credit"] as? NSNumber, CFGetTypeID(credit) != CFBooleanGetTypeID(), credit.doubleValue.isFinite, credit.doubleValue >= 0 else {throw DreaminaError.invalidResponse}
        // Credit metadata may lack an identity even when official login reuses a valid OAuth session.
        // Only a recent explicit login confirmation for this unchanged CLI can tolerate that omission.
        guard Self.hasAccountIdentity(object) || confirmedSession else { throw ClassicCliLoginError.unverifiedIdentity }
        return true
    }
    static func hasAccountIdentity(_ object: [String: Any]) -> Bool {
        if let id=object["user_id"] as? String {
            let value=id.trimmingCharacters(in:.whitespacesAndNewlines)
            return !value.isEmpty && value != "0"
        }
        if let id=object["user_id"] as? NSNumber {
            return CFGetTypeID(id) != CFBooleanGetTypeID() && id.doubleValue.isFinite && id.doubleValue > 0
        }
        return false
    }
    static func object(_ output: DreaminaOutput) throws -> [String: Any] {
        guard output.status == 0, output.data.count <= 2 * 1024 * 1024,
              let text = String(data: output.data, encoding: .utf8), let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end,
              let data = String(text[start...end]).data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DreaminaError.invalidResponse }
        return object
    }
    static func arguments(_ snapshot: ClassicVideoSnapshot, files: [URL]) throws -> [String] {
        try snapshot.validate()
        let refs = snapshot.references ?? []
        guard files.count == refs.count, files.allSatisfy({$0.isFileURL && !$0.path.contains(",") && !$0.path.contains("\n")}) else {throw DreaminaError.invalidResponse}
        let seconds = { (value: Double) in String(format: "%g", value) }
        var args: [String]
        switch snapshot.effectiveMode {
        case "text": args = ["text2video"]
        case "image": args = ["image2video", "--image", files[0].path]
        case "firstlast": args = ["frames2video", "--first", files[0].path, "--last", files[1].path]
        case "imageref":
            args = ["multiframe2video", "--images", files.map(\.path).joined(separator: ",")]
            args += ["--video_resolution", snapshot.resolution]
            if files.count == 2 {
                args += ["--prompt", snapshot.transitions![0].prompt, "--duration", seconds(snapshot.transitions![0].duration)]
            } else {
                for segment in snapshot.transitions! {args += ["--transition-prompt", segment.prompt, "--transition-duration", seconds(segment.duration)]}
            }
            return args + ["--poll", "0"]
        case "omni":
            args = ["multimodal2video"]
            for (reference, file) in zip(refs, files) {args += ["--" + reference.kind, file.path]}
        default: throw DreaminaError.invalidResponse
        }
        args += ["--prompt", snapshot.prompt, "--duration", seconds(snapshot.duration), "--video_resolution", snapshot.resolution, "--model_version", snapshot.model]
        if ["text", "omni"].contains(snapshot.effectiveMode) {args += ["--ratio", snapshot.aspect]}
        return args + ["--poll", "0"]
    }
    func submit(_ snapshot: ClassicVideoSnapshot, files: [URL] = []) async throws -> String {
        let output = try await runner.run(Self.arguments(snapshot, files: files), timeout: 90)
        return try Self.submissionID(output)
    }
    static func submissionID(_ output: DreaminaOutput) throws -> String {
        guard output.data.count<=2*1024*1024,let text=String(data:output.data,encoding:.utf8) else {throw ClassicCliSubmissionError.receiptInvalid}
        if output.status != 0 {
            let lower=text.lowercased()
            if text.contains("AigcComplianceConfirmationRequired") {throw ClassicCliSubmissionError.complianceRequired}
            if text.contains("未检测到有效登录态") || text.contains("请先执行 dreamina login") {throw ClassicCliSubmissionError.loginRequired}
            if text.contains("额度不足") || text.contains("积分不足") || text.contains("余额不足") || lower.contains("insufficient credit") {throw ClassicCliSubmissionError.insufficientCredits}
            if lower.contains("unknown flag") || lower.contains("invalid argument") || lower.contains("required flag") {throw ClassicCliSubmissionError.argumentsRejected}
            throw ClassicCliSubmissionError.rejected
        }
        // Upload progress may contain earlier JSON documents. Accept only the final complete object.
        var depth=0,quoted=false,escaped=false,start:String.Index?,last:[String:Any]?,lastEnd:String.Index?
        for index in text.indices {
            let c=text[index]
            if quoted {if escaped {escaped=false} else if c=="\\" {escaped=true} else if c=="\"" {quoted=false};continue}
            if depth>0 && c=="\"" {quoted=true;continue}
            if c=="{" {if depth==0 {start=index};depth += 1}
            if c=="}" && depth>0 {
                depth -= 1
                if depth==0,let start {
                    last=try? JSONSerialization.jsonObject(with:Data(text[start...index].utf8)) as? [String:Any]
                    lastEnd=text.index(after:index)
                }
            }
        }
        guard depth==0,let object=last,let end=lastEnd,text[end...].trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw ClassicCliSubmissionError.receiptInvalid}
        guard let id=object["submit_id"] as? String,Self.validID(id) else {throw ClassicCliSubmissionError.receiptMissing}
        return id
    }
    static func validID(_ value: String) -> Bool { !value.isEmpty && value.count <= 200 && value.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil }
    struct QueryResult: Sendable {
        let status: String
        let file: URL?
    }
    static func resultFile(_ file: URL, in directory: URL) throws -> URL {
        let file = file.standardizedFileURL, directory = directory.standardizedFileURL
        let parent = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parent.isDirectory == true, parent.isSymbolicLink != true,
              file.deletingLastPathComponent() == directory,
              ["mp4", "mov", "webm"].contains(file.pathExtension.lowercased()) else { throw DreaminaError.invalidResponse }
        let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              let bytes = properties.fileSize, bytes > 0, bytes <= 300 * 1024 * 1024 else { throw DreaminaError.invalidResponse }
        return file
    }
    func queryResult(_ id: String, directory: URL) async throws -> QueryResult {
        guard Self.validID(id) else { throw DreaminaError.invalidResponse }
        let directory = directory.standardizedFileURL
        let properties = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw DreaminaError.invalidResponse }
        // Legacy receipts may expose only video_url. Never mistake a prior
        // attempt's residual download for the result of this invocation.
        let before = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map(\.lastPathComponent))
        let output = try await runner.run(["query_result", "--submit_id", id, "--download_dir", directory.path], timeout: 120)
        try Task.checkCancellation()
        let object = try Self.object(output)
        guard object["submit_id"] as? String == id, let status = object["gen_status"] as? String else { throw DreaminaError.invalidResponse }
        guard status == "success" else { return QueryResult(status: status, file: nil) }
        guard let result = object["result_json"] as? [String: Any], let videos = result["videos"] as? [[String: Any]], videos.count == 1 else { throw DreaminaError.invalidResponse }
        let file: URL
        if let value = videos[0]["path"] as? String {
            guard !value.isEmpty, !value.contains("\0") else { throw DreaminaError.invalidResponse }
            file = try Self.resultFile(value.hasPrefix("/") ? URL(fileURLWithPath: value) : directory.appendingPathComponent(value), in: directory)
        } else {
            guard let value = videos[0]["video_url"] as? String, let url = URL(string: value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw DreaminaError.invalidResponse }
            let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { candidate -> URL? in
                guard !before.contains(candidate.lastPathComponent),
                      let valid = try? Self.resultFile(candidate, in: directory) else { return nil }
                return valid
            }
            guard candidates.count == 1 else { throw DreaminaError.invalidResponse }
            file = candidates[0]
        }
        return QueryResult(status: status, file: file)
    }
    // Retain the readonly status API used by earlier clients and fixtures.
    func query(_ id: String, directory: URL) async throws -> String {
        try await queryResult(id, directory: directory).status
    }
}

/** Durable intent and the server's one-shot dispatch CAS precede every paid command. */
actor ClassicCliExecutor {
    let cli: ClassicDreaminaCLI
    let directory: URL
    private var busy = false
    func isIdle() -> Bool { !busy }
    init(cli: ClassicDreaminaCLI, directory: URL) { self.cli = cli; self.directory = directory }
    nonisolated static func hasUnfinishedTasks(directory: URL, owner: String? = nil) throws -> Bool {
        var directoryState = stat()
        guard lstat(directory.path, &directoryState) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let properties = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw DreaminaError.invalidResponse }
        var unfinished = false
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) where file.pathExtension == "json" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize,
                  bytes > 0, bytes <= 2 * 1024 * 1024 else { throw DreaminaError.invalidResponse }
            let journal = try JSONDecoder().decode(ClassicCliJournal.self, from: Data(contentsOf: file))
            guard ClassicDreaminaCLI.validID(journal.task.id), file.lastPathComponent == journal.task.id + ".json",
                  !journal.owner.isEmpty, !journal.task.projectId.isEmpty, !journal.task.nodeId.isEmpty,
                  journal.task.payloadHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  journal.submitId.map(ClassicDreaminaCLI.validID) != false,
                  ["awaiting-confirmation", "dispatch-intent", "submitted", "unknown", "upload-ready", "completed", "declined", "failed", "preparation-failed"].contains(journal.stage) else { throw DreaminaError.invalidResponse }
            try journal.task.snapshot.validateRecovery()
            // Validate every record before ignoring another owner. An unreadable
            // journal must never permit replacing its original device identity.
            if owner == nil || owner == journal.owner {
                let terminal = journal.stage == "completed" ||
                    ["declined", "failed", "preparation-failed"].contains(journal.stage) && journal.terminalAcknowledged != false
                if !terminal { unfinished = true }
            }
        }
        return unfinished
    }
    nonisolated static func permanentPreparationFailure(_ error: Error) -> Bool {
        if let error = error as? StudioError {
            switch error {
            case .invalidResponse, .invalidURL, .tooLarge: return true
            case .http(let status, _), .mediaHTTP(let status): return [400, 404, 410, 415, 422].contains(status)
            default: return false
            }
        }
        if let error = error as? DreaminaError {
            switch error {
            case .invalidResponse, .unsupportedCLI, .oversized: return true
            default: return false
            }
        }
        if let error = error as? ClassicCliUpgradeError, case .required = error { return true }
        return false
    }
    nonisolated private static func recoverableCacheError(_ error: Error) -> Bool {
        if let error = error as? DreaminaError, case .invalidResponse = error { return true }
        if let error = error as? StudioError, case .invalidResponse = error { return true }
        let value = error as NSError
        return value.domain == "AVFoundationErrorDomain" ||
            value.domain == NSCocoaErrorDomain && [NSFileReadCorruptFileError, NSFileReadNoSuchFileError].contains(value.code) ||
            value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT)
    }
    private func location(_ task: ClassicVideoTask) throws -> URL {
        guard ClassicDreaminaCLI.validID(task.id) else { throw DreaminaError.invalidResponse }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent(task.id + ".json")
    }
    private func save(_ journal: ClassicCliJournal) throws {
        let url = try location(journal.task)
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // Flush the durable rename's contents before any paid invocation.
        let handle = try FileHandle(forWritingTo: url); try handle.synchronize(); try handle.close()
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func step(task: ClassicVideoTask, owner: String, bridge: ClassicCliBridge,
              authorize: (@Sendable () async throws -> Bool)? = nil,
              isCurrent: @Sendable () async -> Bool,
              validateVideo: @Sendable (URL) async throws -> Void) async throws {
        if busy { return }; busy = true; defer { busy = false }
        try Task.checkCancellation()
        try task.snapshot.validateRecovery()
        let path = try location(task)
        // A crash can leave prepared inputs, never a reason to re-submit. Delete
        // only this validated task's private input directories on reentry.
        for old in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey]) where old.lastPathComponent.hasPrefix(task.id + "-input-") {
            let properties = try old.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            if properties.isDirectory == true && properties.isSymbolicLink != true {try FileManager.default.removeItem(at:old)}
        }
        var journal: ClassicCliJournal
        if FileManager.default.fileExists(atPath: path.path) {
            journal = try JSONDecoder().decode(ClassicCliJournal.self, from: Data(contentsOf: path))
            guard journal.owner == owner, journal.task.id == task.id, journal.task.payloadHash == task.payloadHash,
                  task.submitId == nil || journal.submitId == nil || task.submitId == journal.submitId, journal.task.projectId == task.projectId, journal.task.nodeId == task.nodeId, journal.task.snapshot == task.snapshot else { throw DreaminaError.wrongOwner }
        } else {
            journal = ClassicCliJournal(task: task, owner: owner, stage: task.stage, submitId: task.submitId)
            // A server dispatch marker survives loss of the local journal. Never replay it.
            if task.stage != "awaiting-confirmation", task.submitId == nil { journal.stage = "unknown"; try save(journal); try? await bridge.event(task: task, event: "unknown", submitId: nil); return }
            try save(journal)
        }
        guard await isCurrent() else { throw DreaminaError.wrongOwner }
        if journal.stage == "completed" { return }
        if journal.stage == "declined" || journal.stage == "failed" || journal.stage == "preparation-failed" {
            if let code=journal.failureCode {try await bridge.failure(task:task,event:journal.stage,code:code)} else {try await bridge.event(task: task, event: journal.stage, submitId: journal.submitId)}
            journal.terminalAcknowledged = true; try save(journal); return
        }
        if journal.stage == "dispatch-intent", journal.submitId == nil, task.submitId == nil, task.stage == "awaiting-confirmation" {
            // The authoritative claim proves the server has not yet permitted a
            // paid invocation. Retry the original task's one-shot dispatch CAS.
            // A delayed old event or stale claim makes that CAS return conflict;
            // neither a local unknown nor a server dispatch marker is replayable.
            journal.stage = "awaiting-confirmation"; try save(journal)
        }
        if journal.stage == "awaiting-confirmation" {
            guard task.snapshot.profile == "resolution-five" else {
                journal.stage = "preparation-failed"; journal.terminalAcknowledged = false; try save(journal)
                try await bridge.event(task:task,event:"preparation-failed",submitId:nil)
                journal.terminalAcknowledged = true; try save(journal); return
            }
            let inputs = directory.appendingPathComponent(task.id + "-input-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer {try? FileManager.default.removeItem(at: inputs)}
            let files: [URL]
            do {
                files = try await bridge.prepareReferences(task: task, directory: inputs)
                guard files.count == (task.snapshot.references ?? []).count else {throw StudioError.invalidResponse}
                for (file,reference) in zip(files,task.snapshot.references ?? []) {
                    let properties = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                    guard file.deletingLastPathComponent().standardizedFileURL == inputs.standardizedFileURL,
                          properties.isRegularFile == true, properties.isSymbolicLink != true, properties.fileSize == reference.bytes else {throw StudioError.invalidResponse}
                    let bytes = try Data(contentsOf:file,options:.mappedIfSafe)
                    guard SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined() == reference.sha256 else {throw StudioError.invalidResponse}
                }
                _ = try ClassicDreaminaCLI.arguments(task.snapshot, files: files)
            } catch {
                try Task.checkCancellation()
                guard await isCurrent() else { throw DreaminaError.wrongOwner }
                // Preparation has no paid side effect: temporary transport,
                // cancellation and identity failures can retry the original task.
                guard Self.permanentPreparationFailure(error) else { throw error }
                journal.stage = "preparation-failed"; journal.terminalAcknowledged = false; try save(journal)
                try await bridge.event(task: task, event: "preparation-failed", submitId: nil)
                journal.terminalAcknowledged = true; try save(journal); return
            }
            let approved: Bool
            if let authorize { approved = try await authorize() } else { approved = await isCurrent() }
            guard await isCurrent() else { throw DreaminaError.wrongOwner }
            if !approved {
                journal.stage = "declined"; journal.terminalAcknowledged = false; try save(journal)
                try await bridge.event(task: task, event: "declined", submitId: nil)
                journal.terminalAcknowledged = true; try save(journal); return
            }
            guard await isCurrent() else {throw DreaminaError.wrongOwner}
            journal.stage = "dispatch-intent"; try save(journal)
            // If acknowledgement is lost, leave intent durable and do not spawn.
            try await bridge.event(task: task, event: "dispatch-intent", submitId: nil)
            try Task.checkCancellation()
            guard await isCurrent() else { throw DreaminaError.wrongOwner }
            do {
                let id = try await cli.submit(task.snapshot, files: files)
                journal.submitId = id; journal.stage = "submitted"; try save(journal)
            } catch {
                journal.stage = "unknown"
                journal.failureCode=ClassicCliSubmissionError.code(error)
                try save(journal)
                try? await bridge.failure(task:task,event:"unknown",code:journal.failureCode!)
                return
            }
        }
        // Consent declined is persisted even if its first API receipt was lost.
        guard let submitId = journal.submitId ?? task.submitId else {
            journal.stage = "unknown"; try save(journal)
            if let code=journal.failureCode {try? await bridge.failure(task:task,event:"unknown",code:code)} else {try? await bridge.event(task: task, event: "unknown", submitId: nil)}
            return
        }
        guard await isCurrent() else { throw DreaminaError.wrongOwner }
        let downloads = directory.appendingPathComponent(task.id + "-video", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let downloadProperties = try downloads.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard downloadProperties.isDirectory == true, downloadProperties.isSymbolicLink != true else { throw DreaminaError.invalidResponse }
        func localResult(_ path: String?) throws -> URL? {
            guard let path else { return nil }
            let file = URL(fileURLWithPath: path).standardizedFileURL, parent = file.deletingLastPathComponent()
            let direct = parent == downloads
            let attempt = parent.deletingLastPathComponent() == downloads && UUID(uuidString: parent.lastPathComponent) != nil
            guard direct || attempt else { throw DreaminaError.invalidResponse }
            // Missing/truncated cache is recoverable. A linked or out-of-scope
            // path is never read and never used as a reason to relax isolation.
            var parentState = stat()
            if lstat(parent.path, &parentState) == 0 {
                let parentProperties = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard parentProperties.isDirectory == true, parentProperties.isSymbolicLink != true else { throw DreaminaError.invalidResponse }
            } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var fileState = stat()
            guard lstat(file.path, &fileState) == 0 else {
                if errno == ENOENT { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true, let bytes = properties.fileSize else { throw DreaminaError.invalidResponse }
            guard bytes > 0, bytes <= 300 * 1024 * 1024 else { return nil }
            return try ClassicDreaminaCLI.resultFile(file, in: parent)
        }
        var file = journal.stage == "upload-ready" ? try localResult(journal.file) : nil
        if let cached = file {
            do { try await validateVideo(cached) }
            catch {
                try Task.checkCancellation()
                guard await isCurrent() else { throw DreaminaError.wrongOwner }
                guard Self.recoverableCacheError(error) else { throw error }
                file = nil
            }
        }
        if file == nil {
            // The server's upload-ready stage survives local cache/journal loss.
            // Recover by the original submit ID without regressing its stage.
            if task.stage != "upload-ready", journal.stage != "upload-ready" {
                try await bridge.event(task: task, event: "submitted", submitId: submitId)
            }
            let attempt = downloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var retained = false
            defer { if !retained { try? FileManager.default.removeItem(at: attempt) } }
            let result = try await cli.queryResult(submitId, directory: attempt)
            guard await isCurrent() else { throw DreaminaError.wrongOwner }
            if ["fail", "failed", "error"].contains(result.status) {
                guard task.stage != "upload-ready", journal.stage != "upload-ready" else { throw DreaminaError.invalidResponse }
                journal.stage = "failed"; journal.terminalAcknowledged = false; try save(journal)
                try await bridge.event(task: task, event: "failed", submitId: submitId)
                journal.terminalAcknowledged = true; try save(journal); return
            }
            guard result.status == "success", let downloaded = result.file else { return }
            try await validateVideo(downloaded)
            guard await isCurrent() else { throw DreaminaError.wrongOwner }
            journal.stage = "upload-ready"; journal.file = downloaded.path; try save(journal)
            retained = true; file = downloaded
        }
        guard await isCurrent(), let file else { throw DreaminaError.wrongOwner }
        try await validateVideo(file)
        try await bridge.event(task: task, event: "upload-ready", submitId: submitId)
        try await bridge.upload(task: task, submitId: submitId, file: file)
        journal.stage = "completed"; try save(journal)
    }
}

/** Independent presence loop. It never submits and is cancelled with its original owner scope. */
final class ClassicCliHeartbeat: @unchecked Sendable {
    private let task: Task<Void, Never>
    init(intervalNanoseconds: UInt64 = 10_000_000_000, action: @escaping @Sendable () async throws -> Void) {
        task = Task.detached {
            while !Task.isCancelled {
                do { try await action() } catch { if Task.isCancelled { return } }
                do { try await Task.sleep(nanoseconds: intervalNanoseconds) } catch { return }
            }
        }
    }
    func stop() { task.cancel() }
    deinit { task.cancel() }
}

struct ClassicCliReceipt {
    static func event(_ data: Data, task: ClassicVideoTask, event: String, submitId: String?) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["accepted"] as? Bool == true,
              object["jobId"] as? String == task.id, object["payloadHash"] as? String == task.payloadHash,
              object["event"] as? String == event, object["status"] as? String == (["declined", "failed", "preparation-failed"].contains(event) ? "error" : "running"),
              submitId == nil || object["submitId"] as? String == submitId else { throw DreaminaError.invalidResponse }
    }
    static func upload(_ data: Data, task: ClassicVideoTask, submitId: String) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["jobId"] as? String == task.id,
              object["status"] as? String == "done", object["submitId"] as? String == submitId,
              let url = object["url"] as? String, url.range(of: "^/api/private-files/[a-f0-9-]{36}\\.(mp4|mov|webm)$", options: .regularExpression) != nil else { throw DreaminaError.invalidResponse }
    }
}

enum ClassicCliSubmissionError: String, Error {
    case insufficientCredits="insufficient-credits",loginRequired="login-required",argumentsRejected="arguments-rejected",complianceRequired="compliance-required",rejected="cli-rejected",receiptMissing="receipt-missing",receiptInvalid="receipt-invalid"
    static func code(_ error:Error)->String {
        if let error=error as? Self {return error.rawValue}
        if error is CancellationError {return "submit-cancelled"}
        if let error=error as? DreaminaError,case .timedOut=error {return "submit-timeout"}
        return "submit-error"
    }
}
