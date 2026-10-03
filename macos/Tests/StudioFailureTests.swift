import Foundation

private struct FailureMediaStep {
    let method: String
    var status = 200
    var error: URLError.Code?
    var delay: UInt64 = 0
    var suspend = false
    var body: String?
}
private actor FailureTransport: StudioTransport {
    var denialStarted = false
    private var denial: CheckedContinuation<Void, Never>?
    func releaseDenial() { denial?.resume(); denial = nil }
    var mediaSteps: [FailureMediaStep] = []
    func enqueue(_ steps: [FailureMediaStep]) { mediaSteps = steps }
    var status = 401
    var networkError: URLError.Code?
    var privateAssets = false
    var etag = "v1"
    var kind = "video"
    func setKind(_ kind: String) { self.kind = kind }
    func usePrivateAssets() { privateAssets = true }
    func changeVersion() { etag = "v2" }
    var requests: [URLRequest] = []
    func configure(status: Int = 200, error: URLError.Code? = nil) { self.status = status; networkError = error }
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile {
        requests.append(request)
        let path = request.url!.path
        var headers = ["Content-Type":"application/json"]
        let body: String
        var code = 200
        switch path {
        case "/api/auth/login":
            headers["Set-Cookie"] = "kaki_session=failure-fixture; Max-Age=604800; Path=/; HttpOnly; Secure"
            body = #"{"user":{"id":"failure-user","email":"fixture@example.invalid"}}"#
        case "/api/me": body = #"{"id":"failure-user","email":"fixture@example.invalid"}"#
        case "/api/workspaces": body = #"[{"id":"w","name":"Fixture","kind":"personal","role":"owner"}]"#
        case "/api/assets": body = #"{"items":[{"id":"a","url":"https://cdn.example.invalid/media","thumbUrl":"https://cdn.example.invalid/thumb","kind":"video","name":"Fixture"}],"total":1}"#
        case "/api/auth/logout": throw URLError(.notConnectedToInternet)
        default:
            var payload = "fixture-video"
            if !mediaSteps.isEmpty {
                let step = mediaSteps.removeFirst()
                let method = request.value(forHTTPHeaderField: "Range") == nil ? request.httpMethod : "RANGE"
                guard method == step.method else { throw NativeTestFailure(description: "Unexpected fallback media method") }
                if let body = step.body { payload = body }
                if step.suspend { denialStarted = true; await withCheckedContinuation { denial = $0 } }
                if step.delay > 0 { await Task.detached { try? await Task.sleep(nanoseconds: step.delay) }.value }
                if let error = step.error { throw URLError(error) }
                code = step.status
            } else {
                if let networkError { throw URLError(networkError) }
                code = status
            }
            body = request.httpMethod == "HEAD" ? "" : payload
            headers = ["Content-Type":"video/mp4", "ETag":etag, "Content-Length":"13"]
        }
        var responseBody = privateAssets && path == "/api/assets" ? body.replacingOccurrences(of: "https://cdn.example.invalid/media", with: "/api/private-files/media") : body
        if path == "/api/assets", kind == "image" { responseBody = responseBody.replacingOccurrences(of: "\"thumbUrl\":\"https://cdn.example.invalid/thumb\"", with: "\"thumbUrl\":null") }
        if path == "/api/assets" { responseBody = responseBody.replacingOccurrences(of: "\"kind\":\"video\"", with: "\"kind\":\"" + kind + "\"") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(responseBody.utf8).write(to: file)
        return StudioHTTPFile(file: file, response: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!)
    }
}
@MainActor private final class FailureCredentials: StudioCredentialStore {
    var values: [StudioEnvironment: StudioSession] = [:]
    var failRemoval = true
    func read(environment: StudioEnvironment) throws -> StudioSession? { values[environment] }
    func write(_ session: StudioSession, environment: StudioEnvironment) throws { values[environment] = session }
    func remove(environment: StudioEnvironment) throws {
        if failRemoval { throw StudioError.credentials(-1) }
        values.removeValue(forKey: environment)
    }
}
@MainActor private func waitForMedia(_ store: StudioStore) async throws {
    for _ in 0..<200 {
        if !store.mediaBusy { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw NativeTestFailure(description: "Fixture media operation did not finish")
}
@MainActor func runStudioFailureTests() async throws {
    try await runStudioConcurrentReplacementTests()
    try await runStudioFallbackFailureTests()
    try await runStudioStaleFallbackTests()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-failure-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FailureTransport(), credentials = FailureCredentials()
    let store = StudioStore(directory: root, credentials: credentials, transport: transport)
    await store.login(email: "fixture@example.invalid", password: "fixture", code: "")
    _ = await store.thumbnail(store.assets[0])
    try check(store.user != nil && credentials.values[.test] != nil, "external thumbnail 401 preserves Studio identity and credentials")
    let asset = store.assets[0]
    _ = await store.suggestedFilename(asset)
    store.download(asset, destination: root.appendingPathComponent("failed.mp4"))
    try await waitForMedia(store)
    try check(store.user != nil && !FileManager.default.fileExists(atPath: root.appendingPathComponent("failed.mp4").path), "external HEAD and download 401 refuse content without signing out")
    for kind in ["image", "audio"] {
        await transport.setKind(kind)
        await store.refresh()
        var copied = false
        store.copyMaterial(store.assets[0], consumeImage: { _ in copied = true; return true }, consumeFile: { _ in copied = true; return true })
        try await waitForMedia(store)
        try check(!copied && store.user != nil && credentials.values[.test] != nil, "external image/audio copy 401 refuses content without signing out")
    }
    await transport.setKind("video")
    await store.refresh()
    let session = credentials.values[.test]!
    for method in ["GET", "HEAD"] {
        do { _ = try await StudioClient(environment: .test, transport: transport).media("/api/private-files/a", session: session, workspace: "w", maximumBytes: 1024, method: method); throw NativeTestFailure(description: "private 401 accepted") }
        catch StudioError.http(401, _) { try check(true, "Studio media 401 remains session failure") }
    }
    do {
        _ = try await StudioClient(environment: .test, transport: transport).videoRange(asset.url, session: session, workspace: "w", range: 0..<1)
        throw NativeTestFailure(description: "External range 401 accepted")
    } catch StudioError.mediaHTTP(401) { try check(true, "external video Range uses the same media error classification") }
    let external = await transport.requests.filter { $0.url?.host == "cdn.example.invalid" }
    try check(external.count >= 3 && external.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "X-Workspace-Id") == nil }, "external failed requests carry no identity headers")
    await store.logout()
    try check(store.logoutCleanupPending, "failed deletion retains an available cleanup action")
    await store.retrySession()
    try check(store.user == nil, "retry does not restore explicitly logged out session after keychain and server failures")
    let restarted = StudioStore(directory: root, credentials: credentials, transport: transport)
    await restarted.restoreSession()
    try check(restarted.user == nil, "restart does not restore explicitly logged out credentials")
    try check(restarted.logoutCleanupPending, "restart retains pending cleanup action")
    credentials.failRemoval = false
    await restarted.logout()
    try check(credentials.values[.test] == nil && !restarted.logoutCleanupPending, "logged out cleanup can be retried without a visible account")
    credentials.values[.production] = session
    await restarted.changeEnvironment(.production)
    try check(restarted.user != nil, "test logout suppression does not block production restore")
    await restarted.changeEnvironment(.test)
    try check(restarted.user == nil, "environment switch keeps explicit logout suppression")
    await restarted.login(email: "fixture@example.invalid", password: "fixture", code: "")
    try check(restarted.user != nil, "explicit new login clears logout suppression")
    let relogged = StudioStore(directory: root, credentials: credentials, transport: transport)
    await relogged.restoreSession()
    try check(relogged.user != nil, "successful explicit login restores after restart")
    await transport.configure()
    relogged.download(asset, destination: root.appendingPathComponent("first.mp4"))
    try await waitForMedia(relogged)
    let originalGets = await transport.requests.filter { $0.url?.path == "/media" && $0.httpMethod == "GET" }.count
    for failure in [URLError.Code.notConnectedToInternet, .timedOut] {
        await transport.configure(error: failure)
        var consumed = false
        relogged.copyMaterial(asset, consumeImage: { _ in false }, consumeFile: { _ in consumed = true; return true })
        try await waitForMedia(relogged)
        await relogged.refreshCacheStats()
        try check(!consumed && relogged.cacheFiles == 1, "failed HEAD preserves cache without serving unvalidated bytes")
    }
    await transport.configure(status: 503)
    relogged.download(asset, destination: root.appendingPathComponent("unvalidated.mp4"))
    try await waitForMedia(relogged)
    await relogged.refreshCacheStats()
    try check(relogged.cacheFiles == 1 && !FileManager.default.fileExists(atPath: root.appendingPathComponent("unvalidated.mp4").path), "temporary server failure retains cache and denies current transfer")
    await transport.configure()
    relogged.download(asset, destination: root.appendingPathComponent("validated.mp4"))
    try await waitForMedia(relogged)
    let gets = await transport.requests.filter { $0.url?.path == "/media" && $0.httpMethod == "GET" && $0.url?.host == "cdn.example.invalid" }.count
    try check(gets == originalGets && FileManager.default.fileExists(atPath: root.appendingPathComponent("validated.mp4").path), "network recovery validates and reuses preserved original without another GET")
    await transport.changeVersion()
    relogged.download(asset, destination: root.appendingPathComponent("new-version.mp4"))
    try await waitForMedia(relogged)
    let versionGets = await transport.requests.filter { $0.url?.path == "/media" && $0.httpMethod == "GET" }.count
    try check(versionGets == originalGets + 1, "confirmed version change fetches a new original")
    await transport.configure(status: 403)
    relogged.download(asset, destination: root.appendingPathComponent("revoked.mp4"))
    try await waitForMedia(relogged)
    await relogged.refreshCacheStats()
    try check(relogged.cacheFiles == 0 && relogged.user != nil, "confirmed external permission revocation deletes cached content without expiring identity")
    await transport.usePrivateAssets()
    await relogged.refresh()
    await transport.configure(status: 401)
    relogged.download(relogged.assets[0], destination: root.appendingPathComponent("expired.mp4"))
    try await waitForMedia(relogged)
    try check(relogged.user == nil && credentials.values[.test] == nil && credentials.values[.production] != nil, "Studio media 401 clears only the expired environment identity")
    await relogged.login(email: "fixture@example.invalid", password: "fixture", code: "")
    credentials.failRemoval = true
    relogged.download(relogged.assets[0], destination: root.appendingPathComponent("expired-again.mp4"))
    try await waitForMedia(relogged)
    await relogged.retrySession()
    try check(relogged.user == nil && relogged.logoutCleanupPending, "expired identity stays suppressed when keychain cleanup fails")
    let blockedRoot = root.appendingPathComponent("unwritable-marker")
    try FileManager.default.createDirectory(at: blockedRoot, withIntermediateDirectories: true)
    let blocked = StudioStore(directory: blockedRoot, credentials: StudioMemoryCredentials(), transport: transport)
    await blocked.login(email: "fixture@example.invalid", password: "fixture", code: "")
    try FileManager.default.createDirectory(at: blockedRoot.appendingPathComponent("studio-logout-test"), withIntermediateDirectories: true)
    await blocked.logout()
    try check(blocked.user != nil && blocked.message.contains("退出状态保存失败"), "failed durable logout intent keeps account visible and exit retryable")
}

@MainActor private func runStudioFallbackFailureTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-fallback-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for privateAsset in [false, true] {
        for headStatus in [405, 501] {
            for rangeRead in [false, true] {
                for failure in [401, 403, 404, 410, 503, -1, -2] {
                    let dir = root.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let transport = FailureTransport()
                    await transport.configure()
                    if privateAsset { await transport.usePrivateAssets() }
                    let store = StudioStore(directory: dir, credentials: StudioMemoryCredentials(), transport: transport)
                    await store.login(email: "fixture@example.invalid", password: "fixture", code: "")
                    let asset = store.assets[0]
                    store.download(asset, destination: dir.appendingPathComponent("seed.mp4"))
                    try await waitForMedia(store)
                    try check(store.cacheFiles == 1, "fallback fixture starts with a valid cached original")
                    let error: URLError.Code? = failure == -1 ? .notConnectedToInternet : failure == -2 ? .timedOut : nil
                    await transport.enqueue([
                        FailureMediaStep(method: "HEAD", status: headStatus),
                        FailureMediaStep(method: rangeRead ? "RANGE" : "GET", status: failure, error: error)
                    ])
                    let output = dir.appendingPathComponent("rejected.mp4")
                    if rangeRead {
                        let stream = try store.videoStream(asset)
                        defer { store.releaseVideoStream(stream) }
                        do {
                            _ = try await stream.reader.metadata()
                            throw NativeTestFailure(description: "Fallback Range unexpectedly accepted cached media")
                        } catch let failure as NativeTestFailure { throw failure }
                        catch { /* Explicit denial or temporary failure must reach the caller. */ }
                    } else {
                        store.download(asset, destination: output)
                        try await waitForMedia(store)
                    }
                    await store.refreshCacheStats()
                    let revoked = [401, 403, 404, 410].contains(failure)
                    try check(store.cacheFiles == (revoked ? 0 : 1), "HEAD \(headStatus) fallback \(rangeRead ? "Range" : "GET") \(failure) removes only definitively invalid originals")
                    try check(!FileManager.default.fileExists(atPath: output.path), "fallback failure never outputs cached bytes")
                    let methods = await transport.requests.filter { $0.url?.path == (privateAsset ? "/api/private-files/media" : "/media") }.map { $0.value(forHTTPHeaderField: "Range") == nil ? $0.httpMethod! : "RANGE" }
                    try check(methods == ["GET", "HEAD", rangeRead ? "RANGE" : "GET"], "cachedOnly uses bounded Range after unsupported HEAD and download uses GET")
                    store.shutdown()
                }
            }
        }
    }
}

