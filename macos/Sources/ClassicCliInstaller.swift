import Foundation
import CryptoKit

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
        let runner = DreaminaProcessRunner(executable: executable)
        let version = try await runner.run(["--version"], timeout: 15)
        guard version.status == 0, version.data.count < 16_384 else { throw DreaminaError.unsupportedCLI }
        for mode in ["text2video", "image2video", "frames2video", "multiframe2video", "multimodal2video", "query_result"] {
            let help = try await runner.run([mode, "--help"], timeout: 15)
            guard help.status == 0, help.data.count < 128_000, String(decoding: help.data, as: UTF8.self).contains(mode) else { throw DreaminaError.unsupportedCLI }
        }
        let bytes = try Data(contentsOf: executable, options: .mappedIfSafe)
        return ClassicCliInstallation(executable: executable, version: String(decoding: version.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), sha256: SHA256.hash(data: bytes).map {String(format: "%02x", $0)}.joined())
    }
    func install() async throws -> ClassicCliInstallation {
        let fm = FileManager.default, target = directory.appendingPathComponent("dreamina")
        if fm.fileExists(atPath: target.path) { return try await Self.inspect(target) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".dreamina-install-" + UUID().uuidString, isDirectory: true)
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
        // Move never replaces a concurrently installed CLI. No shell/PATH/profile
        // edits, quarantine removal, or modification of existing login state.
        try fm.moveItem(at: candidate, to: target)
        return ClassicCliInstallation(executable: target, version: inspection.version, sha256: inspection.sha256)
    }
}
