import Foundation
import AppKit

@MainActor func runStudioCacheTests() async throws {
    try await runStudioConcurrencyTests()
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("kaki-disk-cache-tests-" + UUID().uuidString)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    let root = directory.appendingPathComponent("cache")
    let cache = StudioDiskCache(directory: root, limitMB: 1, days: 7)
    func key(_ id: String, user: String = "a", workspace: String = "w", environment: String = "test", role: String = "original") -> StudioDiskCache.Key {
        StudioDiskCache.Key(environment: environment, user: user, workspace: workspace, asset: id, url: "https://example.invalid/" + id, role: role)
    }
    let file = directory.appendingPathComponent("payload")
    let bytes = Data(repeating: 17, count: 400 * 1024)
    try bytes.write(to: file)
    let url = URL(string: "https://example.invalid/one")!
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"video/mp4", "ETag":"version-1"])!
    let media = StudioHTTPFile(file: file, response: response)
    let token = await cache.lookup(key("one")).epoch
    await cache.store(media, key: key("one"), epoch: token, now: Date().addingTimeInterval(-100))
    await cache.store(media, key: key("two"), epoch: token, now: Date().addingTimeInterval(-50))
    guard let lease = try await cache.lease(key("one"), responseURL: url, maximumBytes: 1024 * 1024) else { throw NativeTestFailure(description: "Cache lease missing") }
    defer { try? fm.removeItem(at: lease.file) }
    await cache.store(media, key: key("three"), epoch: token)
    let one = await cache.lookup(key("one")), two = await cache.lookup(key("two")), three = await cache.lookup(key("three"))
    let stats = await cache.stats()
    try check(one.entry != nil && two.entry == nil && three.entry != nil && stats.bytes <= 1024 * 1024, "cache evicts least recently used files within its byte budget")
    let restarted = StudioDiskCache(directory: root, limitMB: 1, days: 7)
    let restartEntry = await restarted.lookup(key("one")).entry
    try check(restartEntry?.headers["ETag"] == "version-1" && restartEntry?.mime == "video/mp4", "cache survives relaunch with content validator and media format")
    for other in [key("one", user: "b"), key("one", workspace: "other"), key("one", environment: "production"), key("one", role: "preview")] {
        let entry = await cache.lookup(other).entry
        try check(entry == nil, "cache isolates account/environment/workspace and media representation")
    }
    let index = try String(contentsOf: root.appendingPathComponent("index.json"), encoding: .utf8)
    try check(!index.contains("example.invalid") && !index.contains("Cookie"), "cache index contains opaque keys rather than private URLs or account credentials")
    let foreign = root.appendingPathComponent("keep.txt")
    try Data("foreign file".utf8).write(to: foreign)
    await cache.clear()
    let empty = await cache.stats()
    try check(empty.bytes == 0 && (try? Data(contentsOf: lease.file)) == bytes && fm.fileExists(atPath: foreign.path), "cache cleanup preserves active leases and unrelated files")
    await cache.store(media, key: key("late"), epoch: token)
    let late = await cache.lookup(key("late")).entry
    try check(late == nil, "clear rejects stale in-flight writes that would repopulate deleted cache")
    let freshToken = await cache.lookup(key("fresh")).epoch
    await cache.store(media, key: key("fresh"), epoch: freshToken)
    _ = await cache.lookup(key("fresh"), now: Date().addingTimeInterval(8 * 86400))
    let expired = await cache.stats()
    try check(expired.bytes == 0, "seven days without use expires original files")
    await cache.configure(limitMB: 0, days: 7)
    let disabledToken = await cache.lookup(key("disabled")).epoch
    await cache.store(media, key: key("disabled"), epoch: disabledToken)
    let disabled = await cache.stats()
    try check(disabled.files == 0, "disabled disk cache does not write newly fetched content")
    await cache.configure(limitMB: 1, days: 7)
    let corruptToken = await cache.lookup(key("corrupt")).epoch
    await cache.store(media, key: key("corrupt"), epoch: corruptToken)
    try Data("truncated".utf8).write(to: root.appendingPathComponent(key("corrupt").value + ".data"))
    let corrupted = try await cache.lease(key("corrupt"), responseURL: url, maximumBytes: 1024 * 1024)
    try check(corrupted == nil, "damaged cache payload is discarded instead of supplied to the clipboard")
    let external = directory.appendingPathComponent("external-disk")
    try fm.createDirectory(at: external, withIntermediateDirectories: false)
    let externalCache = external.appendingPathComponent("Kaki Tools Cache")
    let realVolume = (try? external.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? ""
    let oldEpoch = await cache.lookup(key("moving")).epoch
    await cache.store(media, key: key("moving"), epoch: oldEpoch)
    let switched = try await cache.relocate(to: externalCache, volumeUUID: realVolume)
    let newEpoch = await cache.lookup(key("disk")).epoch
    await cache.store(media, key: key("disk"), epoch: newEpoch)
    try check(switched && !fm.fileExists(atPath: root.appendingPathComponent(key("moving").value + ".data").path) && fm.fileExists(atPath: externalCache.appendingPathComponent(key("disk").value + ".data").path), "changing cache location cleans owned old files and puts new cache on selected disk")
    let hiddenExternal = directory.appendingPathComponent("disconnected-disk")
    try fm.moveItem(at: external, to: hiddenExternal)
    let unavailable = await cache.stats()
    await cache.store(media, key: key("offline"), epoch: newEpoch)
    try check(!unavailable.available && !fm.fileExists(atPath: external.path), "disconnected cache disk never causes a substitute directory to be created on system volume")
    try fm.moveItem(at: hiddenExternal, to: external)
    let resumed = await cache.lookup(key("disk")).entry
    try check(resumed != nil, "reconnected selected disk resumes its existing cache")
    let wrongVolume = StudioDiskCache(directory: externalCache, limitMB: 1, days: 7, volumeUUID: "not-the-selected-disk")
    await wrongVolume.clear()
    let wrongStats = await wrongVolume.stats()
    try check(!wrongStats.available && fm.fileExists(atPath: externalCache.appendingPathComponent(key("disk").value + ".data").path), "a different mounted volume is never read or cleaned as the selected cache disk")
    let foreignParent = directory.appendingPathComponent("foreign-parent")
    let foreignRoot = foreignParent.appendingPathComponent("Kaki Tools Cache")
    try fm.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
    let untouched = foreignRoot.appendingPathComponent("user-document.txt")
    try bytes.write(to: untouched)
    do { _ = try await cache.relocate(to: foreignRoot, volumeUUID: ""); throw NativeTestFailure(description: "Occupied foreign cache folder accepted") }
    catch CocoaError.fileWriteNoPermission { try check((try? Data(contentsOf: untouched)) == bytes, "occupied unowned directory is rejected without changing user files") }
    let stillCurrent = await cache.lookup(key("disk")).entry
    try check(stillCurrent != nil, "failed location switch keeps prior cache active")
    try await runStudioAccessPersistenceTests(directory: directory)
    try await runStudioCacheVersionTests(directory: directory)
    try await runStudioCachedMediaTests(directory: directory)
    try await runStudioNoValidatorTests(directory: directory)
}

