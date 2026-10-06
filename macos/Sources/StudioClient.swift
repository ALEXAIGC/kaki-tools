import Foundation
import Security

// Studio remains the identity and permission authority. Tools never creates a second user database.
enum StudioEnvironment: String, CaseIterable, Identifiable {
    case test, production
    var id: String { rawValue }
    var label: String { self == .test ? "测试环境" : "正式环境" }
    var siteLabel: String { self == .test ? "测试站" : "正式站" }
    var baseURL: URL { URL(string: self == .test ? "https://test.kakiai.xin" : "https://kakiai.xin")! }
}
struct StudioUser: Codable, Equatable {
    let id: String
    let email: String
    let name: String?
}
struct StudioWorkspace: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String
    let role: String
    let disabled: Bool?
}
struct StudioAsset: Decodable, Identifiable, Equatable {
    let id: String
    let url: String
    let thumbUrl: String?
    let kind: String
    let category: String?
    let name: String?
    let tags: [String]?
    let note: String?
    let size: Int64?
    var title: String { name?.isEmpty == false ? name! : "未命名素材" }
    var kindLabel: String { kind == "image" ? "图片" : kind == "video" ? "视频" : kind == "audio" ? "音频" : "素材" }
}
struct StudioAssetPage: Decodable {
    let items: [StudioAsset]
    let total: Int
    let nextCursor: String?
}
enum StudioSource: String, CaseIterable, Identifiable {
    case library, recent
    var id: String { rawValue }
    var label: String { self == .library ? "素材库" : "最近生成" }
}
// GET /api/jobs returns the current user's last 50 tasks, without workspace filtering,
// pagination or prompt text. Only completed image/video output URLs are usable here.
struct StudioJob: Decodable {
    let id: String
    let type: String
    let status: String
    let outputUrl: String?
    let thumbUrl: String?
    let model: String?
    let createdAt: String
    var asset: StudioAsset? {
        guard status == "done", type == "image" || type == "video",
              let url = outputUrl, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
        let timestamp = date?.formatted(date: .abbreviated, time: .shortened) ?? ""
        let label = [type == "image" ? "图片" : "视频", model, timestamp, String(id.prefix(8))].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return StudioAsset(id: "job:" + id, url: url, thumbUrl: thumbUrl, kind: type, category: nil, name: label, tags: ["最近生成"], note: nil, size: nil)
    }
}
struct StudioSession: Codable {
    let value: String
    let expiresAt: Date
    var valid: Bool { expiresAt > Date() && !value.isEmpty && !value.contains("\n") && !value.contains("\r") && !value.contains(";") }
}
enum StudioError: Error, LocalizedError {
    case mediaHTTP(Int), http(Int, String), invalidResponse, invalidURL, tooLarge, credentials(OSStatus), missingSession, previewUnavailable
    var errorDescription: String? {
        switch self {
        case .http(let status, let code):
            switch code {
            case "invalid_credentials": return "邮箱或密码不正确。"
            case "invalid_2fa": return "两步验证码不正确，请重新输入。"
            case "account_suspended", "account suspended": return "该账号已停用，请联系 Studio 管理员。"
            default:
                if status == 401 { return "登录已过期，请重新登录。" }
                if status == 403 { return "当前账号没有访问权限，请在 Studio 中确认产品和工作区权限。" }
                if status == 423 { return "此工作区已停用，请联系管理员。" }
                if status == 429 { return "操作过于频繁，请稍后重试。" }
                return "Studio 请求失败（\(status)），请稍后重试。"
            }
        case .mediaHTTP(let status): return "素材服务请求失败（\(status)），请稍后重试或在 Studio 中刷新素材。"
        case .invalidResponse: return "Studio 返回的数据不完整，请稍后重试。"
        case .invalidURL: return "此素材地址无法安全访问。"
        case .tooLarge: return "此素材超过当前下载大小限制。"
        case .credentials: return "无法访问 macOS 钥匙串，请解锁钥匙串后重试。"
        case .missingSession: return "请先登录 Studio 账号。"
        case .previewUnavailable: return "此视频暂时无法预览，可下载后播放。"
        }
    }
}

