import CryptoKit
import Darwin
import Foundation
import Security

@MainActor
func runDeskflowTests() throws {
    let files = FileManager.default
    let temporary = files.temporaryDirectory.appendingPathComponent("kaki-deskflow-tests-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: temporary) }

    let untouched = temporary.appendingPathComponent("untouched")
    let service = DeskflowService(userData: untouched)
    try check(service.role == "idle" && !service.componentAvailable && service.fingerprint.isEmpty, "Deskflow initialization remains idle without a component")
    try check(!files.fileExists(atPath: untouched.path), "Initialization creates neither TLS identities nor user-data directories")
    service.connect(host: "127.0.0.1", fingerprint: "invalid")
    try check(service.error?.contains("指纹") == true, "Invalid fingerprint is rejected before any TLS creation")
    try check(!files.fileExists(atPath: untouched.path), "Invalid connection input cannot create an identity")
    service.startHost()
    try check(service.role == "idle" && service.error != nil, "Missing component cannot launch a server")
    try check(!files.fileExists(atPath: untouched.path), "Missing component cannot create an identity")

    let hex = String(repeating: "ab", count: 32)
    let display = stride(from: 0, to: hex.count, by: 2).map { index -> String in
        let start = hex.index(hex.startIndex, offsetBy: index)
        return String(hex[start..<hex.index(start,offsetBy:2)])
    }.joined(separator: ":").uppercased()
    let normalized = try DeskflowService.normalizedFingerprint(display)
    try check(normalized == hex, "Displayed SHA-256 fingerprints normalize to Deskflow trusted-server format")
    do { _ = try DeskflowService.normalizedFingerprint(hex + "garbage"); throw DeskflowFailure(message: "Malformed fingerprint was accepted") }
    catch let failure as DeskflowFailure { try check(failure.message.contains("指纹"), "Fingerprint garbage is rejected") }
    try check(DeskflowService.cleanComputerName(" --My Mac.local__ ") == "My_Mac.local", "Legacy computer names retain matching sanitization")

    let layoutURL = temporary.appendingPathComponent("layout.json")
    let layoutData = Data("{\"host\":{\"col\":2,\"row\":1},\"client\":{\"col\":3,\"row\":1},\"outside\":{\"col\":99,\"row\":0},\"duplicate\":{\"col\":3,\"row\":1}}".utf8)
    try layoutData.write(to: layoutURL)
    let layout = DeskflowService.loadLayout(layoutURL, deviceName: "host")
    try check(layout.count == 2 && layout["outside"] == nil, "Legacy layouts reject invalid and occupied cells")
    try Data("{\"host\":{\"col\":2,\"row\":1},\"valid\":{\"col\":3,\"row\":1},\"bad\":{\"col\":null,\"row\":0},\"boolean\":{\"col\":true,\"row\":0}}".utf8).write(to:layoutURL)
    let repaired = DeskflowService.loadLayout(layoutURL, deviceName:"host")
    try check(repaired.count == 2 && repaired["valid"] != nil, "Malformed legacy cells do not discard valid peers")
    let config = DeskflowService.serverConfig(layout)
    try check(config.contains("right = client") && config.contains("left = host"), "Adjacent devices have reciprocal Deskflow links")
    var full: [String:DeskflowPosition] = [:]
    for index in 0..<15 { full["device\(index)"] = DeskflowPosition(col:index % 5,row:index / 5) }
    try check(DeskflowService.freePosition(full, host:"device7") == nil, "A full 5 by 3 grid refuses another client")
    try check(DeskflowService.freePosition(["host":DeskflowPosition(col:2,row:1)],host:"host") == DeskflowPosition(col:2,row:0), "Unknown clients receive the closest deterministic empty cell")

    service.role = "host"
    service.layout = ["host":DeskflowPosition(col:2,row:1),"client":DeskflowPosition(col:3,row:1)]
    try check(!service.setLayout(name:"host",col:3,row:1), "Occupied target is rejected")
    try check(!service.setLayout(name:"host",col:-1,row:1), "Out-of-range target is rejected")
    try check(!service.setLayout(name:"missing",col:0,row:0), "Unknown device cannot be moved")
    try check(!files.fileExists(atPath: untouched.path), "Rejected layout moves have no persistence side effects")
    let oldSession = service.sessions.begin()
    let currentSession = service.sessions.begin()
    service.handleLine("\"old-peer\" has connected",session:oldSession)
    try check(service.peer == nil, "Output from a replaced process session cannot update the peer")
    service.handleLine("\"current-peer\" has connected",session:currentSession)
    try check(service.peer == "current-peer", "Active process output updates the peer")
    service.stop()
    service.handleLine("\"late-peer\" has connected",session:currentSession)
    try check(service.peer == nil && service.role == "idle", "A stopped process cannot restore connection state")

    service.role = "host"; service.peer = "shutdown-peer"
    let exitingSession = service.sessions.begin()
    service.shutdown()
    service.handleLine("\"late-shutdown-peer\" has connected",session:exitingSession)
    try check(service.role == "idle" && service.peer == nil && !service.sessions.accepts(exitingSession), "Shutdown invalidates pending process output before exit")

    // 仅启动测试创建的 sleep 子进程；忽略 TERM 的状态由 shell 在 exec 前设置。
    var fixtureProcesses: [Process] = []
    defer {
        for child in fixtureProcesses where child.isRunning { _ = Darwin.kill(child.processIdentifier,SIGKILL) }
    }
    func fixture(ignoresTERM: Bool) throws -> Process {
        let child = Process()
        child.standardInput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        if ignoresTERM {
            let output = Pipe()
            child.executableURL = URL(fileURLWithPath:"/bin/sh")
            child.arguments = ["-c", "trap '' TERM; printf ready; exec /bin/sleep 60"]
            child.standardOutput = output
            try child.run(); fixtureProcesses.append(child)
            let ready = try output.fileHandleForReading.read(upToCount:5)
            try check(ready == Data("ready".utf8), "TERM-ignoring fixture is initialized before shutdown")
        } else {
            child.executableURL = URL(fileURLWithPath:"/bin/sleep")
            child.arguments = ["60"]; child.standardOutput = FileHandle.nullDevice
            try child.run(); fixtureProcesses.append(child)
        }
        return child
    }
    let activeCore = try fixture(ignoresTERM:true), retiringCore = try fixture(ignoresTERM:true)
    let unrelated = try fixture(ignoresTERM:false)
    let shutdownStart = ProcessInfo.processInfo.systemUptime
    DeskflowService.terminateForShutdown([activeCore,retiringCore,activeCore])
    let shutdownElapsed = ProcessInfo.processInfo.systemUptime - shutdownStart
    try check(!activeCore.isRunning && !retiringCore.isRunning, "Exit synchronously ends active and retiring TERM-ignoring children")
    try check(activeCore.terminationReason == .uncaughtSignal && activeCore.terminationStatus == SIGKILL && retiringCore.terminationStatus == SIGKILL, "Unresponsive owned children receive SIGKILL during exit")
    try check(shutdownElapsed < 1, "Shutdown cleanup remains bounded instead of waiting five seconds")
    try check(unrelated.isRunning, "Cleanup never signals a process outside the provided owned handles")
    DeskflowService.terminateForShutdown([activeCore,retiringCore])
    try check(unrelated.isRunning, "Repeated shutdown does not signal exited child identifiers")
    DeskflowService.terminateForShutdown([unrelated])
    try check(!unrelated.isRunning && unrelated.terminationStatus == SIGTERM, "Cooperative children still exit gracefully")

    let identityDirectory = temporary.appendingPathComponent("deskflow")
    let identity = try DeskflowService.ensureIdentity(in:identityDirectory)
    let before = try Data(contentsOf:identity.url)
    let second = try DeskflowService.ensureIdentity(in:identityDirectory)
    let after = try Data(contentsOf:second.url)
    try check(identity.fingerprint == second.fingerprint && before == after, "Existing TLS certificate and private key are reused unchanged")
    let verified = try DeskflowService.systemCommand("/usr/bin/openssl",["verify","-CAfile",identity.url.path,identity.url.path])
    try check(String(decoding:verified,as:UTF8.self).contains("OK"), "New self-signed certificate passes OpenSSL verification")
    let attributes = try files.attributesOfItem(atPath:identity.url.path)
    try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Combined TLS identity remains private")
    try check(identity.fingerprint.split(separator:":").count == 32, "Fingerprint is the complete 32-byte SHA-256 digest")
    let certificateDER = try DeskflowService.systemCommand("/usr/bin/openssl",["x509","-in",identity.url.path,"-outform","DER"])
    let expectedFingerprint = SHA256.hash(data:certificateDER).map { String(format:"%02X",$0) }.joined(separator:":")
    try check(identity.fingerprint == expectedFingerprint, "Native fingerprint matches the legacy certificate DER digest")

    let macOS13 = OperatingSystemVersion(majorVersion:13,minorVersion:6,patchVersion:0)
    do { try DeskflowService.checkMinimumSystemVersion("14.0",current:macOS13); throw DeskflowFailure(message:"Unsupported macOS was accepted") }
    catch let failure as DeskflowFailure { try check(failure.message.contains("macOS 14.0") && failure.message.contains("升级"), "macOS 13 receives an actionable error for the macOS 14 runtime") }
    try DeskflowService.checkMinimumSystemVersion("13.6",current:macOS13)
    try DeskflowService.checkMinimumSystemVersion("13.6.0",current:macOS13)
    try DeskflowService.checkMinimumSystemVersion("9.10",current:OperatingSystemVersion(majorVersion:10,minorVersion:0,patchVersion:0))
    do { try DeskflowService.checkMinimumSystemVersion("13.10",current:macOS13); throw DeskflowFailure(message:"A newer numeric minor version was accepted") }
    catch let failure as DeskflowFailure { try check(failure.message.contains("macOS 13.10"), "Minor versions compare numerically rather than lexically") }
    do { try DeskflowService.checkMinimumSystemVersion("13.6.1",current:macOS13); throw DeskflowFailure(message:"A newer patch version was accepted") }
    catch let failure as DeskflowFailure { try check(failure.message.contains("macOS 13.6.1"), "Patch requirements are enforced") }
    for malformed in ["", "14..0", "14.0.0.1", "-14.0", "14.x", "999999999999999999999999"] {
        do { try DeskflowService.checkMinimumSystemVersion(malformed,current:macOS13); throw DeskflowFailure(message:"Malformed OS minimum was accepted") }
        catch let failure as DeskflowFailure { try check(failure.message.contains("无效"), "Malformed minimum OS metadata cannot be imported") }
    }

    let bundle = temporary.appendingPathComponent("DeskflowRuntime.bundle",isDirectory:true)
    let bin = bundle.appendingPathComponent("Contents/MacOS/deskflow-core")
    try files.createDirectory(at:bin.deletingLastPathComponent(),withIntermediateDirectories:true)
    let info: [String:Any] = ["CFBundleIdentifier":"com.openclaw.kakitools.deskflow-runtime","CFBundlePackageType":"BNDL","CFBundleExecutable":"deskflow-core","LSMinimumSystemVersion":"13.0"]
    try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:bundle.appendingPathComponent("Contents/Info.plist"))
    #if arch(arm64)
    let architecture: [UInt8] = [0x0c,0,0,1]
    #else
    let architecture: [UInt8] = [7,0,0,1]
    #endif
    let header = Data([0xcf,0xfa,0xed,0xfe] + architecture + Array(repeating:0,count:24))
    try header.write(to:bin)
    try files.setAttributes([.posixPermissions:0o755],ofItemAtPath:bin.path)
    try DeskflowService.checkComponentMetadata(bundle)
    try check(DeskflowService.supportsCurrentArchitecture(header), "Component architecture matches the current Mac")
    try check(!DeskflowService.supportsCurrentArchitecture(Data([0,1,2,3])), "Malformed architecture cannot be imported")
    let importing = DeskflowService(userData:temporary.appendingPathComponent("component-user"))
    do { try importing.importComponent(from:bundle); throw DeskflowFailure(message:"Unsigned component was accepted") }
    catch let failure as DeskflowFailure { try check(failure.message.contains("签名"), "An unsigned component cannot be imported or executed") }
    try check(!files.fileExists(atPath:importing.userData.appendingPathComponent("Components").path), "Rejected import leaves the component directory untouched")

    var futureInfo = info
    futureInfo["LSMinimumSystemVersion"] = "999.0"
    try PropertyListSerialization.data(fromPropertyList:futureInfo,format:.xml,options:0).write(to:bundle.appendingPathComponent("Contents/Info.plist"))
    do { try importing.importComponent(from:bundle); throw DeskflowFailure(message:"A future OS component was imported") }
    catch let failure as DeskflowFailure { try check(failure.message.contains("macOS 999.0"), "OS compatibility is checked before component import or signing") }
    try check(!files.fileExists(atPath:importing.userData.appendingPathComponent("Components").path), "Unsupported imports have no staging or installation side effects")
    let incompatibleData = temporary.appendingPathComponent("incompatible-user")
    let incompatibleBundle = incompatibleData.appendingPathComponent("Components/DeskflowRuntime.bundle")
    try files.createDirectory(at:incompatibleBundle.deletingLastPathComponent(),withIntermediateDirectories:true)
    try files.copyItem(at:bundle,to:incompatibleBundle)
    let incompatibleService = DeskflowService(userData:incompatibleData)
    try check(!incompatibleService.componentAvailable && incompatibleService.error?.contains("macOS 999.0") == true, "An installed but incompatible component shows its system requirement")
    incompatibleService.startHost()
    try check(incompatibleService.role == "idle" && !files.fileExists(atPath:incompatibleData.appendingPathComponent("deskflow").path), "Incompatible host startup cannot create TLS or launch a process")
    incompatibleService.connect(host:"127.0.0.1",fingerprint:hex)
    try check(incompatibleService.role == "idle" && !files.fileExists(atPath:incompatibleData.appendingPathComponent("deskflow").path), "Incompatible client startup cannot create TLS or launch a process")
    try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:bundle.appendingPathComponent("Contents/Info.plist"))

    // 只导入并验签合成组件，不启动其中的测试主程序。
    let testExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    try files.removeItem(at: bin)
    try files.copyItem(at: testExecutable, to: bin)
    var signedInfo = info
    signedInfo["CFBundleVersion"] = "1"
    try PropertyListSerialization.data(fromPropertyList:signedInfo,format:.xml,options:0).write(to:bundle.appendingPathComponent("Contents/Info.plist"))
    _ = try DeskflowService.systemCommand("/usr/bin/codesign",["--force","--deep","--sign","-",bundle.path])
    try importing.importComponent(from:bundle)
    let components = importing.userData.appendingPathComponent("Components")
    let installed = components.appendingPathComponent("DeskflowRuntime.bundle")
    try check(importing.componentAvailable, "A verified native component can be imported")
    try DeskflowService.verifyComponent(installed)
    signedInfo["CFBundleVersion"] = "2"
    try PropertyListSerialization.data(fromPropertyList:signedInfo,format:.xml,options:0).write(to:bundle.appendingPathComponent("Contents/Info.plist"))
    _ = try DeskflowService.systemCommand("/usr/bin/codesign",["--force","--deep","--sign","-",bundle.path])
    try importing.importComponent(from:bundle)
    try DeskflowService.verifyComponent(installed)
    let saved = try files.contentsOfDirectory(at:components,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasPrefix("DeskflowRuntime-") }
    try check(saved.count == 1, "Atomic component replacement retains one uniquely named previous component")
    let installedInfo = NSDictionary(contentsOf:installed.appendingPathComponent("Contents/Info.plist"))
    let previousInfo = NSDictionary(contentsOf:saved[0].appendingPathComponent("Contents/Info.plist"))
    try check(installedInfo?["CFBundleVersion"] as? String == "2" && previousInfo?["CFBundleVersion"] as? String == "1", "New and backed-up component contents stay independent")
    let remaining = try files.contentsOfDirectory(atPath:components.path)
    try check(!remaining.contains(where:{$0.hasPrefix(".stage-")}), "Component staging directories are released after import")

}
