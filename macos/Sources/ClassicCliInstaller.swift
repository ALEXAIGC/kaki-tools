import Foundation
import CryptoKit
import Darwin

enum ClassicCliUpgradeError: Error { case required, active, changed }

struct ClassicCliInstallation: Sendable {
    let executable: URL
    let version: String
    let sha256: String // Content receipt, not a vendor-published authenticity hash.
}

struct ClassicCliInstaller: @unchecked Sendable {
    static let base = "https://lf3-static.bytednsdoc.com/obj/eden-cn/psj_hupthlyk/ljhwZthlaukjlkulzlp/dreamina_cli_beta/"
    let directory: URL
    let transport: StudioTransport
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin"), transport: StudioTransport = StudioURLTransport()) {
        self.directory = directory; self.transport = transport
    }
    static var binaryName: String {
        #if arch(arm64)
        return "dreamina_cli_darwin_arm64"
        #else
        return "dreamina_cli_darwin_amd64"
        #endif
    }
    static func inspect(_ executable: URL) async throws -> ClassicCliInstallation {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw DreaminaError.unsupportedCLI }
        return try await inspect(executable, runner:DreaminaProcessRunner(executable:executable))
    }
    static func inspect(_ executable:URL, runner:DreaminaRunning) async throws -> ClassicCliInstallation {
        let version = try await runner.run(["--version"], timeout: 15)
        guard version.status == 0, version.data.count < 16_384 else { throw DreaminaError.unsupportedCLI }
        _ = try await ClassicDreaminaCLI(runner:runner).detectedProfile()
        let hash = try await Task.detached {try ClassicDreaminaCLI.fingerprint(executable).split(separator:":").last.map(String.init)!}.value
        return ClassicCliInstallation(executable: executable, version: String(decoding: version.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), sha256: hash)
    }
    static func processesIdle(_ executable:URL) async throws -> Bool {
        let result=try await DreaminaProcessRunner(executable:URL(fileURLWithPath:"/usr/bin/pgrep")).run(["-x",executable.lastPathComponent],timeout:3)
        guard [0,1].contains(result.status) else {throw ClassicCliUpgradeError.active}
        return result.status == 1
    }
    func install(upgrading executable:URL? = nil, canReplace: @Sendable () async -> Bool = {true}) async throws -> ClassicCliInstallation {
        let fm = FileManager.default, target = executable ?? directory.appendingPathComponent("dreamina")
        let original = fm.fileExists(atPath:target.path) ? try ClassicDreaminaCLI.fingerprint(target) : nil
        if executable == nil, original != nil {return try await Self.inspect(target)}
        guard await canReplace(), try await Self.processesIdle(target) else {throw ClassicCliUpgradeError.active}
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".dreamina-install-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let request = URLRequest(url: URL(string: Self.base + Self.binaryName)!)
        let response = try await transport.perform(request, maximumBytes: 150 * 1024 * 1024)
        defer { try? fm.removeItem(at: response.file) }
        guard response.response.statusCode == 200, response.response.url == request.url else { throw DreaminaError.invalidResponse }
        let data = try Data(contentsOf: response.file, options: .mappedIfSafe)
        guard data.count > 4096, data.prefix(4) == Data([0xcf, 0xfa, 0xed, 0xfe]) else { throw DreaminaError.invalidResponse }
        #if arch(arm64)
        let architecture = Data([0x0c, 0x00, 0x00, 0x01])
        #else
        let architecture = Data([0x07, 0x00, 0x00, 0x01])
        #endif
        guard data.subdata(in: 4..<8) == architecture else {throw DreaminaError.invalidResponse}
        let candidate = staging.appendingPathComponent("dreamina")
        try data.write(to: candidate, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)
        let inspection = try await Self.inspect(candidate)
        try Task.checkCancellation()
        guard await canReplace(), try await Self.processesIdle(target) else {throw ClassicCliUpgradeError.active}
        if let original {
            guard (try target.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true, try ClassicDreaminaCLI.fingerprint(target) == original else {throw ClassicCliUpgradeError.changed}
            // Keep a non-executable recovery copy. POSIX rename atomically replaces only the rechecked binary.
            let backup=target.deletingLastPathComponent().appendingPathComponent(".dreamina-backup-" + UUID().uuidString)
            try fm.copyItem(at:target,to:backup)
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path)
            guard await canReplace(), try ClassicDreaminaCLI.fingerprint(target) == original else {throw ClassicCliUpgradeError.changed}
            try Task.checkCancellation()
            guard rename(candidate.path,target.path) == 0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        } else {try fm.moveItem(at: candidate, to: target)}
        return ClassicCliInstallation(executable: target, version: inspection.version, sha256: inspection.sha256)
    }
}