@MainActor protocol StudioCredentialStore {
    func read(environment: StudioEnvironment) throws -> StudioSession?
    func write(_ session: StudioSession, environment: StudioEnvironment) throws
    func remove(environment: StudioEnvironment) throws
}
@MainActor final class StudioKeychain: StudioCredentialStore {
    nonisolated static let defaultService = "com.openclaw.kakitools.studio-session"
    let service: String
    init(service: String = StudioKeychain.defaultService) { self.service = service }
    private func query(_ environment: StudioEnvironment) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: environment.baseURL.host!, kSecAttrSynchronizable as String: false]
    }
    func read(environment: StudioEnvironment) throws -> StudioSession? {
        var q = query(environment); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StudioError.credentials(status) }
        guard let session = try? JSONDecoder().decode(StudioSession.self, from: data), session.valid else { try remove(environment: environment); return nil }
        return session
    }
    func write(_ session: StudioSession, environment: StudioEnvironment) throws {
        let data = try JSONEncoder().encode(session)
        var q = query(environment)
        let updates = [kSecValueData as String: data]
        var status = SecItemUpdate(q as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StudioError.credentials(status) }
    }
    func remove(environment: StudioEnvironment) throws {
        let status = SecItemDelete(query(environment) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StudioError.credentials(status) }
    }
}
@MainActor final class StudioMemoryCredentials: StudioCredentialStore {
    var sessions: [StudioEnvironment: StudioSession] = [:]
    func read(environment: StudioEnvironment) throws -> StudioSession? { sessions[environment] }
    func write(_ session: StudioSession, environment: StudioEnvironment) throws { sessions[environment] = session }
    func remove(environment: StudioEnvironment) throws { sessions.removeValue(forKey: environment) }
}

