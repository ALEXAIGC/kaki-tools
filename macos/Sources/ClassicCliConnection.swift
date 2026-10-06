import Foundation
import CryptoKit
import AppKit
import Combine
import AVFoundation

struct ClassicStudioBridge: ClassicCliBridge, @unchecked Sendable {
    let client: StudioClient
    let session: StudioSession
    let workspace: String
    let device: ClassicCliDevice
    let current: @Sendable () async -> Bool
    func request(_ path: String, fields: [String: String] = [:]) throws -> URLRequest {
        var request = client.request(path: "api/local-cli/" + path, method: "POST", session: session, workspace: workspace, body: try JSONEncoder().encode(fields))
        request.setValue(device.id, forHTTPHeaderField: "X-Local-CLI-Device")
        request.setValue(device.secret, forHTTPHeaderField: "X-Local-CLI-Secret")
        return request
    }
    func event(task: ClassicVideoTask, event: String, submitId: String?) async throws {
        guard await current() else { throw DreaminaError.wrongOwner }
        var fields = ["payloadHash": task.payloadHash, "event": event]
        if let submitId { fields["submitId"] = submitId }
        let (data, _) = try await client.json(request("tasks/" + task.id + "/events", fields: fields))
        try ClassicCliReceipt.event(data, task: task, event: event, submitId: submitId)
        guard await current() else { throw DreaminaError.wrongOwner }
    }
    func failure(task: ClassicVideoTask, event: String, code: String) async throws {
        guard await current() else {throw DreaminaError.wrongOwner}
        let fields=["payloadHash":task.payloadHash,"event":event,"failureCode":code]
        let (data,_)=try await client.json(request("tasks/"+task.id+"/events",fields:fields))
        try ClassicCliReceipt.event(data,task:task,event:event,submitId:nil)
        guard await current() else {throw DreaminaError.wrongOwner}
    }
    func upload(task: ClassicVideoTask, submitId: String, file: URL) async throws {
        guard await current() else { throw DreaminaError.wrongOwner }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 300 * 1024 * 1024 else { throw StudioError.tooLarge }
        var request = client.request(path: "api/local-cli/tasks/" + task.id + "/result-upload", method: "POST", session: session, workspace: workspace,
                                     query: [URLQueryItem(name: "name", value: "result." + file.pathExtension), URLQueryItem(name: "size", value: String(size)), URLQueryItem(name: "projectId", value: task.projectId)])
        request.httpBody = try Data(contentsOf: file, options: .mappedIfSafe)
        request.setValue(file.pathExtension == "webm" ? "video/webm" : file.pathExtension == "mov" ? "video/quicktime" : "video/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        request.setValue(device.id, forHTTPHeaderField: "X-Local-CLI-Device")
        request.setValue(device.secret, forHTTPHeaderField: "X-Local-CLI-Secret")
        request.setValue(submitId, forHTTPHeaderField: "X-Local-CLI-Submit")
        let (data, _) = try await client.json(request)
        try ClassicCliReceipt.upload(data, task: task, submitId: submitId)
        guard await current() else { throw DreaminaError.wrongOwner }
    }
}

@MainActor final class ClassicCliConnection: ObservableObject {
    @Published private(set) var status = "未连接"
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var installed = false
    @Published private(set) var version = ""
    @Published private(set) var needsUpgrade = false
    @Published private(set) var authorizationUserCode=""
    @Published private(set) var authorizationURL:URL?
    private let openAuthorization: @MainActor (URL) -> Bool
    private let loginTimeout:TimeInterval
    private let pollInterval:UInt64
    private var executor: ClassicCliExecutor?
    private var claimed = false
    private weak var studio: StudioStore?
    private let directory: URL
    private let enabled: Bool
    private var loop: Task<Void, Never>?
    private var heartbeat: ClassicCliHeartbeat?
    private var operation: Task<Void, Never>?
    private var bridge: ClassicStudioBridge?
    private var generation = UUID()
    private var operationID=UUID()
    private let locator: @Sendable () -> URL?
    private let inspector: @Sendable (URL) async throws -> ClassicCliInstallation
    private let runnerFactory: @Sendable (URL) -> DreaminaRunning
    private let detectionTimeout:TimeInterval
    private struct Authorization: Codable { let owner: String; let fingerprint: String; let device: ClassicCliDevice; var profile: String? = nil }
    init(studio: StudioStore, directory: URL, enabled: Bool, locator: @escaping @Sendable () -> URL? = {ClassicDreaminaCLI.locate()}, inspector: @escaping @Sendable (URL) async throws -> ClassicCliInstallation = {try await ClassicCliInstaller.inspect($0)}, runnerFactory: @escaping @Sendable (URL) -> DreaminaRunning = {DreaminaProcessRunner(executable:$0)}, detectionTimeout:TimeInterval = 30,loginTimeout:TimeInterval = 180,pollInterval:UInt64 = 2_000_000_000,openAuthorization:@escaping @MainActor (URL)->Bool = {NSWorkspace.shared.open($0)}) {
        self.studio=studio;self.directory=directory.appendingPathComponent("classic-cli",isDirectory:true);self.enabled=enabled
        self.locator=locator;self.inspector=inspector;self.runnerFactory=runnerFactory;self.detectionTimeout=detectionTimeout;self.loginTimeout=loginTimeout;self.pollInterval=pollInterval;self.openAuthorization=openAuthorization;self.installed=locator() != nil
    }
    func cancelOperation() {clearAuthorization();operationID=UUID();operation?.cancel();operation=nil;busy=false;status="操作已取消，请重试"}