@MainActor private func runStudioStaleFallbackTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-stale-fallback-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for change in ["cache", "account", "cancel"] {
        let dir = root.appendingPathComponent(change)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transport = FailureTransport()
        await transport.configure()
        let store = StudioStore(directory: dir, credentials: StudioMemoryCredentials(), transport: transport)
        await store.login(email: "fixture@example.invalid", password: "fixture", code: "")
        let asset = store.assets[0]
        store.download(asset, destination: dir.appendingPathComponent("seed.mp4"))
        try await waitForMedia(store)
        await transport.enqueue([
            FailureMediaStep(method: "HEAD", status: 405),
            FailureMediaStep(method: "RANGE", status: 403, delay: 350_000_000)
        ])
        let stream = try store.videoStream(asset)
        let oldRead = Task { try await stream.reader.metadata() }
        for _ in 0..<200 {
            if await transport.requests.contains(where: { $0.value(forHTTPHeaderField: "Range") != nil }) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let started = await transport.requests.contains(where: { $0.value(forHTTPHeaderField: "Range") != nil })
        try check(started, "delayed fallback Range actually starts before state change")
        if change == "cache" { await store.clearMaterialCache() }
        else if change == "account" { await store.login(email: "fixture@example.invalid", password: "fixture", code: ""); await store.refreshCacheStats() }
        else { oldRead.cancel() }
        store.download(store.assets[0], destination: dir.appendingPathComponent("fresh.mp4"))
        try await waitForMedia(store)
        do { _ = try await oldRead.value; throw NativeTestFailure(description: "Stale denied Range succeeded") }
        catch let error as NativeTestFailure { throw error }
        catch { }
        await store.refreshCacheStats()
        try check(store.cacheFiles == 1 && store.user != nil, "late Range denial after \(change) does not delete current original or identity")
        try check((try? Data(contentsOf: dir.appendingPathComponent("fresh.mp4"))) == Data("fixture-video".utf8), "fresh validated transfer survives stale Range failure")
        store.releaseVideoStream(stream); store.shutdown()
    }
}

@MainActor private func runStudioConcurrentReplacementTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-replacement-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for method in ["RANGE", "HEAD", "GET"] {
        for sameETag in [true, false] {
            let dir = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let transport = FailureTransport()
            await transport.configure()
            if method == "GET" { await transport.setKind("image") }
            let store = StudioStore(directory: dir, credentials: StudioMemoryCredentials(), transport: transport)
            await store.login(email: "fixture@example.invalid", password: "fixture", code: "")
            let asset = store.assets[0], sessionRevision = store.sessionRevision
            store.download(asset, destination: dir.appendingPathComponent("seed.mp4"))
            try await waitForMedia(store)
            var oldSteps: [FailureMediaStep] = []
            if method != "HEAD" { oldSteps.append(FailureMediaStep(method: "HEAD", status: 405)) }
            oldSteps.append(FailureMediaStep(method: method, status: 403, suspend: true))
            await transport.enqueue(oldSteps)
            let stream = method == "GET" ? nil : try store.videoStream(asset)
            let oldRead = Task { () throws -> Void in
                if let stream {
                    do { _ = try await stream.reader.metadata(); throw NativeTestFailure(description: "Old denied request succeeded") }
                    catch let error as NativeTestFailure { throw error }
                    catch { }
                } else { _ = await store.thumbnail(asset) }
            }
            for _ in 0..<200 {
                if await transport.denialStarted { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let started = await transport.denialStarted
            guard started else { oldRead.cancel(); await transport.releaseDenial(); throw NativeTestFailure(description: "Replacement fixture did not start old request") }
            if !sameETag { await transport.changeVersion() }
            await transport.enqueue([
                FailureMediaStep(method: "HEAD", status: 405),
                FailureMediaStep(method: "GET", body: "fresh-video!!")
            ])
            store.download(asset, destination: dir.appendingPathComponent("fresh.mp4"))
            try await waitForMedia(store)
            await store.refreshCacheStats()
            let before = store.cacheFiles
            await transport.releaseDenial()
            try await oldRead.value
            await store.refreshCacheStats()
            try check(before == 1 && store.cacheFiles == 1 && store.sessionRevision == sessionRevision, "old \(method) denial cannot delete new original with \(sameETag ? "same" : "different") ETag in unchanged session")
            try check((try? Data(contentsOf: dir.appendingPathComponent("fresh.mp4"))) == Data("fresh-video!!".utf8), "concurrent replacement delivers new validated bytes")
            await transport.enqueue([FailureMediaStep(method: "HEAD", status: 200)])
            store.download(asset, destination: dir.appendingPathComponent("retained.mp4"))
            try await waitForMedia(store)
            try check((try? Data(contentsOf: dir.appendingPathComponent("retained.mp4"))) == Data("fresh-video!!".utf8), "later validated read reuses the preserved replacement")
            if let stream { store.releaseVideoStream(stream) }
            store.shutdown()
        }
    }
}