private struct CacheStep {
    let path: String
    let method: String
    var status = 200
    var headers = ["Content-Type":"application/json"]
    var body = Data()
    var delay: UInt64 = 0
}
private actor CacheTransport: StudioTransport {
    var steps: [CacheStep]
    var requests: [URLRequest] = []
    init(_ steps: [CacheStep]) { self.steps = steps }
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile {
        requests.append(request)
        guard !steps.isEmpty else { throw NativeTestFailure(description: "Unexpected cache transport call") }
        let step = steps.removeFirst()
        guard request.url?.path == step.path && request.httpMethod == step.method else { throw NativeTestFailure(description: "Wrong cache HTTP route or method") }
        if step.delay > 0 { try await Task.sleep(nanoseconds: step.delay) }
        guard step.body.count <= maximumBytes else { throw StudioError.tooLarge }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-cache-http-test-" + UUID().uuidString)
        try step.body.write(to: file)
        return StudioHTTPFile(file: file, response: HTTPURLResponse(url: request.url!, statusCode: step.status, httpVersion: nil, headerFields: step.headers)!)
    }
}
@MainActor private func runStudioCachedMediaTests(directory: URL) async throws {
    let dir = directory.appendingPathComponent("integration")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    let json = { (text: String) in Data(text.utf8) }
    let user = #"{"user":{"id":"cache-user","email":"cache@example.invalid","name":"Fixture"}}"#
    let ws = #"[{"id":"cache-ws","name":"Fixture","kind":"personal","role":"owner","disabled":false}]"#
    let page = #"{"items":[{"id":"cached-video","url":"/api/private-files/cached-video","kind":"video","name":"素材.mp4"}],"total":1,"nextCursor":null}"#
    let login = CacheStep(path: "/api/auth/login", method: "POST", headers: ["Content-Type":"application/json", "Set-Cookie":"kaki_session=cache-fixture; Max-Age=604800; Path=/; HttpOnly; Secure; SameSite=Lax"], body: json(user))
    let workspaces = CacheStep(path: "/api/workspaces", method: "GET", body: json(ws))
    let assets = CacheStep(path: "/api/assets", method: "GET", body: json(page))
    let v1 = Data("version-one-media".utf8), v2 = Data("version-two-media".utf8)
    let mediaPath = "/api/private-files/cached-video"
    let transport = CacheTransport([
        login, workspaces, assets,
        CacheStep(path: mediaPath, method: "GET", headers: ["Content-Type":"video/mp4", "ETag":"v1"], body: v1),
        CacheStep(path: mediaPath, method: "HEAD", headers: ["Content-Type":"video/mp4", "ETag":"v1", "Content-Length":String(v1.count)]),
        CacheStep(path: mediaPath, method: "HEAD", headers: ["Content-Type":"video/mp4", "ETag":"v1", "Content-Length":String(v1.count)]),
        CacheStep(path: mediaPath, method: "HEAD", headers: ["Content-Type":"video/mp4", "ETag":"v2", "Content-Length":String(v2.count)]),
        CacheStep(path: mediaPath, method: "GET", headers: ["Content-Type":"video/mp4", "ETag":"v2"], body: v2),
        CacheStep(path: mediaPath, method: "HEAD", status: 403, body: json(#"{"error":"forbidden"}"#)),
        CacheStep(path: "/api/auth/logout", method: "POST", status: 204)
    ])
    let store = StudioStore(directory: dir, credentials: StudioMemoryCredentials(), transport: transport)
    await store.login(email: "cache@example.invalid", password: "fixture", code: "")
    let output = dir.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    store.download(ids: ["cached-video"], to: output)
    for _ in 0..<200 { if !store.mediaBusy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    let saved = output.appendingPathComponent("素材.mp4")
    try check((try? Data(contentsOf: saved)) == v1 && store.cacheBytes == Int64(v1.count), "first original read populates cache and user download separately")
    var copied: URL?
    store.copyMaterial(store.assets[0], consumeImage: { _ in false }, consumeFile: { copied = $0; return true })
    for _ in 0..<200 { if !store.mediaBusy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    let requests = await transport.requests
    try check(requests.filter { $0.url?.path == mediaPath && $0.httpMethod == "GET" }.count == 1 && copied.flatMap { try? Data(contentsOf: $0) } == v1, "repeat copy reuses cached bytes after lightweight HEAD access validation")
    let stream = try store.videoStream(store.assets[0])
    let local = try await stream.reader.read(offset: 0, length: v1.count)
    store.releaseVideoStream(stream)
    let previewRequests = await transport.requests
    try check(local == v1 && previewRequests.last?.httpMethod == "HEAD" && previewRequests.last?.value(forHTTPHeaderField: "Range") == nil, "cached original preview reads local ranges without downloading video again")
    store.download(ids: ["cached-video"], to: output)
    for _ in 0..<200 { if !store.mediaBusy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    try check((try? Data(contentsOf: output.appendingPathComponent("素材 (2).mp4"))) == v2, "changed object ETag invalidates cached original and downloads new content")
    var unauthorizedCopy = false
    store.copyMaterial(store.assets[0], consumeImage: { _ in false }, consumeFile: { _ in unauthorizedCopy = true; return true })
    for _ in 0..<200 { if !store.mediaBusy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    try check(!unauthorizedCopy && store.message.contains("访问权限"), "revoked access never serves old private media from cache")
    await store.clearMaterialCache()
    try check(store.cacheBytes == 0 && copied.map { FileManager.default.fileExists(atPath: $0.path) } == true && FileManager.default.fileExists(atPath: saved.path), "clean cache keeps user download and current clipboard file intact")
    await store.logout()
    let remaining = await transport.steps.count
    try check(remaining == 0, "cache protocol checks complete without hidden full media re-downloads")
}

@MainActor private func runStudioCacheVersionTests(directory: URL) async throws {
    let root = directory.appendingPathComponent("write-versions")
    let cache = StudioDiskCache(directory: root, limitMB: 1)
    let key = StudioDiskCache.Key(environment: "test", user: "fixture", workspace: "w", asset: "a", url: "https://example.invalid/a", role: "original")
    let source = directory.appendingPathComponent("version-payload")
    try Data("fixture".utf8).write(to: source)
    let url = URL(string: "https://example.invalid/a")!
    let media = StudioHTTPFile(file: source, response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"video/mp4", "ETag":"unchanged"])!)
    let absent = await cache.lookup(key)
    await cache.store(media, key: key, epoch: absent.epoch)
    let first = await cache.lookup(key)
    let removedAbsent = await cache.remove(key, ifUnchanged: absent.version)
    try check(!removedAbsent && first.entry != nil, "absence snapshot cannot invalidate a later first write")
    if let lease = try await cache.lease(key, responseURL: url, maximumBytes: 1024) { try? FileManager.default.removeItem(at: lease.file) }
    let touched = await cache.lookup(key)
    try check(touched.version == first.version, "cache lease updates usage without changing write identity")
    await cache.store(media, key: key, epoch: first.epoch)
    let second = await cache.lookup(key)
    guard let actualLease = try await cache.leaseVersioned(key, responseURL: url, maximumBytes: 1024) else { throw NativeTestFailure(description: "Versioned lease missing") }
    defer { try? FileManager.default.removeItem(at: actualLease.media.file) }
    try check(actualLease.version == second.version && actualLease.version != first.version, "atomic lease reports the actually leased write rather than an earlier lookup")
    let removedOld = await cache.remove(key, ifUnchanged: first.version)
    try check(second.version != first.version && !removedOld, "same ETag and same bytes still receive a new write identity")
    let missing = StudioHTTPFile(file: directory.appendingPathComponent("missing-source"), response: media.response)
    await cache.store(missing, key: key, epoch: second.epoch)
    let failedWrite = await cache.lookup(key)
    try check(failedWrite.version == second.version && failedWrite.entry != nil, "failed cache write preserves the existing identity and payload")
    let removedCurrent = await cache.remove(key, ifUnchanged: second.version)
    let empty = await cache.lookup(key)
    try check(removedCurrent && empty.entry == nil, "matching write snapshot can atomically remove a definitively invalid entry")
    await cache.store(media, key: key, epoch: empty.epoch)
    let recreated = await cache.lookup(key)
    let removedRecreated = await cache.remove(key, ifUnchanged: second.version)
    try check(recreated.entry != nil && !removedRecreated, "delete and recreate cannot reuse an old write identity")
    let index = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("index.json"))) as! [String: Any]
    let savedEntries = index["entries"] as! [[String: Any]]
    try check(index["version"] as? Int == 1 && Set(savedEntries[0].keys) == Set(["key", "owner", "mime", "bytes", "headers", "lastUsed"]), "in-memory write identities keep the existing v1 disk index schema")
    let restarted = StudioDiskCache(directory: root, limitMB: 1)
    let reloaded = await restarted.lookup(key)
    let removedBeforeRestart = await restarted.remove(key, ifUnchanged: recreated.version)
    try check(reloaded.entry?.headers["ETag"] == "unchanged" && !removedBeforeRestart, "restart loads existing index and assigns fresh local write identities")
    let removedReloaded = await restarted.remove(key, ifUnchanged: reloaded.version)
    let reloadedEmpty = await restarted.lookup(key)
    try check(removedReloaded && reloadedEmpty.entry == nil, "post-restart validation can still remove its observed cache entry")
}

@MainActor private func runStudioNoValidatorTests(directory: URL) async throws {
    let dir = directory.appendingPathComponent("no-validator")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    let v1 = Data("version-one-media".utf8), v2 = Data("version-two-media".utf8)
    let path = "/api/private-files/no-validator"
    let transport = CacheTransport([
        CacheStep(path: "/api/auth/login", method: "POST", headers: ["Content-Type":"application/json", "Set-Cookie":"kaki_session=cache-fixture; Max-Age=604800; Path=/; HttpOnly; Secure"], body: Data(#"{"user":{"id":"cache-user","email":"cache@example.invalid"}}"#.utf8)),
        CacheStep(path: "/api/workspaces", method: "GET", body: Data(#"[{"id":"cache-ws","name":"Fixture","kind":"personal","role":"owner","disabled":false}]"#.utf8)),
        CacheStep(path: "/api/assets", method: "GET", body: Data(#"{"items":[{"id":"no-validator","url":"/api/private-files/no-validator","kind":"video","name":"素材.mp4"}],"total":1}"#.utf8)),
        CacheStep(path: path, method: "GET", headers: ["Content-Type":"video/mp4"], body: v1),
        CacheStep(path: path, method: "HEAD", headers: ["Content-Type":"video/mp4", "Content-Length":String(v1.count)]),
        CacheStep(path: path, method: "GET", status: 503),
        CacheStep(path: path, method: "HEAD", headers: ["Content-Type":"video/mp4", "Content-Length":String(v2.count)]),
        CacheStep(path: path, method: "GET", headers: ["Content-Type":"video/mp4"], body: v2)
    ])
    let store = StudioStore(directory: dir, credentials: StudioMemoryCredentials(), transport: transport)
    let downloads = dir.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
    await store.login(email: "cache@example.invalid", password: "fixture", code: "")
    store.download(ids: ["no-validator"], to: downloads)
    for _ in 0..<200 { if !store.mediaBusy { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    store.download(ids: ["no-validator"], to: downloads)
    for _ in 0..<200 { if !store.mediaBusy { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    try check(store.cacheFiles == 1 && !FileManager.default.fileExists(atPath: downloads.appendingPathComponent("素材 (2).mp4").path), "validator-free transient GET failure retains cache without serving unverifiable old media")
    store.download(ids: ["no-validator"], to: downloads)
    for _ in 0..<200 { if !store.mediaBusy { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let requests = await transport.requests
    let remaining = await transport.steps.count
    try check((try? Data(contentsOf: downloads.appendingPathComponent("素材 (2).mp4"))) == v2 && requests.filter { $0.url?.path == path && $0.httpMethod == "GET" }.count == 3 && remaining == 0, "same-size changed content without ETag/Last-Modified is fetched rather than mistaken for cached identity")
    store.shutdown()
}

@MainActor private func runStudioAccessPersistenceTests(directory: URL) async throws {
    let root = directory.appendingPathComponent("access-write-tests")
    let cache = StudioDiskCache(directory: root, limitMB: 1)
    let key = StudioDiskCache.Key(environment: "test", user: "fixture", workspace: "w", asset: "hot", url: "https://example.invalid/hot", role: "original")
    let file = directory.appendingPathComponent("hot-payload")
    let data = Data("hot-media".utf8)
    try data.write(to: file)
    let url = URL(string: "https://example.invalid/hot")!
    let media = StudioHTTPFile(file: file, response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"video/mp4"])!)
    let initial = await cache.lookup(key)
    await cache.store(media, key: key, epoch: initial.epoch)
    let index = root.appendingPathComponent("index.json")
    let before = try Data(contentsOf: index)
    var changedFiles = 0, previous = before
    for _ in 0..<10 {
        guard let lease = try await cache.lease(key, responseURL: url, maximumBytes: 1024) else { throw NativeTestFailure(description: "Hot cache lease missing") }
        try check((try? Data(contentsOf: lease.file)) == data, "hot cache lease preserves owned payload")
        try? FileManager.default.removeItem(at: lease.file)
        _ = await cache.stats()
        let current = try Data(contentsOf: index)
        if current != previous { changedFiles += 1 }; previous = current
    }
    try check(changedFiles == 0, "ten hot leases and stats do not rewrite the index inside the access persistence window")
    let used = await cache.lookup(key).entry!.lastUsed
    let other = StudioDiskCache.Key(environment: "test", user: "fixture", workspace: "w", asset: "other", url: "https://example.invalid/other", role: "original")
    await cache.store(media, key: other, epoch: initial.epoch)
    let restarted = StudioDiskCache(directory: root, limitMB: 1)
    let savedUse = await restarted.lookup(key).entry!.lastUsed
    try check(abs(savedUse.timeIntervalSince(used)) < 0.001, "structural write includes pending access timestamps for relaunch")
    await cache.store(media, key: key, epoch: initial.epoch, now: Date().addingTimeInterval(-120))
    let old = try Data(contentsOf: index)
    guard let lease = try await cache.lease(key, responseURL: url, maximumBytes: 1024) else { throw NativeTestFailure(description: "Old access fixture missing") }
    try? FileManager.default.removeItem(at: lease.file)
    let persisted = try Data(contentsOf: index)
    try check(persisted != old, "first access after the persistence window immediately updates the disk timestamp")
    await cache.remove(key)
    let deleted = StudioDiskCache(directory: root, limitMB: 1)
    let removed = await deleted.lookup(key).entry
    try check(removed == nil, "entry deletion is durable despite access write throttling")
    print("Cache index observation: 10 hot leases plus stats, \(changedFiles) index content changes")
}
