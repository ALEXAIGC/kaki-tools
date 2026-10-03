import Foundation

enum StudioMediaFiles {
    struct PreparedClipboard {
        let directory: URL
        let file: URL
    }
    static func mime(_ result: StudioHTTPFile) -> String {
        result.response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    }
    static func filename(title: String, suffix: String) -> String {
        let clean = title.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))).joined(separator: "_")
        let known = Set(["jpg", "jpeg", "png", "webp", "gif", "heic", "avif", "mp4", "mov", "webm", "mp3", "wav", "m4a", "ogg", "bin"])
        let existing = (clean as NSString).pathExtension.lowercased()
        let base = (known.contains(existing) ? (clean as NSString).deletingPathExtension : clean).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.isEmpty || base.allSatisfy({ $0 == "." }) ? "素材" : String(base.prefix(100)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // Keep the whole filename within common filesystems' 255-byte component limit.
        var bounded = name
        while bounded.utf8.count > 200 { bounded.removeLast() }
        return bounded + "." + (suffix == "bin" && known.contains(existing) ? existing : suffix)
    }
    static func isWritableDirectory(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return directory.isFileURL && FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue && FileManager.default.isWritableFile(atPath: directory.path)
    }
    static func stage(_ source: URL, in directory: URL) throws -> URL {
        let stage = directory.appendingPathComponent(".kaki-download-" + UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: source, to: stage)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.path)
            return stage
        } catch { try? FileManager.default.removeItem(at: stage); throw error }
    }
    static func commitUnique(_ stage: URL, filename: String, directory: URL) throws -> URL {
        let base = (filename as NSString).deletingPathExtension, ext = (filename as NSString).pathExtension
        for number in 1...10000 {
            let name = number == 1 ? filename : "\(base) (\(number)).\(ext)"
            let file = directory.appendingPathComponent(name)
            do { try FileManager.default.moveItem(at: stage, to: file); return file }
            catch {
                // A concurrent downloader may claim the same name after our check.
                guard FileManager.default.fileExists(atPath: file.path) else { throw error }
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
    static func prepareClipboard(_ result: StudioHTTPFile, title: String, directory: URL) throws -> PreparedClipboard {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let pending = directory.appendingPathComponent("pending-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = pending.appendingPathComponent(filename(title: title, suffix: StudioStore.mediaExtension(mime(result))))
            try FileManager.default.copyItem(at: result.file, to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return PreparedClipboard(directory: pending, file: file)
        } catch { try? FileManager.default.removeItem(at: pending); throw error }
    }
    static func removeOldClipboardFiles(directory: URL, keeping retained: URL) {
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.standardizedFileURL.path != retained.standardizedFileURL.path {
            let name = file.lastPathComponent
            let prefix = name.hasPrefix("material-") ? "material-" : "pending-"
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
