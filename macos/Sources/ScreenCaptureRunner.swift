import Foundation
import ImageIO

enum ScreenCaptureResult {
    case captured(Data)
    case cancelled
    case failed(ScreenCaptureFailure)
}

struct ScreenCaptureFailure: Equatable {
    enum Reason: String {
        case launch, permissionDenied, commandFailed, missingImage, unreadableImage, invalidImage
    }
    let reason: Reason
    let exitStatus: Int32?
    let diagnostic: String
    var isPermissionDenied: Bool { reason == .permissionDenied }
}

@MainActor protocol ScreenCaptureRunning: AnyObject {
    func capture(completion: @escaping (ScreenCaptureResult) -> Void)
    func cancel()
}

@MainActor final class SystemScreenCaptureRunner: ScreenCaptureRunning {
    private struct Operation {
        let id: UUID
        let process: Process
    }
    private let executable: URL
    private let argumentsBuilder: (URL) -> [String]
    private let temporaryRoot: URL
    private let queue = DispatchQueue(label: "com.kakitools.screen-capture", qos: .userInitiated)
    private var operation: Operation?

    init(executable: URL = URL(fileURLWithPath: "/usr/sbin/screencapture"),
         temporaryRoot: URL = FileManager.default.temporaryDirectory,
         argumentsBuilder: @escaping (URL) -> [String] = { ["-i", "-s", "-x", $0.path] }) {
        self.executable = executable
        self.temporaryRoot = temporaryRoot
        self.argumentsBuilder = argumentsBuilder
    }

    func capture(completion: @escaping (ScreenCaptureResult) -> Void) {
        guard operation == nil else { return }
        let id = UUID()
        let directory = temporaryRoot.appendingPathComponent("kaki-capture-" + id.uuidString, isDirectory: true)
        let image = directory.appendingPathComponent("capture.png")
        let stderr = directory.appendingPathComponent("diagnostic.txt")
        var diagnosticHandle: FileHandle?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: stderr.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            diagnosticHandle = try FileHandle(forWritingTo: stderr)
            let process = Process()
            process.executableURL = executable
            process.arguments = argumentsBuilder(image)
            // A regular file avoids an unread stderr pipe blocking the child.
            process.standardError = diagnosticHandle
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let worker = queue
            process.terminationHandler = { [weak self] child in
                child.terminationHandler = nil
                let status = child.terminationStatus
                let terminatedNormally = child.terminationReason == .exit
                worker.async { [weak self] in
                    let result = Self.readResult(status: status,
                        terminatedNormally: terminatedNormally,
                        image: image, stderr: stderr, directory: directory)
                    try? FileManager.default.removeItem(at: directory)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.operation?.id == id else { return }
                        self.operation = nil
                        completion(result)
                    }
                }
            }
            operation = Operation(id: id, process: process)
            do { try process.run() }
            catch {
                process.terminationHandler = nil
                operation = nil
                throw error
            }
            // The child has inherited its descriptor; release the parent's copy.
            try? diagnosticHandle?.close()
        } catch {
            try? diagnosticHandle?.close()
            try? FileManager.default.removeItem(at: directory)
            completion(.failed(ScreenCaptureFailure(reason: .launch, exitStatus: nil,
                diagnostic: Self.sanitized(error.localizedDescription, directory: directory))))
        }
    }

    func cancel() {
        // Invalidate before terminating so any queued result cannot be delivered.
        let running = operation?.process
        operation = nil
        if let running, running.isRunning { running.terminate() }
    }

    private nonisolated static func readResult(status: Int32, terminatedNormally: Bool,
        image: URL, stderr: URL, directory: URL) -> ScreenCaptureResult {
        let diagnostic = readDiagnostic(stderr, directory: directory)
        let exists = FileManager.default.fileExists(atPath: image.path)
        if (!terminatedNormally || status != 0 || !exists) && explicitPermissionDenial(diagnostic) {
            return .failed(ScreenCaptureFailure(reason: .permissionDenied, exitStatus: status, diagnostic: diagnostic))
        }
        guard terminatedNormally && status == 0 else {
            // Esc produces no file and normally no diagnostics. A nonzero exit
            // with an output file is still a failed command, never a valid image.
            if terminatedNormally && status == 1 && !exists && diagnostic.isEmpty { return .cancelled }
            return .failed(ScreenCaptureFailure(reason: .commandFailed, exitStatus: status, diagnostic: diagnostic))
        }
        guard exists else {
            if diagnostic.isEmpty { return .cancelled }
            return .failed(ScreenCaptureFailure(reason: .missingImage, exitStatus: status, diagnostic: diagnostic))
        }
        let data: Data
        do { data = try Data(contentsOf: image, options: .mappedIfSafe) }
        catch {
            return .failed(ScreenCaptureFailure(reason: .unreadableImage, exitStatus: status,
                diagnostic: sanitized(error.localizedDescription, directory: directory)))
        }
        guard validPNG(data) else {
            return .failed(ScreenCaptureFailure(reason: .invalidImage, exitStatus: status, diagnostic: diagnostic))
        }
        return .captured(data)
    }

    private nonisolated static func readDiagnostic(_ file: URL, directory: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        return sanitized(String(decoding: data, as: UTF8.self), directory: directory)
    }

    private nonisolated static func sanitized(_ value: String, directory: URL) -> String {
        let cleaned = value.replacingOccurrences(of: directory.path, with: "<temporary>")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = String(decoding: cleaned.utf8.prefix(4096), as: UTF8.self)
        // A partial UTF-8 scalar at the boundary can expand to a replacement
        // character, so enforce the byte limit after decoding too.
        while result.utf8.count > 4096 { result.removeLast() }
        return result
    }

    private nonisolated static func explicitPermissionDenial(_ value: String) -> Bool {
        let text = value.lowercased()
        let phrases = ["screen capture permission denied", "screen recording permission denied",
            "screen capture access denied", "screen recording access denied",
            "not authorized to capture screen", "not authorised to capture screen",
            "user denied screen capture", "no permission to capture screen",
            "permission to record screen was denied", "screen capture not allowed",
            "没有屏幕录制权限", "屏幕录制权限被拒绝", "未获准录制屏幕"]
        return phrases.contains { text.contains($0) }
    }

    private nonisolated static func validPNG(_ data: Data) -> Bool {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        // Read metadata only. A legitimately black screenshot is valid too.
        return width.int64Value > 0 && height.int64Value > 0
    }
}
