import Foundation
import AppKit
import AVFoundation
import SwiftUI
import AVKit

private actor StudioVideoFixtureTransport: StudioTransport {
    let video: Data
    var invalidRange = false
    var ignoresRange = false
    private(set) var requests: [URLRequest] = []
    private(set) var transferred = 0
    init(video: Data) { self.video = video }
    func setInvalidRange() { invalidRange = true }
    func setIgnoresRange() { ignoresRange = true }
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile {
        try Task.checkCancellation()
        requests.append(request)
        guard let text = request.value(forHTTPHeaderField: "Range"), text.hasPrefix("bytes=") else { throw StudioError.invalidResponse }
        let bounds = text.dropFirst(6).split(separator: "-").compactMap { Int($0) }
        guard bounds.count == 2, bounds[0] >= 0, bounds[1] < video.count else { throw StudioError.invalidResponse }
        let data = video.subdata(in: bounds[0]..<(bounds[1] + 1))
        guard data.count <= maximumBytes else { throw StudioError.tooLarge }
        transferred += data.count
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-video-test-" + UUID().uuidString)
        try data.write(to: file)
        let headers = ["Content-Type": "video/mp4", "Content-Length": String(data.count), "Content-Range": invalidRange ? "bytes 0-999/1000" : "bytes \(bounds[0])-\(bounds[1])/\(video.count)"]
        return StudioHTTPFile(file: file, response: HTTPURLResponse(url: request.url!, statusCode: ignoresRange ? 200 : 206, httpVersion: nil, headerFields: headers)!)
    }
}

private func makeStudioVideoFixture(_ file: URL) async throws -> Data {
    let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? StudioError.invalidResponse }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<3 {
        var pixel: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw StudioError.invalidResponse }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            let row = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<180 {
                let line = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
                for x in 0..<320 { line[x * 4] = 255; line[x * 4 + 1] = 240; line[x * 4 + 2] = 90; line[x * 4 + 3] = 20 }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
        guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 2)) else { throw writer.error ?? StudioError.invalidResponse }
    }
    input.markAsFinished(); await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? StudioError.invalidResponse }
    let original = try Data(contentsOf: file)
    // Keep the sample offsets intact but move the metadata behind a large free
    // atom. Real frame extraction must seek to it rather than fetch the whole file.
    var offset = 0, moov: Int?
    while offset + 8 <= original.count {
        var size = original[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        if size == 1, offset + 16 <= original.count { size = original[(offset + 8)..<(offset + 16)].reduce(0) { ($0 << 8) | Int($1) } }
        guard size >= 8, size <= original.count - offset else { throw StudioError.invalidResponse }
        if String(data: original[(offset + 4)..<(offset + 8)], encoding: .ascii) == "moov" { moov = offset; break }
        offset += size
    }
    guard let moov else { throw StudioError.invalidResponse }
    let paddingSize = 8 * 1024 * 1024
    let header = withUnsafeBytes(of: UInt32(paddingSize).bigEndian) { Data($0) } + Data("free".utf8)
    return original.prefix(moov) + header + Data(repeating: 0, count: paddingSize - 8) + original.suffix(from: moov)
}

