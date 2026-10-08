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
    @Published private(set) var actionTitle = "检查连接"
    @Published private(set) var status = "未连接"
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var loggedIn = false
    @Published private(set) var loginChecked = false
    @Published private(set) var installed = false
    @Published private(set) var version = ""
    @Published private(set) var needsUpgrade = false
    @Published private(set) var authorizationUserCode=""
    @Published private(set) var authorizationURL:URL?
    @Published private(set) var capabilityPreview: ClassicCliCapabilityPreview?
    @Published private(set) var capabilityStatus = ""
    private var capabilityApproval: CapabilityApproval?
    private struct CapabilityApproval { let owner: String; let ticket: UUID; let fingerprint: String; let identity: ClassicDreaminaCLI.FileIdentity; let executable: URL; let bridge: ClassicStudioBridge }
    @Published private(set) var creditTotal: Double?
    @Published private(set) var creditStatus = "积分未查询"
    @Published private(set) var creditQueriedAt: Date?
    private var creditExpiresAt: Date?
    private var creditLoop: Task<Void, Never>?
    private var creditService: ClassicCreditRefresh?
    private var creditTicket = UUID()
    private let creditRunnerFactory: @Sendable (URL) -> DreaminaRunning
    private let creditConfirmation: @MainActor (Bool) async -> Bool
    private let creditPollingNanoseconds: UInt64
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
    private var restoreTask: Task<Void, Never>?
    private var restoreAttempts = 0
    private let restoreRetryNanoseconds: UInt64
    private var bridge: ClassicStudioBridge?
    private var generation = UUID()
    private var operationID=UUID()
    private let locator: @Sendable () -> URL?
    private let inspector: @Sendable (URL) async throws -> ClassicCliInstallation
    private let runnerFactory: @Sendable (URL) -> DreaminaRunning
    private let capabilityFingerprint: @Sendable (URL) async throws -> String
    private let detectionTimeout:TimeInterval
    private struct Authorization: Codable { let owner: String; let fingerprint: String; let device: ClassicCliDevice; var profile: String? = nil; var autoResume: Bool? = nil; var capabilities: ClassicCliPublicDevice? = nil; var pendingCapabilities: ClassicCliCapabilityPayload? = nil }
    init(studio: StudioStore, directory: URL, enabled: Bool, locator: @escaping @Sendable () -> URL? = {ClassicDreaminaCLI.locate()}, inspector: @escaping @Sendable (URL) async throws -> ClassicCliInstallation = {try await ClassicCliInstaller.inspect($0)}, runnerFactory: @escaping @Sendable (URL) -> DreaminaRunning = {DreaminaProcessRunner(executable:$0)}, detectionTimeout:TimeInterval = 30,loginTimeout:TimeInterval = 180,pollInterval:UInt64 = 2_000_000_000,restoreRetryNanoseconds: UInt64 = 30_000_000_000,openAuthorization:@escaping @MainActor (URL)->Bool = {NSWorkspace.shared.open($0)}, capabilityFingerprint: @escaping @Sendable (URL) async throws -> String = { url in try await Task.detached { try ClassicDreaminaCLI.fingerprint(url) }.value }, creditRunnerFactory: @escaping @Sendable (URL) -> DreaminaRunning = { ClassicCreditReadOnlyRunner(executable: $0) }, creditConfirmation: @escaping @MainActor (Bool) async -> Bool = { await ClassicCreditConsent.confirm(changed: $0) }, creditPollingNanoseconds: UInt64 = 1_000_000_000) {
        self.studio=studio;self.directory=directory.appendingPathComponent("classic-cli",isDirectory:true);self.enabled=enabled
        self.restoreRetryNanoseconds = max(1_000_000, min(120_000_000_000, restoreRetryNanoseconds))
        self.creditRunnerFactory = creditRunnerFactory; self.creditConfirmation = creditConfirmation; self.creditPollingNanoseconds = max(10_000_000, creditPollingNanoseconds)
        self.capabilityFingerprint = capabilityFingerprint
        self.locator=locator;self.inspector=inspector;self.runnerFactory=runnerFactory;self.detectionTimeout=detectionTimeout;self.loginTimeout=loginTimeout;self.pollInterval=pollInterval;self.openAuthorization=openAuthorization;self.installed=locator() != nil
    }
    func cancelOperation() {stopCreditRefresh();discardCapabilityPreview();clearAuthorization();operationID=UUID();operation?.cancel();operation=nil;busy=false;status="操作已取消，请重试"; restartCreditRefresh()}

    private var owner: String? {
        guard let studio, let user = studio.user, !studio.workspaceID.isEmpty else { return nil }
        return studio.environment.baseURL.absoluteString + "|" + user.id + "|" + studio.workspaceID
    }
    var targetSiteDescription: String {
        guard let studio else { return "请先登录 Studio" }
        let site = studio.environment.siteLabel + " · " + (studio.environment.baseURL.host ?? "")
        return (connected ? "已关联：" : "当前站点：") + site
    }
    var hasStudioAccount: Bool { owner != nil }
    var targetSiteName: String { studio?.environment.siteLabel ?? "Studio" }
    var targetWorkspaceName: String { studio?.workspaceName ?? "未选择工作区" }
    var targetDescription: String { targetSiteDescription + "\n工作区：" + targetWorkspaceName }
    func identityChanged() {
        stopCreditRefresh()
        restoreTask?.cancel(); restoreTask = nil
        discardCapabilityPreview()
        clearAuthorization()
        generation = UUID(); loop?.cancel(); heartbeat?.stop(); operation?.cancel(); loop = nil; heartbeat = nil; operation = nil
        let previous = bridge; bridge = nil; connected = false; busy = false; status = "站点、账号或工作区已变更，请重新连接"
        if let previous {
            Task { _ = try? await previous.client.json(previous.request("devices/pause")) }
        }
    }
    func discardCapabilityPreview() { capabilityPreview = nil; capabilityApproval = nil }
    private func saveAuthorization(_ saved: Authorization, at file: URL) throws {
        try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    // No suspension between this check and a side effect on MainActor.
    private func capabilityContextCurrent(_ approval: CapabilityApproval, op: UUID) -> Bool {
        owner == approval.owner && generation == approval.ticket && operationID == op && !Task.isCancelled &&
        connected && bridge?.device.id == approval.bridge.device.id && bridge?.device.epoch == approval.bridge.device.epoch &&
        locator()?.resolvingSymlinksInPath() == approval.executable.resolvingSymlinksInPath() &&
        (try? ClassicDreaminaCLI.fileIdentity(approval.executable)) == approval.identity
    }
    private func capabilityCurrent(_ approval: CapabilityApproval, op: UUID) async -> Bool {
        guard capabilityContextCurrent(approval, op: op) else { return false }
        let fingerprint = try? await capabilityFingerprint(approval.executable)
        // The detached hash does not inherit cancellation or serialize account changes.
        return capabilityContextCurrent(approval, op: op) && fingerprint == approval.fingerprint
    }
    private func readCapabilities(_ approval: CapabilityApproval, minimumRevision: Int, op: UUID) async throws -> ClassicCliPublicDevice {
        guard await capabilityCurrent(approval, op: op), capabilityContextCurrent(approval, op: op) else { throw DreaminaError.wrongOwner }
        let api = approval.bridge
        let request = api.client.request(path: "api/local-cli/catalog", session: api.session, workspace: api.workspace)
        guard capabilityContextCurrent(approval, op: op) else { throw DreaminaError.wrongOwner }
        let (data, _) = try await api.client.json(request)
        struct Catalog: Decodable { let device: ClassicCliPublicDevice? }
        guard let device = try JSONDecoder().decode(Catalog.self, from: data).device else { throw DreaminaError.notLinked }
        try device.validate(for: api.device, minimumRevision: minimumRevision)
        guard await capabilityCurrent(approval, op: op), capabilityContextCurrent(approval, op: op) else { throw DreaminaError.wrongOwner }
        return device
    }
    func detectCapabilities() {
        guard enabled, !busy, connected, let owner, let bridge, let executable = locator() else {
            capabilityStatus = "请先单独连接原设备，再检测能力；暂停或断开不会自动恢复。"; return
        }
        discardCapabilityPreview()
        busy = true; actionTitle = "检测设备能力"; capabilityStatus = "验证原授权 CLI 与四命令型号交集…"
        let ticket = generation, op = UUID(); operationID = op
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == ticket && self.operationID == op { self.busy = false } }
            do {
                let file = try self.location(owner)
                let saved = try JSONDecoder().decode(Authorization.self, from: Data(contentsOf: file))
                let identity = try ClassicDreaminaCLI.fileIdentity(executable)
                let fingerprint = try await self.capabilityFingerprint(executable)
                guard saved.owner == owner, saved.device.id == bridge.device.id, saved.device.epoch == bridge.device.epoch,
                      saved.fingerprint == fingerprint else { throw DreaminaError.wrongOwner }
                let approval = CapabilityApproval(owner: owner, ticket: ticket, fingerprint: fingerprint, identity: identity, executable: executable, bridge: bridge)
                guard await self.capabilityCurrent(approval, op: op), self.capabilityContextCurrent(approval, op: op) else { throw DreaminaError.wrongOwner }
                let models = try await classicCliDeadline(seconds: self.detectionTimeout) {
                    try await ClassicDreaminaCLI(runner: self.runnerFactory(executable)).verify()
                }
                let current = try await self.readCapabilities(approval, minimumRevision: saved.capabilities?.effectiveRevision ?? 0, op: op)
                let payload: ClassicCliCapabilityPayload
                if let pending = saved.pendingCapabilities {
                    // An uncertain response must be reconciled with the exact original request.
                    guard pending.models == Array(Set(models)).sorted() else { throw DreaminaError.wrongOwner }
                    payload = pending
                } else { payload = try ClassicCliCapabilityPayload(current: current, models: models) }
                guard await self.capabilityCurrent(approval, op: op), self.capabilityContextCurrent(approval, op: op) else { return }
                self.capabilityApproval = approval
                self.capabilityPreview = ClassicCliCapabilityPreview(current: current, payload: payload, retry: saved.pendingCapabilities != nil)
                self.capabilityStatus = "检测完成，请核对并确认。型号能力不代表会员资格，VIP 失败不会降级或切渠道。"
            } catch {
                if self.generation == ticket && self.operationID == op {
                    self.discardCapabilityPreview()
                    self.capabilityStatus = "检测未完成：请确认原设备已连接、Studio 支持能力接口，且 CLI 路径与内容仍为原授权版本。CLI 变化需单独重新授权；不会自动关联设备。"
                }
            }
        }
    }
    func confirmCapabilities() {
        guard !busy, let preview = capabilityPreview, let approval = capabilityApproval else { return }
        stopCreditRefresh()
        busy = true; actionTitle = "更新设备能力"; capabilityStatus = "提交已确认的能力版本…"
        let op = UUID(); operationID = op
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == approval.ticket && self.operationID == op { self.busy = false; self.restartCreditRefresh() } }
            do {
                guard await self.capabilityCurrent(approval, op: op), self.capabilityContextCurrent(approval, op: op) else { throw DreaminaError.wrongOwner }
                let file = try self.location(approval.owner)
                var saved = try JSONDecoder().decode(Authorization.self, from: Data(contentsOf: file))
                guard saved.owner == approval.owner, saved.device.id == approval.bridge.device.id,
                      saved.device.epoch == approval.bridge.device.epoch, saved.fingerprint == approval.fingerprint,
                      saved.pendingCapabilities == nil || saved.pendingCapabilities == preview.payload else { throw DreaminaError.wrongOwner }
                // Persist before sending, so a restart never substitutes a newer CAS revision.
                saved.pendingCapabilities = preview.payload
                guard self.capabilityContextCurrent(approval, op: op) else { throw DreaminaError.wrongOwner }
                try self.saveAuthorization(saved, at: file)
                var request = try approval.bridge.request("devices/capabilities")
                request.httpBody = try JSONEncoder().encode(preview.payload)
                guard await self.capabilityCurrent(approval, op: op), self.capabilityContextCurrent(approval, op: op) else { throw DreaminaError.wrongOwner }
                let (data, _) = try await approval.bridge.client.json(request)
                let receipt = try JSONDecoder().decode(ClassicCliPublicDevice.self, from: data)
                try preview.payload.validateReceipt(receipt, device: saved.device)
                guard await self.capabilityCurrent(approval, op: op), self.capabilityContextCurrent(approval, op: op) else { return }
                // Reload so an explicit disconnect or another operation cannot be overwritten.
                var latest = try JSONDecoder().decode(Authorization.self, from: Data(contentsOf: file))
                guard latest.owner == saved.owner, latest.device.id == saved.device.id, latest.device.epoch == saved.device.epoch,
                      latest.pendingCapabilities == preview.payload,
                      receipt.effectiveRevision >= (latest.capabilities?.effectiveRevision ?? 0) else { throw DreaminaError.wrongOwner }
                latest.capabilities = receipt; latest.pendingCapabilities = nil
                guard self.capabilityContextCurrent(approval, op: op) else { throw DreaminaError.wrongOwner }
                try self.saveAuthorization(latest, at: file)
                self.discardCapabilityPreview(); self.capabilityStatus = "设备能力已确认更新（版本 \(receipt.effectiveRevision)）。原设备与任务记录保留。"
            } catch StudioError.http(409, _) {
                guard await self.capabilityCurrent(approval, op: op), self.capabilityContextCurrent(approval, op: op) else { return }
                self.discardCapabilityPreview()
                do {
                    let current = try await self.readCapabilities(approval, minimumRevision: preview.current.effectiveRevision, op: op)
                    guard await self.capabilityCurrent(approval, op: op), self.capabilityContextCurrent(approval, op: op) else { return }
                    let file = try self.location(approval.owner)
                    var saved = try JSONDecoder().decode(Authorization.self, from: Data(contentsOf: file))
                    guard saved.owner == approval.owner, saved.device.id == current.id, saved.device.epoch == current.epoch,
                          saved.pendingCapabilities == preview.payload, self.capabilityContextCurrent(approval, op: op) else { return }
                    saved.capabilities = current; saved.pendingCapabilities = nil
                    guard self.capabilityContextCurrent(approval, op: op) else { return }
                    try self.saveAuthorization(saved, at: file)
                    self.capabilityStatus = "设备版本冲突，已重新读取版本 \(current.effectiveRevision)。请重新检测并核对，再确认；不会自动覆盖。"
                } catch { guard self.capabilityContextCurrent(approval, op: op) else { return }; self.capabilityStatus = "设备版本冲突，当前设备暂无法读取。请核对原设备连接后重新检测；不会自动覆盖。" }
            } catch {
                guard self.generation == approval.ticket && self.operationID == op else { return }
                self.discardCapabilityPreview()
                self.capabilityStatus = "更新未确认。重新检测后可明确重试原请求，保持原型号与 revision；不会重新注册、恢复暂停或重投任务。"
            }
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
        guard let executable = locator() else {installed = false; loggedIn = false; loginChecked = false; needsUpgrade = false; version = ""; status = "未安装即梦 CLI"; return}
        busy = true; actionTitle = "检查连接"; loginChecked = false; status = "检查 CLI 与五种视频方式…"
        let ticket = generation, op=UUID();operationID=op
        operation = Task { [weak self] in
            guard let self else {return}
            defer {
                if self.generation == ticket && self.operationID == op {
                    self.busy = false
                    if self.loggedIn && !self.connected { self.restoreRememberedConnection() }
                }
            }
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
                self.loggedIn = loggedIn; self.loginChecked = true
                guard self.generation == ticket && self.operationID == op else {return}
                self.status = self.connected ? "已连接 · 使用本机即梦登录" : loggedIn ? "已安装 · 即梦已登录 · 未连接" : "已安装 · 请登录即梦"
            } catch ClassicCliUpgradeError.required {if self.generation == ticket && self.operationID == op {self.installed=true;self.needsUpgrade=true;self.status="请更新即梦 CLI 以使用五种视频方式"}} catch {if self.generation == ticket && self.operationID == op {self.status = "CLI 检测失败或超时，请重试；登录状态尚未确认"}}
        }
    }
    func install() {
        guard !busy else {return}
        if locator() != nil {detect(); return}
        busy = true; actionTitle = "安装即梦 CLI"; status = "正在下载安装即梦 CLI…"
        let ticket = generation, op=UUID();operationID=op
        operation = Task { [weak self] in
            guard let self else {return}
            defer {if self.generation == ticket && self.operationID == op {self.busy = false}}
            do {
                let receipt = try await ClassicCliInstaller().install(canReplace:{[self] in await self.canUpgrade(ticket,op:op)})
                guard self.generation == ticket && self.operationID == op else {return}
                self.installed = true; self.needsUpgrade = false; self.loginChecked = false
                self.version = receipt.version.prefix(100).description
                self.status = "已安装 · 请登录即梦后连接"
            } catch {if self.generation == ticket && self.operationID == op {self.status = "安装失败，可重新检测或重试安装"}}
        }
    }
    func upgrade() {
        guard !busy, !claimed, !connected, let executable=locator() else {status="请先断开连接并等待本机任务结束";return}
        busy=true;actionTitle="更新即梦 CLI";status="正在验证并更新即梦 CLI…"
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
                self.installed=true;self.needsUpgrade=false;self.loginChecked=false;self.version=""
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
        busy=true;actionTitle="登录即梦";clearAuthorization();status="检查即梦登录…"
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
                self.loggedIn = true; self.loginChecked = true
                self.status="即梦已登录 · 可连接当前 Studio 工作区"
            } catch {if self.generation == ticket && self.operationID == op {self.status="即梦登录取消、超时或未完成，请重试"}}
        }
    }
    // Restore only a previously approved device. Never register or open OAuth silently.
    func restoreRememberedConnection() {
        guard enabled else { return }
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard let self, !Task.isCancelled, !self.busy, !self.connected,
                  let owner = self.owner, let file = try? self.location(owner),
                  let data = try? Data(contentsOf: file),
                  let saved = try? JSONDecoder().decode(Authorization.self, from: data),
                  saved.owner == owner, saved.autoResume != false else { return }
            self.connect(automatically: true)
        }
    }
    private func retryRememberedConnection(ticket: UUID) {
        restoreTask?.cancel()
        restoreAttempts = min(restoreAttempts + 1, 4)
        let delay = min(120_000_000_000, restoreRetryNanoseconds * UInt64(1 << (restoreAttempts - 1)))
        restoreTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled, self.generation == ticket else { return }
            self.restoreRememberedConnection()
        }
    }
    func connect(automatically: Bool = false) {
        guard enabled, !busy, let studio, let owner, let context = studio.classicCliContext(), let executable = locator() else { status = "请先登录 Studio，并安装即梦 CLI"; return }
        busy = true; actionTitle = automatically ? "恢复连接" : "连接 Studio"; status = "检查本机登录…"
        let ticket = generation, op=UUID();operationID=op
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == ticket && self.operationID == op && !Task.isCancelled { self.busy = false } }
            do {
                let fingerprint = try await Task.detached { try ClassicDreaminaCLI.fingerprint(executable) }.value
                let cli = ClassicDreaminaCLI(runner: self.runnerFactory(executable))
                let models = try await classicCliDeadline(seconds:self.detectionTimeout) {try await cli.verify()}
                self.loggedIn = true; self.loginChecked = true
                let profile = "resolution-five"
                guard self.owner == owner, self.generation == ticket && self.operationID == op && !Task.isCancelled else { return }
                let file = try self.location(owner)
                var saved = try? JSONDecoder().decode(Authorization.self, from: Data(contentsOf: file))
                if automatically && (saved?.owner != owner || saved?.autoResume == false) { return }
                let current: @Sendable () async -> Bool = { [self] in
                    guard await self.matches(owner: owner, ticket: ticket) else { return false }
                    return (try? await Task.detached { try ClassicDreaminaCLI.fingerprint(executable) }.value) == fingerprint
                }
                var candidate: ClassicStudioBridge?
                if let saved, saved.owner == owner, saved.fingerprint == fingerprint, saved.profile == profile {
                    let restored = ClassicStudioBridge(client: context.client, session: context.session, workspace: context.workspace, device: saved.device, current: current)
                    do {
                        try Task.checkCancellation()
                        _ = try await restored.client.json(restored.request("devices/resume"))
                        candidate = restored
                    } catch {
                        guard !Task.isCancelled, self.generation == ticket else { return }
                        if automatically {
                            if error is URLError { throw error }
                            if case StudioError.http(let status, _) = error, status >= 500 { throw error }
                        }
                        // A revoked association requires explicit confirmation; never register a replacement automatically.
                    }
                }
                guard self.owner == owner, self.generation == ticket && self.operationID == op && !Task.isCancelled else { return }
                if candidate == nil {
                    guard !automatically else { self.status = "已保留即梦登录，请手动确认 Studio 连接"; return }
                    let alert = NSAlert(); alert.messageText = "关联本机即梦登录？"
                    alert.informativeText = "使用本机即梦登录，常规 CLI 不核验即梦账号 ID。关联当前 Studio 账号与工作区；画布点击生成后由本机直接执行，使用本人即梦额度。"
                    alert.addButton(withTitle: "关联"); alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { self.status = "未连接"; return }
                    guard await current(),self.operationID == op,!Task.isCancelled else { return }
                    let body = try JSONSerialization.data(withJSONObject: ["origin": context.client.environment.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "models": models, "profile": profile] as [String: Any])
                    let (data, _) = try await context.client.json(context.client.request(path: "api/local-cli/devices/register", method: "POST", session: context.session, workspace: context.workspace, body: body))
                    guard await current(),self.operationID == op,!Task.isCancelled else {return}
                    let device = try JSONDecoder().decode(ClassicCliDevice.self, from: data)
                    let publicDevice = try? JSONDecoder().decode(ClassicCliPublicDevice.self, from: data)
                    if let publicDevice { try publicDevice.validate(for: device) }
                    let authorization = Authorization(owner: owner, fingerprint: fingerprint, device: device, profile: profile, capabilities: publicDevice)
                    try JSONEncoder().encode(authorization).write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    saved = authorization
                    candidate = ClassicStudioBridge(client: context.client, session: context.session, workspace: context.workspace, device: device, current: current)
                }
                guard let candidate, await current(),self.operationID == op,!Task.isCancelled else { return }
                if var remembered = saved {
                    remembered.autoResume = true
                    try JSONEncoder().encode(remembered).write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    saved = remembered
                }
                self.restoreAttempts = 0
                self.bridge = candidate; self.loggedIn = true; self.loginChecked = true; self.connected = true; self.status = "已连接 · 使用本机即梦登录"
                self.startCreditRefresh(executable: executable, bridge: candidate, owner: owner, ticket: ticket, fingerprint: fingerprint)
                self.start(cli: cli, executable: executable, bridge: candidate, owner: owner, ticket: ticket)
            } catch DreaminaError.notLinked {if self.generation == ticket && self.operationID == op && !Task.isCancelled {self.loggedIn=false;self.loginChecked=true;self.status="请先登录即梦"}} catch ClassicCliUpgradeError.required {if self.generation == ticket && self.operationID == op && !Task.isCancelled {self.needsUpgrade=true;self.status="请更新即梦 CLI 后重新关联"}} catch {
                if self.generation == ticket && self.operationID == op && !Task.isCancelled {
                    self.status = automatically ? "连接暂未恢复，稍后自动重试" : "连接失败，请检查 Studio 与本机即梦登录"
                    if automatically { self.retryRememberedConnection(ticket: ticket) }
                }
            }
        }
    }
    private func restartCreditRefresh() {
        guard connected, let bridge, let owner, let executable = locator(),
              let file = try? location(owner), let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Authorization.self, from: data),
              saved.owner == owner, saved.device.id == bridge.device.id, saved.device.epoch == bridge.device.epoch else { return }
        startCreditRefresh(executable: executable, bridge: bridge, owner: owner, ticket: generation, fingerprint: saved.fingerprint)
    }
    private func stopCreditRefresh() {
        _ = try? creditService?.ledger.read()
        creditTicket = UUID(); creditLoop?.cancel(); creditLoop = nil; creditService = nil
        creditTotal = nil; creditQueriedAt = nil; creditExpiresAt = nil; creditStatus = "积分未查询"
    }
    private func startCreditRefresh(executable: URL, bridge: ClassicStudioBridge, owner: String, ticket: UUID, fingerprint: String) {
        stopCreditRefresh()
        let creditTicket = self.creditTicket
        guard let identity = try? ClassicDreaminaCLI.fileIdentity(executable),
              let ledger = try? ClassicCreditLedger(directory: directory, binding: owner + "|" + bridge.device.id + "|" + bridge.device.epoch, epoch: bridge.device.epoch) else { return }
        let context: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.owner == owner && self.generation == ticket && self.creditTicket == creditTicket && !Task.isCancelled &&
                self.connected && self.bridge?.device.id == bridge.device.id && self.bridge?.device.epoch == bridge.device.epoch &&
                self.locator()?.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath() &&
                (try? ClassicDreaminaCLI.fileIdentity(executable)) == identity
        }
        let hash: @MainActor () async -> Bool = { [weak self] in
            guard let self, context() else { return false }
            let actual = try? await self.capabilityFingerprint(executable)
            return context() && actual == fingerprint
        }
        let service = ClassicCreditRefresh(ledger: ledger, device: bridge.device, bridge: bridge, runner: creditRunnerFactory(executable), current: context, hashCurrent: hash,
                                          confirm: { [weak self] changed in
            guard let self, context() else { return false }
            self.creditTotal = nil; self.creditStatus = changed ? "即梦登录已变化，请确认本次积分查询" : "请确认首次积分查询"
            let accepted = await self.creditConfirmation(changed)
            return context() && accepted
        })
        creditService = service
        creditLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, context() else { return }
                do {
                    var request = bridge.client.request(path: "api/local-cli/devices/credit-refresh", session: bridge.session, workspace: bridge.workspace)
                    request.setValue(bridge.device.id, forHTTPHeaderField: "X-Local-CLI-Device")
                    request.setValue(bridge.device.secret, forHTTPHeaderField: "X-Local-CLI-Secret")
                    guard context() else { return }
                    let (data, _) = try await bridge.client.json(request)
                    guard context() else { return }
                    struct Response: Decodable { let request: ClassicCreditRequest? }
                    var pendingRequest = try JSONDecoder().decode(Response.self, from: data).request
                    // A completed server slot is no longer returned by polling. Reconcile the
                    // original uncertain payload without executing another CLI query.
                    if pendingRequest == nil, let saved = try? ledger.read(), let payload = saved.pending,
                       let requestID = payload.requestId, let expiration = saved.reservations?[requestID],
                       let deadline = ClassicCreditRefresh.date(expiration), Date() < deadline {
                        pendingRequest = ClassicCreditRequest(requestId: requestID, deviceId: bridge.device.id, epoch: payload.epoch,
                            capabilityRevision: payload.capabilityRevision, status: "pending", requestedAt: ClassicCreditRefresh.timestamp(deadline.addingTimeInterval(-60)), expiresAt: expiration)
                    }
                    if let pending = pendingRequest {
                        self.creditTotal = nil; self.creditStatus = "正在刷新即梦积分…"
                        if let snapshot = try await service.run(pending), context() {
                            self.creditTotal = snapshot.status == "available" ? snapshot.totalCredit : nil
                            self.creditQueriedAt = snapshot.queriedAt.flatMap(ClassicCreditRefresh.date)
                            self.creditExpiresAt = snapshot.expiresAt.flatMap(ClassicCreditRefresh.date)
                            if let queried = self.creditQueriedAt, let expiry = self.creditExpiresAt { self.creditExpiresAt = min(expiry, queried.addingTimeInterval(120)) }
                            self.creditStatus = snapshot.status == "available" ? "最近查询快照，可能因即梦账号切换或使用而变化" : "积分读取失败或已过期，请重新刷新"
                        } else if context() { self.creditStatus = "本次查询已处理或未确认，请在Studio核对结果；超时后可重新刷新" }
                    }
                } catch { if context() { self.creditTotal = nil; self.creditStatus = "积分读取失败，请重新刷新" } }
                do { try await Task.sleep(nanoseconds: self.creditPollingNanoseconds) } catch { return }
                guard context() else { return }
                if self.creditExpiresAt.map({ Date() >= $0 }) == true {
                    self.creditTotal = nil; self.creditQueriedAt = nil; self.creditStatus = "积分快照已过期，请重新刷新"
                }
                // Local expiry never triggers a CLI query or network upload.
                if let state = try? ledger.read(), let pending = state.pending,
                   ClassicCreditRefresh.date(pending.queriedAt).map({ Date().timeIntervalSince($0) >= 120 }) == true {
                    self.creditTotal = nil
                    var expired = state; expired.pending = nil; expired.pendingIdentityHMAC = nil
                    if context() { try? ledger.write(expired) }
                }
            }
        }
    }
    private func start(cli: ClassicDreaminaCLI, executable: URL, bridge: ClassicStudioBridge, owner: String, ticket: UUID) {
        loop?.cancel(); heartbeat?.stop()
        // Keep presence alive independently of confirmation, submission, and slow result downloads.
        // The copied bridge binds the original session/workspace; identityChanged cancels this task.
        let identity = try? ClassicDreaminaCLI.fileIdentity(executable)
        heartbeat = ClassicCliHeartbeat { _ = try await bridge.client.json(bridge.request("devices/heartbeat")) }
        let executor = ClassicCliExecutor(cli: cli, directory: directory.appendingPathComponent("journal", isDirectory: true)); self.executor=executor
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.owner == owner, self.generation == ticket else { return }
                do {
                    guard let identity, (try? ClassicDreaminaCLI.fileIdentity(executable)) == identity else {
                        self.identityChanged(); self.status = "CLI 已变化，请重新关联"; return
                    }
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
    func disconnect() {
        // Persist explicit disconnection so a restart cannot undo the user's choice.
        if let owner, let file = try? location(owner) {
            do {
                if let data = try? Data(contentsOf: file), var saved = try? JSONDecoder().decode(Authorization.self, from: data) {
                    saved.autoResume = false
                    try JSONEncoder().encode(saved).write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
            } catch { status = "断开状态保存失败，请重试"; return }
        }
        identityChanged(); status = "未连接"
    }
    func shutdown() { stopCreditRefresh(); discardCapabilityPreview(); restoreTask?.cancel(); generation = UUID(); loop?.cancel(); heartbeat?.stop(); operation?.cancel() }
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
        return "\(title) · \(ClassicVideoModels.title(snapshot.model)) · \(String(format:"%g",snapshot.duration))秒 · \(snapshot.aspect == "source" ? "随源图比例" : snapshot.aspect) · \(snapshot.resolution == "default" ? "CLI 默认清晰度" : snapshot.resolution)\n引用：\(order.isEmpty ? "无" : order)\n\(preview)\n使用当前本机即梦登录；画布点击生成后直接执行。"
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