struct StudioHTTPFile {
    let file: URL
    let response: HTTPURLResponse
}
protocol StudioTransport {
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile
}
final class StudioRedirectGuard: NSObject, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let text = downloadTask.taskDescription, let maximum = Int64(text) else { downloadTask.cancel(); return }
        if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum {
            downloadTask.taskDescription = "oversized:" + text
            downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a Studio session to a redirected origin or downgrade HTTPS.
        completionHandler(nil)
    }
}
final class StudioURLTransport: StudioTransport {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config, delegate: StudioRedirectGuard(), delegateQueue: nil)
    }
    func perform(_ request: URLRequest, maximumBytes: Int64) async throws -> StudioHTTPFile {
        if request.httpMethod == "HEAD" {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw StudioError.invalidResponse }
            guard data.count <= maximumBytes else { throw StudioError.tooLarge }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-studio-" + UUID().uuidString)
            try data.write(to: file)
            do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            catch { try? FileManager.default.removeItem(at: file); throw error }
            return StudioHTTPFile(file: file, response: http)
        }
        let cancellation = StudioDownloadCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request) { file, response, error in
                    let exceeded = cancellation.finish()
                    if exceeded { continuation.resume(throwing: StudioError.tooLarge); return }
                    if let error { continuation.resume(throwing: error); return }
                    guard let file, let http = response as? HTTPURLResponse else { continuation.resume(throwing: StudioError.invalidResponse); return }
                    let owned = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-studio-" + UUID().uuidString)
                    do {
                        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard bytes <= maximumBytes else { throw StudioError.tooLarge }
                        try FileManager.default.moveItem(at: file, to: owned)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: owned.path)
                        continuation.resume(returning: StudioHTTPFile(file: owned, response: http))
                    } catch { try? FileManager.default.removeItem(at: owned); continuation.resume(throwing: error) }
                }
                task.taskDescription = String(maximumBytes)
                cancellation.start(task)
            }
        }, onCancel: { cancellation.cancel() })
    }
    deinit { session.invalidateAndCancel() }
}
private final class StudioDownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    func start(_ value: URLSessionDownloadTask) {
        lock.lock(); task = value; let stop = cancelled; lock.unlock()
        if stop { value.cancel() }
        value.resume()
    }
    func cancel() { lock.lock(); cancelled = true; let value = task; lock.unlock(); value?.cancel() }
    func finish() -> Bool {
        lock.lock(); let exceeded = task?.taskDescription?.hasPrefix("oversized:") == true; task = nil; lock.unlock()
        return exceeded
    }
}
struct StudioLoginResult { let user: StudioUser?; let session: StudioSession?; let twoFactorRequired: Bool }
struct StudioClient {
    let environment: StudioEnvironment
    let transport: StudioTransport
    init(environment: StudioEnvironment, transport: StudioTransport = StudioURLTransport()) { self.environment = environment; self.transport = transport }
    func request(path: String, method: String = "GET", session: StudioSession? = nil, workspace: String? = nil, body: Data? = nil, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: environment.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!); request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let session, session.valid { request.setValue("kaki_session=" + session.value, forHTTPHeaderField: "Cookie") }
        if let workspace { request.setValue(workspace, forHTTPHeaderField: "X-Workspace-Id") }
        return request
    }
    func json(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try await transport.perform(request, maximumBytes: 2 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: result.file) }
        let data = try Data(contentsOf: result.file)
        try Self.validate(result.response, data: data)
        return (data, result.response)
    }
    static func validate(_ response: HTTPURLResponse, data: Data = Data()) throws {
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw StudioError.http(response.statusCode, (object?["message"] as? String) ?? (object?["error"] as? String) ?? "")
        }
    }
    static func extractSession(response: HTTPURLResponse, url: URL, now: Date = Date()) -> StudioSession? {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String, let value = entry.value as? String { result[key] = value }
        }
        guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).first(where: { $0.name == "kaki_session" && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == url.host && $0.path == "/" && $0.isSecure }),
              let expiry = cookie.expiresDate, expiry > now else { return nil }
        let session = StudioSession(value: cookie.value, expiresAt: expiry)
        return session.valid ? session : nil
    }
    func login(email: String, password: String, code: String) async throws -> StudioLoginResult {
        var fields = ["email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "password": password]
        if !code.isEmpty { fields["code"] = code }
        let request = request(path: "api/auth/login", method: "POST", body: try JSONEncoder().encode(fields))
        let (data, response) = try await json(request)
        struct Body: Decodable { let user: StudioUser?; let twoFactorRequired: Bool? }
        let body = try JSONDecoder().decode(Body.self, from: data)
        if body.twoFactorRequired == true { return StudioLoginResult(user: nil, session: nil, twoFactorRequired: true) }
        guard let user = body.user, let cookie = Self.extractSession(response: response, url: environment.baseURL) else { throw StudioError.invalidResponse }
        return StudioLoginResult(user: user, session: cookie, twoFactorRequired: false)
    }
    func me(_ session: StudioSession) async throws -> StudioUser { let (data, _) = try await json(request(path: "api/me", session: session)); return try JSONDecoder().decode(StudioUser.self, from: data) }
    func workspaces(_ session: StudioSession) async throws -> [StudioWorkspace] { let (data, _) = try await json(request(path: "api/workspaces", session: session)); return try JSONDecoder().decode([StudioWorkspace].self, from: data) }
    func assets(_ session: StudioSession, workspace: String, query: String, cursor: String?) async throws -> StudioAssetPage {
        var params = [URLQueryItem(name: "pageSize", value: "40")]
        if !query.isEmpty { params.append(URLQueryItem(name: "q", value: query)) }
        if let cursor { params.append(URLQueryItem(name: "cursor", value: cursor)) }
        // Studio's API currently has no kind filter; apply kind in the native presentation only.
        let (data, _) = try await json(request(path: "api/assets", session: session, workspace: workspace, query: params))
        return try JSONDecoder().decode(StudioAssetPage.self, from: data)
    }
    func recent(_ session: StudioSession, query: String) async throws -> StudioAssetPage {
        // Do not send workspace/search parameters: the existing API ignores them.
        let (data, _) = try await json(request(path: "api/jobs", session: session))
        let items = try JSONDecoder().decode([StudioJob].self, from: data).prefix(50).compactMap(\.asset)
        let matches = items.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
        return StudioAssetPage(items: matches, total: matches.count, nextCursor: nil)
    }
    func logout(_ session: StudioSession) async throws { _ = try await json(request(path: "api/auth/logout", method: "POST", session: session)) }
    func mediaRequest(_ raw: String, session: StudioSession, workspace: String) throws -> URLRequest {
        guard session.valid else { throw StudioError.missingSession }
        guard let url = URL(string: raw, relativeTo: environment.baseURL)?.absoluteURL, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host else { throw StudioError.invalidURL }
        // Test and production identities/objects must never be mixed.
        let other = environment == .test ? StudioEnvironment.production : .test
        guard host != other.baseURL.host, host != (environment == .test ? "media-studio.kakiai.xin" : "media-studio-test.kakiai.xin") else { throw StudioError.invalidURL }
        var request = URLRequest(url: url)
        if host == environment.baseURL.host {
            guard url.path.hasPrefix("/api/private-files/") || url.path.hasPrefix("/api/files/") else { throw StudioError.invalidURL }
            request.setValue("kaki_session=" + session.value, forHTTPHeaderField: "Cookie")
            request.setValue(workspace, forHTTPHeaderField: "X-Workspace-Id")
        } else {
            // Third-party media receives no account cookies, authorization, or workspace identity.
            guard !host.contains(":"), host != "localhost", !host.hasSuffix(".local"), host.range(of: "^[0-9.]+$", options: .regularExpression) == nil else { throw StudioError.invalidURL }
        }
        return request
    }
    func media(_ raw: String, session: StudioSession, workspace: String, maximumBytes: Int64, method: String = "GET") async throws -> StudioHTTPFile {
        var request = try mediaRequest(raw, session: session, workspace: workspace); request.httpMethod = method
        let result = try await transport.perform(request, maximumBytes: maximumBytes)
        do { try validateMedia(result.response, request: request); return result }
        catch { try? FileManager.default.removeItem(at: result.file); throw error }
    }
    private func validateMedia(_ response: HTTPURLResponse, request: URLRequest) throws {
        if !(200..<300).contains(response.statusCode), request.url?.host != environment.baseURL.host {
            throw StudioError.mediaHTTP(response.statusCode)
        }
        try Self.validate(response)
    }
    // AVFoundation only reads through this guarded transport, never through a URL
    // containing account cookies. Refuse servers that ignore ranges instead of
    // silently downloading an entire video just to show a card.
    func videoRange(_ raw: String, session: StudioSession, workspace: String, range: Range<Int64>) async throws -> StudioVideoChunk {
        guard range.lowerBound >= 0, !range.isEmpty, range.count <= StudioVideoReader.chunkSize else { throw StudioError.invalidResponse }
        var request = try mediaRequest(raw, session: session, workspace: workspace)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // Allow a small JSON error body even for the one-byte probe, so a 401
        // can expire the session instead of being mislabeled as a large video.
        let result = try await transport.perform(request, maximumBytes: max(Int64(range.count), 16 * 1024))
        defer { try? FileManager.default.removeItem(at: result.file) }
        try validateMedia(result.response, request: request)
        guard result.response.statusCode == 206,
              let header = result.response.value(forHTTPHeaderField: "Content-Range"),
              let total = StudioVideoChunk.totalSize(header, range: range) else { throw StudioError.previewUnavailable }
        let mime = result.response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.lowercased() ?? ""
        guard mime.hasPrefix("video/") || mime == "application/octet-stream" else { throw StudioError.previewUnavailable }
        let data = try Data(contentsOf: result.file)
        guard data.count == range.count else { throw StudioError.invalidResponse }
        return StudioVideoChunk(data: data, total: total, mime: mime)
    }
}
