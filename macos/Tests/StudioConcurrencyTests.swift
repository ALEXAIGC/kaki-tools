import Foundation
import AppKit

private final class MediaFixtureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?
    func wait() async throws {
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            finish(.failure(NativeTestFailure(description: "Controlled media gate timed out")))
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let outcome { lock.unlock(); continuation.resume(with: outcome) }
                else { self.continuation = continuation; lock.unlock() }
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }
    func finish(_ value: Result<Void, Error> = .success(())) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = value
        let continuation = continuation; self.continuation = nil
        lock.unlock(); continuation?.resume(with: value)
    }
}

private actor MediaConcurrencyTransport: StudioTransport {
    let png: Data
    var requests = 0
    var active = 0
    var maximumActive = 0
    var cancelled = 0
    var automatic = false
    private var gates: [UUID: MediaFixtureGate] = [:]
    init(png: Data) { self.png = png }
    func counters() -> (requests: Int, active: Int, maximum: Int, cancelled: Int) { (requests, active, maximumActive, cancelled) }
    func reset() { requests = 0; active = 0; maximumActive = 0; cancelled = 0; automatic = false }
    func releaseAll() { automatic = true; for gate in gates.values { gate.finish() } }
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile {
        let path = request.url!.path
        var headers = ["Content-Type":"application/json"], status = 200
        let body: Data
        switch path {
        case "/api/auth/login":
            headers["Set-Cookie"] = "kaki_session=concurrency-fixture; Max-Age=3600; Path=/; HttpOnly; Secure"
            body = Data(#"{"user":{"id":"concurrency-user","email":"fixture@example.invalid"}}"#.utf8)
        case "/api/workspaces":
            body = Data(#"[{"id":"w","name":"Fixture","kind":"personal","role":"owner"}]"#.utf8)
        case "/api/assets":
            let items = (0..<16).map { ["id":"image-\($0)", "url":"/api/private-files/image-\($0)", "thumbUrl":"/api/private-files/thumb-\($0)", "kind":"image", "name":"Fixture \($0)"] }
            body = try JSONSerialization.data(withJSONObject: ["items":items, "total":16])
        case "/api/auth/logout": body = Data()
        default:
            let range = request.value(forHTTPHeaderField: "Range")?.dropFirst(6).split(separator: "-").compactMap { Int64($0) }
            let isMetadata = range?.count == 2 && range?[0] == 0 && range?[1] == 0
            if !isMetadata {
                requests += 1; active += 1; maximumActive = max(active, maximumActive)
                let id = UUID(), gate = MediaFixtureGate(); gates[id] = gate
                defer { gates.removeValue(forKey: id); active -= 1 }
                if !automatic {
                    do { try await gate.wait() }
                    catch { cancelled += 1; throw error }
                }
            }
            if let range, range.count == 2 {
                body = Data(repeating: 19, count: Int(range[1] - range[0] + 1))
                headers = ["Content-Type":"video/mp4", "Content-Range":"bytes \(range[0])-\(range[1])/10485760"]
                status = 206
            } else { body = png; headers = ["Content-Type":"image/png"] }
        }
        try Task.checkCancellation()
        guard body.count <= maximumBytes else { throw StudioError.tooLarge }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-concurrency-fixture-" + UUID().uuidString)
        try body.write(to: file)
        return StudioHTTPFile(file: file, response: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

@MainActor private func waitForMediaCondition(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw NativeTestFailure(description: "Controlled media condition timed out")
}

@MainActor func runStudioConcurrencyTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-media-concurrency-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let png = bitmap.representation(using: .png, properties: [:])!
    let transport = MediaConcurrencyTransport(png: png)
    let store = StudioStore(directory: directory, credentials: StudioMemoryCredentials(), transport: transport)
    await store.login(email: "fixture@example.invalid", password: "fixture", code: "")
    let first = store.assets[0]
    let joined = (0..<16).map { _ in Task { await store.thumbnail(first) != nil } }
    try await waitForMediaCondition { await transport.counters().requests == 1 }
    try await Task.sleep(nanoseconds: 20_000_000)
    let duplicate = await transport.counters()
    await transport.releaseAll()
    var images = 0
    for task in joined { if await task.value { images += 1 } }
    try check(duplicate.requests == 1 && duplicate.maximum == 1 && images == 16, "sixteen concurrent thumbnail consumers share one transfer/decode")

    await store.clearMaterialCache(); await transport.reset()
    let distinct = store.assets.prefix(12).map { asset in Task { await store.thumbnail(asset) != nil } }
    try await waitForMediaCondition { await transport.counters().active == 4 }
    try await Task.sleep(nanoseconds: 20_000_000)
    let bounded = await transport.counters()
    await store.refresh(background: true)
    await transport.releaseAll()
    var distinctImages = 0
    for task in distinct { if await task.value { distinctImages += 1 } }
    let completed = await transport.counters()
    try check(bounded.requests == 4 && completed.requests == 12 && completed.maximum <= 4 && distinctImages == 12, "background refresh preserves queued thumbnail consumers while at most four transfers/decodes run")

    await store.clearMaterialCache(); await transport.reset()
    let cancelledConsumer = Task { await store.thumbnail(first) != nil }
    let survivor = Task { await store.thumbnail(first) != nil }
    try await waitForMediaCondition { await transport.counters().active == 1 }
    try await Task.sleep(nanoseconds: 20_000_000)
    cancelledConsumer.cancel()
    let cancelledImage = await cancelledConsumer.value
    let shared = await transport.counters()
    try check(!cancelledImage && shared.cancelled == 0 && shared.active == 1, "cancelled thumbnail consumer returns promptly while the shared transfer survives")
    await transport.releaseAll()
    let survivorImage = await survivor.value
    try check(survivorImage, "remaining thumbnail consumer receives its image")

    await store.clearMaterialCache(); await transport.reset()
    let abandoned = Task { await store.thumbnail(first) != nil }
    try await waitForMediaCondition { await transport.counters().active == 1 }
    abandoned.cancel(); _ = await abandoned.value
    try await waitForMediaCondition { await transport.counters().cancelled == 1 }
    let cacheStats = store.cacheFiles
    let retry = Task { await store.thumbnail(first) != nil }
    try await waitForMediaCondition { await transport.counters().requests == 2 }
    await transport.releaseAll()
    let retryImage = await retry.value
    try check(cacheStats == 0 && retryImage, "last thumbnail consumer cancels transport and cannot publish or cache its abandoned result")

    await store.clearMaterialCache(); await transport.reset()
    let old = Task { await store.thumbnail(first) != nil }
    try await waitForMediaCondition { await transport.counters().active == 1 }
    store.query = "new search"
    _ = await old.value
    try await waitForMediaCondition { await transport.counters().cancelled == 1 }
    try check(store.cacheFiles == 0, "query replacement cancels obsolete thumbnail work without repopulating cache")
    store.shutdown()
    try await runPreviewLeaseReplacementTests(directory: directory, png: png)
    try await runVideoConsumerCancellationTests(png: png)
    try await runMediaQueueResourceTests()
}

@MainActor private func runPreviewLeaseReplacementTests(directory: URL, png: Data) async throws {
    let root = directory.appendingPathComponent("replacement")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let cache = StudioDiskCache(directory: root.appendingPathComponent("studio-cache"))
    let transport = MediaConcurrencyTransport(png: png)
    let gate = MediaFixtureGate()
    var decodingBad = false
    let store = StudioStore(directory: root, credentials: StudioMemoryCredentials(), transport: transport, cache: cache, thumbnailDecoder: { file in
        let data = try? Data(contentsOf: file)
        if data == Data("bad-preview".utf8) {
            decodingBad = true; try? await gate.wait(); return nil
        }
        return data
    })
    await store.login(email: "fixture@example.invalid", password: "fixture", code: "")
    let asset = store.assets[0]
    let key = StudioDiskCache.Key(environment: "test", user: "concurrency-user", workspace: "w", asset: asset.id, url: asset.thumbUrl!, role: "preview:" + asset.url)
    let file = root.appendingPathComponent("input")
    let response = HTTPURLResponse(url: StudioEnvironment.test.baseURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"image/png"])!
    let epoch = await cache.lookup(key).epoch
    try Data("bad-preview".utf8).write(to: file)
    await cache.store(StudioHTTPFile(file: file, response: response), key: key, epoch: epoch)
    let reading = Task { await store.thumbnail(asset) != nil }
    try await waitForMediaCondition { decodingBad }
    // A real transfer has a fresh temporary URL. Reusing the earlier URL would
    // reuse Foundation's cached fileSize from the bad payload in this fixture.
    let replacementFile = root.appendingPathComponent("replacement-input")
    try png.write(to: replacementFile)
    await cache.store(StudioHTTPFile(file: replacementFile, response: response), key: key, epoch: epoch)
    let replacement = await cache.lookup(key)
    gate.finish()
    let image = await reading.value
    let after = await cache.lookup(key)
    let calls = await transport.counters().requests
    try check(image && after.version == replacement.version && after.entry != nil && calls == 0, "late bad-preview decode preserves and reuses a newer lease instead of deleting or overwriting it")
    store.shutdown()
}

@MainActor private func runVideoConsumerCancellationTests(png: Data) async throws {
    let transport = MediaConcurrencyTransport(png: png)
    let session = StudioSession(value: "fixture", expiresAt: Date().addingTimeInterval(600))
    func reader() -> StudioVideoReader {
        StudioVideoReader(api: StudioClient(environment: .test, transport: transport), session: session, workspace: "w", url: "/api/private-files/video", byteBudget: 32 * 1024 * 1024)
    }
    let shared = reader()
    _ = try await shared.metadata()
    let first = Task { try await shared.read(offset: 100, length: 20) }
    let second = Task { try await shared.read(offset: 120, length: 20) }
    try await waitForMediaCondition { await transport.counters().active == 1 }
    try await Task.sleep(nanoseconds: 20_000_000)
    first.cancel()
    do { _ = try await first.value; throw NativeTestFailure(description: "Cancelled video waiter completed") }
    catch is CancellationError { try check(true, "individual video waiter cancels promptly") }
    let active = await transport.counters()
    try check(active.active == 1 && active.cancelled == 0 && active.requests == 1, "another video consumer keeps its shared chunk transfer alive")
    await transport.releaseAll()
    let surviving = try await second.value
    try check(surviving == Data(repeating: 19, count: 20), "shared chunk survivor receives exact requested bytes")
    shared.cancel(); await transport.reset()

    let seeking = reader()
    _ = try await seeking.metadata()
    let reads = (0..<8).map { index in Task { try await seeking.read(offset: Int64(index) * StudioVideoReader.chunkSize, length: 20) } }
    try await waitForMediaCondition { await transport.counters().active == 4 }
    let started = Date()
    for task in reads { task.cancel() }
    for task in reads {
        do { _ = try await task.value; throw NativeTestFailure(description: "Cancelled seek completed") }
        catch is CancellationError { }
    }
    try await waitForMediaCondition { await transport.counters().active == 0 }
    let stopped = await transport.counters()
    try check(Date().timeIntervalSince(started) < 0.5 && stopped.cancelled == stopped.requests && stopped.maximum <= 4, "seek cancellation stops all abandoned underlying ranges and bounds concurrency")
    seeking.cancel()
}

@MainActor private func runMediaQueueResourceTests() async throws {
    let work = StudioMediaWork<String, Int>(limit: 1)
    var release: CheckedContinuation<Void, Never>?
    var running = false, nextStarted = false
    let first = Task { try await work.value(for: "one") {
        running = true
        // Simulate a decoder that cannot interrupt until it releases memory.
        await withCheckedContinuation { release = $0 }
        return 1
    } }
    try await waitForMediaCondition { running }
    first.cancel()
    do { _ = try await first.value; throw NativeTestFailure(description: "Cancelled resource waiter returned") }
    catch is CancellationError { }
    let second = Task { try await work.value(for: "two") { nextStarted = true; return 2 } }
    try await Task.sleep(nanoseconds: 20_000_000)
    try check(!nextStarted, "cancelled decoder retains its concurrency slot until its resources finish")
    release?.resume(); release = nil
    let value = try await second.value
    try check(value == 2, "queued media work resumes after cancelled decoder really exits")
    work.cancelAll()
}