    private var owner: String? {
        guard let studio, let user = studio.user, !studio.workspaceID.isEmpty else { return nil }
        return studio.environment.baseURL.absoluteString + "|" + user.id + "|" + studio.workspaceID
    }
    var targetSiteDescription: String {
        guard let studio else { return "请先登录 Studio" }
        let site = studio.environment.siteLabel + " · " + (studio.environment.baseURL.host ?? "")
        return (connected ? "已关联：" : "当前站点：") + site
    }
    var targetWorkspaceName: String { studio?.workspaceName ?? "未选择工作区" }
    var targetDescription: String { targetSiteDescription + "\n工作区：" + targetWorkspaceName }
    func identityChanged() {
        clearAuthorization()
        generation = UUID(); loop?.cancel(); heartbeat?.stop(); operation?.cancel(); loop = nil; heartbeat = nil; operation = nil
        let previous = bridge; bridge = nil; connected = false; busy = false; status = "站点、账号或工作区已变更，请重新连接"
        if let previous {
            Task { _ = try? await previous.client.json(previous.request("devices/pause")) }
        }
    }
    private func location(_ owner: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Stable, filesystem-safe owner key without exposing account identifiers in filenames.
        let hash = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    func detect() {
        guard !busy else {return}
        guard let executable = locator() else {installed = false; status = "未安装即梦 CLI"; return}
        busy = true; status = "检查 CLI 与五种视频方式…"
        let ticket = generation, op=UUID();operationID=op
        operation = Task { [weak self] in
            guard let self else {return}
            defer {if self.generation == ticket && self.operationID == op {self.busy = false}}
            do {
                let checked = try await classicCliDeadline(seconds:self.detectionTimeout) {
                    let receipt=try await self.inspector(executable)
                    await self.checkingLogin(ticket,op:op)
                    let loggedIn=try await ClassicDreaminaCLI(runner:self.runnerFactory(executable)).loginState()
                    return (receipt,loggedIn)
                }
                let receipt=checked.0
                guard self.generation == ticket && self.operationID == op else {return}
                self.installed = true
                self.needsUpgrade = false
                let object = try? JSONSerialization.jsonObject(with: Data(receipt.version.utf8)) as? [String: Any]
                self.version = (object?["version"] as? String) ?? receipt.version.prefix(100).description
                let loggedIn=checked.1
                guard self.generation == ticket && self.operationID == op else {return}
                self.status = self.connected ? "已连接 · 使用本机即梦登录" : loggedIn ? "已安装 · 即梦已登录 · 未连接" : "已安装 · 请登录即梦"
            } catch ClassicCliUpgradeError.required {if self.generation == ticket && self.operationID == op {self.installed=true;self.needsUpgrade=true;self.status="请更新即梦 CLI 以使用五种视频方式"}} catch {if self.generation == ticket && self.operationID == op {self.status = "CLI 检测失败或超时，请重试；登录状态尚未确认"}}
        }
    }
    func install() {
        guard !busy else {return}
        if locator() != nil {detect(); return}
        busy = true; status = "正在下载安装即梦 CLI…"
        let ticket = generation, op=UUID();operationID=op
        operation = Task { [weak self] in
            guard let self else {return}
            defer {if self.generation == ticket && self.operationID == op {self.busy = false}}
            do {
                let receipt = try await ClassicCliInstaller().install(canReplace:{[self] in await self.canUpgrade(ticket,op:op)})
                guard self.generation == ticket && self.operationID == op else {return}
                self.installed = true; self.needsUpgrade = false
                self.version = receipt.version.prefix(100).description
                self.status = "已安装 · 请登录即梦后连接"
            } catch {if self.generation == ticket && self.operationID == op {self.status = "安装失败，可重新检测或重试安装"}}
        }
    }
    func upgrade() {
        guard !busy, !claimed, !connected, let executable=locator() else {status="请先断开连接并等待本机任务结束";return}
        busy=true;status="正在验证并更新即梦 CLI…"
        let ticket=generation, op=UUID();operationID=op
        operation=Task { [weak self] in
            guard let self else {return}
            defer {if self.generation == ticket && self.operationID == op {self.busy=false}}
            do {
                _ = try await ClassicCliInstaller().install(upgrading:executable,canReplace:{[self] in
                    guard await self.canUpgrade(ticket,op:op) else {return false}
                    return await self.executor?.isIdle() ?? true
                })
                guard self.generation == ticket && self.operationID == op else {return}
                self.installed=true;self.needsUpgrade=false;self.version=""
                self.status="CLI 已更新，请重新检测、登录并关联工作区"
            } catch {if self.generation == ticket && self.operationID == op {self.status="CLI 更新未完成，原登录与任务记录保留"}}
        }
    }
    private func canUpgrade(_ ticket:UUID,op:UUID) -> Bool {generation == ticket && operationID == op && !Task.isCancelled && !claimed && !connected}
    private func checkingLogin(_ ticket:UUID,op:UUID) {if generation == ticket && operationID == op {status="检查即梦登录…"}}
    private func clearAuthorization() {authorizationUserCode="";authorizationURL=nil}
    private func showAuthorization(_ value:ClassicCliAuthorization,ticket:UUID,op:UUID) -> Bool {
        guard generation == ticket && operationID == op && !Task.isCancelled else {return false}
        authorizationUserCode=value.userCode;authorizationURL=value.url;status="等待即梦授权，请在官方页面输入授权码"
        _ = openAuthorization(value.url) // Once for this session; the visible button allows an explicit retry.
        return true
    }
    func openAuthorizationPage() {if let url=authorizationURL {_ = openAuthorization(url)}}
    func copyAuthorizationCode(to board:NSPasteboard = .general) {
        guard !authorizationUserCode.isEmpty else {return}
        board.clearContents();board.setString(authorizationUserCode,forType:.string)
        board.setData(Data(),forType:.init("org.nspasteboard.TransientType"))
    }
    func login() {
        guard !busy,!needsUpgrade,let executable=locator() else {return}
        busy=true;clearAuthorization();status="检查即梦登录…"
        let ticket=generation,op=UUID();operationID=op
        operation=Task { [weak self] in
            guard let self else {return}
            defer {if self.generation == ticket && self.operationID == op {self.busy=false;self.clearAuthorization()}}
            do {
                let runner=self.runnerFactory(executable)
                try await classicCliDeadline(seconds:self.loginTimeout) {
                    if try await ClassicDreaminaCLI(runner:runner).loginState() {return}
                    let authorization=try await ClassicCliAuthorization.begin(runner)
                    guard await self.showAuthorization(authorization,ticket:ticket,op:op) else {throw CancellationError()}
                    while true {
                        try Task.checkCancellation()
                        if try await authorization.poll(runner) {
                            guard try await ClassicDreaminaCLI(runner:runner).loginState() else {throw DreaminaError.invalidResponse}
                            return
                        }
                        try await Task.sleep(nanoseconds:self.pollInterval)
                    }
                }
                guard self.generation == ticket && self.operationID == op else {return}
                self.status="即梦已登录 · 可连接当前 Studio 工作区"
            } catch {if self.generation == ticket && self.operationID == op {self.status="即梦登录取消、超时或未完成，请重试"}}
        }
    }
    func connect() {
        guard enabled, !busy, let studio, let owner, let context = studio.classicCliContext(), let executable = locator() else { status = "请先登录 Studio，并安装经典即梦 CLI"; return }
        busy = true; status = "检查本机登录…"
        let ticket = generation, op=UUID();operationID=op
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == ticket && self.operationID == op && !Task.isCancelled { self.busy = false } }
            do {
                let fingerprint = try await Task.detached { try ClassicDreaminaCLI.fingerprint(executable) }.value
                let cli = ClassicDreaminaCLI(runner: self.runnerFactory(executable))
                let models = try await classicCliDeadline(seconds:self.detectionTimeout) {try await cli.verify()}
                let profile = "resolution-five"
                guard self.owner == owner, self.generation == ticket && self.operationID == op && !Task.isCancelled else { return }
                let file = try self.location(owner)
                let saved = try? JSONDecoder().decode(Authorization.self, from: Data(contentsOf: file))
                let current: @Sendable () async -> Bool = { [self] in
                    guard await self.matches(owner: owner, ticket: ticket) else { return false }
                    return (try? await Task.detached { try ClassicDreaminaCLI.fingerprint(executable) }.value) == fingerprint
                }
                var candidate: ClassicStudioBridge?
                if let saved, saved.owner == owner, saved.fingerprint == fingerprint, saved.profile == profile {
                    let restored = ClassicStudioBridge(client: context.client, session: context.session, workspace: context.workspace, device: saved.device, current: current)
                    do {try Task.checkCancellation(); _ = try await restored.client.json(restored.request("devices/resume")); candidate = restored } catch { /* explicit consent required before replacement */ }
                }
                guard self.owner == owner, self.generation == ticket && self.operationID == op && !Task.isCancelled else { return }
                if candidate == nil {
                    let alert = NSAlert(); alert.messageText = "关联本机即梦登录？"
                    alert.informativeText = "使用本机即梦登录，经典 CLI 无法核验即梦账号 ID。关联当前 Studio 账号与工作区；画布点击生成后由本机直接执行，使用本人即梦额度。"
                    alert.addButton(withTitle: "关联"); alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { self.status = "未连接"; return }
                    guard await current(),self.operationID == op,!Task.isCancelled else { return }
                    let body = try JSONSerialization.data(withJSONObject: ["origin": context.client.environment.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "models": models, "profile": profile] as [String: Any])
                    let (data, _) = try await context.client.json(context.client.request(path: "api/local-cli/devices/register", method: "POST", session: context.session, workspace: context.workspace, body: body))
                    guard await current(),self.operationID == op,!Task.isCancelled else {return}
                    let device = try JSONDecoder().decode(ClassicCliDevice.self, from: data)
                    let authorization = Authorization(owner: owner, fingerprint: fingerprint, device: device, profile: profile)
                    try JSONEncoder().encode(authorization).write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    candidate = ClassicStudioBridge(client: context.client, session: context.session, workspace: context.workspace, device: device, current: current)
                }
                guard let candidate, await current(),self.operationID == op,!Task.isCancelled else { return }
                self.bridge = candidate; self.connected = true; self.status = "已连接 · 使用本机即梦登录"
                self.start(cli: cli, executable: executable, fingerprint: fingerprint, bridge: candidate, owner: owner, ticket: ticket)
            } catch ClassicCliUpgradeError.required {if self.generation == ticket && self.operationID == op && !Task.isCancelled {self.needsUpgrade=true;self.status="请更新即梦 CLI 后重新关联"}} catch { if self.generation == ticket && self.operationID == op && !Task.isCancelled { self.status = "连接失败，请检查 Studio 与本机即梦登录" } }
        }
    }
    private func start(cli: ClassicDreaminaCLI, executable: URL, fingerprint: String, bridge: ClassicStudioBridge, owner: String, ticket: UUID) {
        loop?.cancel(); heartbeat?.stop()
        // Keep presence alive independently of confirmation, submission, and slow result downloads.
        // The copied bridge binds the original session/workspace; identityChanged cancels this task.
        heartbeat = ClassicCliHeartbeat { _ = try await bridge.client.json(bridge.request("devices/heartbeat")) }
        let executor = ClassicCliExecutor(cli: cli, directory: directory.appendingPathComponent("journal", isDirectory: true)); self.executor=executor
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.owner == owner, self.generation == ticket else { return }
                do {
                    let actual = try await Task.detached { try ClassicDreaminaCLI.fingerprint(executable) }.value
                    guard actual == fingerprint else { self.identityChanged(); self.status = "CLI 已变化，请重新关联"; return }
                    _ = try await bridge.client.json(bridge.request("devices/heartbeat"))
                    let (data, _) = try await bridge.client.json(bridge.request("devices/claim"))
                    struct Claim: Decodable { let task: ClassicVideoTask? }
                    if let task = try JSONDecoder().decode(Claim.self, from: data).task {
                        self.claimed=true
                        defer {self.claimed=false}
                        self.status = task.submitId == nil && task.stage != "awaiting-confirmation" ? "提交结果待核对，请勿重新生成" : "本机视频处理中"
                        try await executor.step(task: task, owner: owner, bridge: bridge, isCurrent: bridge.current, validateVideo: { try await Self.validateVideo($0) })
                    } else { self.status = "已连接 · 使用本机即梦登录" }
                } catch {
                    guard self.generation == ticket else { return }
                    self.status = "连接或结果待核对，不会重新生成"
                }
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            }
        }
    }
    nonisolated private static func validateVideo(_ file: URL) async throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 300 * 1024 * 1024 else { throw DreaminaError.invalidResponse }
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        guard !tracks.isEmpty, duration.seconds.isFinite, duration.seconds > 0, try await asset.load(.isPlayable) else { throw DreaminaError.invalidResponse }
    }
    private func matches(owner: String, ticket: UUID) -> Bool { self.owner == owner && self.generation == ticket }
    func disconnect() { identityChanged(); status = "未连接" }
    func shutdown() { generation = UUID(); loop?.cancel(); heartbeat?.stop(); operation?.cancel() }
}

