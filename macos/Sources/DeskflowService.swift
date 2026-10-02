import AppKit
import Combine
import CryptoKit
import Foundation
import Security
import Darwin

struct DeskflowPosition: Codable, Equatable, Hashable {
    let col: Int
    let row: Int
    var isValid: Bool { (0..<5).contains(col) && (0..<3).contains(row) }
}

struct DeskflowSessionGate {
    private(set) var current: UUID?
    mutating func begin() -> UUID { let value = UUID(); current = value; return value }
    mutating func invalidate() { current = nil }
    func accepts(_ value: UUID) -> Bool { current == value }
}

struct DeskflowFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class DeskflowService: ObservableObject {
    @Published var role = "idle"
    @Published var statusText = "跨屏组件未安装"
    @Published var peer: String?
    @Published var error: String?
    @Published var fingerprint = ""
    @Published var addresses: [String] = []
    @Published var layout: [String: DeskflowPosition] = [:]
    @Published var componentAvailable = false

    let deviceName: String
    let userData: URL
    private let files = FileManager.default
    private var process: Process?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var outputBuffers: [Int: Data] = [:]
    private var activation = 0
    private var retiringProcess: Process?
    var sessions = DeskflowSessionGate()
    private var settingsURL: URL { directory.appendingPathComponent("deskflow.conf") }
    private var directory: URL { userData.appendingPathComponent("deskflow", isDirectory: true) }
    private var components: URL { userData.appendingPathComponent("Components", isDirectory: true) }
    private var component: URL { components.appendingPathComponent("DeskflowRuntime.bundle", isDirectory: true) }
    private var executable: URL { component.appendingPathComponent("Contents/MacOS/deskflow-core") }

    init(userData: URL) {
        self.userData = userData
        deviceName = Self.cleanComputerName(ProcessInfo.processInfo.hostName)
        refreshComponent()
    }

    func refreshComponent() {
        do {
            try Self.checkComponentMetadata(component)
            componentAvailable = true
            if role == "idle" { statusText = "跨屏组件已就绪"; error = nil }
        } catch {
            componentAvailable = false
            if role == "idle" {
                let installed = files.fileExists(atPath: component.path)
                statusText = installed ? "跨屏组件不可用" : "跨屏组件未安装"
                if installed { self.error = error.localizedDescription }
            }
        }
    }

    func importComponent(from source: URL) throws {
        guard role == "idle", process == nil, retiringProcess?.isRunning != true else { throw DeskflowFailure(message: "请先停止跨屏连接，再导入组件。") }
        try Self.verifyComponent(source)
        try files.createDirectory(at: components, withIntermediateDirectories: true)
        let staging = components.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("DeskflowRuntime.bundle", isDirectory: true)
        try files.copyItem(at: source, to: staged)
        try Self.verifyComponent(staged)
        if files.fileExists(atPath: component.path) {
            let backup = "DeskflowRuntime-\(UUID().uuidString).bundle"
            _ = try files.replaceItemAt(component, withItemAt: staged, backupItemName: backup,
                                        options: [.usingNewMetadataOnly, .withoutDeletingBackupItem])
        } else {
            try files.moveItem(at: staged, to: component)
        }
        refreshComponent()
        error = nil
        statusText = "跨屏组件已导入"
    }

    func startHost() {
        do {
            try Self.verifyComponent(component)
            let identity = try Self.ensureIdentity(in: directory)
            fingerprint = identity.fingerprint
            addresses = Self.localAddresses()
            layout = Self.loadLayout(directory.appendingPathComponent("layout.json"), deviceName: deviceName)
            try saveLayout()
            try writeServerConfig()
            try writeSettings(mode: "server", certificate: identity.url)
            begin(mode: "server")
        } catch { fail(error) }
    }

    func connect(host: String, fingerprint input: String) {
        do {
            let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, !host.contains(where: { $0.isNewline || $0 == "=" || $0 == "[" || $0 == "]" }) else {
                throw DeskflowFailure(message: "请填写有效的主机地址。")
            }
            let trusted = try Self.normalizedFingerprint(input)
            try Self.verifyComponent(component)
            let identity = try Self.ensureIdentity(in: directory)
            fingerprint = identity.fingerprint
            try Data("v2:sha256:\(trusted)\n".utf8).write(to: directory.appendingPathComponent("tls/trusted-servers"), options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("tls/trusted-servers").path)
            try writeSettings(mode: "client", certificate: identity.url, host: host)
            begin(mode: "client")
        } catch { fail(error) }
    }

