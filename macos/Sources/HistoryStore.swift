import Foundation
import AppKit
import Combine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

private struct HistorySnapshot: Codable, Sendable {
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
    private var started = false
    private var workerEnded = false
    private var reservationReleased = false
    private var result: Result<ImageResult, Error>?
    init(id: String, data: Data, temporary: URL, reservation: Int) {
        self.id = id; self.data = data; self.temporary = temporary; self.reservation = reservation
    }
    func input() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return nil }
        started = true
        return data
    }
    // A running worker owns a local Data copy and decoder allocations even after
    // cancellation clears this job's copy. Release only after its pool has drained.
    func endProcessing() {
        lock.lock(); workerEnded = true
        let discard = cancelled
        lock.unlock()
        if discard { try? FileManager.default.removeItem(at: temporary) }
    }
    func takeReleasedReservation() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !reservationReleased, !started || workerEnded else { return nil }
        reservationReleased = true
        return reservation
    }
    func cancel() {
        lock.lock(); cancelled = true; data = nil; result = nil
        let discard = !started || workerEnded
        lock.unlock()
        if discard { try? FileManager.default.removeItem(at: temporary) }
    }
    func finish(_ outcome: Result<ImageResult, Error>) {
        lock.lock(); data = nil
        if !cancelled { result = outcome }
        lock.unlock()
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
    private(set) var revision = 0
    @Published private(set) var items: [HistoryItem] = [] { didSet { revision &+= 1 } }
    @Published private(set) var boards: [String] = [] { didSet { revision &+= 1 } }
    @Published private(set) var lastError: String?
    private(set) var isReadOnly = false
    @Published private(set) var loading = false
    @Published private(set) var contentBytes: Int64 = 0
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var pendingImageBytes = 0
    let thumbnailChanges = PassthroughSubject<String, Never>()
    var onError: ((String) -> Void)?
    let directory: URL
    private let images: URL
    private let history: URL
    private let limit: Int
    private let imageBudget: Int
    private let imageProcessor: @Sendable (Data) throws -> Data
    private let queue = DispatchQueue(label: "com.kakitools.history", qos: .utility)
    private var pending: [String: ImageJob] = [:]
    private var imageReservations: [String: ImageJob] = [:]
    private var deferredImageFiles: Set<String> = []
    private var persistWork: DispatchWorkItem?
    private var thumbnails: [String: NSImage] = [:]
    private var boardCopies = Set<String>()
    private var thumbnailOrder: [String] = []
    struct ThumbnailSource: Equatable {
        let file: String?; let thumb: String?; let hash: String?
        init(_ item: HistoryItem) { file = item.file; thumb = item.thumb; hash = item.hash }
    }
    private var thumbnailSources: [String: ThumbnailSource] = [:]
    private var loadingThumbnails: [String: UUID] = [:]

    init(directory: URL, limit: Int = 100, imageBudget: Int = 384 * 1024 * 1024, deferredLoading: Bool = false,
         imageProcessor: @escaping @Sendable (Data) throws -> Data = { try ImageCodec.png($0) }) {
        self.directory = directory
        self.images = directory.appendingPathComponent("images", isDirectory: true)
        self.history = directory.appendingPathComponent("history.json")
        self.limit = min(100, max(1, limit))
        self.imageBudget = imageBudget
        self.imageProcessor = imageProcessor
        if deferredLoading {
            loading = true
            let imageDirectory = images, historyFile = history
            queue.async { [weak self] in
                let result = Result { () -> (HistorySnapshot?, String?, Set<String>, Int64) in
                    try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
                    let (snapshot, warning) = try Self.readHistory(directory: directory, images: imageDirectory, history: historyFile)
                    let candidates = Self.temporaryImages(images: imageDirectory, items: snapshot?.items ?? [])
                    return (snapshot, warning, candidates, Self.contentSize(snapshot?.items ?? []))
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let (snapshot, warning, candidates, bytes)):
                        self.contentBytes = bytes
                        self.applyHistory(snapshot, warning: warning)
                        self.deferredImageFiles.formUnion(candidates)
                        self.loading = false; self.trim()
                    case .failure(let error):
                        self.isReadOnly = true; self.loading = false
                        self.lastError = "历史加载失败，原文件保持完整：\(error.localizedDescription)"
                        self.onError?(self.lastError!)
                    }
                    let waiters = self.loadWaiters; self.loadWaiters.removeAll()
                    for waiter in waiters { waiter.resume() }
                }
            }
        } else {
            do {
                try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
                let (snapshot, warning) = try Self.readHistory(directory: directory, images: images, history: history)
                contentBytes = Self.contentSize(snapshot?.items ?? [])
                applyHistory(snapshot, warning: warning)
                deferredImageFiles.formUnion(Self.temporaryImages(images: images, items: items))
                trim()
            } catch {
                isReadOnly = true
                lastError = "历史加载失败，原文件保持完整：\(error.localizedDescription)"
            }
        }
    }
    func waitUntilLoaded() async {
        guard loading else { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }
    private nonisolated static func readHistory(directory: URL, images: URL, history: URL) throws -> (HistorySnapshot?, String?) {
        let manager = FileManager.default
        let hasPrimary = manager.fileExists(atPath: history.path)
        let backupFile = directory.appendingPathComponent("history.backup.json")
        guard hasPrimary || manager.fileExists(atPath: backupFile.path) else { return (nil, nil) }
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
        var warning: String?
        do { snapshot = try decoder.decode(HistorySnapshot.self, from: Data(contentsOf: history)) }
        catch {
            let preserved = directory.appendingPathComponent("history.unreadable.\(UUID().uuidString).json")
            if hasPrimary { try manager.copyItem(at: history, to: preserved) }
            snapshot = try decoder.decode(HistorySnapshot.self, from: Data(contentsOf: backupFile))
            warning = "主历史文件无法解析，已保留原文件并从备份恢复。"
        }
        return (snapshot, warning)
    }
    private func applyHistory(_ snapshot: HistorySnapshot?, warning: String?) {
        lastError = warning
        guard let snapshot else { return }
        items = snapshot.items.map { original in
            var item = original
            if item.type == "image", let file = item.file, !file.isEmpty {
                item.file = images.appendingPathComponent(URL(fileURLWithPath: file).lastPathComponent).path
            }
            return item
        }
        boards = snapshot.boards
    }
    private nonisolated static func temporaryImages(images: URL, items: [HistoryItem]) -> Set<String> {
        var candidates = Set<String>()
        guard let files = try? FileManager.default.contentsOfDirectory(at: images,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return candidates }
        let liveFiles = Set(items.compactMap { $0.file.map { URL(fileURLWithPath: $0).lastPathComponent } })
        for file in files where file.pathExtension == "png" && !liveFiles.contains(file.lastPathComponent) {
            // Recover payloads left by a crash after an index commit, without
            // touching unrelated legacy files or the independent import backup.
            if UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                candidates.insert(file.path)
            }
        }
        for file in files where file.lastPathComponent.hasSuffix(".png.pending") {
            let base = String(file.lastPathComponent.dropLast(".png.pending".count))
            guard UUID(uuidString: base) != nil,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: file)
        }
        return candidates
    }
    private func report(_ error: Error) { lastError = error.localizedDescription; onError?(error.localizedDescription) }
    private func mayWrite() -> Bool {
        if loading { return false }
        if isReadOnly { report(HistoryFailure.unavailableHistory); return false }
        return true
    }
    private func changed() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistAsync() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    private func snapshot() -> HistorySnapshot {
        HistorySnapshot(items: items.filter { pending[$0.id] == nil }, boards: boards)
    }
    private nonisolated static func write(_ snapshot: HistorySnapshot, to file: URL,
                                         images: URL, deleting candidates: Set<String>) throws -> Set<String> {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: file, options: .atomic)
        // The atomic primary commit is the deletion barrier. A failed commit must
        // leave every payload available to the previous primary and backup index.
        guard !candidates.isEmpty else { return [] }
        var referenced = Set(snapshot.items.filter { $0.type == "image" }.compactMap { item in
            item.file.map { URL(fileURLWithPath: $0).lastPathComponent }
        })
        let backup = file.deletingLastPathComponent().appendingPathComponent("history.backup.json")
        if FileManager.default.fileExists(atPath: backup.path) {
            // If an existing backup cannot be inspected, retain payloads rather
            // than guess. The one-time import backup owns its own image copies.
            guard let data = try? Data(contentsOf: backup),
                  let saved = try? JSONDecoder().decode(HistorySnapshot.self, from: data) else { return [] }
            referenced.formUnion(saved.items.filter { $0.type == "image" }.compactMap { item in
                item.file.map { URL(fileURLWithPath: $0).lastPathComponent }
            })
        }
        var removed: Set<String> = []
        let imageDirectory = images.standardizedFileURL
        for path in candidates {
            let payload = URL(fileURLWithPath: path).standardizedFileURL
            guard payload.deletingLastPathComponent() == imageDirectory,
                  !referenced.contains(payload.lastPathComponent) else { continue }
            var complete = true
            for suffix in ["", ".thumb", ".thumbnail.png"] {
                let target = URL(fileURLWithPath: payload.path + suffix)
                do { if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) } }
                catch { complete = false }
            }
            if complete { removed.insert(path) }
        }
        return removed
    }
    private nonisolated static func contentSize(_ items: [HistoryItem]) -> Int64 {
        var total: Int64 = 0
        for item in items {
            for bytes in [item.bytes ?? 0, item.text?.utf8.count ?? 0, item.html?.utf8.count ?? 0,
                          item.rtf?.utf8.count ?? 0, item.rtfData?.count ?? 0] {
                let (sum, overflow) = total.addingReportingOverflow(Int64(max(0, bytes)))
                if overflow { return Int64.max }
                total = sum
            }
        }
        return total
    }
    private func persistAsync() {
        guard !isReadOnly else { return }
        let snapshot = snapshot(), file = history, images = images, deleting = deferredImageFiles, currentRevision = revision
        queue.async { [weak self] in
            do {
                let removed = try Self.write(snapshot, to: file, images: images, deleting: deleting)
                let bytes = Self.contentSize(snapshot.items)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.deferredImageFiles.subtract(removed)
                    if self.revision == currentRevision && self.contentBytes != bytes { self.contentBytes = bytes }
                }
            } catch { DispatchQueue.main.async { [weak self] in self?.report(error) } }
        }
    }
    func flush() {
        guard !loading else { return }
        persistWork?.cancel(); persistWork = nil
        guard !isReadOnly else { return }
        // Drain older snapshots and image workers before collecting final values.
        queue.sync {}
        for job in Array(imageReservations.values) { settleReservation(job) }
        for job in Array(pending.values) { complete(job) }
        persistWork?.cancel(); persistWork = nil
        let final = snapshot(), file = history, images = images, deleting = deferredImageFiles
        contentBytes = Self.contentSize(final.items)
        do {
            let removed = try queue.sync { try Self.write(final, to: file, images: images, deleting: deleting) }
            deferredImageFiles.subtract(removed)
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
            pending[item.id] = job; imageReservations[item.id] = job; pendingImageBytes += reservation
            items.insert(record, at: 0); changed()
            let processor = imageProcessor
            queue.async { [weak self] in
                autoreleasepool {
                    guard let input = job.input() else { return }
                    do {
                        let png = try processor(input)
                        guard png.count <= ImageCodec.maximumBytes else { throw HistoryFailure.imageTooLarge }
                        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
                        try png.write(to: job.temporary, options: .atomic)
                        job.finish(.success(ImageResult(hash: hash, bytes: png.count)))
                    } catch { job.finish(.failure(error)) }
                }
                job.endProcessing()
                DispatchQueue.main.async { [weak self] in self?.settleReservation(job); self?.complete(job) }
            }
            return true
        } catch { report(error); return false }
    }
    private func release(_ job: ImageJob) {
        guard pending.removeValue(forKey: job.id) != nil else { return }
        job.cancel()
        settleReservation(job)
    }
    private func settleReservation(_ job: ImageJob) {
        guard let bytes = job.takeReleasedReservation() else { return }
        imageReservations.removeValue(forKey: job.id)
        pendingImageBytes -= bytes
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
            release(job); trim(); changed(); thumbnailChanges.send(job.id)
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
        thumbnails[id] = nil; thumbnailSources[id] = nil; loadingThumbnails[id] = nil; thumbnailOrder.removeAll { $0 == id }
        if item.type == "image", let path = item.file { deferredImageFiles.insert(path) }
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
    private func boardClone(id: String, board: String) -> HistoryItem? {
        guard mayWrite(), boards.contains(board) else { return nil }
        if isPending(id: id) { report(HistoryFailure.imageProcessing); return nil }
        guard let source = item(id: id),
              !items.contains(where: { $0.board == board && ($0.type == "text" && $0.text == source.text || $0.type == "image" && $0.hash == source.hash) }) else { return nil }
        var clone = source; clone.id = UUID().uuidString.lowercased(); clone.board = board
        clone.pinned = false; clone.createdAt = Date().timeIntervalSince1970 * 1000
        return clone
    }
    private nonisolated static func copyBoardImage(_ original: HistoryItem, images: URL) throws -> HistoryItem {
        var clone = original
        guard clone.type == "image", let path = clone.file else { return clone }
        let destination = images.appendingPathComponent(clone.id + ".png")
        do {
            try FileManager.default.copyItem(atPath: path, toPath: destination.path)
            clone.file = destination.path
            for suffix in [".thumb", ".thumbnail.png"] where FileManager.default.fileExists(atPath: path + suffix) {
                try? FileManager.default.copyItem(atPath: path + suffix, toPath: destination.path + suffix)
            }
            return clone
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    func addToBoard(id: String, board: String) {
        guard let clone = boardClone(id: id, board: board) else { return }
        do { items.insert(try Self.copyBoardImage(clone, images: images), at: 0); changed() }
        catch { report(error) }
    }
    func addToBoardInBackground(id: String, board: String) async {
        let key = id + "|" + board
        guard !boardCopies.contains(key), let clone = boardClone(id: id, board: board) else { return }
        boardCopies.insert(key); defer { boardCopies.remove(key) }
        let imageDirectory = images
        do {
            let copied = try await Task.detached(priority: .utility) {
                try Self.copyBoardImage(clone, images: imageDirectory)
            }.value
            guard !Task.isCancelled, boards.contains(board), let source = item(id: id),
                  source.file == clone.file, source.hash == clone.hash,
                  !items.contains(where: { $0.board == board && ($0.type == "text" && $0.text == clone.text || $0.type == "image" && $0.hash == clone.hash) }) else {
                if copied.type == "image", let path = copied.file {
                    queue.async { for suffix in ["", ".thumb", ".thumbnail.png"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
                }
                return
            }
            items.insert(copied, at: 0); changed()
        } catch { report(error) }
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
        guard pending[item.id] == nil, let current = items.first(where: { $0.id == item.id }), current.type == "image" else { return nil }
        let source = ThumbnailSource(current)
        guard source == ThumbnailSource(item) else { return nil }
        if thumbnailSources[item.id] != source {
            thumbnails[item.id] = nil; thumbnailOrder.removeAll { $0 == item.id }; loadingThumbnails[item.id] = nil
            thumbnailSources[item.id] = source
        }
        if let cached = thumbnails[item.id] { return cached }
        if let value = item.thumb, let image = legacyThumbnail(value) { cache(image, id: item.id); return image }
        guard let path = item.file else { return nil }
        if let value = try? String(contentsOfFile: path + ".thumb", encoding: .utf8), let image = legacyThumbnail(value) {
            cache(image, id: item.id); return image
        }
        guard loadingThumbnails[item.id] == nil else { return nil }
        let ticket = UUID(); loadingThumbnails[item.id] = ticket
        let id = item.id, file = URL(fileURLWithPath: path)
        queue.async { [weak self] in
            let image = autoreleasepool { ImageCodec.thumbnail(file: file) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadingThumbnails[id] == ticket else { return }
                self.loadingThumbnails[id] = nil
                if let image, let current = self.items.first(where: { $0.id == id }), ThumbnailSource(current) == source {
                    self.cache(image, id: id); self.thumbnailChanges.send(id)
                }
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
