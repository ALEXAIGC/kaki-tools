import Foundation
import AppKit

private struct StudioStubStep {
    let path: String
    var status = 200
    var headers: [String: String] = ["Content-Type": "application/json"]
    var json: String
    var delay: UInt64 = 0
    var bytes: Data? = nil
}
private actor StudioStubTransport: StudioTransport {
    private var steps: [StudioStubStep]
    private(set) var requests: [URLRequest] = []
    init(_ steps: [StudioStubStep]) { self.steps = steps }
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile {
        requests.append(request)
        guard !steps.isEmpty else { throw NativeTestFailure(description: "Unexpected Studio request") }
        let step = steps.removeFirst()
        guard request.url?.path == step.path else { throw NativeTestFailure(description: "Unexpected Studio route: \(request.url?.path ?? "nil")") }
        if step.delay > 0 { try await Task.sleep(nanoseconds: step.delay) }
        let data = step.bytes ?? Data(step.json.utf8)
        guard data.count <= maximumBytes else { throw StudioError.tooLarge }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-studio-stub-" + UUID().uuidString)
        try data.write(to: file)
        return StudioHTTPFile(file: file, response: HTTPURLResponse(url: request.url!, statusCode: step.status, httpVersion: "HTTP/1.1", headerFields: step.headers)!)
    }
    func remaining() -> Int { steps.count }
}
private let studioUserJSON = #"{"id":"user-a","email":"a@example.invalid","name":"Alice"}"#
private let studioWorkspaceJSON = #"[{"id":"ws-a","name":"个人素材","kind":"personal","role":"owner","disabled":false},{"id":"ws-b","name":"团队素材","kind":"team","role":"viewer","disabled":false}]"#
private let studioPageJSON = #"{"items":[{"id":"asset-a","url":"/api/private-files/private-a","thumbUrl":null,"kind":"image","name":"人物","tags":["角色"],"size":1000}],"total":2,"nextCursor":"next-a"}"#
private func studioLoginStep(delay: UInt64 = 0) -> StudioStubStep {
    StudioStubStep(path: "/api/auth/login", headers: ["Content-Type": "application/json", "Set-Cookie": "kaki_session=test-session-a; Max-Age=604800; Path=/; HttpOnly; Secure; SameSite=Lax"], json: "{\"user\":" + studioUserJSON + "}", delay: delay)
}
@MainActor func runStudioTests() async throws {
    try runStudioReferenceSelectionTests()
    try await runStudioExportTests()
    let suffixes = ["image/png":"png", "image/jpeg":"jpg", "image/webp":"webp", "image/gif":"gif", "image/heic":"heic", "image/avif":"avif", "video/mp4":"mp4", "video/quicktime":"mov", "video/webm":"webm", "audio/mpeg":"mp3", "audio/wav":"wav", "audio/x-wav":"wav", "audio/mp4":"m4a", "audio/ogg":"ogg"]
    try check(suffixes.allSatisfy { StudioMediaFiles.mediaExtension($0.key) == $0.value } && StudioMediaFiles.mediaExtension("application/octet-stream") == "bin", "low-level MIME mapping preserves every existing export extension and fallback")
    let secret = StudioSession(value: "test-session", expiresAt: Date().addingTimeInterval(600))
    let api = StudioClient(environment: .test, transport: StudioStubTransport([]))
    let privateRequest = try api.mediaRequest("/api/private-files/asset-a", session: secret, workspace: "ws-a")
    try check(privateRequest.url?.absoluteString == "https://test.kakiai.xin/api/private-files/asset-a", "relative private media stays on the chosen origin")
    try check(privateRequest.value(forHTTPHeaderField: "Cookie") == "kaki_session=test-session", "private media carries Studio cookie")
    try check(privateRequest.value(forHTTPHeaderField: "X-Workspace-Id") == "ws-a", "private media carries selected workspace")
    let external = try api.mediaRequest("https://example.invalid/image.jpg", session: secret, workspace: "ws-a")
    try check(external.value(forHTTPHeaderField: "Cookie") == nil && external.value(forHTTPHeaderField: "X-Workspace-Id") == nil && external.value(forHTTPHeaderField: "Authorization") == nil, "third-party media never receives identity headers")
    for raw in ["http://example.invalid/a", "file:///tmp/a", "https://user:pass@example.invalid/a", "https://localhost/a", "https://127.0.0.1/a", "https://[::1]/a", "https://kakiai.xin/api/private-files/a", "https://media-studio.kakiai.xin/a", "//kakiai.xin/api/private-files/a", "/api/me", "https://example.invalid:8788/a"] {
        do { _ = try api.mediaRequest(raw, session: secret, workspace: "ws-a"); throw NativeTestFailure(description: "Unsafe media URL accepted") }
        catch StudioError.invalidURL { try check(true, "unsafe or cross-environment media rejected") }
    }
    let configuration = URLSessionConfiguration.ephemeral
    let sessionForRedirect = URLSession(configuration: configuration)
    defer { sessionForRedirect.invalidateAndCancel() }
    let task = sessionForRedirect.downloadTask(with: privateRequest)
    let guardDelegate = StudioRedirectGuard()
    let redirectResponse = HTTPURLResponse(url: privateRequest.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location":"https://example.invalid/a"])!
    var forwarded = true
    guardDelegate.urlSession(sessionForRedirect, task: task, willPerformHTTPRedirection: redirectResponse, newRequest: external) { forwarded = $0 != nil }
    try check(!forwarded, "redirect delegate refuses to forward authenticated or unauthenticated media requests")
    task.taskDescription = "10"
    guardDelegate.urlSession(sessionForRedirect, downloadTask: task, didWriteData: 11, totalBytesWritten: 11, totalBytesExpectedToWrite: 11)
    try check(task.taskDescription?.hasPrefix("oversized:") == true, "oversized streamed downloads are distinguished from user cancellation")
    try check(StudioMediaFiles.mediaExtension("image/jpeg") == "jpg" && StudioMediaFiles.mediaExtension("video/mp4") == "mp4", "download filename follows verified MIME rather than private opaque object id")
    let expired = StudioSession(value: "old", expiresAt: Date().addingTimeInterval(-1))
    try check(!expired.valid && api.request(path: "api/me", session: expired).value(forHTTPHeaderField: "Cookie") == nil, "expired session cannot be sent")
    let response = HTTPURLResponse(url: StudioEnvironment.test.baseURL, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": "kaki_session=a; Max-Age=3600; Path=/; Secure; HttpOnly"])!
    try check(StudioClient.extractSession(response: response, url: StudioEnvironment.test.baseURL)?.value == "a", "secure cookie with lifetime is extracted")
    let insecure = HTTPURLResponse(url: StudioEnvironment.test.baseURL, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": "kaki_session=a; Max-Age=3600; Path=/"])!
    try check(StudioClient.extractSession(response: insecure, url: StudioEnvironment.test.baseURL) == nil, "insecure auth cookie is rejected")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-studio-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let credentials = StudioMemoryCredentials()
    let transport = StudioStubTransport([studioLoginStep(), StudioStubStep(path: "/api/workspaces", json: studioWorkspaceJSON), StudioStubStep(path: "/api/assets", json: studioPageJSON), StudioStubStep(path: "/api/assets", json: #"{"items":[{"id":"asset-a","url":"/api/private-files/private-a","kind":"image"},{"id":"asset-b","url":"/api/private-files/private-b","kind":"video"}],"total":2,"nextCursor":null}"#), StudioStubStep(path: "/api/assets", json: #"{"items":[],"total":0,"nextCursor":null}"#), StudioStubStep(path: "/api/auth/logout", status: 204, json: "")])
    let store = StudioStore(directory: dir, credentials: credentials, transport: transport)
    try check(store.environment == .test && store.user == nil, "first run defaults to isolated test environment and does not read credentials")
    await store.login(email: " A@EXAMPLE.INVALID ", password: "not-real-password", code: "")
    try check(store.user?.id == "user-a" && store.workspaceID == "ws-a" && store.assets.count == 1, "login loads identity, personal workspace and first asset page")
    try check(credentials.sessions[.test]?.value == "test-session-a" && credentials.sessions[.production] == nil, "session persistence is separated by environment")
    let firstRequests = await transport.requests
    let fields = try JSONSerialization.jsonObject(with: firstRequests[0].httpBody!) as! [String: String]
    try check(fields["email"] == "a@example.invalid" && fields["password"] == "not-real-password", "native login normalizes only email, preserving password")
    try check(firstRequests[0].value(forHTTPHeaderField: "Cookie") == nil, "login does not inherit a prior session")
    try check(firstRequests[2].url?.query?.contains("pageSize=40") == true && firstRequests[2].value(forHTTPHeaderField: "X-Workspace-Id") == "ws-a", "asset list uses explicit pagination and selected membership")
    let referenceText = try store.referenceText(ids: ["asset-a"])
    let envelope = try JSONDecoder().decode(StudioReferenceEnvelope.self, from: Data(referenceText.dropFirst(StudioReferenceEnvelope.prefix.count).utf8))
    try check(envelope.items == [StudioMaterialReference(source: "asset", id: "asset-a", workspaceId: "ws-a")] && envelope.origin == "https://test.kakiai.xin", "asset clipboard contains only scoped canonical ids")
    try check(!referenceText.contains("private-a") && !referenceText.contains("session") && !referenceText.contains("人物"), "references contain no bytes, URLs, names or credentials")
    let afterReference = await transport.requests.count
    try check(afterReference == firstRequests.count, "copying a reference performs no media or metadata requests")
    do { _ = try store.referenceText(ids: ["missing"]); throw NativeTestFailure(description: "stale asset copied") }
    catch StudioError.invalidResponse { try check(true, "stale selection cannot enter clipboard") }
    await store.refresh(more: true)
    try check(store.assets.map(\.id) == ["asset-a", "asset-b"] && store.nextCursor == nil, "later asset pages deduplicate and retain cursor semantics")
    store.kind = "video"
    try check(store.visibleAssets.map(\.id) == ["asset-b"], "type filter keeps underlying pagination intact")
    let revision = store.sessionRevision
    await store.selectWorkspace("ws-b")
    try check(store.assets.isEmpty && store.workspaceID == "ws-b" && store.sessionRevision > revision, "workspace switch clears previous material and invalidates thumbnails")
    await store.logout()
    try check(store.user == nil && store.workspaces.isEmpty && store.assets.isEmpty && credentials.sessions[.test] == nil, "logout clears account data and saved session")
    let remainingSteps = await transport.remaining()
    try check(remainingSteps == 0, "all expected Studio operations executed")
    let preference = dir.appendingPathComponent("studio-environment.json")
    if FileManager.default.fileExists(atPath: preference.path) { let text = try String(contentsOf: preference); try check(!text.contains("test-session"), "preference file never contains credentials") }
    let second = StudioStubTransport([StudioStubStep(path: "/api/auth/login", json: #"{"twoFactorRequired":true}"#), studioLoginStep(), StudioStubStep(path: "/api/workspaces", json: studioWorkspaceJSON), StudioStubStep(path: "/api/assets", json: studioPageJSON)])
    let twoFactor = StudioStore(directory: dir, credentials: StudioMemoryCredentials(), transport: second)
    await twoFactor.login(email: "a@example.invalid", password: "test", code: "")
    try check(twoFactor.twoFactorRequired && twoFactor.user == nil, "two-factor challenge does not mark account authenticated")
    await twoFactor.login(email: "a@example.invalid", password: "test", code: "123456")
    try check(twoFactor.user != nil && !twoFactor.twoFactorRequired, "second factor completes native login")
    let secondRequests = await second.requests
    let secondFields = try JSONSerialization.jsonObject(with: secondRequests[1].httpBody!) as! [String: String]
    try check(secondFields["code"] == "123456", "two-factor code is passed without storage")
    let savedCredentials = StudioMemoryCredentials(); savedCredentials.sessions[.test] = secret
    let expiredTransport = StudioStubTransport([StudioStubStep(path: "/api/me", status: 401, json: #"{"error":"token expired"}"#)])
    let expiredStore = StudioStore(directory: dir, credentials: savedCredentials, transport: expiredTransport)
    await expiredStore.restoreSession()
    try check(expiredStore.user == nil && savedCredentials.sessions[.test] == nil && !expiredStore.message.isEmpty, "server-expired session is deleted and prompts login")
    let denied = StudioStubTransport([studioLoginStep(), StudioStubStep(path: "/api/workspaces", status: 403, json: #"{"error":"forbidden"}"#)])
    let deniedStore = StudioStore(directory: dir, credentials: StudioMemoryCredentials(), transport: denied)
    await deniedStore.login(email: "a@example.invalid", password: "test", code: "")
    try check(deniedStore.user != nil && deniedStore.workspaces.isEmpty && deniedStore.assets.isEmpty && !deniedStore.message.isEmpty, "product permission denial cannot leak assets or masquerade as bad credentials")
    let lateCredentials = StudioMemoryCredentials()
    let late = StudioStubTransport([studioLoginStep(delay: 120_000_000)])
    let lateStore = StudioStore(directory: dir, credentials: lateCredentials, transport: late)
    let loginTask = Task { await lateStore.login(email: "a@example.invalid", password: "test", code: "") }
    try await Task.sleep(nanoseconds: 20_000_000)
    await lateStore.logout(); await loginTask.value
    try check(lateStore.user == nil && lateCredentials.sessions.isEmpty && lateStore.assets.isEmpty, "late login result cannot restore an account after logout")
    let accountCredentials = StudioMemoryCredentials(); accountCredentials.sessions[.test] = secret
    let switching = StudioStubTransport([StudioStubStep(path: "/api/me", json: studioUserJSON, delay: 120_000_000)])
    // Isolate this delayed restore from the preceding explicit logout tombstone.
    let switchingDirectory = dir.appendingPathComponent("switching")
    try FileManager.default.createDirectory(at: switchingDirectory, withIntermediateDirectories: true)
    let switchingStore = StudioStore(directory: switchingDirectory, credentials: accountCredentials, transport: switching)
    let restoreTask = Task { await switchingStore.restoreSession() }
    try await Task.sleep(nanoseconds: 20_000_000)
    await switchingStore.changeEnvironment(.production); await restoreTask.value
    let switchingRequests = await switching.requests
    try check(switchingRequests.count == 1, "isolated restore actually starts before environment switch")
    try check(switchingStore.environment == .production && switchingStore.user == nil && switchingStore.assets.isEmpty, "late test identity cannot populate production state")
    try check(StudioStore(directory: switchingDirectory, credentials: StudioMemoryCredentials(), transport: StudioStubTransport([])).environment == .production, "environment choice persists without credentials")
    try await runStudioMediaTests(directory: dir)
    try await runStudioSyncTests(directory: dir)
    try await runStudioVideoStoreTests(directory: dir)
    print("Studio contract/auth tests passed (synthetic credentials, private transport, no server mutation)")
}

@MainActor private func runStudioVideoStoreTests(directory: URL) async throws {
    let videoPage = #"{"items":[{"id":"video-a","url":"/api/private-files/video-a","kind":"video","name":"视频"}],"total":1,"nextCursor":null}"#
    let denied = StudioStubTransport([studioLoginStep(), StudioStubStep(path: "/api/workspaces", json: studioWorkspaceJSON), StudioStubStep(path: "/api/assets", json: videoPage), StudioStubStep(path: "/api/private-files/video-a", status: 401, json: #"{"error":"expired"}"#)])
    let credentials = StudioMemoryCredentials()
    let deniedStore = StudioStore(directory: directory, credentials: credentials, transport: denied)
    await deniedStore.login(email: "a@example.invalid", password: "test", code: "")
    let deniedPoster = await deniedStore.thumbnail(deniedStore.assets[0])
    try check(deniedPoster == nil && deniedStore.user == nil && credentials.sessions[.test] == nil, "one-byte video probe preserves 401 handling and removes expired credentials")
    let late = StudioStubTransport([studioLoginStep(), StudioStubStep(path: "/api/workspaces", json: studioWorkspaceJSON), StudioStubStep(path: "/api/assets", json: videoPage), StudioStubStep(path: "/api/private-files/video-a", status: 206, headers: ["Content-Type":"video/mp4", "Content-Range":"bytes 0-0/100"], json: "x", delay: 120_000_000), StudioStubStep(path: "/api/jobs", json: "[]")])
    let store = StudioStore(directory: directory, credentials: StudioMemoryCredentials(), transport: late)
    await store.login(email: "a@example.invalid", password: "test", code: "")
    let stream = try store.videoStream(store.assets[0])
    let request = Task { try await stream.reader.metadata() }
    try await Task.sleep(nanoseconds: 20_000_000)
    await store.selectSource(.recent)
    do { _ = try await request.value; throw NativeTestFailure(description: "Old video survived source change") }
    catch is CancellationError { try check(true, "changing the asset source cancels in-flight video readers") }
    let thumbnailJob = try JSONDecoder().decode(StudioJob.self, from: Data(#"{"id":"job-thumb","type":"video","status":"done","model":"model","outputUrl":"/api/private-files/video","thumbUrl":"/api/private-files/poster","createdAt":"2026-10-03T00:00:00Z"}"#.utf8))
    try check(thumbnailJob.asset?.thumbUrl == "/api/private-files/poster", "recent results accept a shared server-generated cover when available")
}

@MainActor private func runStudioSyncTests(directory: URL) async throws {
    let empty = #"{"items":[],"total":0,"nextCursor":null}"#
    func page(_ ids: [String], total: Int, cursor: String? = nil) throws -> String {
        let items = ids.map { ["id": $0, "name": $0, "kind": "image", "url": "/api/private-files/" + $0] }
        return String(data: try JSONSerialization.data(withJSONObject: ["items": items, "total": total, "nextCursor": cursor as Any? ?? NSNull()]), encoding: .utf8)!
    }
    let first = try page(["a"], total: 2, cursor: "second")
    let sync = StudioStubTransport([
        studioLoginStep(), StudioStubStep(path: "/api/workspaces", json: studioWorkspaceJSON),
        StudioStubStep(path: "/api/assets", json: first),
        StudioStubStep(path: "/api/assets", json: try page(["b"], total: 2)),
        StudioStubStep(path: "/api/assets", json: first),
        StudioStubStep(path: "/api/assets", json: try page(["new"], total: 3, cursor: "after-new")),
        StudioStubStep(path: "/api/assets", json: try page(["a", "b"], total: 3)),
        StudioStubStep(path: "/api/assets", status: 503, json: "{}"),
        StudioStubStep(path: "/api/assets", json: try page(["new", "b"], total: 2)),
        StudioStubStep(path: "/api/assets", json: empty, delay: 120_000_000),
        StudioStubStep(path: "/api/assets", json: try page(["searched"], total: 1))
    ])
    let store = StudioStore(directory: directory, credentials: StudioMemoryCredentials(), transport: sync)
    await store.login(email: "a@example.invalid", password: "test", code: "")
    await store.refresh(more: true)
    await store.refresh(background: true)
    let inactiveCount = await sync.requests.count
    try check(inactiveCount == 4 && store.assets.map(\.id) == ["a", "b"], "inactive library does not poll or discard older loaded pages")
    store.setLibraryActive(true)
    await store.refresh(background: true)
    let unchangedCount = await sync.requests.count
    try check(unchangedCount == 5 && store.assets.map(\.id) == ["a", "b"], "unchanged head uses one metadata request, preserving older pages")
    await store.refresh(background: true)
    try check(store.assets.map(\.id) == ["new", "a", "b"] && store.total == 3 && store.nextCursor == nil, "new head reloads enough older pages before replacing the visible snapshot")
    await store.refresh(background: true)
    try check(store.assets.map(\.id) == ["new", "a", "b"] && !store.syncNote.isEmpty, "failed background sync preserves the prior snapshot with retry feedback")
    await store.refresh(background: true)
    try check(store.assets.map(\.id) == ["new", "b"] && store.syncNote.isEmpty && store.lastSyncedAt != nil, "later successful snapshot removes deleted entries and clears sync error")
    let late = Task { await store.refresh(background: true) }
    try await Task.sleep(nanoseconds: 20_000_000)
    store.query = "searched"
    await store.refresh(); await late.value
    try check(store.assets.map(\.id) == ["searched"] && !store.loadingAssets, "late background response cannot replace a newer search")
    store.setLibraryActive(false); await store.refresh(background: true)
    let stopped = await sync.remaining()
    try check(stopped == 0, "deactivated library stops background requests")

    let jobs = #"[{"id":"image-job","type":"image","status":"done","model":"Seedream","outputUrl":"/api/private-files/new-image","createdAt":"2026-10-03T00:00:00.000Z"},{"id":"video-job","type":"video","status":"done","model":"Seedance","outputUrl":"/api/private-files/new-video","createdAt":"2026-10-03T00:01:00Z"},{"id":"pending-job","type":"image","status":"running","outputUrl":null,"createdAt":"2026-10-03T00:02:00Z"},{"id":"failed-job","type":"video","status":"error","outputUrl":"https://example.invalid/failed.mp4","createdAt":"2026-10-03T00:03:00Z"},{"id":"workflow-job","type":"workflow","status":"done","outputUrl":null,"createdAt":"2026-10-03T00:04:00Z"}]"#
    let justDone = #"[{"id":"pending-job","type":"image","status":"done","model":"NewModel","outputUrl":"/api/private-files/just-done","createdAt":"2026-10-03T00:02:00Z"}]"#
    let recent = StudioStubTransport([
        studioLoginStep(), StudioStubStep(path: "/api/workspaces", json: studioWorkspaceJSON), StudioStubStep(path: "/api/assets", json: empty),
        StudioStubStep(path: "/api/jobs", json: jobs), StudioStubStep(path: "/api/jobs", json: jobs),
        StudioStubStep(path: "/api/jobs", json: justDone),
        StudioStubStep(path: "/api/jobs", json: jobs, delay: 120_000_000),
        StudioStubStep(path: "/api/assets", json: try page(["saved"], total: 1)),
        StudioStubStep(path: "/api/jobs", status: 401, json: #"{"error":"expired"}"#)
    ])
    let recentStore = StudioStore(directory: directory, credentials: StudioMemoryCredentials(), transport: recent)
    await recentStore.login(email: "a@example.invalid", password: "test", code: "")
    await recentStore.selectSource(.recent)
    try check(recentStore.assets.map(\.id) == ["job:image-job", "job:video-job"] && recentStore.nextCursor == nil, "unregistered completed image/video outputs appear without saving them as library assets")
    try check(recentStore.assets[0].title.contains("Seedream") && recentStore.assets[0].tags == ["最近生成"], "recent result label exposes available model/date/id rather than inventing prompt names")
    let jobReference = try recentStore.referenceText(ids: ["job:video-job", "job:image-job"])
    let jobEnvelope = try JSONDecoder().decode(StudioReferenceEnvelope.self, from: Data(jobReference.dropFirst(StudioReferenceEnvelope.prefix.count).utf8))
    try check(jobEnvelope.items.map(\.id) == ["video-job", "image-job"] && jobEnvelope.items.allSatisfy { $0.source == "job" && $0.workspaceId == nil }, "unregistered job references preserve selection order and job identity")
    recentStore.query = "Seedance"; await recentStore.refresh()
    try check(recentStore.assets.map(\.id) == ["job:video-job"], "recent search filters the bounded result window locally")
    recentStore.query = ""; await recentStore.refresh()
    try check(recentStore.assets.map(\.id) == ["job:pending-job"], "a newly completed task becomes a usable result on the next refresh")
    recentStore.setLibraryActive(true)
    let recentTask = Task { await recentStore.refresh(background: true) }
    try await Task.sleep(nanoseconds: 20_000_000)
    await recentStore.selectSource(.library); await recentTask.value
    try check(recentStore.assets.map(\.id) == ["saved"] && recentStore.source == .library, "late generation result cannot contaminate the workspace library after switching sources")
    await recentStore.selectSource(.recent)
    try check(recentStore.user == nil && recentStore.assets.isEmpty && recentStore.source == .library, "generation endpoint expiry clears identity and all prior material")
    await recentStore.logout()
    let requests = await recent.requests
    let jobRequests = requests.filter { $0.url?.path == "/api/jobs" }
    try check(jobRequests.count == 5 && jobRequests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Cookie") != nil && $0.value(forHTTPHeaderField: "X-Workspace-Id") == nil && $0.url?.query == nil }, "generation history uses authenticated account scope, without falsely claiming workspace or server search filters")
    try check(requests.allSatisfy { $0.httpMethod == "GET" || ["/api/auth/login", "/api/auth/logout"].contains($0.url?.path) }, "sync never saves assets, triggers generation or writes Studio data")
    try check(recentStore.assets.isEmpty && recentStore.source == .library, "logout clears recent generated results and source state")
}

@MainActor private func runStudioMediaTests(directory: URL) async throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
    var imageStep = StudioStubStep(path: "/api/private-files/private-a", headers: ["Content-Type": "image/jpeg"], json: "")
    imageStep.bytes = jpeg
    let changedThumbnail = StudioStubStep(path: "/api/private-files/new-thumb", headers: ["Content-Type": "image/jpeg"], json: "", bytes: jpeg)
    let transport = StudioStubTransport([studioLoginStep(), StudioStubStep(path: "/api/workspaces", json: studioWorkspaceJSON), StudioStubStep(path: "/api/assets", json: studioPageJSON), imageStep, imageStep, imageStep,
        StudioStubStep(path: "/api/assets", json: #"{"items":[{"id":"asset-a","url":"/api/private-files/private-a","thumbUrl":"/api/private-files/new-thumb","kind":"image","name":"updated"}],"total":1,"nextCursor":null}"#), changedThumbnail])
    let store = StudioStore(directory: directory, credentials: StudioMemoryCredentials(), transport: transport)
    await store.login(email: "a@example.invalid", password: "test", code: "")
    let asset = store.assets[0]
    var copied: Data?
    store.copyImage(asset) { copied = $0; return true }
    for _ in 0..<100 { if copied != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    try check(copied?.prefix(8) == Data([137,80,78,71,13,10,26,10]), "JPEG copy is converted into actual PNG bytes before tagging the pasteboard")
    let dimensions = try ImageCodec.dimensions(copied!)
    try check(dimensions.width == 12 && dimensions.height == 8, "image copy preserves original dimensions")
    let thumb = await store.thumbnail(asset)
    try check(thumb != nil && (thumb?.size.width ?? 999) <= 280, "Studio thumbnail decode is bounded and independent of original payload")
    let destination = directory.appendingPathComponent("download-test.jpg")
    try Data("prior content".utf8).write(to: destination)
    store.download(asset, destination: destination)
    var saved: Data?
    for _ in 0..<100 {
        saved = try Data(contentsOf: destination)
        if saved == jpeg { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try check(saved == jpeg, "download replaces the chosen destination with original bytes")
    let requests = await transport.requests
    try check(requests.suffix(3).allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "kaki_session=test-session-a" }, "copy, thumbnail and download enforce private-file identity")
    _ = await store.thumbnail(asset)
    let cachedCount = await transport.requests.count
    try check(cachedCount == requests.count, "unchanged thumbnail is served from bounded memory cache")
    await store.refresh()
    let changed = await store.thumbnail(store.assets[0])
    let afterChange = await transport.requests
    try check(changed != nil && afterChange.last?.url?.path == "/api/private-files/new-thumb", "changed thumbnail URL for the same asset id invalidates the preview cache")
    let late = StudioStubTransport([studioLoginStep(), StudioStubStep(path: "/api/workspaces", json: studioWorkspaceJSON), StudioStubStep(path: "/api/assets", json: studioPageJSON), StudioStubStep(path: "/api/private-files/private-a", json: "", delay: 120_000_000, bytes: jpeg), StudioStubStep(path: "/api/auth/logout", status: 204, json: "")])
    let lateStore = StudioStore(directory: directory, credentials: StudioMemoryCredentials(), transport: late)
    await lateStore.login(email: "a@example.invalid", password: "test", code: "")
    var leakedCopy = false
    lateStore.copyImage(lateStore.assets[0]) { _ in leakedCopy = true; return true }
    try await Task.sleep(nanoseconds: 20_000_000)
    await lateStore.logout()
    try await Task.sleep(nanoseconds: 140_000_000)
    try check(!leakedCopy && lateStore.assets.isEmpty, "logout cancels in-flight material before it can modify clipboard")
}

@MainActor private func runStudioReferenceSelectionTests() throws {
    let visible = (1...25).map { "asset-" + String($0) }
    var selection = StudioSelection()
    selection.reconcile(visible)
    try check(selection.ids == ["asset-1"], "library selects first visible material")
    selection.select("asset-3", visible: visible, toggle: false, range: false)
    selection.select("asset-5", visible: visible, toggle: true, range: false)
    try check(selection.ids == ["asset-3", "asset-5"], "Command click adds in user order")
    selection.select("asset-3", visible: visible, toggle: true, range: false)
    try check(selection.ids == ["asset-5"], "Command click removes an item")
    selection.select("asset-7", visible: visible, toggle: false, range: true)
    try check(selection.ids == ["asset-3", "asset-4", "asset-5", "asset-6", "asset-7"], "Shift range follows display order and anchor")
    try check(!selection.select("asset-25", visible: visible, toggle: false, range: true) && selection.ids.count == 5, "oversized range leaves prior selection intact")
    selection.reconcile(["asset-5", "asset-7"])
    try check(selection.ids == ["asset-5", "asset-7"], "refresh removes unavailable items and preserves order")
    selection.clear(); selection.reconcile(["new"])
    try check(selection.ids == ["new"], "new source cannot retain old selection")
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-reference-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = HistoryStore(directory: directory)
    let clipboard = ClipboardService(store: history, pasteboard: board)
    let text = try StudioReferenceEnvelope(version: 1, origin: "https://test.kakiai.xin", items: [StudioMaterialReference(source: "job", id: "abc", workspaceId: nil)]).clipboardText()
    try check(clipboard.writeStudioReferences(text) != nil && board.string(forType: .string) == text && board.data(forType: .png) == nil, "reference write is browser-readable text without image data")
    clipboard.captureNow()
    try check(history.items.isEmpty, "own reference write is not recaptured as clipboard history")
}

@MainActor private func runStudioExportTests() async throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("kaki-export-test-" + UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let output = dir.appendingPathComponent("downloads")
    try fm.createDirectory(at: output, withIntermediateDirectories: false)
    let page = #"{"items":[{"id":"video-a","url":"/api/private-files/video-a","kind":"video","name":"片段.mp4"},{"id":"video-b","url":"/api/private-files/video-b","kind":"video","name":"片段.mp4"},{"id":"audio-c","url":"/api/private-files/audio-c","kind":"audio","name":"声音"}],"total":3,"nextCursor":null}"#
    let video = Data("original video bytes".utf8), audio = Data("original audio bytes".utf8)
    let videoStep = StudioStubStep(path: "/api/private-files/video-a", headers: ["Content-Type":"video/mp4"], json: "", bytes: video)
    let transport = StudioStubTransport([
        studioLoginStep(), StudioStubStep(path: "/api/workspaces", json: studioWorkspaceJSON), StudioStubStep(path: "/api/assets", json: page),
        videoStep, videoStep,
        StudioStubStep(path: "/api/private-files/video-b", headers: ["Content-Type":"video/mp4; charset=binary"], json: "", bytes: video),
        StudioStubStep(path: "/api/private-files/audio-c", headers: ["Content-Type":"audio/mpeg"], json: "", bytes: audio),
        StudioStubStep(path: "/api/private-files/audio-c", headers: ["Content-Type":"audio/mpeg"], json: "", bytes: audio),
        videoStep,
        StudioStubStep(path: "/api/private-files/video-b", status: 500, json: "{}"),
        StudioStubStep(path: "/api/private-files/audio-c", headers: ["Content-Type":"audio/mpeg"], json: "", bytes: audio), videoStep
    ])
    let store = StudioStore(directory: dir, credentials: StudioMemoryCredentials(), transport: transport)
    await store.login(email: "a@example.invalid", password: "test", code: "")
    let board = NSPasteboard(name: .init("kaki-material-export-" + UUID().uuidString))
    defer { board.releaseGlobally() }
    let history = HistoryStore(directory: dir.appendingPathComponent("history"))
    let clipboard = ClipboardService(store: history, pasteboard: board)
    var copied: URL?
    store.copyMaterial(store.assets[0], consumeImage: { _ in false }, consumeFile: { file in copied = file; return clipboard.writeMaterialFile(file) != nil })
    try check(store.mediaBusy, "copy file is visibly busy until transfer and clipboard installation complete")
    for _ in 0..<200 { if !store.mediaBusy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    guard let copied else { throw NativeTestFailure(description: "Video file copy did not finish") }
    try check(copied.pathExtension == "mp4" && (try? Data(contentsOf: copied)) == video, "video clipboard retains original file after temporary HTTP file is removed")
    try check(board.string(forType: .fileURL) == copied.absoluteString && board.string(forType: .string) == nil, "actual media copy advertises a local file instead of remote URL or reference text")
    clipboard.captureNow()
    try check(history.items.isEmpty, "own file copy does not create misleading text history")
    let prior = output.appendingPathComponent("片段.mp4")
    try Data("do not replace".utf8).write(to: prior)
    store.download(ids: ["video-a", "video-b", "audio-c"], to: output)
    for _ in 0..<200 { if !store.mediaBusy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    try check((try? Data(contentsOf: prior)) == Data("do not replace".utf8), "default-folder and batch download never overwrite existing files")
    try check((try? Data(contentsOf: output.appendingPathComponent("片段 (2).mp4"))) == video && (try? Data(contentsOf: output.appendingPathComponent("片段 (3).mp4"))) == video, "same-name selected files are both downloaded with unique suffixes")
    try check((try? Data(contentsOf: output.appendingPathComponent("声音.mp3"))) == audio && store.message == "已下载 3 项。", "batch uses actual response MIME and reports completed count")
    let outputNames = try fm.contentsOfDirectory(atPath: output.path)
    try check(!outputNames.contains(where: { $0.hasPrefix(".kaki-download-") }), "batch leaves no staging files")
    var copiedAudio: URL?
    store.copyMaterial(store.assets[2], consumeImage: { _ in false }, consumeFile: { file in copiedAudio = file; return clipboard.writeMaterialFile(file) != nil })
    for _ in 0..<200 { if !store.mediaBusy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    try check(copiedAudio?.pathExtension == "mp3" && !fm.fileExists(atPath: copied.path), "next successful file copy prunes prior owned file cache")
    store.download(ids: ["video-a", "video-b", "audio-c"], to: output)
    for _ in 0..<200 { if !store.mediaBusy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    try check(store.message.contains("已下载 2 项，1 项失败") && fm.fileExists(atPath: output.appendingPathComponent("声音 (2).mp3").path), "failed batch item does not discard earlier files or prevent subsequent downloads")
    store.copyMaterial(store.assets[0], consumeImage: { _ in false }, consumeFile: { _ in false })
    for _ in 0..<200 { if !store.mediaBusy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    let retainedClipboardFiles = try fm.contentsOfDirectory(atPath: dir.appendingPathComponent("studio-clipboard").path)
    try check(copiedAudio.map { fm.fileExists(atPath: $0.path) } == true && retainedClipboardFiles.count == 1 && board.string(forType: .fileURL) == copiedAudio?.absoluteString, "failed clipboard installation cleans only the new file and preserves last successful copy")
    let remaining = await transport.remaining()
    try check(remaining == 0, "batch reuses cached files with one lightweight validation instead of another full GET")
    let safeName = StudioMediaFiles.filename(title: "../危险:/名称\\片段.mp4", suffix: "mov")
    try check(!safeName.contains("/") && !safeName.contains(":") && !safeName.contains("\\") && safeName.hasSuffix(".mov"), "filenames cannot escape destination and follow media MIME")
    try check(StudioMediaFiles.filename(title: "...", suffix: "png") == "素材.png" && StudioMediaFiles.filename(title: String(repeating: "材", count: 300), suffix: "mp4").utf8.count <= 255, "empty and long multilingual titles get usable bounded filenames")
    try check(!StudioMediaFiles.isWritableDirectory(prior), "file path cannot masquerade as a default download folder")
    let cancelTransport = StudioStubTransport([
        studioLoginStep(), StudioStubStep(path: "/api/workspaces", json: studioWorkspaceJSON), StudioStubStep(path: "/api/assets", json: page), videoStep,
        StudioStubStep(path: "/api/private-files/video-b", headers: ["Content-Type":"video/mp4"], json: "", delay: 500_000_000, bytes: video)
    ])
    let cancelled = StudioStore(directory: dir, credentials: StudioMemoryCredentials(), transport: cancelTransport)
    await cancelled.login(email: "a@example.invalid", password: "test", code: "")
    let partialOutput = dir.appendingPathComponent("partial")
    try fm.createDirectory(at: partialOutput, withIntermediateDirectories: false)
    cancelled.download(ids: ["video-a", "video-b", "audio-c"], to: partialOutput)
    for _ in 0..<200 {
        if await cancelTransport.requests.count == 5 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    cancelled.cancelMedia()
    try await Task.sleep(nanoseconds: 40_000_000)
    let partialNames = try fm.contentsOfDirectory(atPath: partialOutput.path)
    let cancelledRequests = await cancelTransport.requests
    try check(partialNames == ["片段.mp4"] && !cancelled.mediaBusy && cancelled.message.contains("已取消"), "manual cancellation keeps completed files and stops subsequent items")
    try check(!cancelledRequests.contains(where: { $0.url?.path == "/api/private-files/audio-c" }), "cancellation does not fetch remaining batch materials")
    let lateTransport = StudioStubTransport([
        studioLoginStep(), StudioStubStep(path: "/api/workspaces", json: studioWorkspaceJSON), StudioStubStep(path: "/api/assets", json: page),
        StudioStubStep(path: "/api/private-files/video-a", headers: ["Content-Type":"video/mp4"], json: "", delay: 120_000_000, bytes: video),
        StudioStubStep(path: "/api/auth/logout", status: 204, json: "")
    ])
    let late = StudioStore(directory: dir, credentials: StudioMemoryCredentials(), transport: lateTransport)
    await late.login(email: "a@example.invalid", password: "test", code: "")
    let emptyOutput = dir.appendingPathComponent("cancelled")
    try fm.createDirectory(at: emptyOutput, withIntermediateDirectories: false)
    late.download(ids: ["video-a", "video-b"], to: emptyOutput)
    try await Task.sleep(nanoseconds: 20_000_000)
    await late.logout()
    try await Task.sleep(nanoseconds: 140_000_000)
    let cancelledNames = try fm.contentsOfDirectory(atPath: emptyOutput.path)
    try check(!late.mediaBusy && cancelledNames.isEmpty, "logout cancels batch before late response can write any file")
}