    func stop() {
        activation += 1
        sessions.invalidate()
        let previous = detachProcess() ?? retiringProcess
        retiringProcess = previous
        Self.terminate(previous)
        role = "idle"
        peer = nil
        error = nil
        statusText = componentAvailable ? "跨屏组件已停止" : "跨屏组件未安装"
    }

    func shutdown() {
        activation += 1
        sessions.invalidate()
        let active = detachProcess(), retiring = retiringProcess
        retiringProcess = nil
        role = "idle"; peer = nil; error = nil
        statusText = componentAvailable ? "跨屏组件已停止" : "跨屏组件未安装"
        Self.terminateForShutdown([active, retiring].compactMap { $0 })
    }

    @discardableResult
    func setLayout(name: String, col: Int, row: Int) -> Bool {
        let clean = Self.cleanComputerName(name, fallback: "")
        let position = DeskflowPosition(col: col, row: row)
        guard role == "host", layout[clean] != nil, position.isValid,
              !layout.contains(where: { $0.key != clean && $0.value == position }) else {
            error = "该位置无效或已被其他设备占用。"
            return false
        }
        if layout[clean] == position { return true }
        let previous = layout
        layout[clean] = position
        do {
            try saveLayout()
            try writeServerConfig()
            error = nil
            begin(mode: "server")
            return true
        } catch {
            layout = previous
            try? saveLayout(); try? writeServerConfig()
            fail(error); return false
        }
    }

    private func fail(_ failure: Error) {
        error = failure.localizedDescription
        statusText = failure.localizedDescription
    }

