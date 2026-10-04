import Foundation
import CryptoKit

// Application-owned files only. All disk work stays off the main actor; leases
// let a transfer/player finish even when the user clears or evicts the cache.
actor StudioDiskCache {
    struct Key {
        let value: String
        let owner: String
        init(environment: String, user: String, workspace: String, asset: String, url: String, role: String) {
            owner = Self.hash([environment, user])
            value = Self.hash([environment, user, workspace, asset, url, role])
        }
        private static func hash(_ parts: [String]) -> String {
            SHA256.hash(data: try! JSONEncoder().encode(parts)).map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Entry: Codable {
        let key: String
        let owner: String
        let mime: String
        let bytes: Int64
        let headers: [String: String]
        var lastUsed: Date
    }
    // In-memory write identity; ETag and lastUsed are not write generations.
    // Loaded v1 indexes receive fresh identities without changing their schema.
    struct Version: Equatable { let epoch: Int; let write: UUID? }
    struct Lookup { let entry: Entry?; let epoch: Int; let version: Version }
    struct Stats { let bytes: Int64; let files: Int; let available: Bool }
    private struct Index: Codable { var version = 1; var entries: [Entry] }
    private var directory: URL
    private var volumeUUID: String
    private let marker = "kaki-tools-cache-v1\n"
    private var entries: [String: Entry] = [:]
    private var writes: [String: UUID] = [:]
    private var loaded = false
    private var dirty = false
    private var accessDirty = false
    private var persistedUses: [String: Date] = [:]
    private var epoch = 0
    private var limit: Int64
    private var days: Int
    init(directory: URL, limitMB: Int = 1024, days: Int = 7, volumeUUID: String = "") {
        self.directory = directory; self.volumeUUID = volumeUUID; limit = Int64(max(0, limitMB)) * 1024 * 1024; self.days = days
    }
    private func available() -> Bool {
        let parent = directory.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        if !volumeUUID.isEmpty {
            guard (try? parent.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == volumeUUID else { return false }
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory) == true,
                  (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
            if let saved = try? String(contentsOf: directory.appendingPathComponent(".kaki-cache-owner"), encoding: .utf8) { return saved == marker }
            // Accept an empty dedicated folder; older builds used the default studio-cache without a marker.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["unreadable"]
            return names.isEmpty || (directory.lastPathComponent == "studio-cache" && names.contains("index.json"))
        }
        return true
    }
    private func prepareDirectory() throws {
        guard available() else { throw CocoaError(.fileWriteNoPermission) }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let path = directory.appendingPathComponent(".kaki-cache-owner")
        if !FileManager.default.fileExists(atPath: path.path) {
            try Data(marker.utf8).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }
    func relocate(to target: URL, volumeUUID expected: String) throws -> Bool {
        if target.standardizedFileURL.path == directory.standardizedFileURL.path && expected == volumeUUID { return true }
        let previous = directory, previousVolume = volumeUUID
        directory = target; volumeUUID = expected
        do { try prepareDirectory() }
        catch { directory = previous; volumeUUID = previousVolume; throw error }
        directory = previous; volumeUUID = previousVolume
        let oldAvailable = available()
        load(); epoch += 1
        var cleared = oldAvailable
        for entry in Array(entries.values) { if !remove(entry.key) { cleared = false } }
        save()
        directory = target; volumeUUID = expected; entries = [:]; writes = [:]; loaded = false; dirty = false; accessDirty = false; persistedUses = [:]
        load()
        return cleared
    }
    private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".data") }
    private func load() {
        guard !loaded, available() else { return }; loaded = true
        let index = directory.appendingPathComponent("index.json")
        if let size = try? index.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
           let data = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode(Index.self, from: data), saved.version == 1 {
            for entry in saved.entries.prefix(2000) where Self.validKey(entry.key) && Self.validKey(entry.owner) && entry.bytes > 0 {
                if let values = try? file(entry.key).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                   values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == entry.bytes {
                    entries[entry.key] = entry
                    writes[entry.key] = UUID()
                    persistedUses[entry.key] = entry.lastUsed
                }
            }
        }
        // A crash may leave a private staging file or a payload without its index.
        for path in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let name = path.lastPathComponent
            if name.hasSuffix(".data"), Self.validKey(String(name.dropLast(5))), entries[String(name.dropLast(5))] == nil {
                try? FileManager.default.removeItem(at: path)
            } else if name.hasPrefix("pending-"), UUID(uuidString: String(name.dropFirst(8))) != nil {
                try? FileManager.default.removeItem(at: path)
            }
        }
    }
    private static func validKey(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
    }
    private func save(includeAccess: Bool = false) {
        guard dirty || (includeAccess && accessDirty) else { return }
        guard available(), FileManager.default.fileExists(atPath: directory.path) else { return }
        let path = directory.appendingPathComponent("index.json")
        if let data = try? JSONEncoder().encode(Index(entries: Array(entries.values))) {
            do { try data.write(to: path, options: .atomic); dirty = false; accessDirty = false; persistedUses = entries.mapValues { $0.lastUsed } } catch { return }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }
    @discardableResult private func remove(_ key: String) -> Bool {
        guard available() else { return false }
        if FileManager.default.fileExists(atPath: file(key).path) {
            do { try FileManager.default.removeItem(at: file(key)) } catch { return false }
        }
        dirty = true; entries.removeValue(forKey: key); writes.removeValue(forKey: key); persistedUses.removeValue(forKey: key); return true
    }
    private func trim(now: Date = Date()) {
        for entry in Array(entries.values) where limit == 0 || (days > 0 && now.timeIntervalSince(entry.lastUsed) > Double(days) * 86400) { remove(entry.key) }
        var bytes = entries.values.reduce(Int64(0)) { $0 + $1.bytes }
        var count = entries.count
        guard bytes > limit || count > 1000 else { return }
        for entry in entries.values.sorted(by: { $0.lastUsed < $1.lastUsed }) where bytes > limit || count > 1000 {
            if remove(entry.key) { bytes -= entry.bytes; count -= 1 }
        }
    }
    func lookup(_ key: Key, now: Date = Date()) -> Lookup {
        guard available() else { return Lookup(entry: nil, epoch: epoch, version: Version(epoch: epoch, write: nil)) }
        load(); trim(now: now); save()
        let entry = limit > 0 ? entries[key.value] : nil
        if let entry, !FileManager.default.fileExists(atPath: file(entry.key).path) { remove(entry.key); save(); return Lookup(entry: nil, epoch: epoch, version: Version(epoch: epoch, write: nil)) }
        return Lookup(entry: entry, epoch: epoch, version: Version(epoch: epoch, write: writes[key.value]))
    }
    func lease(_ key: Key, responseURL: URL, maximumBytes: Int64) throws -> StudioHTTPFile? {
        guard available() else { return nil }
        load(); trim(); save()
        guard limit > 0, var entry = entries[key.value] else { return nil }
        guard entry.bytes <= maximumBytes else { throw StudioError.tooLarge }
        let leased = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-cache-" + UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: file(key.value), to: leased)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: leased.path)
            guard Int64(try leased.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) == entry.bytes else { throw StudioError.invalidResponse }
            var headers = entry.headers; headers["Content-Type"] = entry.mime; headers["Content-Length"] = String(entry.bytes)
            let response = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            entry.lastUsed = Date(); entries[key.value] = entry; accessDirty = true
            // Keep exact LRU in memory. Persist each entry's access at least once
            // per minute; an abrupt exit can lose at most 60s of access recency.
            if entry.lastUsed.timeIntervalSince(persistedUses[key.value] ?? .distantPast) >= 60 { save(includeAccess: true) }
            return StudioHTTPFile(file: leased, response: response)
        } catch { try? FileManager.default.removeItem(at: leased); remove(key.value); save(); return nil }
    }
    func store(_ result: StudioHTTPFile, key: Key, epoch expected: Int, now: Date = Date()) {
        guard available() else { return }
        load()
        guard expected == epoch, limit > 0,
              let bytes = try? result.file.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0, Int64(bytes) <= limit else { return }
        let staging = directory.appendingPathComponent("pending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try prepareDirectory()
            try FileManager.default.copyItem(at: result.file, to: staging)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
            remove(key.value)
            try FileManager.default.moveItem(at: staging, to: file(key.value))
            var headers: [String: String] = [:]
            for name in ["ETag", "Last-Modified"] {
                if let value = result.response.value(forHTTPHeaderField: name), value.utf8.count <= 1024 { headers[name] = value }
            }
            entries[key.value] = Entry(key: key.value, owner: key.owner, mime: StudioMediaFiles.mime(result), bytes: Int64(bytes), headers: headers, lastUsed: now)
            writes[key.value] = UUID()
            dirty = true; trim(now: now); save()
        } catch { /* A cache failure must not turn a successful media read into an error. */ }
    }
    func remove(_ key: Key) { load(); remove(key.value); save() }
    @discardableResult func remove(_ key: Key, ifUnchanged expected: Version) -> Bool {
        guard available() else { return false }
        load()
        // Compare and delete without suspension in this actor. An absent entry's
        // snapshot also cannot delete a later first write, or a relocated cache.
        guard expected.epoch == epoch, expected.write == writes[key.value] else { return false }
        let removed = remove(key.value); save(); return removed
    }
    func clear(owner: String? = nil) {
        load(); epoch += 1
        for entry in Array(entries.values) where owner == nil || entry.owner == owner { remove(entry.key) }
        save()
    }
    func configure(limitMB: Int, days: Int) {
        load(); epoch += 1; limit = Int64(max(0, limitMB)) * 1024 * 1024; self.days = days
        trim(); save()
    }
    func stats() -> Stats {
        guard available() else { return Stats(bytes: 0, files: 0, available: false) }
        load(); trim(); save()
        return Stats(bytes: entries.values.reduce(0) { $0 + $1.bytes }, files: entries.count, available: true)
    }
}