// Review only the values used by the frozen CLI argv; never expose internal node IDs.
enum ClassicCliConfirmation {
    static func text(_ snapshot: ClassicVideoSnapshot) -> String {
        let mode = snapshot.effectiveMode
        let title = ["text":"文生视频", "image":"单图视频", "firstlast":"首尾帧", "imageref":"多帧故事", "omni":"全能参考"][mode] ?? mode
        let references = snapshot.references ?? []
        let counts = ["image":"图", "video":"视频", "audio":"音频"]
        let summary = ["image","video","audio"].compactMap { kind -> String? in
            let count = references.filter {$0.kind == kind}.count
            return count > 0 ? "\(count)份\(counts[kind]!)" : nil
        }.joined(separator:" · ")
        let order = mode == "firstlast" ? "首帧 → 尾帧" : mode == "imageref" ? references.indices.map {"第\($0 + 1)张"}.joined(separator:" → ") : summary
        let preview: String
        if mode == "imageref" {
            let rows = snapshot.transitions ?? []
            preview = "\(rows.count)段过渡 · 总时长\(String(format:"%g",snapshot.duration))秒\n" + rows.enumerated().map {index,row in
                "第\(index + 1)→\(index + 2)张 · \(String(format:"%g",row.duration))秒：\(row.prompt.prefix(100))"
            }.joined(separator:"\n")
        } else { preview = String(snapshot.prompt.prefix(500)) }
        return "\(title) · \(snapshot.model) · \(String(format:"%g",snapshot.duration))秒 · \(snapshot.aspect == "source" ? "随源图比例" : snapshot.aspect) · \(snapshot.resolution == "default" ? "CLI 默认清晰度" : snapshot.resolution)\n引用：\(order.isEmpty ? "无" : order)\n\(preview)\n使用当前本机即梦登录；画布点击生成后直接执行。"
    }
}

/** A single operation deadline cancels its child; the process runner then kills/reaps its own group. */
func classicCliDeadline<T:Sendable>(seconds:TimeInterval, operation:@escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of:T.self) {group in
        group.addTask {try await operation()}
        group.addTask {try await Task.sleep(nanoseconds:UInt64(max(0.01,seconds)*1_000_000_000));throw DreaminaError.timedOut}
        defer {group.cancelAll()}
        guard let value=try await group.next() else {throw DreaminaError.invalidResponse}
        return value
    }
}
