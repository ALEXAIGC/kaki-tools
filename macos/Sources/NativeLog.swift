import Foundation

final class NativeLog {
    private let queue = DispatchQueue(label: "com.kakitools.log", qos: .utility)
    private let file: URL
    init(directory: URL) { file = directory.appendingPathComponent("native.log") }
    func write(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(String(message.prefix(2048)))\n"
        queue.async { [file] in
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 1_048_576 {
                    let old = file.appendingPathExtension("old")
                    try? FileManager.default.removeItem(at: old)
                    try FileManager.default.moveItem(at: file, to: old)
                }
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8))
            } catch { /* Logging must not interfere with the clipboard. */ }
        }
    }
    func flush() { queue.sync {} }
}
