import Foundation
import CryptoKit
import CoreFoundation
import Darwin
import AppKit

struct ClassicCreditRequest: Codable, Equatable, Sendable {
    let requestId: String
    let deviceId: String
    let epoch: String
    let capabilityRevision: Int
    let status: String
    let requestedAt: String
    let expiresAt: String
}
struct ClassicCreditSnapshot: Codable, Sendable {
    struct SequenceMeta: Codable, Sendable { let lastSequence: Int }
    let status: String
    let deviceId: String?
    let epoch: String?
    let capabilityRevision: Int?
    let snapshotSequence: Int?
    let totalCredit: Double?
    let queriedAt: String?
    let receivedAt: String?
    let expiresAt: String?
    let sequenceMeta: SequenceMeta?
    let requestId: String?
}
struct ClassicCreditPayload: Codable, Equatable, Sendable {
    let epoch: String
    let capabilityRevision: Int
    let sequence: Int
    let queriedAt: String
    let status: String
    let totalCredit: Double?
    let requestId: String?
}
struct ClassicCreditState: Codable {
    var reserved = 0
    var identityHMAC: String?
    var pending: ClassicCreditPayload?
    var pendingIdentityHMAC: String?
    var handledRequest: String?
    var reservations: [String: String]?
}
// Separate owner/device/epoch private record: old authorization writers cannot overwrite the counter.
@MainActor final class ClassicCreditLedger {
    let file: URL
    init(directory: URL, binding: String) throws {
        let directory = directory.appendingPathComponent("credit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = directory.appendingPathComponent(SHA256.hash(data: Data(binding.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }
    func read() throws -> ClassicCreditState {
        guard FileManager.default.fileExists(atPath: file.path) else { return ClassicCreditState() }
        return try JSONDecoder().decode(ClassicCreditState.self, from: Data(contentsOf: file))
    }
    func write(_ state: ClassicCreditState) throws {
        let data = try JSONEncoder().encode(state)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".credit-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DreaminaError.invalidResponse }
        defer { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DreaminaError.invalidResponse }
                written += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, file.path) == 0 else { throw DreaminaError.invalidResponse }
        let parent = open(file.deletingLastPathComponent().path, O_RDONLY)
        guard parent >= 0 else { throw DreaminaError.invalidResponse }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw DreaminaError.invalidResponse }
    }
    func reserve(highwater: Int, request: ClassicCreditRequest, now: Date) throws -> Int {
        var state = try read()
        let value = max(state.reserved, highwater)
        guard highwater >= 0, state.reserved >= 0, value < 9_007_199_254_740_991 else { throw DreaminaError.invalidResponse }
        state.reserved = value + 1; state.pending = nil; state.pendingIdentityHMAC = nil
        var reservations = (state.reservations ?? [:]).filter { ClassicCreditRefresh.date($0.value).map { $0 > now } == true }
        reservations[request.requestId] = request.expiresAt
        state.reservations = reservations
        state.handledRequest = request.requestId
        try write(state)
        return state.reserved
    }
}
struct ClassicCreditObservation: Sendable {
    let total: Double
    let identityHMAC: String
    static func parse(_ output: DreaminaOutput, device: ClassicCliDevice) throws -> Self {
        let object = try ClassicDreaminaCLI.object(output)
        guard ClassicDreaminaCLI.hasAccountIdentity(object), let credit = object["total_credit"] as? NSNumber,
              CFGetTypeID(credit) != CFBooleanGetTypeID(), credit.doubleValue.isFinite, credit.doubleValue >= 0 else { throw DreaminaError.invalidResponse }
        let identity: String
        if let id = object["user_id"] as? String { identity = id.trimmingCharacters(in: .whitespacesAndNewlines) }
        else if let id = object["user_id"] as? NSNumber { identity = id.stringValue }
        else { throw DreaminaError.invalidResponse }
        let digest = HMAC<SHA256>.authenticationCode(for: Data(identity.utf8), using: SymmetricKey(data: Data(device.secret.utf8)))
        return Self(total: credit.doubleValue, identityHMAC: digest.map { String(format: "%02x", $0) }.joined())
    }
}
// The CLI's built-in account diagnostic logger must not write identity/credit to disk.
struct ClassicCreditReadOnlyRunner: DreaminaRunning {
    let executable: URL
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> DreaminaOutput {
        guard arguments == ["user_credit"] else { throw DreaminaError.invalidResponse }
        return try await DreaminaProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"))
            .run(["-p", "(version 1) (allow default) (deny file-write*)", executable.path, "user_credit"], timeout: min(20, timeout))
    }
}
protocol ClassicCreditBridge: Sendable {
    func bootstrap() async throws -> ClassicCreditSnapshot
    func submit(_ payload: ClassicCreditPayload) async throws -> ClassicCreditSnapshot
}
extension ClassicStudioBridge: ClassicCreditBridge {
    func bootstrap() async throws -> ClassicCreditSnapshot {
        var request = client.request(path: "api/local-cli/credit-snapshot", session: session, workspace: workspace)
        request.setValue(device.id, forHTTPHeaderField: "X-Local-CLI-Device")
        request.setValue(device.secret, forHTTPHeaderField: "X-Local-CLI-Secret")
        let (data, _) = try await client.json(request)
        return try JSONDecoder().decode(ClassicCreditSnapshot.self, from: data)
    }
    func submit(_ payload: ClassicCreditPayload) async throws -> ClassicCreditSnapshot {
        var request = try self.request("devices/credit-snapshot")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await client.json(request)
        return try JSONDecoder().decode(ClassicCreditSnapshot.self, from: data)
    }
}
@MainActor final class ClassicCreditRefresh {
    let ledger: ClassicCreditLedger
    let device: ClassicCliDevice
    let bridge: any ClassicCreditBridge
    let runner: any DreaminaRunning
    let current: () -> Bool
    let hashCurrent: () async -> Bool
    let confirm: (_ changed: Bool) async -> Bool
    let clock: () -> Date
    private var inFlight = false
    init(ledger: ClassicCreditLedger, device: ClassicCliDevice, bridge: any ClassicCreditBridge, runner: any DreaminaRunning,
         current: @escaping () -> Bool, hashCurrent: @escaping () async -> Bool,
         confirm: @escaping (Bool) async -> Bool, clock: @escaping () -> Date = Date.init) {
        self.ledger = ledger; self.device = device; self.bridge = bridge; self.runner = runner
        self.current = current; self.hashCurrent = hashCurrent; self.confirm = confirm; self.clock = clock
    }
    nonisolated static func date(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
    nonisolated static func timestamp(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
    private func valid(_ request: ClassicCreditRequest) -> Bool {
        current() && !Task.isCancelled && request.deviceId == device.id && request.epoch == device.epoch && request.status == "pending" &&
        !request.requestId.isEmpty && request.requestId.count <= 200 && request.capabilityRevision >= 0 && request.capabilityRevision <= 9_007_199_254_740_991 &&
        Self.date(request.expiresAt).map { clock() < $0 } == true && Self.date(request.requestedAt).map { $0 <= clock().addingTimeInterval(30) } == true
    }
    func run(_ request: ClassicCreditRequest) async throws -> ClassicCreditSnapshot? {
        guard !inFlight, valid(request) else { return nil }
        inFlight = true; defer { inFlight = false }
        guard await hashCurrent(), valid(request) else { throw DreaminaError.wrongOwner }
        let state = try ledger.read()
        if let pending = state.pending, pending.requestId == request.requestId {
            return try await send(pending, request: request)
        }
        guard state.handledRequest != request.requestId, state.reservations?[request.requestId] == nil else { return nil }
        if state.identityHMAC == nil {
            let accepted = await confirm(false)
            guard valid(request) else { return nil }
            if !accepted { var declined = try ledger.read(); declined.handledRequest = request.requestId; try ledger.write(declined); return nil }
        }
        guard await hashCurrent(), valid(request) else { throw DreaminaError.wrongOwner }
        let bootstrap = try await bridge.bootstrap()
        guard valid(request), bootstrap.deviceId == device.id, bootstrap.epoch == device.epoch,
              bootstrap.capabilityRevision == request.capabilityRevision, let meta = bootstrap.sequenceMeta,
              ["available", "unknown", "expired", "error"].contains(bootstrap.status) else { throw DreaminaError.wrongOwner }
        guard valid(request) else { throw DreaminaError.wrongOwner }
        let sequence = try ledger.reserve(highwater: meta.lastSequence, request: request, now: clock())
        var observedAt = clock()
        var observation: ClassicCreditObservation?
        do {
            guard await hashCurrent(), valid(request) else { throw DreaminaError.wrongOwner }
            let output = try await runner.run(["user_credit"], timeout: min(20, max(0.01, (Self.date(request.expiresAt) ?? clock()).timeIntervalSince(clock()))))
            observedAt = clock()
            observation = try ClassicCreditObservation.parse(output, device: device)
        } catch {
            guard valid(request) else { throw DreaminaError.wrongOwner }
            observedAt = clock(); observation = nil
        }
        guard await hashCurrent(), valid(request) else { throw DreaminaError.wrongOwner }
        var latest = try ledger.read()
        guard latest.reserved == sequence else { throw DreaminaError.wrongOwner }
        if let observation, let previous = latest.identityHMAC, previous != observation.identityHMAC {
            let accepted = await confirm(true)
            guard valid(request) else { return nil }
            if !accepted { var declined = try ledger.read(); declined.handledRequest = request.requestId; try ledger.write(declined); return nil }
        }
        guard valid(request), clock().timeIntervalSince(observedAt) < 120 else { return nil }
        latest = try ledger.read()
        guard latest.reserved == sequence else { throw DreaminaError.wrongOwner }
        let payload = ClassicCreditPayload(epoch: device.epoch, capabilityRevision: request.capabilityRevision, sequence: sequence,
                                           queriedAt: Self.timestamp(observedAt), status: observation == nil ? "error" : "ok", totalCredit: observation?.total, requestId: request.requestId)
        latest.pending = payload; latest.pendingIdentityHMAC = observation?.identityHMAC
        guard valid(request) else { throw DreaminaError.wrongOwner }
        try ledger.write(latest)
        return try await send(payload, request: request)
    }
    private func send(_ payload: ClassicCreditPayload, request: ClassicCreditRequest) async throws -> ClassicCreditSnapshot {
        guard await hashCurrent(), valid(request), payload.capabilityRevision == request.capabilityRevision,
              payload.epoch == device.epoch, payload.requestId == request.requestId else { throw DreaminaError.wrongOwner }
        do {
            let result = try await bridge.submit(payload)
            guard await hashCurrent(), valid(request), result.deviceId == device.id, result.epoch == device.epoch,
                  result.capabilityRevision == payload.capabilityRevision, result.requestId == payload.requestId,
                  result.sequenceMeta?.lastSequence == payload.sequence, result.snapshotSequence == payload.sequence else { throw DreaminaError.wrongOwner }
            if result.status == "available" {
                guard payload.status == "ok", result.totalCredit == payload.totalCredit,
                      result.totalCredit?.isFinite == true, result.totalCredit! >= 0,
                      result.expiresAt.flatMap(Self.date).map({ clock() < $0 }) == true else { throw DreaminaError.invalidResponse }
            } else { guard result.totalCredit == nil, ["error", "unknown", "expired"].contains(result.status) else { throw DreaminaError.invalidResponse } }
            var state = try ledger.read()
            guard state.pending == payload, valid(request) else { throw DreaminaError.wrongOwner }
            if payload.status == "ok" { state.identityHMAC = state.pendingIdentityHMAC }
            state.pending = nil; state.pendingIdentityHMAC = nil; state.handledRequest = request.requestId
            try ledger.write(state)
            return result
        } catch StudioError.http(409, _) {
            guard valid(request) else { throw DreaminaError.wrongOwner }
            var state = try ledger.read()
            if state.pending == payload { state.pending = nil; state.pendingIdentityHMAC = nil; state.handledRequest = request.requestId; try ledger.write(state) }
            throw StudioError.http(409, "积分版本已变化，请重新刷新")
        }
    }
}

@MainActor enum ClassicCreditConsent {
    static func confirm(changed: Bool) async -> Bool {
        let alert = NSAlert()
        alert.messageText = changed ? "即梦登录已变化，采用本次积分快照？" : "允许查询当前本机即梦积分？"
        alert.informativeText = "仅查询当前本机即梦登录的剩余积分并向原Studio工作区显示短时快照，不生成或消费。最近查询快照可能随即梦账号切换或使用变化；不作为会员或生成授权保证。"
        alert.addButton(withTitle: "允许查询并显示"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