@MainActor func runStudioVideoTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-video-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = try await makeStudioVideoFixture(directory.appendingPathComponent("sample.mp4"))
    let session = StudioSession(value: "synthetic-video-session", expiresAt: Date().addingTimeInterval(600))
    let transport = StudioVideoFixtureTransport(video: video)
    let api = StudioClient(environment: .test, transport: transport)
    let reader = StudioVideoReader(api: api, session: session, workspace: "ws-video", url: "/api/private-files/video", byteBudget: 4 * 1024 * 1024)
    let stream = StudioVideoStream(reader: reader)
    let poster = try await stream.poster()
    try check(poster.size.width > 0 && poster.size.width <= 280 && poster.size.height <= 280, "real video decoder extracts a bounded poster through authenticated ranges")
    let requests = await transport.requests
    let transferred = await transport.transferred
    try check(transferred < video.count / 2 && transferred <= 4 * 1024 * 1024, "tail metadata is reached without downloading the full eight MiB video")
    try check(requests.allSatisfy { $0.value(forHTTPHeaderField: "Range") != nil && $0.value(forHTTPHeaderField: "Cookie") == "kaki_session=synthetic-video-session" && $0.value(forHTTPHeaderField: "X-Workspace-Id") == "ws-video" }, "video ranges retain private-file authorization without exposing it to AVFoundation")
    do { _ = try await reader.metadata(); throw NativeTestFailure(description: "Cancelled reader remained active") }
    catch is CancellationError { try check(true, "poster completion releases its reader and cached video bytes") }

    let cached = StudioVideoFixtureTransport(video: video)
    let cachedAPI = StudioClient(environment: .test, transport: cached)
    let cachedReader = StudioVideoReader(api: cachedAPI, session: session, workspace: "ws-video", url: "/api/private-files/video", byteBudget: 4 * 1024 * 1024)
    let first = try await cachedReader.read(offset: 100, length: 20)
    let second = try await cachedReader.read(offset: 120, length: 20)
    let cachedCount = await cached.requests.count
    try check(first == video.subdata(in: 100..<120) && second == video.subdata(in: 120..<140) && cachedCount == 2, "neighboring reads reuse one bounded chunk after the metadata probe")
    cachedReader.cancel()
    let external = StudioVideoFixtureTransport(video: video)
    _ = try await StudioClient(environment: .test, transport: external).videoRange("https://cdn.example.invalid/video.mp4", session: session, workspace: "ws-video", range: 0..<1)
    let externalRequest = await external.requests[0]
    try check(externalRequest.value(forHTTPHeaderField: "Cookie") == nil && externalRequest.value(forHTTPHeaderField: "X-Workspace-Id") == nil, "CDN video requests do not receive Studio identity")
    let malformed = StudioVideoFixtureTransport(video: video); await malformed.setInvalidRange()
    do { _ = try await StudioClient(environment: .test, transport: malformed).videoRange("/api/private-files/video", session: session, workspace: "ws-video", range: 0..<1); throw NativeTestFailure(description: "Mismatched range accepted") }
    catch StudioError.previewUnavailable { try check(true, "inconsistent byte ranges fail safely") }
    let ignored = StudioVideoFixtureTransport(video: video); await ignored.setIgnoresRange()
    do { _ = try await StudioClient(environment: .test, transport: ignored).videoRange("/api/private-files/video", session: session, workspace: "ws-video", range: 0..<1); throw NativeTestFailure(description: "Full-file response accepted") }
    catch StudioError.previewUnavailable { try check(true, "servers ignoring Range cannot trigger a full-video preview download") }
    let budgetTransport = StudioVideoFixtureTransport(video: video)
    let budgetReader = StudioVideoReader(api: StudioClient(environment: .test, transport: budgetTransport), session: session, workspace: "ws-video", url: "/api/private-files/video", byteBudget: 10)
    do { _ = try await budgetReader.read(offset: 0, length: 20); throw NativeTestFailure(description: "Poster budget exceeded") }
    catch StudioError.tooLarge { try check(true, "poster byte budget is enforced before issuing the oversized range") }
    let budgetRequests = await budgetTransport.requests.count
    try check(budgetRequests == 1, "failed poster budget leaves only the one-byte metadata probe")
    budgetReader.cancel()
    let playbackTransport = StudioVideoFixtureTransport(video: video)
    let playbackStream = StudioVideoStream(reader: StudioVideoReader(api: StudioClient(environment: .test, transport: playbackTransport), session: session, workspace: "ws-video", url: "/api/private-files/video", byteBudget: 32 * 1024 * 1024))
    let item = AVPlayerItem(asset: playbackStream.asset)
    item.preferredForwardBufferDuration = 3
    let player = AVPlayer(playerItem: item); player.isMuted = true
    player.play()
    for _ in 0..<200 {
        if item.status != .unknown { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try check(item.status == .readyToPlay, "native player becomes ready through the same guarded video stream")
    try await renderStudioVideoPlayer(player)
    player.pause(); player.replaceCurrentItem(with: nil); playbackStream.cancel()
    let stopped = await playbackTransport.requests.count
    try await Task.sleep(nanoseconds: 80_000_000)
    let afterStop = await playbackTransport.requests.count
    try check(stopped == afterStop, "closing playback stops subsequent video requests")
    // Exercise the real native decoder/player against a complete disk-cached movie,
    // including cache cleanup during playback. Synthetic byte reads alone are insufficient.
    let cachedMovie = directory.appendingPathComponent("cached-full.mp4")
    try video.write(to: cachedMovie)
    let movieURL = StudioEnvironment.test.baseURL.appendingPathComponent("api/private-files/video")
    let movieResponse = HTTPURLResponse(url: movieURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"video/mp4"])!
    let disk = StudioDiskCache(directory: directory.appendingPathComponent("disk-cache"), limitMB: 32, days: 7)
    let diskKey = StudioDiskCache.Key(environment: "test", user: "video-fixture", workspace: "ws-video", asset: "video", url: movieURL.absoluteString, role: "original")
    let epoch = await disk.lookup(diskKey).epoch
    await disk.store(StudioHTTPFile(file: cachedMovie, response: movieResponse), key: diskKey, epoch: epoch)
    let localTransport = StudioVideoFixtureTransport(video: video)
    let localAPI = StudioClient(environment: .test, transport: localTransport)
    let localPosterStream = StudioVideoStream(reader: StudioVideoReader(api: localAPI, session: session, workspace: "ws-video", url: "/api/private-files/video", byteBudget: 4 * 1024 * 1024, localLoader: {
        try await disk.lease(diskKey, responseURL: movieURL, maximumBytes: 32 * 1024 * 1024)
    }))
    let localPoster = try await localPosterStream.poster()
    try check(localPoster.size.width > 0 && localPoster.size.width <= 280, "native poster extractor reads a disk-cached complete video")
    var activeLease: URL?
    let localPlaybackStream = StudioVideoStream(reader: StudioVideoReader(api: localAPI, session: session, workspace: "ws-video", url: "/api/private-files/video", byteBudget: 32 * 1024 * 1024, localLoader: {
        let lease = try await disk.lease(diskKey, responseURL: movieURL, maximumBytes: 32 * 1024 * 1024)
        activeLease = lease?.file; return lease
    }))
    let localItem = AVPlayerItem(asset: localPlaybackStream.asset)
    let localPlayer = AVPlayer(playerItem: localItem); localPlayer.isMuted = true; localPlayer.play()
    for _ in 0..<200 {
        if localItem.status != .unknown { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try check(localItem.status == .readyToPlay, "native player becomes ready from cached video without network ranges")
    await disk.clear()
    try await renderStudioVideoPlayer(localPlayer)
    let networkCalls = await localTransport.requests.count
    try check(networkCalls == 0 && activeLease.map { FileManager.default.fileExists(atPath: $0.path) } == true, "cache cleanup leaves ongoing local playback alive and makes no video HTTP reads")
    localPlayer.pause(); localPlayer.replaceCurrentItem(with: nil); localPlaybackStream.cancel()
    try check(activeLease.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "closing cached playback releases its temporary local movie")
    print("Studio video tests passed (native decoder, synthetic private ranges, no network)")
}

@MainActor private func renderStudioVideoPlayer(_ player: AVPlayer) async throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: VideoPlayer(player: player).frame(width: 680, height: 460))
    window.contentView = host
    // Rendering the actual SwiftUI player resolves AVPlayerView's superclass.
    // AVPlayer.readyToPlay alone missed the missing AVKit link in version 1.2.2.
    for _ in 0..<8 { try await Task.sleep(nanoseconds: 50_000_000); host.layoutSubtreeIfNeeded() }
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NativeTestFailure(description: "Player view could not render") }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try check(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "actual video player view renders without fatal AVPlayerView metadata failure")
    window.close()
}
