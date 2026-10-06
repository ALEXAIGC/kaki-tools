import Foundation
import Darwin
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
              refs.count <= 20, Set(refs.map {$0.kind + ":" + $0.nodeId}).count == refs.count,
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
        guard ["seedance2.0", "seedance2.0fast"].contains(model), duration.rounded() == duration, (4...15).contains(duration), resolution == "720p", transitions?.isEmpty != false else {throw DreaminaError.invalidResponse}
        switch effectiveMode {
        case "text": guard refs.isEmpty else {throw DreaminaError.invalidResponse}
        case "image": guard images.count == 1, refs.count == 1, aspect == "source" else {throw DreaminaError.invalidResponse}
        case "firstlast": guard images.count == 2, refs.count == 2, aspect == "source" else {throw DreaminaError.invalidResponse}
        case "omni":
            guard images.count + videos.count > 0, images.count <= 9, videos.count <= 3, audios.count <= 3, refs.count <= 12 else {throw DreaminaError.invalidResponse}
            for kind in ["video", "audio"] {
                let media = refs.filter {$0.kind == kind}
                guard media.allSatisfy({$0.duration?.isFinite == true && $0.duration! >= 2 && $0.duration! <= 15}), media.reduce(0, {$0 + ($1.duration ?? 0)}) <= 15 else {throw DreaminaError.invalidResponse}
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
              refs.count <= 20, Set(refs.map {$0.kind + ":" + $0.nodeId}).count == refs.count,
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
        guard ["seedance2.0", "seedance2.0fast"].contains(model), duration.rounded() == duration, (4...15).contains(duration), resolution == "720p", transitions?.isEmpty != false else {throw DreaminaError.invalidResponse}
        switch effectiveMode {
        case "text": guard refs.isEmpty else {throw DreaminaError.invalidResponse}
        case "image": guard images.count == 1, refs.count == 1, aspect == "source" else {throw DreaminaError.invalidResponse}
        case "firstlast": guard images.count == 2, refs.count == 2, aspect == "source" else {throw DreaminaError.invalidResponse}
        case "omni":
            guard images.count + videos.count > 0, images.count <= 9, videos.count <= 3, audios.count <= 3, refs.count <= 12 else {throw DreaminaError.invalidResponse}
            for kind in ["video", "audio"] {
                let media = refs.filter {$0.kind == kind}
                guard media.allSatisfy({$0.duration?.isFinite == true && $0.duration! >= 2 && $0.duration! <= 15}), media.reduce(0, {$0 + ($1.duration ?? 0)}) <= 15 else {throw DreaminaError.invalidResponse}
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
}
protocol ClassicCliBridge: Sendable {
    func prepareReferences(task: ClassicVideoTask, directory: URL) async throws -> [URL]
    func event(task: ClassicVideoTask, event: String, submitId: String?) async throws
    func upload(task: ClassicVideoTask, submitId: String, file: URL) async throws
}
extension ClassicCliBridge {
    func prepareReferences(task: ClassicVideoTask, directory: URL) async throws -> [URL] {
        guard task.snapshot.references?.isEmpty != false else {throw DreaminaError.unsupportedCLI}
        return []
    }
}
struct ClassicDreaminaCLI: Sendable {
    let runner: DreaminaRunning
    static func locate() -> URL? {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/dreamina"), URL(fileURLWithPath: "/opt/homebrew/bin/dreamina"), URL(fileURLWithPath: "/usr/local/bin/dreamina")].first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    static func fingerprint(_ executable: URL) throws -> String {
        // Bind the actual executable bytes. Replacing an executable invalidates authorization.
        let data = try Data(contentsOf: executable.resolvingSymlinksInPath(), options: .mappedIfSafe)
        return executable.resolvingSymlinksInPath().path + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func detectedProfile() async throws -> String {
        let contracts: [(String, [String])] = [
            ("text2video", ["--prompt", "--duration", "--ratio", "--video_resolution", "--model_version", "--poll", "seedance2.0", "seedance2.0fast", "720p", "21:9"]),
            ("image2video", ["--image", "--prompt", "--duration", "--video_resolution", "--model_version", "--poll"]),
            ("frames2video", ["--first", "--last", "--prompt", "--duration", "--video_resolution", "--model_version", "--poll"]),
            ("multiframe2video", ["--images", "--transition-prompt", "--transition-duration", "--poll", "--video_resolution", "720p", "1080p"]),
            ("multimodal2video", ["--image", "--video", "--audio", "--prompt", "--duration", "--ratio", "--video_resolution", "--model_version", "--poll"]),
            ("query_result", ["--submit_id", "--download_dir"])
        ]
        let profile = "resolution-five"
        for (command, flags) in contracts {
            let output = try await runner.run([command, "--help"], timeout: 15)
            let text = String(decoding: output.data, as: UTF8.self)
            guard output.status == 0, output.data.count < 128000, flags.allSatisfy(text.contains) else {throw ClassicCliUpgradeError.required}

        }
        return profile
    }
    func verify() async throws -> [String] {
        _ = try await detectedProfile()
        guard try await loginState() else {throw DreaminaError.notLinked}
        return ["seedance2.0", "seedance2.0fast", "dreamina-multiframe"]
    }
    func loginState() async throws -> Bool {
        let output=try await runner.run(["user_credit"],timeout:15)
        if output.status != 0 {
            let text=String(decoding:output.data,as:UTF8.self)
            if text.contains("未检测到有效登录态") || text.contains("请先执行 dreamina login") {return false}
            throw DreaminaError.invalidResponse
        }
        let object=try Self.object(output)
        guard let credit=object["total_credit"] as? NSNumber, credit.doubleValue.isFinite, credit.doubleValue >= 0 else {throw DreaminaError.invalidResponse}
        return true
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
        let object = try Self.object(output)
        guard let id = object["submit_id"] as? String, Self.validID(id) else { throw DreaminaError.invalidResponse }
        return id
    }
    static func validID(_ value: String) -> Bool { !value.isEmpty && value.count <= 200 && value.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil }
    func query(_ id: String, directory: URL) async throws -> String {
        guard Self.validID(id) else { throw DreaminaError.invalidResponse }
        let output = try await runner.run(["query_result", "--submit_id", id, "--download_dir", directory.path], timeout: 120)
        let object = try Self.object(output)
        guard object["submit_id"] as? String == id, let status = object["gen_status"] as? String else { throw DreaminaError.invalidResponse }
        if status == "success" {
            guard let result = object["result_json"] as? [String: Any], let videos = result["videos"] as? [[String: Any]], videos.count == 1,
                  let value = videos[0]["video_url"] as? String, let url = URL(string: value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw DreaminaError.invalidResponse }
        }
        return status
    }
}

/** Durable dispatch intent precedes the only paid command. Reentry can only query or upload. */
actor ClassicCliExecutor {
    let cli: ClassicDreaminaCLI
    let directory: URL
    private var busy = false
    func isIdle() -> Bool { !busy }
    init(cli: ClassicDreaminaCLI, directory: URL) { self.cli = cli; self.directory = directory }
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
              authorize: @Sendable () async throws -> Bool,
              isCurrent: @Sendable () async -> Bool,
              validateVideo: @Sendable (URL) async throws -> Void) async throws {
        if busy { return }; busy = true; defer { busy = false }
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
            guard journal.owner == owner, journal.task.payloadHash == task.payloadHash, journal.task.projectId == task.projectId, journal.task.nodeId == task.nodeId, journal.task.snapshot == task.snapshot else { throw DreaminaError.wrongOwner }
        } else {
            journal = ClassicCliJournal(task: task, owner: owner, stage: task.stage, submitId: task.submitId)
            // A server dispatch marker survives loss of the local journal. Never replay it.
            if task.stage != "awaiting-confirmation", task.submitId == nil { journal.stage = "unknown"; try save(journal); try? await bridge.event(task: task, event: "unknown", submitId: nil); return }
            try save(journal)
        }
        guard await isCurrent() else { throw DreaminaError.wrongOwner }
        if journal.stage == "completed" { return }
        if journal.stage == "declined" || journal.stage == "failed" || journal.stage == "preparation-failed" {
            try await bridge.event(task: task, event: journal.stage, submitId: journal.submitId); return
        }
        if journal.stage == "awaiting-confirmation" {
            guard task.snapshot.profile == "resolution-five" else {
                journal.stage = "preparation-failed"; try save(journal)
                try await bridge.event(task:task,event:"preparation-failed",submitId:nil)
                return
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
                journal.stage = "preparation-failed"; try save(journal)
                try await bridge.event(task: task, event: "preparation-failed", submitId: nil)
                return
            }
            let approved = try await authorize()
            guard await isCurrent() else { throw DreaminaError.wrongOwner }
            if !approved { journal.stage = "declined"; try save(journal); try await bridge.event(task: task, event: "declined", submitId: nil); return }
            guard await isCurrent() else {throw DreaminaError.wrongOwner}
            journal.stage = "dispatch-intent"; try save(journal)
            // If acknowledgement is lost, leave intent durable and do not spawn.
            try await bridge.event(task: task, event: "dispatch-intent", submitId: nil)
            guard await isCurrent() else { throw DreaminaError.wrongOwner }
            do {
                let id = try await cli.submit(task.snapshot, files: files)
                journal.submitId = id; journal.stage = "submitted"; try save(journal)
            } catch {
                journal.stage = "unknown"; try save(journal)
                try? await bridge.event(task: task, event: "unknown", submitId: nil)
                return
            }
        }
        // Consent declined is persisted even if its first API receipt was lost.
        guard let submitId = journal.submitId ?? task.submitId else {
            journal.stage = "unknown"; try save(journal); try? await bridge.event(task: task, event: "unknown", submitId: nil); return
        }
        guard await isCurrent() else { throw DreaminaError.wrongOwner }
        if journal.stage != "upload-ready" {
            try await bridge.event(task: task, event: "submitted", submitId: submitId)
            let downloads = directory.appendingPathComponent(task.id + "-video", isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let status = try await cli.query(submitId, directory: downloads)
            if ["fail", "failed", "error"].contains(status) {
                journal.stage = "failed"; try save(journal); try await bridge.event(task: task, event: "failed", submitId: submitId); return
            }
            guard status == "success" else { return }
            let files = try FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            let videos = try files.filter { file in
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                return values.isRegularFile == true && values.isSymbolicLink != true && ["mp4", "mov", "webm"].contains(file.pathExtension.lowercased()) && (values.fileSize ?? 0) > 0 && (values.fileSize ?? 0) <= 300 * 1024 * 1024
            }
            guard videos.count == 1 else { throw DreaminaError.invalidResponse }
            try await validateVideo(videos[0])
            journal.stage = "upload-ready"; journal.file = videos[0].path; try save(journal)
        }
        guard await isCurrent(), let filePath = journal.file else { throw DreaminaError.wrongOwner }
        let file = URL(fileURLWithPath: filePath).standardizedFileURL
        guard file.deletingLastPathComponent() == directory.appendingPathComponent(task.id + "-video", isDirectory: true).standardizedFileURL,
              (try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw DreaminaError.invalidResponse }
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