    private func saveLayout() throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(layout).write(to: directory.appendingPathComponent("layout.json"), options: .atomic)
    }

    private func writeServerConfig() throws {
        try Data(Self.serverConfig(layout).utf8).write(to: directory.appendingPathComponent("server.conf"), options: .atomic)
    }

    private func writeSettings(mode: String, certificate: URL, host: String = "") throws {
        var text = "[core]\ncomputerName=\(deviceName)\nport=24800\ncoreMode=\(mode == "server" ? 2 : 1)\n"
        if mode == "server" {
            text += "[server]\nexternalConfig=true\nexternalConfigFile=\(directory.appendingPathComponent("server.conf").path)\nenableClipboard=true\n"
        } else {
            text += "[client]\nremoteHost=\(host)\nlanguageSync=true\n"
        }
        // 兼容现有主机策略：TLS 加密，客户端固定主机指纹；主机按网格接纳客户端。
        text += "[security]\ntlsEnabled=true\ncheckPeerFingerprints=\(mode == "client" ? "true" : "false")\ncertificate=\(certificate.path)\n[log]\nlevel=info\n"
        try Data(text.utf8).write(to: settingsURL, options: .atomic)
    }

    private func begin(mode: String) {
        activation += 1
        let request = activation
        sessions.invalidate()
        let previous = detachProcess() ?? retiringProcess
        retiringProcess = previous
        Self.terminate(previous)
        role = mode == "server" ? "host" : "client"
        peer = nil
        error = nil
        statusText = mode == "server" ? "正在开启主机…" : "正在连接主机…"
        // 等旧核心释放监听端口后再启动，连续请求仅执行最后一个。
        if let previous, previous.isRunning {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                previous.waitUntilExit()
                DispatchQueue.main.async { [weak self] in self?.launch(mode: mode, request: request) }
            }
        } else { launch(mode: mode, request: request) }
    }

    private func launch(mode: String, request: Int) {
        guard request == activation, role != "idle" else { return }
        retiringProcess = nil
        do {
            // 组件可能在空闲时被替换；启动前重新检查，不执行其他任意路径。
            try Self.verifyComponent(component)
            let child = Process()
            let out = Pipe(), err = Pipe()
            child.executableURL = executable
            child.arguments = [mode, "-s", settingsURL.path]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = out
            child.standardError = err
            let session = sessions.begin()
            process = child; stdout = out; stderr = err; outputBuffers = [:]
            for (index, pipe) in [out, err].enumerated() {
                pipe.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil; return }
                    DispatchQueue.main.async { [weak self, weak child] in
                        guard let self, let child, self.process === child, self.sessions.accepts(session) else { return }
                        self.receive(data, stream: index, session: session)
                    }
                }
            }
            child.terminationHandler = { [weak self] ended in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.process === ended, self.sessions.accepts(session) else { return }
                    self.sessions.invalidate()
                    _ = self.detachProcess()
                    self.role = "idle"; self.peer = nil
                    if self.error == nil { self.error = "跨屏核心已退出（\(ended.terminationStatus)）。" }
                    self.statusText = self.error ?? "跨屏连接已停止"
                }
            }
            try child.run()
            statusText = mode == "server" ? "主机已开启，等待设备连接" : "正在连接主机…"
        } catch {
            sessions.invalidate(); _ = detachProcess(); role = "idle"; fail(error)
        }
    }

    private func detachProcess() -> Process? {
        let old = process
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        process = nil; stdout = nil; stderr = nil; outputBuffers = [:]
        return old
    }

    private static func terminate(_ child: Process?) {
        guard let child, child.isRunning else { return }
        child.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        }
    }

    // 仅在应用退出时使用：普通停止/重启仍给予核心五秒正常退出。
    // 持有的 Process 是本应用创建的子进程，不按名称查找其他进程。
    static func terminateForShutdown(_ children: [Process]) {
        var seen = Set<ObjectIdentifier>()
        let owned = children.filter { seen.insert(ObjectIdentifier($0)).inserted }
        for child in owned where child.isRunning { child.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while owned.contains(where: { $0.isRunning }) && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        for child in owned where child.isRunning {
            let pid = child.processIdentifier
            if pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
        }
        let reapDeadline = ProcessInfo.processInfo.systemUptime + 0.1
        while owned.contains(where: { $0.isRunning }) && ProcessInfo.processInfo.systemUptime < reapDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func receive(_ data: Data, stream: Int, session: UUID) {
        var buffer = outputBuffers[stream, default: Data()]
        buffer.append(data)
        if buffer.count > 64 * 1024 { buffer = Data(buffer.suffix(64 * 1024)) }
        while let newline = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<newline].prefix(4096), as: UTF8.self)
            buffer.removeSubrange(...newline)
            handleLine(line, session: session)
            if !sessions.accepts(session) { return }
        }
        outputBuffers[stream] = buffer
    }

    func handleLine(_ line: String, session: UUID) {
        guard sessions.accepts(session), role != "idle" else { return }
        if line.contains("does not trust this process") || line.contains("assistive devices") {
            error = "请在系统设置的辅助功能中允许 Kaki Tools 与跨屏组件。"
            statusText = error!
        } else if line.contains("unrecognised client name"), role == "host", let name = Self.quotedName(line) {
            addClient(name)
        } else if line.contains("has connected") || line.contains("connected to secure socket") {
            peer = Self.quotedName(line) ?? "已连接"
            error = nil; statusText = "已连接：\(peer!)"
        } else if line.contains("disconnected") || line.contains("failed to connect") || line.contains("Connection refused") {
            peer = nil; statusText = role == "host" ? "等待设备重新连接" : "连接中断，正在重试"
        } else if line.localizedCaseInsensitiveContains("fingerprint mismatch") {
            error = "主机指纹不匹配，请重新核对主机指纹。"; statusText = error!
        }
    }

    private static func quotedName(_ line: String) -> String? {
        let pieces = line.split(separator: "\"", omittingEmptySubsequences: false)
        return pieces.count >= 3 ? String(pieces[1]) : nil
    }

    private func addClient(_ input: String) {
        let name = Self.cleanComputerName(input, fallback: "")
        guard !name.isEmpty else { return }
        if layout[name] == nil {
            guard let position = Self.freePosition(layout, host: deviceName) else { fail(DeskflowFailure(message: "设备网格已满，最多支持 15 台设备。")); return }
            layout[name] = position
        }
        do { try saveLayout(); try writeServerConfig(); begin(mode: "server") }
        catch { fail(error) }
    }

    static func cleanComputerName(_ name: String, fallback: String = "KakiMac") -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: "_")
        let filtered = words.unicodeScalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || "_-.".unicodeScalars.contains($0) }
        let clean = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: CharacterSet(charactersIn: "_-.")).prefix(255)
        return clean.isEmpty ? fallback : String(clean)
    }

    static func normalizedFingerprint(_ input: String) throws -> String {
        let permitted = CharacterSet(charactersIn: "0123456789abcdefABCDEF:-").union(.whitespacesAndNewlines)
        guard input.unicodeScalars.allSatisfy({ permitted.contains($0) }) else { throw DeskflowFailure(message: "主机指纹格式不正确，需要 64 位十六进制。") }
        let result = input.lowercased().filter { "0123456789abcdef".contains($0) }
        guard result.count == 64 else { throw DeskflowFailure(message: "主机指纹格式不正确，需要 64 位十六进制。") }
        return result
    }

    static func loadLayout(_ url: URL, deviceName: String) -> [String: DeskflowPosition] {
        let decoded = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        var result: [String: DeskflowPosition] = [:]
        for (input, raw) in decoded.sorted(by: { $0.key < $1.key }) {
            guard let object = raw as? [String: Any], let col = object["col"] as? NSNumber, let row = object["row"] as? NSNumber,
                  CFGetTypeID(col) != CFBooleanGetTypeID(), CFGetTypeID(row) != CFBooleanGetTypeID(),
                  col.doubleValue.isFinite, row.doubleValue.isFinite,
                  col.doubleValue.rounded(.towardZero) == col.doubleValue, row.doubleValue.rounded(.towardZero) == row.doubleValue,
                  col.doubleValue >= 0, col.doubleValue < 5, row.doubleValue >= 0, row.doubleValue < 3 else { continue }
            let position = DeskflowPosition(col: col.intValue, row: row.intValue)
            let name = cleanComputerName(input, fallback: "")
            guard !name.isEmpty, result[name] == nil, !result.values.contains(position) else { continue }
            result[name] = position
        }
        if result[deviceName] == nil {
            let center = DeskflowPosition(col: 2, row: 1)
            if let free = freePosition(result, host: deviceName) { result[deviceName] = free }
            else {
                if let displaced = result.first(where: { $0.value == center })?.key { result.removeValue(forKey: displaced) }
                result[deviceName] = center
            }
        }
        return result
    }

    static func freePosition(_ layout: [String: DeskflowPosition], host: String) -> DeskflowPosition? {
        let origin = layout[host] ?? DeskflowPosition(col: 2, row: 1)
        for distance in 0..<8 {
            for row in 0..<3 {
                for col in 0..<5 {
                    let position = DeskflowPosition(col: col, row: row)
                    if abs(col - origin.col) + abs(row - origin.row) == distance && !layout.values.contains(position) { return position }
                }
            }
        }
        return nil
    }

    static func serverConfig(_ layout: [String: DeskflowPosition]) -> String {
        let sorted = layout.keys.sorted()
        var lines = ["# Kaki Tools generated Deskflow server config", "section: screens"]
        lines += sorted.map { "\t\($0):" }
        lines += ["end", "section: links"]
        let directions = [(1,0,"right"),(-1,0,"left"),(0,-1,"up"),(0,1,"down")]
        for name in sorted {
            lines.append("\t\(name):")
            guard let origin = layout[name], origin.isValid else { continue }
            for (dc,dr,direction) in directions {
                let target = DeskflowPosition(col: origin.col + dc, row: origin.row + dr)
                if let neighbor = sorted.first(where: { $0 != name && layout[$0] == target }) { lines.append("\t\t\(direction) = \(neighbor)") }
            }
        }
        return (lines + ["end", ""]).joined(separator: "\n")
    }

    static func checkComponentMetadata(_ bundle: URL) throws {
        guard bundle.pathExtension == "bundle", let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == "com.openclaw.kakitools.deskflow-runtime",
              info["CFBundlePackageType"] as? String == "BNDL",
              info["CFBundleExecutable"] as? String == "deskflow-core" else { throw DeskflowFailure(message: "请选择有效的 DeskflowRuntime.bundle 组件。") }
        guard let minimum = info["LSMinimumSystemVersion"] as? String else {
            throw DeskflowFailure(message: "组件缺少最低 macOS 版本信息，请重新获取完整组件。")
        }
        try checkMinimumSystemVersion(minimum)
        let executable = bundle.appendingPathComponent("Contents/MacOS/deskflow-core")
        let root = bundle.resolvingSymlinksInPath().path + "/"
        guard executable.resolvingSymlinksInPath().path.hasPrefix(root), FileManager.default.isExecutableFile(atPath: executable.path) else { throw DeskflowFailure(message: "组件主程序不可用。") }
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4096) ?? Data()
        guard supportsCurrentArchitecture(header) else { throw DeskflowFailure(message: "组件架构与这台 Mac 不兼容。") }
    }

    static func checkMinimumSystemVersion(_ minimum: String, current: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws {
        let parts = minimum.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            throw DeskflowFailure(message: "组件的最低 macOS 版本信息无效，请重新获取完整组件。")
        }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count, let major = values.first, major > 0 else {
            throw DeskflowFailure(message: "组件的最低 macOS 版本信息无效，请重新获取完整组件。")
        }
        let minor = values.count > 1 ? values[1] : 0
        let patch = values.count > 2 ? values[2] : 0
        if (major, minor, patch) > (current.majorVersion, current.minorVersion, current.patchVersion) {
            let required = patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
            throw DeskflowFailure(message: "此跨屏组件需要 macOS \(required) 或更新版本。请升级系统，或选择适配本机系统的组件。")
        }
    }

    static func supportsCurrentArchitecture(_ header: Data) -> Bool {
        #if arch(arm64)
        let expected: UInt32 = 0x0100000c
        #else
        let expected: UInt32 = 0x01000007
        #endif
        let bytes = [UInt8](header)
        func number(_ offset: Int, little: Bool) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let slice = Array(bytes[offset..<offset+4])
            let ordered = little ? Array(slice.reversed()) : slice
            return ordered.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        guard bytes.count >= 8 else { return false }
        let magic = Array(bytes.prefix(4))
        if magic == [0xcf,0xfa,0xed,0xfe] { return number(4, little: true) == expected }
        if magic == [0xfe,0xed,0xfa,0xcf] { return number(4, little: false) == expected }
        let little = magic == [0xbe,0xba,0xfe,0xca] || magic == [0xbf,0xba,0xfe,0xca]
        let fat64 = magic == [0xca,0xfe,0xba,0xbf] || magic == [0xbf,0xba,0xfe,0xca]
        guard little || magic == [0xca,0xfe,0xba,0xbe] || fat64, let count = number(4,little:little), count > 0, count <= 64 else { return false }
        return (0..<Int(count)).contains { number(8 + $0 * (fat64 ? 32 : 20),little:little) == expected }
    }

    static func verifyComponent(_ url: URL) throws {
        try checkComponentMetadata(url)
        _ = try systemCommand("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
    }

    static func ensureIdentity(in directory: URL) throws -> (url: URL, fingerprint: String) {
        let tls = directory.appendingPathComponent("tls", isDirectory: true)
        let certificate = tls.appendingPathComponent("deskflow.pem")
        try FileManager.default.createDirectory(at: tls, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: certificate.path) {
            let temporary = tls.appendingPathComponent("tmp-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let key = temporary.appendingPathComponent("key.pem"), cert = temporary.appendingPathComponent("cert.pem")
            _ = try systemCommand("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", cert.path, "-days", "3650", "-subj", "/CN=Kaki-Tools-\(UUID().uuidString)"])
            var combined = try Data(contentsOf: cert)
            combined.append(try Data(contentsOf: key))
            try combined.write(to: certificate, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certificate.path)
        }
        let pem = try String(contentsOf: certificate, encoding: .utf8)
        guard let start = pem.range(of: "-----BEGIN CERTIFICATE-----"), let end = pem.range(of: "-----END CERTIFICATE-----", range: start.upperBound..<pem.endIndex),
              let der = Data(base64Encoded: String(pem[start.upperBound..<end.lowerBound]), options: .ignoreUnknownCharacters),
              SecCertificateCreateWithData(nil, der as CFData) != nil else { throw DeskflowFailure(message: "本地 TLS 身份文件无效，已保留原文件。") }
        let hex = SHA256.hash(data: der).map { String(format: "%02X", $0) }
        return (certificate, hex.joined(separator: ":"))
    }

    static func systemCommand(_ executable: String, _ arguments: [String]) throws -> Data {
        guard ["/usr/bin/codesign", "/usr/bin/openssl"].contains(executable) else { throw DeskflowFailure(message: "无效的系统验证工具。") }
        let child = Process(), out = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = out
        child.standardError = FileHandle.nullDevice
        try child.run()
        let timeout = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
        let result = out.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit(); timeout.cancel()
        guard child.terminationStatus == 0 else { throw DeskflowFailure(message: executable.hasSuffix("codesign") ? "组件签名验证失败，请重新获取完整的签名组件。" : "无法创建 TLS 身份，请检查系统工具及目录权限。") }
        return result
    }

    static func localAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        var result: [(String,String)] = [], cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET), entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard !["awdl","llw","utun","bridge","docker","vmenet","vmnet"].contains(where: { name.hasPrefix($0) }) else { continue }
            var ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil else { continue }
            result.append((name,String(cString:buffer)))
        }
        return result.sorted { ($0.0.hasPrefix("en") ? 0 : 1, $0.0) < ($1.0.hasPrefix("en") ? 0 : 1, $1.0) }.map(\.1)
    }
}
