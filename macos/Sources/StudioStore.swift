import Foundation
import AppKit
import Combine
import ImageIO

@MainActor final class StudioStore: ObservableObject {
    @Published private(set) var environment: StudioEnvironment = .test
    @Published private(set) var user: StudioUser?
    @Published private(set) var workspaces: [StudioWorkspace] = []
    @Published private(set) var workspaceID = ""
    @Published private(set) var source: StudioSource = .library
    @Published private(set) var assets: [StudioAsset] = []
    @Published private(set) var total = 0
    @Published private(set) var nextCursor: String?
    @Published private(set) var busy = false
    @Published private(set) var loadingAssets = false
    @Published private(set) var twoFactorRequired = false
    @Published private(set) var message = ""
    @Published private(set) var sessionRevision = 0
    @Published private(set) var libraryActive = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var syncNote = ""
    @Published private(set) var cacheBytes: Int64 = 0
    @Published private(set) var cacheFiles = 0
    @Published private(set) var cacheClearing = false
    @Published private(set) var cacheMessage = ""
    @Published private(set) var cacheAvailable = true
    @Published private(set) var cacheLocation = ""
    @Published private(set) var cacheChanging = false
    private let defaultCacheDirectory: URL
    private var cacheTimer: Timer?
    private let diskCache: StudioDiskCache
    private var cacheRevision = 0
    @Published var query = "" {
        didSet {
            if query != oldValue {
                thumbnailRevision += 1; thumbnailWork.cancelAll()
                searchGeneration += 1; loadingAssets = false
                assets = []; total = 0; nextCursor = nil; loadedQuery = nil; lastSyncedAt = nil; syncNote = ""
            }
        }
    }
    @Published var kind = "all"
    @Published private(set) var logoutCleanupPending = false
    private var suppressedEnvironments = Set<StudioEnvironment>()
    private var session: StudioSession?
    private let credentials: StudioCredentialStore
    private let transport: StudioTransport
    private let preference: URL
    private let clipboardDirectory: URL
    var mediaBusy: Bool { !mediaTasks.isEmpty }
    private var restored = false
    private var generation = 0
    private var searchGeneration = 0
    private var loadedQuery: String?
    @Published private var mediaTasks: [UUID: Task<Void, Never>] = [:]
    private let thumbnails = NSCache<NSString, NSImage>()
    private let thumbnailWork = StudioMediaWork<String, NSImage?>(limit: 4)
    private var thumbnailRevision = 0
    private let decodeThumbnail: (URL) async -> Data?
    private var videoStreams: [UUID: StudioVideoStream] = [:]
    private var posterSlots = Set<UUID>()
    private var failedPosters: [NSString: Date] = [:]
    init(directory: URL, credentials: StudioCredentialStore? = nil, transport: StudioTransport = StudioURLTransport(), cacheLimitMB: Int = 1024, cacheDays: Int = 7, cacheFolder: String = "", cacheVolumeUUID: String = "", cache: StudioDiskCache? = nil, thumbnailDecoder: ((URL) async -> Data?)? = nil) {
        decodeThumbnail = thumbnailDecoder ?? Self.thumbnailPNG
        defaultCacheDirectory = directory.appendingPathComponent("studio-cache", isDirectory: true)
        let cacheDirectory = cacheFolder.isEmpty ? defaultCacheDirectory : URL(fileURLWithPath: cacheFolder, isDirectory: true).appendingPathComponent("Kaki Tools Cache", isDirectory: true)
        cacheLocation = cacheDirectory.path
        diskCache = cache ?? StudioDiskCache(directory: cacheDirectory, limitMB: cacheLimitMB, days: cacheDays, volumeUUID: cacheVolumeUUID)
        self.credentials = credentials ?? StudioKeychain(); self.transport = transport
        clipboardDirectory = directory.appendingPathComponent("studio-clipboard", isDirectory: true)
        preference = directory.appendingPathComponent("studio-environment.json")
        if let data = try? Data(contentsOf: preference), let value = try? JSONDecoder().decode(String.self, from: data), let environment = StudioEnvironment(rawValue: value) { self.environment = environment }
        updateLogoutCleanupState()
        thumbnails.countLimit = 24; thumbnails.totalCostLimit = 12 * 1024 * 1024
    }
    // A non-secret, per-environment tombstone survives failed keychain deletion.
    // Only a successful explicit login may remove it and permit restoration.
    private var logoutMarker: URL { preference.deletingLastPathComponent().appendingPathComponent("studio-logout-" + environment.rawValue) }
    private var restoreSuppressed: Bool { suppressedEnvironments.contains(environment) || FileManager.default.fileExists(atPath: logoutMarker.path) }
    private func updateLogoutCleanupState() { logoutCleanupPending = restoreSuppressed && (try? Data(contentsOf: logoutMarker)) != Data([0]) }
    private func saveLogoutIntent(pending: Bool) throws {
        try FileManager.default.createDirectory(at: logoutMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([pending ? 1 : 0]).write(to: logoutMarker, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logoutMarker.path)
        suppressedEnvironments.insert(environment)
        logoutCleanupPending = pending
    }
    private var client: StudioClient { StudioClient(environment: environment, transport: transport) }
    func classicCliContext() -> (client: StudioClient, session: StudioSession, workspace: String)? {
        guard user != nil, let session, session.valid, !workspaceID.isEmpty else { return nil }
        return (client, session, workspaceID)
    }
    var visibleAssets: [StudioAsset] { assets.filter { kind == "all" || $0.kind == kind } }
    func setLibraryActive(_ value: Bool) { libraryActive = value }
    var syncStatus: String {
        if !syncNote.isEmpty { return syncNote }
        if let date = lastSyncedAt { return (libraryActive ? "前台每10秒更新 · " : "聚焦后自动更新 · ") + date.formatted(date: .omitted, time: .standard) + " 已同步" }
        return "素材按需读取，复制和下载后可在本机使用。"
    }
    var workspaceName: String { workspaces.first(where: { $0.id == workspaceID })?.name ?? "未选择工作区" }
    private func clearAccount() {
        cacheRevision += 1
        if let user {
            let owner = StudioDiskCache.Key(environment: environment.rawValue, user: user.id, workspace: "", asset: "", url: "", role: "").owner
            Task { await diskCache.clear(owner: owner); await refreshCacheStats() }
        }
        generation += 1; searchGeneration += 1; sessionRevision += 1
        for task in mediaTasks.values { task.cancel() }; mediaTasks.removeAll()
        session = nil; user = nil; workspaces = []; workspaceID = ""; source = .library
        assets = []; total = 0; nextCursor = nil; query = ""; kind = "all"
        thumbnailWork.cancelAll(); clearVideoStreams(); thumbnails.removeAllObjects(); busy = false; loadingAssets = false; twoFactorRequired = false
        loadedQuery = nil; lastSyncedAt = nil; syncNote = ""
    }
    func changeEnvironment(_ value: StudioEnvironment) async {
        guard value != environment else { return }
        clearAccount(); environment = value; updateLogoutCleanupState(); message = ""; restored = false
        do { try JSONEncoder().encode(value.rawValue).write(to: preference, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preference.path) }
        catch { message = "环境设置保存失败；本次切换仍然有效。" }
        await restoreSession()
    }
    func restoreSession() async {
        guard !restored else { return }; restored = true
        guard !restoreSuppressed else { updateLogoutCleanupState(); return }
        let revision = generation, api = client, env = environment
        busy = true
        defer { if generation == revision { busy = false } }
        do {
            guard let saved = try credentials.read(environment: env), saved.valid else { return }
            let profile = try await api.me(saved)
            guard generation == revision else { return }
            session = saved; user = profile; sessionRevision += 1
            await loadWorkspaces()
        } catch { if generation == revision { handle(error) } }
    }
    func retrySession() async {
        if restoreSuppressed { await logout(); return }
        restored = false; await restoreSession()
    }
    func login(email: String, password: String, code: String) async {
        guard !busy, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else { return }
        clearAccount(); busy = true; message = ""; restored = true
        let revision = generation, api = client, env = environment
        defer { if generation == revision { busy = false } }
        do {
            let result = try await api.login(email: email, password: password, code: code)
            guard generation == revision else { return }
            if result.twoFactorRequired { twoFactorRequired = true; message = "请输入动态验证码或备用码，再次登录。"; return }
            guard let saved = result.session, let profile = result.user else { throw StudioError.invalidResponse }
            try credentials.write(saved, environment: env)
            if FileManager.default.fileExists(atPath: logoutMarker.path) { try FileManager.default.removeItem(at: logoutMarker) }
            suppressedEnvironments.remove(env)
            logoutCleanupPending = false
            session = saved; user = profile; twoFactorRequired = false; sessionRevision += 1
            await loadWorkspaces()
        } catch {
            if generation == revision {
                if case StudioError.http(401, "invalid_2fa") = error { twoFactorRequired = true; message = error.localizedDescription }
                else { handle(error) }
            }
        }
    }
    private func loadWorkspaces() async {
        guard let saved = session else { return }
        let revision = generation, api = client
        do {
            let result = try await api.workspaces(saved)
            guard generation == revision else { return }
            workspaces = result.filter { $0.disabled != true }
            workspaceID = workspaces.first(where: { $0.kind == "personal" })?.id ?? workspaces.first?.id ?? ""
            if workspaceID.isEmpty { message = "当前账号暂无可用工作区，请在 Studio 中确认权限。"; return }
            await refresh()
        } catch { if generation == revision { handle(error) } }
    }
    func retryWorkspaces() async { guard user != nil && !busy else { return }; busy = true; let revision = generation; await loadWorkspaces(); if generation == revision { busy = false } }
    func selectWorkspace(_ id: String) async {
        guard id != workspaceID, workspaces.contains(where: { $0.id == id }) else { return }
        generation += 1; sessionRevision += 1; thumbnails.removeAllObjects()
        thumbnailWork.cancelAll()
        clearVideoStreams()
        for task in mediaTasks.values { task.cancel() }; mediaTasks.removeAll()
        workspaceID = id; assets = []; total = 0; nextCursor = nil; busy = false
        loadedQuery = nil; lastSyncedAt = nil; syncNote = ""
        await refresh()
    }
    func selectSource(_ value: StudioSource) async {
        guard value != source else { return }
        generation += 1; sessionRevision += 1; searchGeneration += 1
        for task in mediaTasks.values { task.cancel() }; mediaTasks.removeAll()
        thumbnails.removeAllObjects(); source = value
        thumbnailWork.cancelAll()
        clearVideoStreams()
        if value == .recent && kind == "audio" { kind = "all" }
        assets = []; total = 0; nextCursor = nil; query = ""; loadingAssets = false
        loadedQuery = nil; lastSyncedAt = nil; syncNote = ""
        await refresh()
    }
    func refresh(more: Bool = false, background: Bool = false) async {
        guard let saved = session, !workspaceID.isEmpty else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if background && (!libraryActive || loadingAssets || loadedQuery != text || !mediaTasks.isEmpty) { return }
        if more && (loadingAssets || nextCursor == nil || loadedQuery != text) { return }
        searchGeneration += 1
        let searchRevision = searchGeneration, revision = generation, api = client
        let ws = workspaceID, cursor = more ? nextCursor : nil
        let previous = assets, previousTotal = total
        loadingAssets = true
        if !background { message = "" }
        defer { if generation == revision && searchGeneration == searchRevision { loadingAssets = false } }
        do {
            let page: StudioAssetPage
            if source == .recent { page = try await api.recent(saved, query: text) }
            else { page = try await api.assets(saved, workspace: ws, query: text, cursor: cursor) }
            guard generation == revision && searchGeneration == searchRevision else { return }
            var result = page.items, resultCursor = page.nextCursor
            if background && previous.count > page.items.count && previous.prefix(page.items.count).elementsEqual(page.items) && page.total == previousTotal {
                // Most checks fetch one metadata page; leave older loaded pages and scroll position intact.
                lastSyncedAt = Date(); syncNote = ""; return
            }
            if background && resultCursor != nil {
                let priorIDs = Set(previous.map(\.id))
                let newCount = page.items.filter { !priorIDs.contains($0.id) }.count
                let target = min(400, max(40, previous.count + newCount))
                var usedCursors = Set<String>()
                while result.count < target, let next = resultCursor, usedCursors.insert(next).inserted {
                    let following = try await api.assets(saved, workspace: ws, query: text, cursor: next)
                    guard generation == revision && searchGeneration == searchRevision else { return }
                    result.append(contentsOf: following.items); resultCursor = following.nextCursor
                }
            }
            var merged = more ? previous : []
            var ids = Set(merged.map(\.id))
            for item in result where ids.insert(item.id).inserted { merged.append(item) }
            assets = Array(merged.prefix(400)); total = page.total
            nextCursor = assets.count >= 400 ? nil : resultCursor
            loadedQuery = text; lastSyncedAt = Date(); syncNote = ""
            if assets.count >= 400 && !background { message = "已显示前400条；可搜索定位更早的素材。" }
        } catch {
            if generation == revision && searchGeneration == searchRevision {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                if background, case StudioError.http(401, _) = error { handle(error) }
                else if background { syncNote = "更新暂未完成，当前列表已保留；可点击刷新重试。" }
                else { handle(error) }
            }
        }
    }
    func logout() async {
        let old = session, api = client, env = environment
        // Persist the user's intent before removing the only visible exit control.
        // If local persistence fails, keep the account visible so logout is retryable.
        do { try saveLogoutIntent(pending: true) }
        catch { message = "退出状态保存失败，请检查本机存储后重试退出。"; return }
        clearAccount(); restored = true; message = ""
        do {
            try credentials.remove(environment: env)
            try saveLogoutIntent(pending: false)
        } catch {
            logoutCleanupPending = true
            message = "已退出账号；本机会话清理未完成，请解锁钥匙串后点击“重试退出清理”。旧会话不会自动恢复。"
        }
        // Remote invalidation is best effort; local suppression does not depend on it.
        if let old { try? await api.logout(old) }
    }
    private func handle(_ error: Error) {
        if case StudioError.http(401, _) = error {
            // Failed keychain cleanup must not reintroduce an expired identity.
            suppressedEnvironments.insert(environment)
            try? saveLogoutIntent(pending: true)
            clearAccount(); restored = true
            do {
                try credentials.remove(environment: environment)
                if restoreSuppressed { try saveLogoutIntent(pending: false) }
            } catch { logoutCleanupPending = true }
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        message = (error as? StudioError)?.localizedDescription ?? "无法连接 Studio，请检查网络后重试。"
    }
    func dismissMessage() { message = "" }
    func setMessage(_ value: String) { message = value }
    func referenceText(ids: [String]) throws -> String {
        guard user != nil, session?.valid == true, !ids.isEmpty, ids.count <= StudioReferenceEnvelope.maximumItems,
              Set(ids).count == ids.count else { throw StudioError.invalidResponse }
        let current = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let references = try ids.map { id -> StudioMaterialReference in
            guard let asset = current[id] else { throw StudioError.invalidResponse }
            if source == .recent {
                guard asset.id.hasPrefix("job:"), asset.kind == "image" || asset.kind == "video" else { throw StudioError.invalidResponse }
                return StudioMaterialReference(source: "job", id: String(asset.id.dropFirst(4)), workspaceId: nil)
            }
            return StudioMaterialReference(source: "asset", id: asset.id, workspaceId: workspaceID)
        }
        return try StudioReferenceEnvelope(version: 1, origin: environment.baseURL.absoluteString, items: references).clipboardText()
    }
    func refreshCacheStats() async {
        let stats = await diskCache.stats(); cacheBytes = stats.bytes; cacheFiles = stats.files; cacheAvailable = stats.available
    }
    func startCacheMaintenance() {
        cacheTimer?.invalidate()
        Task { await refreshCacheStats() }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshCacheStats() }
        }
        cacheTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func changeCacheLocation(folder: String, volumeUUID: String) async throws {
        guard !mediaBusy, !cacheClearing, !cacheChanging else { throw CocoaError(.userCancelled) }
        cacheChanging = true; cacheRevision += 1
        thumbnailWork.cancelAll()
        defer { cacheChanging = false }
        let target = folder.isEmpty ? defaultCacheDirectory : URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("Kaki Tools Cache", isDirectory: true)
        let oldCleared = try await diskCache.relocate(to: target, volumeUUID: volumeUUID)
        cacheLocation = target.path
        await refreshCacheStats()
        cacheMessage = oldCleared ? "缓存位置已更新。" : "缓存位置已更新，原位置的缓存未能清理。"
    }
    func configureCache(limitMB: Int, days: Int) async {
        cacheRevision += 1
        thumbnailWork.cancelAll()
        await diskCache.configure(limitMB: limitMB, days: days)
        await refreshCacheStats()
    }
    func clearMaterialCache() async {
        guard !mediaBusy, !cacheClearing, !cacheChanging else { return }
        cacheClearing = true; cacheRevision += 1
        thumbnailWork.cancelAll()
        thumbnails.removeAllObjects(); failedPosters.removeAll()
        await diskCache.clear(); await refreshCacheStats()
        cacheClearing = false
        cacheMessage = cacheBytes == 0 ? "缓存已清理。" : "部分文件未能清理，请检查缓存文件夹权限。"
    }
    private func cacheKey(_ asset: StudioAsset, url: String, role: String) -> StudioDiskCache.Key? {
        guard let user, session?.valid == true else { return nil }
        return StudioDiskCache.Key(environment: environment.rawValue, user: user.id, workspace: workspaceID, asset: asset.id, url: url, role: role)
    }
    private func mediaStatus(_ error: Error) -> Int? {
        switch error {
        case StudioError.http(let status, _), StudioError.mediaHTTP(let status): return status
        default: return nil
        }
    }
    private func invalidateOriginal(_ error: Error, key: StudioDiskCache.Key, revision: Int, cacheVersion: Int, version: StudioDiskCache.Version) async {
        guard generation == revision, cacheRevision == cacheVersion, !Task.isCancelled,
              let status = mediaStatus(error), [401, 403, 404, 410].contains(status) else { return }
        await diskCache.remove(key, ifUnchanged: version)
    }
    private func cachedMedia(_ asset: StudioAsset, api: StudioClient, saved: StudioSession, workspace: String, revision: Int, maximumBytes: Int64, cachedOnly: Bool = false, onLookup: ((StudioDiskCache.Version) -> Void)? = nil) async throws -> StudioHTTPFile? {
        guard let key = cacheKey(asset, url: asset.url, role: "original") else { throw StudioError.missingSession }
        let cacheVersion = cacheRevision
        let lookup = await diskCache.lookup(key)
        onLookup?(lookup.version)
        let responseURL = try api.mediaRequest(asset.url, session: saved, workspace: workspace).url!
        if let entry = lookup.entry {
            guard entry.bytes <= maximumBytes else { throw StudioError.tooLarge }
            do {
                let head = try await api.media(asset.url, session: saved, workspace: workspace, maximumBytes: 2 * 1024 * 1024, method: "HEAD")
                defer { try? FileManager.default.removeItem(at: head.file) }
                try Task.checkCancellation()
                guard generation == revision, cacheRevision == cacheVersion else { throw CancellationError() }
                let etag = head.response.value(forHTTPHeaderField: "ETag")
                let modified = head.response.value(forHTTPHeaderField: "Last-Modified")
                let size = head.response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
                let headMime = StudioMediaFiles.mime(head)
                // Length/MIME do not establish identity for a mutable URL. A
                // validator must be present and agree before reusing old bytes.
                let hasValidator = etag?.isEmpty == false || modified?.isEmpty == false
                let sameVersion = hasValidator && (headMime.isEmpty || headMime == entry.mime) && (etag == nil || entry.headers["ETag"] == etag) && (modified == nil || entry.headers["Last-Modified"] == modified)
                if sameVersion && (size == nil || size == entry.bytes),
                   let lease = try await diskCache.leaseVersioned(key, responseURL: responseURL, maximumBytes: maximumBytes) {
                    let leased = lease.media
                    if generation != revision || cacheRevision != cacheVersion || Task.isCancelled { try? FileManager.default.removeItem(at: leased.file); throw CancellationError() }
                    if lease.version == lookup.version {
                        await refreshCacheStats()
                        return leased
                    }
                    try? FileManager.default.removeItem(at: leased.file)
                }
                // Without validators retry GET, retaining old bytes if the
                // network fails. They are never served without revalidation.
                if hasValidator { await diskCache.remove(key, ifUnchanged: lookup.version) }
            } catch {
                guard generation == revision, cacheRevision == cacheVersion, !Task.isCancelled else { throw CancellationError() }
                let status = mediaStatus(error)
                if status == 405 || status == 501 {
                    // HEAD unsupported: GET still validates access before any bytes
                    // are used. Keep the old cache if that transfer also fails.
                } else {
                    await invalidateOriginal(error, key: key, revision: revision, cacheVersion: cacheVersion, version: lookup.version)
                    // Network errors and temporary service failures say nothing
                    // about cached version/access. Retain it, but fail this read.
                    throw error
                }
            }
        }
        guard !cachedOnly else { return nil }
        try Task.checkCancellation()
        guard generation == revision else { throw CancellationError() }
        let result: StudioHTTPFile
        do { result = try await api.media(asset.url, session: saved, workspace: workspace, maximumBytes: maximumBytes) }
        catch {
            await invalidateOriginal(error, key: key, revision: revision, cacheVersion: cacheVersion, version: lookup.version)
            throw error
        }
        if generation != revision || Task.isCancelled { try? FileManager.default.removeItem(at: result.file); throw CancellationError() }
        if cacheRevision == cacheVersion { await diskCache.store(result, key: key, epoch: lookup.epoch) }
        await refreshCacheStats()
        return result
    }
    func thumbnail(_ asset: StudioAsset) async -> NSImage? {
        guard let saved = session, saved.valid, !workspaceID.isEmpty, assets.contains(where: { $0.id == asset.id }),
              let diskKey = cacheKey(asset, url: asset.thumbUrl ?? asset.url, role: "preview:" + asset.url) else { return nil }
        let key = diskKey.value as NSString
        if let image = thumbnails.object(forKey: key) { return image }
        let revision = generation, cacheVersion = cacheRevision, thumbnailVersion = thumbnailRevision
        let workKey = "\(revision):\(cacheVersion):\(thumbnailVersion):\(diskKey.value)"
        return try? await thumbnailWork.value(for: workKey) { [weak self] in
            guard let self, self.generation == revision, self.cacheRevision == cacheVersion,
                  self.thumbnailRevision == thumbnailVersion,
                  self.assets.contains(where: { $0.id == asset.id && $0.url == asset.url && $0.thumbUrl == asset.thumbUrl }) else { throw CancellationError() }
            return await self.loadThumbnail(asset, saved: saved, diskKey: diskKey, revision: revision, cacheVersion: cacheVersion)
        }
    }
    private func loadThumbnail(_ asset: StudioAsset, saved: StudioSession, diskKey: StudioDiskCache.Key, revision: Int, cacheVersion: Int, retryReplacement: Bool = true) async -> NSImage? {
        let key = diskKey.value as NSString, api = client, workspace = workspaceID
        let lookup = await diskCache.lookup(diskKey)
        guard generation == revision, cacheRevision == cacheVersion, !Task.isCancelled else { return nil }
        do {
            if let lease = try await diskCache.leaseVersioned(diskKey, responseURL: environment.baseURL, maximumBytes: 1024 * 1024) {
                let cached = lease.media
                defer { try? FileManager.default.removeItem(at: cached.file) }
                if let png = await decodeThumbnail(cached.file), let image = NSImage(data: png) {
                    guard generation == revision, cacheRevision == cacheVersion, !Task.isCancelled else { return nil }
                    thumbnails.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
                    await refreshCacheStats(); return image
                }
                guard generation == revision, cacheRevision == cacheVersion, !Task.isCancelled else { return nil }
                if !(await diskCache.remove(diskKey, ifUnchanged: lease.version)) {
                    // A replacement arrived during decoding. Do not delete or
                    // overwrite it with work based on the stale bad lease.
                    if retryReplacement { return await loadThumbnail(asset, saved: saved, diskKey: diskKey, revision: revision, cacheVersion: cacheVersion, retryReplacement: false) }
                    return nil
                }
            }
            let image: NSImage?
            var png: Data?
            if asset.kind == "video", asset.thumbUrl == nil {
                image = await videoPoster(asset, key: key)
                if let image, let data = image.tiffRepresentation { png = try? ImageCodec.png(data) }
            } else {
                guard asset.thumbUrl != nil || (asset.kind == "image" && (asset.size ?? 0) <= 8 * 1024 * 1024) else { return nil }
                let result: StudioHTTPFile
                if asset.thumbUrl == nil {
                    guard let original = try await cachedMedia(asset, api: api, saved: saved, workspace: workspace, revision: revision, maximumBytes: 8 * 1024 * 1024) else { return nil }
                    result = original
                } else { result = try await api.media(asset.thumbUrl!, session: saved, workspace: workspace, maximumBytes: 8 * 1024 * 1024) }
                defer { try? FileManager.default.removeItem(at: result.file) }
                png = await decodeThumbnail(result.file)
                image = png.flatMap { NSImage(data: $0) }
            }
            guard generation == revision, cacheRevision == cacheVersion, !Task.isCancelled else { return nil }
            if let image { thumbnails.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4)) }
            if let png { await cachePreview(png, key: diskKey, epoch: lookup.epoch) }
            await refreshCacheStats()
            return image
        } catch {
            if generation == revision, case StudioError.http(401, _) = error { handle(error) }
            return nil
        }
    }
    private nonisolated static func thumbnailPNG(_ file: URL) async -> Data? {
        await Task.detached(priority: .utility) { () -> Data? in
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 280, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, cg, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }.value
    }
    private func cachePreview(_ png: Data, key: StudioDiskCache.Key, epoch: Int) async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try png.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let response = HTTPURLResponse(url: environment.baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"image/png"])!
            await diskCache.store(StudioHTTPFile(file: file, response: response), key: key, epoch: epoch)
        } catch { /* Preview caching is optional. */ }
    }
    private func videoPoster(_ asset: StudioAsset, key: NSString) async -> NSImage? {
        if let failed = failedPosters[key], Date().timeIntervalSince(failed) < 60 { return nil }
        let revision = generation, slot = UUID()
        do {
            // Do not let a grid of videos compete with normal application work.
            while posterSlots.count >= 2 {
                try await Task.sleep(nanoseconds: 50_000_000)
                guard generation == revision else { return nil }
            }
            try Task.checkCancellation()
            guard generation == revision else { return nil }
            if let image = thumbnails.object(forKey: key) { return image }
            posterSlots.insert(slot)
            defer { posterSlots.remove(slot) }
            let stream = try videoStream(asset, byteBudget: 4 * 1024 * 1024)
            defer { releaseVideoStream(stream) }
            let image = try await stream.poster()
            try Task.checkCancellation()
            guard generation == revision else { return nil }
            thumbnails.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
            failedPosters.removeValue(forKey: key)
            return image
        } catch {
            if generation == revision, !Task.isCancelled {
                if failedPosters.count >= 400 { failedPosters.removeAll() }
                failedPosters[key] = Date()
            }
            return nil
        }
    }
    func videoStream(_ asset: StudioAsset, byteBudget: Int64 = 512 * 1024 * 1024, onError: @escaping (Error) -> Void = { _ in }) throws -> StudioVideoStream {
        guard asset.kind == "video", let saved = session, saved.valid,
              assets.contains(where: { $0.id == asset.id && $0.url == asset.url }) else { throw StudioError.missingSession }
        _ = try client.mediaRequest(asset.url, session: saved, workspace: workspaceID)
        let revision = generation, cacheVersion = cacheRevision
        let originalKey = cacheKey(asset, url: asset.url, role: "original")
        var originalVersion: StudioDiskCache.Version?
        let api = client, workspace = workspaceID
        let stream = StudioVideoStream(reader: StudioVideoReader(api: api, session: saved, workspace: workspace, url: asset.url, byteBudget: byteBudget, localLoader: { [weak self] in
            guard let self, self.generation == revision else { throw CancellationError() }
            return try await self.cachedMedia(asset, api: api, saved: saved, workspace: workspace, revision: revision, maximumBytes: 512 * 1024 * 1024, cachedOnly: true, onLookup: { originalVersion = $0 })
        }, onRemoteError: { [weak self] error in
            guard let self, let originalKey, let originalVersion else { return }
            await self.invalidateOriginal(error, key: originalKey, revision: revision, cacheVersion: cacheVersion, version: originalVersion)
        }))
        stream.onError = { [weak self] error in
            guard let self, self.generation == revision else { return }
            if case StudioError.http(401, _) = error { self.handle(error) }
            onError(error)
        }
        videoStreams[UUID()] = stream
        return stream
    }
    func releaseVideoStream(_ stream: StudioVideoStream) {
        if let key = videoStreams.first(where: { $0.value === stream })?.key { videoStreams.removeValue(forKey: key) }
        stream.cancel()
    }
    private func clearVideoStreams() {
        let streams = Array(videoStreams.values); videoStreams.removeAll()
        for stream in streams { stream.cancel() }
        failedPosters.removeAll()
    }
    func copyImage(_ asset: StudioAsset, consume: @escaping (Data) -> Bool) {
        guard asset.kind == "image" else { return }
        runMedia(asset, maximumBytes: 32 * 1024 * 1024, prepare: { result in
            let file = result.file
            return try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                _ = try ImageCodec.dimensions(data)
                return try ImageCodec.png(data)
            }.value
        }) { data in
            guard consume(data) else { throw StudioError.invalidResponse }
            return "图片已复制到剪贴板。"
        }
    }
    func copyMaterial(_ asset: StudioAsset, consumeImage: @escaping (Data) -> Bool, consumeFile: @escaping (URL) -> Bool) {
        if asset.kind == "image" { copyImage(asset, consume: consumeImage); return }
        guard ["video", "audio"].contains(asset.kind) else { return }
        let directory = clipboardDirectory
        runMedia(asset, maximumBytes: 512 * 1024 * 1024, prepare: { result in
            try await Task.detached(priority: .userInitiated) {
                try StudioMediaFiles.prepareClipboard(result, title: asset.title, directory: directory)
            }.value
        }, cleanup: { prepared in try? FileManager.default.removeItem(at: prepared.directory) }) { prepared in
            let retained = directory.appendingPathComponent("material-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.moveItem(at: prepared.directory, to: retained)
            let file = retained.appendingPathComponent(prepared.file.lastPathComponent)
            guard consumeFile(file) else {
                try? FileManager.default.removeItem(at: retained)
                throw StudioError.invalidResponse
            }
            // Only the current copied file needs to survive after the transfer task finishes.
            StudioMediaFiles.removeOldClipboardFiles(directory: directory, keeping: retained)
            return "素材已复制到剪贴板。"
        }
    }
    func cancelMedia() {
        for task in mediaTasks.values { task.cancel() }
        mediaTasks.removeAll()
        message = "已取消；已下载的文件保留。"
    }
    func download(ids: [String], to directory: URL) {
        guard let saved = session, !ids.isEmpty, ids.count <= StudioReferenceEnvelope.maximumItems,
              Set(ids).count == ids.count else { return }
        let current = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let selected = ids.compactMap { current[$0] }
        guard selected.count == ids.count else { message = "请重新选择素材。"; return }
        guard mediaTasks.isEmpty else { message = "正在读取素材，请稍候再操作。"; return }
        guard StudioMediaFiles.isWritableDirectory(directory) else { message = "下载文件夹不可用，请在设置中重新选择。"; return }
        let revision = generation, api = client, workspace = workspaceID, taskID = UUID()
        message = "正在下载 0 / \(selected.count)…"
        mediaTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { self.mediaTasks.removeValue(forKey: taskID) }
            var completed = 0, failures = 0
            for (index, asset) in selected.enumerated() {
                do {
                    try Task.checkCancellation()
                    guard self.generation == revision else { return }
                    self.message = "正在下载 \(index + 1) / \(selected.count)…"
                    guard let result = try await self.cachedMedia(asset, api: api, saved: saved, workspace: workspace, revision: revision, maximumBytes: 512 * 1024 * 1024) else { throw StudioError.invalidResponse }
                    defer { try? FileManager.default.removeItem(at: result.file) }
                    let stage = try await Task.detached(priority: .utility) {
                        try StudioMediaFiles.stage(result.file, in: directory)
                    }.value
                    defer { try? FileManager.default.removeItem(at: stage) }
                    try Task.checkCancellation()
                    guard self.generation == revision else { return }
                    let filename = StudioMediaFiles.filename(title: asset.title, suffix: StudioMediaFiles.mediaExtension(StudioMediaFiles.mime(result)))
                    _ = try StudioMediaFiles.commitUnique(stage, filename: filename, directory: directory)
                    completed += 1
                } catch {
                    guard self.generation == revision else { return }
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                    if case StudioError.http(401, _) = error { self.handle(error); return }
                    failures += 1
                }
            }
            guard self.generation == revision, !Task.isCancelled else { return }
            self.message = failures == 0 ? "已下载 \(completed) 项。" : "已下载 \(completed) 项，\(failures) 项失败，请重新选择失败的素材后重试。"
        }
    }
    func suggestedFilename(_ asset: StudioAsset) async -> String? {
        guard let saved = session, assets.contains(where: { $0.id == asset.id }) else { return nil }
        let revision = generation, api = client, workspace = workspaceID
        var suffix = "bin"
        if let key = cacheKey(asset, url: asset.url, role: "original"), let entry = await diskCache.lookup(key).entry {
            return StudioMediaFiles.filename(title: asset.title, suffix: StudioMediaFiles.mediaExtension(entry.mime))
        }
        do {
            let result = try await api.media(asset.url, session: saved, workspace: workspace, maximumBytes: 2 * 1024 * 1024, method: "HEAD")
            defer { try? FileManager.default.removeItem(at: result.file) }
            let mime = result.response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.lowercased() ?? ""
            suffix = StudioMediaFiles.mediaExtension(mime)
        } catch {
            if generation == revision, case StudioError.http(401, _) = error { handle(error); return nil }
        }
        guard generation == revision else { return nil }
        return StudioMediaFiles.filename(title: asset.title, suffix: suffix)
    }
    func download(_ asset: StudioAsset, destination: URL) {
        runMedia(asset, maximumBytes: 512 * 1024 * 1024, prepare: { result in
            try await Task.detached(priority: .utility) {
                try StudioMediaFiles.stage(result.file, in: destination.deletingLastPathComponent())
            }.value
        }, cleanup: { stage in try? FileManager.default.removeItem(at: stage) }) { stage in
            // The save panel obtains explicit overwrite consent. Commit only after the
            // background copy completes and the current session/cancellation is checked.
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage) }
            else { try FileManager.default.moveItem(at: stage, to: destination) }
            return "素材已保存。"
        }
    }
    private func runMedia<Value>(_ asset: StudioAsset, maximumBytes: Int64, prepare: @escaping (StudioHTTPFile) async throws -> Value, cleanup: @escaping (Value) -> Void = { _ in }, consume: @escaping (Value) throws -> String) {
        guard let saved = session, assets.contains(where: { $0.id == asset.id }) else { return }
        guard mediaTasks.isEmpty else { message = "正在读取素材，请稍候再操作。"; return }
        let revision = generation, api = client, workspace = workspaceID, taskID = UUID()
        message = "正在读取素材…"
        mediaTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { self.mediaTasks.removeValue(forKey: taskID) }
            do {
                guard let result = try await self.cachedMedia(asset, api: api, saved: saved, workspace: workspace, revision: revision, maximumBytes: maximumBytes) else { throw StudioError.invalidResponse }
                defer { try? FileManager.default.removeItem(at: result.file) }
                let value = try await prepare(result)
                defer { cleanup(value) }
                try Task.checkCancellation()
                guard self.generation == revision else { return }
                self.message = try consume(value)
            } catch { if self.generation == revision { self.handle(error) } }
        }
    }
    func shutdown() { cacheTimer?.invalidate(); cacheTimer = nil; libraryActive = false; generation += 1; for task in mediaTasks.values { task.cancel() }; mediaTasks.removeAll(); thumbnailWork.cancelAll(); clearVideoStreams(); thumbnails.removeAllObjects() }
}
