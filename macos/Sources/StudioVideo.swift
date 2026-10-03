import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Combine

struct StudioVideoChunk {
    let data: Data
    let total: Int64
    let mime: String
    static func totalSize(_ header: String, range: Range<Int64>) -> Int64? {
        let prefix = "bytes \(range.lowerBound)-\(range.upperBound - 1)/"
        guard header.hasPrefix(prefix), let total = Int64(header.dropFirst(prefix.count)), total >= range.upperBound else { return nil }
        return total
    }
}

// One small, bounded cache per active stream; closing it cancels all requests.
// The same reader supports poster extraction and click-to-play previews.
@MainActor final class StudioVideoReader {
    nonisolated static let chunkSize: Int64 = 512 * 1024
    private let api: StudioClient
    private let session: StudioSession
    private let workspace: String
    private let url: String
    private let byteBudget: Int64
    private var usedBytes: Int64 = 0
    private var closed = false
    private var info: StudioVideoChunk?
    private let onRemoteError: ((Error) async -> Void)?
    private let localLoader: (() async throws -> StudioHTTPFile?)?
    private var localTask: Task<StudioHTTPFile?, Error>?
    private var localFile: StudioHTTPFile?
    private let cache = NSCache<NSString, NSData>()
    private var pending: [String: Task<StudioVideoChunk, Error>] = [:]
    init(api: StudioClient, session: StudioSession, workspace: String, url: String, byteBudget: Int64, localLoader: (() async throws -> StudioHTTPFile?)? = nil, onRemoteError: ((Error) async -> Void)? = nil) {
        self.localLoader = localLoader; self.onRemoteError = onRemoteError
        self.api = api; self.session = session; self.workspace = workspace; self.url = url; self.byteBudget = byteBudget
        cache.countLimit = 8; cache.totalCostLimit = 4 * 1024 * 1024
    }
    func metadata() async throws -> StudioVideoChunk {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if let info { return info }
        let result = try await fetch(0..<1)
        guard !closed else { throw CancellationError() }
        info = result
        return result
    }
    func read(offset: Int64, length: Int) async throws -> Data {
        let info = try await metadata()
        guard offset >= 0, offset < info.total, length > 0 else { throw StudioError.invalidResponse }
        let start = offset / Self.chunkSize * Self.chunkSize
        let end = min(info.total, start + Self.chunkSize)
        let key = "\(start)-\(end)"
        let data: Data
        if let cached = cache.object(forKey: key as NSString) { data = cached as Data }
        else {
            let chunk = try await fetch(start..<end)
            guard chunk.total == info.total, chunk.mime == info.mime else { throw StudioError.invalidResponse }
            data = chunk.data
            cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let local = Int(offset - start), count = min(length, data.count - local)
        return data.subdata(in: local..<(local + count))
    }
    private func fetch(_ range: Range<Int64>) async throws -> StudioVideoChunk {
        guard !closed else { throw CancellationError() }
        if let localLoader {
            if localTask == nil { localTask = Task { try await localLoader() } }
            if let local = try await localTask?.value {
                guard !closed, !Task.isCancelled else { try? FileManager.default.removeItem(at: local.file); throw CancellationError() }
                localFile = local
                let result = try await Task.detached(priority: .userInitiated) {
                    let total = Int64(try local.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                    guard range.lowerBound >= 0, range.upperBound <= total else { throw StudioError.invalidResponse }
                    let handle = try FileHandle(forReadingFrom: local.file)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(range.lowerBound))
                    let data = try handle.read(upToCount: range.count) ?? Data()
                    guard data.count == range.count else { throw StudioError.invalidResponse }
                    return StudioVideoChunk(data: data, total: total, mime: StudioMediaFiles.mime(local))
                }.value
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                return result
            }
        }
        let key = "\(range.lowerBound)-\(range.upperBound)"
        if let task = pending[key] { return try await task.value }
        let count = Int64(range.count)
        guard count <= byteBudget - usedBytes else { throw StudioError.tooLarge }
        usedBytes += count
        let task = Task { try await api.videoRange(url, session: session, workspace: workspace, range: range) }
        pending[key] = task
        defer { pending.removeValue(forKey: key) }
        let result: StudioVideoChunk
        do { result = try await task.value }
        catch { await onRemoteError?(error); throw error }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return result
    }
    func cancel() {
        closed = true
        localTask?.cancel()
        if let localFile { try? FileManager.default.removeItem(at: localFile.file) }
        localFile = nil
        for task in pending.values { task.cancel() }
        pending.removeAll(); cache.removeAllObjects(); info = nil
    }
}

// AVFoundation's Objective-C delegate is not actor annotated. Its callbacks are
// explicitly delivered on .main below, matching the isolated state here.
@MainActor final class StudioVideoStream: NSObject, @preconcurrency AVAssetResourceLoaderDelegate {
    let asset: AVURLAsset
    let reader: StudioVideoReader
    var onError: ((Error) -> Void)?
    private var closed = false
    private var cancelPoster: (() -> Void)?
    private var requests: [ObjectIdentifier: (AVAssetResourceLoadingRequest, Task<Void, Never>)] = [:]
    init(reader: StudioVideoReader) {
        self.reader = reader
        asset = AVURLAsset(url: URL(string: "kaki-video://preview/\(UUID().uuidString).mp4")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: .main)
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard !closed else { request.finishLoading(with: CancellationError()); return true }
        let key = ObjectIdentifier(request)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.requests.removeValue(forKey: key) }
            do {
                let metadata = try await self.reader.metadata()
                try Task.checkCancellation()
                guard !request.isCancelled, !self.closed else { return }
                if let content = request.contentInformationRequest {
                    content.contentType = UTType(mimeType: metadata.mime)?.identifier ?? UTType.movie.identifier
                    content.contentLength = metadata.total
                    content.isByteRangeAccessSupported = true
                }
                if let data = request.dataRequest {
                    guard data.requestedOffset >= 0, data.requestedLength >= 0 else { throw StudioError.invalidResponse }
                    let (requestedEnd, overflow) = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
                    guard !overflow else { throw StudioError.invalidResponse }
                    let end = data.requestsAllDataToEndOfResource ? metadata.total : min(metadata.total, requestedEnd)
                    var offset = max(data.requestedOffset, data.currentOffset)
                    while offset < end {
                        try Task.checkCancellation()
                        guard !request.isCancelled, !self.closed else { return }
                        let chunk = try await self.reader.read(offset: offset, length: Int(min(end - offset, StudioVideoReader.chunkSize)))
                        try Task.checkCancellation()
                        guard !request.isCancelled, !self.closed else { return }
                        data.respond(with: chunk); offset += Int64(chunk.count)
                    }
                }
                if !request.isCancelled, !request.isFinished { request.finishLoading() }
            } catch {
                if !request.isCancelled, !request.isFinished { request.finishLoading(with: error) }
                if !(error is CancellationError), !self.closed { self.onError?(error) }
            }
        }
        requests[key] = (request, task)
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        requests.removeValue(forKey: ObjectIdentifier(request))?.1.cancel()
    }
    func cancel() {
        closed = true
        let active = Array(requests.values); requests.removeAll()
        cancelPoster?(); cancelPoster = nil
        for (request, task) in active {
            task.cancel()
            if !request.isCancelled, !request.isFinished { request.finishLoading(with: CancellationError()) }
        }
        reader.cancel(); asset.cancelLoading(); asset.resourceLoader.setDelegate(nil, queue: nil)
    }
    func poster() async throws -> NSImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 280, height: 280)
        // A key frame near the beginning avoids scanning the entire timeline.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let result = StudioVideoPosterResult()
        let previousError = onError
        onError = { error in result.finish(.failure(error)); previousError?(error) }
        cancelPoster = { result.finish(.failure(CancellationError())) }
        let timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
            result.finish(.failure(StudioError.previewUnavailable))
            generator.cancelAllCGImageGeneration(); self?.cancel()
        }
        defer { onError = previousError; timeout.cancel(); generator.cancelAllCGImageGeneration(); cancel() }
        return try await withTaskCancellationHandler(operation: {
            let image: CGImage = try await withCheckedThrowingContinuation { continuation in
                result.start(continuation)
                if Task.isCancelled { result.finish(.failure(CancellationError())); return }
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, status, error in
                    if status == .succeeded, let image { result.finish(.success(image)) }
                    else { result.finish(.failure(error ?? StudioError.previewUnavailable)) }
                }
            }
            try Task.checkCancellation()
            return NSImage(cgImage: image, size: .zero)
        }, onCancel: {
            result.finish(.failure(CancellationError()))
            generator.cancelAllCGImageGeneration()
            Task { @MainActor [weak self] in self?.cancel() }
        })
    }
}

