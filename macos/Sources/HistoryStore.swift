import Foundation
import AppKit
import Combine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

private struct HistorySnapshot: Codable {
    var items: [HistoryItem]
    var boards: [String]
    init(items: [HistoryItem], boards: [String]) { self.items = items; self.boards = boards }
    private enum CodingKeys: String, CodingKey { case items, boards }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode([HistoryItem].self, forKey: .items)
        boards = try values.decodeIfPresent([String].self, forKey: .boards) ?? []
    }
}
private struct ImageResult {
    let hash: String
    let bytes: Int
}
private final class ImageJob: @unchecked Sendable {
    let id: String
    let temporary: URL
    let reservation: Int
    private let lock = NSLock()
    private var data: Data?
    private var cancelled = false
    private var result: Result<ImageResult, Error>?
    init(id: String, data: Data, temporary: URL, reservation: Int) {
        self.id = id; self.data = data; self.temporary = temporary; self.reservation = reservation
    }
    func input() -> Data? { lock.lock(); defer { lock.unlock() }; return cancelled ? nil : data }
    func cancel() { lock.lock(); cancelled = true; data = nil; result = nil; lock.unlock() }
    func finish(_ outcome: Result<ImageResult, Error>) {
        lock.lock(); data = nil
        if !cancelled { result = outcome }
        let discard = cancelled
        lock.unlock()
        if discard { try? FileManager.default.removeItem(at: temporary) }
    }
    func outcome() -> Result<ImageResult, Error>? { lock.lock(); defer { lock.unlock() }; return result }
}
private enum HistoryFailure: LocalizedError {
    case invalidImage, imageTooLarge, imageQueueFull, imageProcessing, unavailableHistory
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取图片内容。"
        case .imageTooLarge: return "图片超过 4000 万像素或 160 MiB，未加入历史。"
        case .imageQueueFull: return "图片处理队列已达到 384 MiB，请稍后重新复制。"
        case .imageProcessing: return "图片正在处理，请完成后再次收藏。"
        case .unavailableHistory: return "历史文件无法恢复，已停止写入以保护原文件。"
        }
    }
}
enum ImageCodec {
    static let maximumPixels = 40_000_000
    static let maximumBytes = 160 * 1024 * 1024
    static func dimensions(_ data: Data) throws -> ImageDimensions {
        guard data.count <= maximumBytes else { throw HistoryFailure.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw HistoryFailure.invalidImage }
        guard width <= maximumPixels / height else { throw HistoryFailure.imageTooLarge }
        return ImageDimensions(width: width, height: height)
    }
    static func png(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw HistoryFailure.invalidImage
        }
        if CGImageSourceGetType(source) as String? == UTType.png.identifier { return data }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw HistoryFailure.invalidImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw HistoryFailure.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw HistoryFailure.invalidImage }
        guard output.length <= maximumBytes else { throw HistoryFailure.imageTooLarge }
        return output as Data
    }
    static func thumbnail(file: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 280,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var boards: [String] = []
    @Published private(set) var lastError: String?
    private(set) var isReadOnly = false
    private(set) var pendingImageBytes = 0
    var onError: ((String) -> Void)?
    let directory: URL
    private let images: URL
    private let history: URL
    private let limit: Int
    private let imageBudget: Int
    private let queue = DispatchQueue(label: "com.kakitools.history", qos: .utility)
    private var pending: [String: ImageJob] = [:]
    private var persistWork: DispatchWorkItem?
    private var thumbnails: [String: NSImage] = [:]
    private var thumbnailOrder: [String] = []
    private var loadingThumbnails: Set<String> = []

    init(directory: URL, limit: Int = 100, imageBudget: Int = 384 * 1024 * 1024) {
        self.directory = directory
        self.images = directory.appendingPathComponent("images", isDirectory: true)
        self.history = directory.appendingPathComponent("history.json")
        self.limit = min(100, max(1, limit))
        self.imageBudget = imageBudget
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try load()
            cleanupTemporaryImages()
            trim()
        } catch {
            isReadOnly = true
            lastError = "历史加载失败，原文件保持完整：\(error.localizedDescription)"
        }
    }
    private func load() throws {
        let manager = FileManager.default
        let hasPrimary = manager.fileExists(atPath: history.path)
        let backupFile = directory.appendingPathComponent("history.backup.json")
        guard hasPrimary || manager.fileExists(atPath: backupFile.path) else { return }
        let backup = directory.appendingPathComponent("native-import-backup", isDirectory: true)
        if !manager.fileExists(atPath: backup.path) {
            let staging = directory.appendingPathComponent("native-import-backup.\(UUID().uuidString).pending", isDirectory: true)
            do {
                try manager.createDirectory(at: staging, withIntermediateDirectories: false)
                if hasPrimary { try manager.copyItem(at: history, to: staging.appendingPathComponent("history.json")) }
                let oldBackup = directory.appendingPathComponent("history.backup.json")
                if manager.fileExists(atPath: oldBackup.path) {
                    try manager.copyItem(at: oldBackup, to: staging.appendingPathComponent("history.backup.json"))
                }
                try manager.copyItem(at: images, to: staging.appendingPathComponent("images"))
                try manager.moveItem(at: staging, to: backup)
            } catch { try? manager.removeItem(at: staging); throw error }
        }
        let decoder = JSONDecoder()
        let snapshot: HistorySnapshot
        do { snapshot = try decoder.decode(HistorySnapshot.self, from: Data(contentsOf: history)) }
        catch {
            let preserved = directory.appendingPathComponent("history.unreadable.\(UUID().uuidString).json")
            if hasPrimary { try manager.copyItem(at: history, to: preserved) }
            snapshot = try decoder.decode(HistorySnapshot.self, from: Data(contentsOf: backupFile))
            lastError = "主历史文件无法解析，已保留原文件并从备份恢复。"
        }
        items = snapshot.items.map { original in
            var item = original
            if item.type == "image", let file = item.file, !file.isEmpty {
                item.file = images.appendingPathComponent(URL(fileURLWithPath: file).lastPathComponent).path
            }
            return item
        }
        boards = snapshot.boards
    }
    private func cleanupTemporaryImages() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: images,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for file in files where file.lastPathComponent.hasSuffix(".png.pending") {
            let base = String(file.lastPathComponent.dropLast(".png.pending".count))
            guard UUID(uuidString: base) != nil,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
    private func report(_ error: Error) { lastError = error.localizedDescription; onError?(error.localizedDescription) }
    private func mayWrite() -> Bool {
        if isReadOnly { report(HistoryFailure.unavailableHistory); return false }
        return true
    }
    private func changed() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistAsync() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    private func snapshotData() throws -> Data {
        try JSONEncoder().encode(HistorySnapshot(items: items.filter { pending[$0.id] == nil }, boards: boards))
    }
    private func persistAsync() {
        guard !isReadOnly else { return }
        do {
            let payload = try snapshotData(), file = history
            queue.async { [weak self] in
                do {
                    try payload.write(to: file, options: .atomic)
                } catch { DispatchQueue.main.async { self?.report(error) } }
            }
        } catch { report(error) }
    }
    func flush() {
        persistWork?.cancel(); persistWork = nil
        guard !isReadOnly else { return }
        queue.sync {}
        for job in Array(pending.values) { complete(job) }
        do {
            let payload = try snapshotData()
            try queue.sync { try payload.write(to: history, options: .atomic) }
        } catch { report(error) }
    }
    func isPending(id: String) -> Bool { pending[id] != nil }
    func item(id: String) -> HistoryItem? {
        // Interactive actions must never wait for every encoded image. A completed
        // item is published by the main-queue callback; callers can retry then.
        guard !isPending(id: id) else { return nil }
        return items.first { $0.id == id }
    }
    func addText(_ text: String, html: String? = nil, rtf: String? = nil, rtfData: Data? = nil) {
        guard mayWrite(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let html = html.flatMap { $0.utf8.count < 512 * 1024 ? $0 : nil }
        let rtf = rtf.flatMap { $0.utf8.count < 512 * 1024 ? $0 : nil }
        let rtfData = rtfData.flatMap { $0.count < 512 * 1024 ? $0 : nil }
        if let head = items.first(where: { $0.board == nil }), head.type == "text", head.text == text,
           head.html == html, head.rtf == rtf, head.rtfData == rtfData { return }
        if let index = items.firstIndex(where: { $0.board == nil && $0.type == "text" && $0.text == text }) {
            var item = items.remove(at: index)
            item.html = html; item.rtf = rtf; item.rtfData = rtfData; item.createdAt = Date().timeIntervalSince1970 * 1000
            items.insert(item, at: 0)
        } else { items.insert(HistoryItem(text: text, html: html, rtf: rtf, rtfData: rtfData), at: 0) }
        trim(); changed()
    }
    @discardableResult
    func captureImage(data: Data) -> Bool {
        guard mayWrite() else { return false }
        do {
            let size = try ImageCodec.dimensions(data)
            let reservation = max(size.width * size.height * 8, data.count)
            guard pendingImageBytes + reservation <= imageBudget else { throw HistoryFailure.imageQueueFull }
            let item = HistoryItem(type: "image", size: size, bytes: 0)
            let file = images.appendingPathComponent(item.id + ".png")
            let temporary = images.appendingPathComponent(item.id + ".png.pending")
            var record = item; record.file = file.path
            let job = ImageJob(id: item.id, data: data, temporary: temporary, reservation: reservation)
            pending[item.id] = job; pendingImageBytes += reservation
            items.insert(record, at: 0); changed()
            queue.async { [weak self] in
                autoreleasepool {
                    guard let input = job.input() else { return }
                    do {
                        let png = try ImageCodec.png(input)
                        guard png.count <= ImageCodec.maximumBytes else { throw HistoryFailure.imageTooLarge }
                        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
                        try png.write(to: job.temporary, options: .atomic)
                        job.finish(.success(ImageResult(hash: hash, bytes: png.count)))
                    } catch { job.finish(.failure(error)) }
                }
                DispatchQueue.main.async { self?.complete(job) }
            }
            return true
        } catch { report(error); return false }
    }
    private func release(_ job: ImageJob) {
        guard pending.removeValue(forKey: job.id) != nil else { return }
        pendingImageBytes -= job.reservation
        job.cancel()
        try? FileManager.default.removeItem(at: job.temporary)
    }
    private func complete(_ job: ImageJob) {
        guard pending[job.id] === job, let result = job.outcome(), let index = items.firstIndex(where: { $0.id == job.id }) else { return }
        do {
            let image = try result.get()
            if let duplicate = items.first(where: { $0.id != job.id && $0.board == nil && $0.type == "image" && $0.hash == image.hash }) {
                removeInternal(id: job.id); touch(id: duplicate.id); return
            }
            guard let path = items[index].file else { throw HistoryFailure.invalidImage }
            try FileManager.default.moveItem(at: job.temporary, to: URL(fileURLWithPath: path))
            items[index].hash = image.hash; items[index].bytes = image.bytes
            release(job); trim(); changed()
        } catch { removeInternal(id: job.id); report(error); changed() }
    }
    private func trim() {
        let ordinary = items.filter { $0.board == nil && !$0.pinned && pending[$0.id] == nil }
        for item in ordinary.dropFirst(limit) { removeInternal(id: item.id) }
        if ordinary.count > limit { changed() }
    }
    private func removeInternal(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        if let job = pending[id] { release(job) }
        thumbnails[id] = nil; thumbnailOrder.removeAll { $0 == id }
        if item.type == "image", let path = item.file {
            for suffix in ["", ".thumb", ".thumbnail.png"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
    }
    func remove(id: String) { guard mayWrite() else { return }; removeInternal(id: id); changed() }
    func touch(id: String) {
        guard mayWrite(), let index = items.firstIndex(where: { $0.id == id }), items[index].board == nil else { return }
        var item = items.remove(at: index); item.createdAt = Date().timeIntervalSince1970 * 1000
        items.insert(item, at: 0); changed()
    }
    func togglePin(id: String) {
        guard mayWrite(), let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle(); trim(); changed()
    }
    @discardableResult
    func createBoard(_ name: String) -> String? {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
        guard mayWrite(), !name.isEmpty, !boards.contains(name) else { return nil }
        boards.append(name); changed(); return name
    }
    func renameBoard(_ name: String, to replacement: String) {
        let replacement = String(replacement.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
        guard mayWrite(), !replacement.isEmpty, let index = boards.firstIndex(of: name), !boards.contains(replacement) else { return }
        boards[index] = replacement
        for index in items.indices where items[index].board == name { items[index].board = replacement }
        changed()
    }
    func deleteBoard(_ name: String) {
        guard mayWrite() else { return }
        for item in items.filter({ $0.board == name }) { removeInternal(id: item.id) }
        boards.removeAll { $0 == name }; changed()
    }
    func addToBoard(id: String, board: String) {
        guard mayWrite(), boards.contains(board) else { return }
        if isPending(id: id) { report(HistoryFailure.imageProcessing); return }
        guard let source = item(id: id),
              !items.contains(where: { $0.board == board && ($0.type == "text" && $0.text == source.text || $0.type == "image" && $0.hash == source.hash) }) else { return }
        var clone = source; clone.id = UUID().uuidString.lowercased(); clone.board = board
        clone.pinned = false; clone.createdAt = Date().timeIntervalSince1970 * 1000
        if source.type == "image", let path = source.file {
            let destination = images.appendingPathComponent(clone.id + ".png")
            do { try FileManager.default.copyItem(atPath: path, toPath: destination.path); clone.file = destination.path }
            catch { report(error); return }
            for suffix in [".thumb", ".thumbnail.png"] {
                if FileManager.default.fileExists(atPath: path + suffix) {
                    try? FileManager.default.copyItem(atPath: path + suffix, toPath: destination.path + suffix)
                }
            }
        }
        items.insert(clone, at: 0); changed()
    }
    func updateMetadata(id: String, tags: [String], note: String) {
        guard mayWrite(), let index = items.firstIndex(where: { $0.id == id }) else { return }
        var seen: Set<String> = []
        let cleanTags = tags.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20)) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(8)
        let cleanNote = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
        items[index].tags = cleanTags.isEmpty ? nil : Array(cleanTags)
        items[index].note = cleanNote.isEmpty ? nil : cleanNote; changed()
    }
    func clearHistory() {
        guard mayWrite() else { return }
        for item in items.filter({ $0.board == nil }) { removeInternal(id: item.id) }
        changed()
    }
    func thumbnail(for item: HistoryItem) -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        if let value = item.thumb, let image = legacyThumbnail(value) { cache(image, id: item.id); return image }
        guard let path = item.file else { return nil }
        if let value = try? String(contentsOfFile: path + ".thumb", encoding: .utf8), let image = legacyThumbnail(value) {
            cache(image, id: item.id); return image
        }
        guard !loadingThumbnails.contains(item.id) else { return nil }
        loadingThumbnails.insert(item.id)
        let id = item.id, file = URL(fileURLWithPath: path)
        queue.async { [weak self] in
            let image = autoreleasepool { ImageCodec.thumbnail(file: file) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingThumbnails.remove(id)
                if let image, self.items.contains(where: { $0.id == id }) { self.cache(image, id: id); self.objectWillChange.send() }
            }
        }
        return nil
    }
    private func legacyThumbnail(_ value: String) -> NSImage? {
        guard let comma = value.firstIndex(of: ","), let data = Data(base64Encoded: String(value[value.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }
    private func cache(_ image: NSImage, id: String) {
        thumbnails[id] = image; thumbnailOrder.removeAll { $0 == id }; thumbnailOrder.append(id)
        while thumbnailOrder.count > 24 { thumbnails.removeValue(forKey: thumbnailOrder.removeFirst()) }
    }
}