// AVFoundation completion and cancellation may arrive on different queues.
// Resolve once, including when cancellation precedes registration; do not rely
// on the decoder callback to unblock a closed or unauthorized preview.
private final class StudioVideoPosterResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var outcome: Result<CGImage, Error>?
    func start(_ continuation: CheckedContinuation<CGImage, Error>) {
        lock.lock()
        if let outcome { lock.unlock(); continuation.resume(with: outcome) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let continuation = continuation; self.continuation = nil
        lock.unlock(); continuation?.resume(with: result)
    }
}

@MainActor final class StudioVideoPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var error = ""
    private var stream: StudioVideoStream?
    private var observation: NSKeyValueObservation?
    private weak var studio: StudioStore?
    func start(_ asset: StudioAsset, studio: StudioStore) {
        stop(); error = ""; self.studio = studio
        do {
            let stream = try studio.videoStream(asset) { [weak self] error in self?.fail(error) }
            self.stream = stream
            let item = AVPlayerItem(asset: stream.asset)
            item.preferredForwardBufferDuration = 3
            observation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed {
                    Task { @MainActor in
                        guard self?.player?.currentItem === item else { return }
                        self?.fail(StudioError.previewUnavailable)
                    }
                }
            }
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = true
            self.player = player; player.play()
        } catch { fail(error) }
    }
    private func fail(_ failure: Error) {
        guard error.isEmpty else { return }
        error = (failure as? StudioError)?.localizedDescription ?? StudioError.previewUnavailable.localizedDescription
        stop()
    }
    func stop() {
        observation?.invalidate(); observation = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        if let stream { studio?.releaseVideoStream(stream) }
        stream = nil
    }
}
