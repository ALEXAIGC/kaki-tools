import Foundation
import AppKit
import SwiftUI

private actor ModernLoginRunner:DreaminaRunning {
    var done=false
    var networkError=false
    var pendingCalls=0
    func configure(done:Bool=false,network:Bool=false) {self.done=done;networkError=network}
    func calls()->Int {pendingCalls}
    func run(_ arguments:[String],timeout:TimeInterval) async throws -> DreaminaOutput {
        if arguments == ["user_credit"] {
            if networkError {throw DreaminaError.timedOut}
            return DreaminaOutput(status:done ? 0 : 1,data:Data((done ? "{\"total_credit\":42,\"user_id\":\"fixture-account\"}" : "未检测到有效登录态，请先执行 dreamina login").utf8))
        }
        if arguments == ["login","--help"] {return DreaminaOutput(status:0,data:Data("--headless".utf8))}
        if arguments == ["login","--headless"] {return DreaminaOutput(status:0,data:Data("verification_uri: https://jimeng.jianying.com/ai-tool/cli-auth\nuser_code: TEST-1234\ndevice_code: synthetic-device-session\n".utf8))}
        guard arguments == ["login","checklogin","--device_code","synthetic-device-session","--poll","0"] else {throw DreaminaError.invalidResponse}
        pendingCalls += 1
        return DreaminaOutput(status:done ? 0 : 1,data:Data((done ? "授权成功" : "登录尚未完成，请稍后重试或增加 --poll").utf8))
    }
}
private actor ModernInspection {
    var calls=0
    var hang=false
    func configure(hang:Bool){self.hang=hang}
    func count()->Int {calls}
    func inspect(_ url:URL) async throws -> ClassicCliInstallation {
        calls += 1
        if hang {try await Task.sleep(nanoseconds:5_000_000_000)}
        return ClassicCliInstallation(executable:url,version:"{\"version\":\"1d0bd17-dirty\"}",sha256:String(repeating:"a",count:64))
    }
}
private struct BrokenInspectionRunner:DreaminaRunning {
    let failure:Int
    func run(_ arguments:[String],timeout:TimeInterval) async throws -> DreaminaOutput {
        if arguments == ["--version"] {return DreaminaOutput(status:0,data:Data("fixture".utf8))}
        switch failure {
        case 0:throw DreaminaError.timedOut
        case 1:throw CancellationError()
        default:throw DreaminaError.failed("synthetic process error")
        }
    }
}
@MainActor private func until(_ condition:()->Bool,line:UInt = #line) async throws {
    for _ in 0..<150 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
    throw NativeTestFailure(description:"modern CLI operation did not settle at line \(line) within test bound")
}
@MainActor func runClassicModernTests() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("classic-modern-" + UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:root)}
    let runner=ModernLoginRunner(), inspector=ModernInspection(), binary=root.appendingPathComponent("dreamina")
    // Inspect must propagate command errors; only a mismatched help contract requests upgrade.
    for failure in 0..<3 {
        do {_ = try await ClassicCliInstaller.inspect(binary,runner:BrokenInspectionRunner(failure:failure));throw NativeTestFailure(description:"inspection failure expected")}
        catch DreaminaError.timedOut {try check(failure == 0,"command timeout remains a timeout, not upgrade")}
        catch is CancellationError {try check(failure == 1,"cancelled inspection remains cancelled, not upgrade")}
        catch DreaminaError.failed {try check(failure == 2,"process failure remains process failure, not upgrade")}
    }
    let studio=StudioStore(directory:root.appendingPathComponent("studio"),credentials:StudioMemoryCredentials())
    var opens=0
    let connection=ClassicCliConnection(studio:studio,directory:root,enabled:true,locator:{binary},inspector:{try await inspector.inspect($0)},runnerFactory:{_ in runner},detectionTimeout:0.1,loginTimeout:0.25,pollInterval:20_000_000,openAuthorization:{_ in opens += 1;return true})
    await inspector.configure(hang:true)
    connection.detect();connection.detect()
    try await until {!connection.busy}
    let calls=await inspector.count()
    try check(calls == 1 && connection.status.contains("超时") && !connection.status.contains("请登录"),"one bounded detection, timeout distinct from not logged in, retry restored")
    // Identity changes invalidate an in-flight inspection and its late callback.
    connection.detect()
    try await Task.sleep(nanoseconds:20_000_000)
    connection.identityChanged()
    try await Task.sleep(nanoseconds:150_000_000)
    try check(!connection.connected && !connection.busy && connection.status.contains("重新连接"), "identity invalidation clears connection and prevents stale detection callback")
    try check(connection.targetDescription.contains("测试站 · test.kakiai.xin") && connection.targetDescription.contains("未选择工作区"), "unassociated CLI names the exact current site and workspace")
    await studio.changeEnvironment(.production)
    connection.identityChanged()
    try check(connection.targetDescription.contains("正式站 · kakiai.xin") && !connection.targetDescription.contains("test.kakiai.xin"), "production target never displays the old test origin")
    await inspector.configure(hang:false)
    connection.detect();try await until {!connection.busy}
    try check(connection.status == "已安装 · 请登录即梦","real not logged in outcome without swallowing network errors")
    await runner.configure(network:true)
    connection.detect();try await until {!connection.busy}
    try check(connection.status.contains("登录状态尚未确认"),"network error does not become a logout result")
    await runner.configure()
    try await until {!connection.busy};connection.login();try await until {!connection.authorizationUserCode.isEmpty}
    try check(connection.busy && opens == 1 && connection.authorizationURL?.host == "jimeng.jianying.com" && !connection.connected,"headless code visible while polling, URL opened once, login is not association")
    let board=NSPasteboard.withUniqueName();defer {board.releaseGlobally()}
    connection.copyAuthorizationCode(to:board)
    try check(board.string(forType:.string) == "TEST-1234" && board.types?.contains(.init("org.nspasteboard.TransientType")) == true,"user code copied as transient, excluded from clipboard history")
    if let path=ProcessInfo.processInfo.environment["KAKI_MODERN_QA_DIR"] {
        try snapshot(connection,root:URL(fileURLWithPath:path),name:"native-wait")
    }
    connection.cancelOperation()
    connection.detect();try await until {!connection.busy}
    try await Task.sleep(nanoseconds:80_000_000)
    try check(connection.authorizationUserCode.isEmpty && connection.authorizationURL == nil && connection.status == "已安装 · 请登录即梦","cancelled session cannot overwrite concurrent retry or retain codes")
    if let path=ProcessInfo.processInfo.environment["KAKI_MODERN_QA_DIR"] {try snapshot(connection,root:URL(fileURLWithPath:path),name:"native-cancel-retry")}
    try await until {!connection.busy};connection.login();try await until {!connection.authorizationUserCode.isEmpty};try await until {!connection.busy}
    try check(connection.authorizationUserCode.isEmpty && connection.authorizationURL == nil && connection.status.contains("超时"),"whole login deadline clears codes and restores retry")
    try await until {!connection.busy};connection.login();try await until {!connection.authorizationUserCode.isEmpty};await runner.configure(done:true);try await until {!connection.busy}
    try check(connection.status.contains("即梦已登录") && !connection.connected && connection.authorizationUserCode.isEmpty,"successful login stays unassociated and clears ephemeral authorization")
    let pollCalls=await runner.calls();try check(pollCalls > 0,"login used actual nested checklogin fixed argv")
    let actualShapeCode=String(repeating:"a",count:32)
    func wrapped(_ inner:String,extra:String="") -> String {
        var outer=URLComponents(string:"https://jimeng.jianying.com/ai-tool/cli-auth")!
        outer.queryItems=[URLQueryItem(name:"verification_uri",value:inner)]
        return outer.url!.absoluteString + extra
    }
    func authorizationOutput(_ uri:String,code:String=actualShapeCode) -> DreaminaOutput {
        DreaminaOutput(status:0,data:Data("verification_uri: \(uri)\nuser_code: \(code)\ndevice_code: synthetic-device-session\n".utf8))
    }
    let scan="https://jimeng.jianying.com/passport/open/scan_user_code/?user_code=" + actualShapeCode
    let actualShapeURI=wrapped(scan)
    let parsed=try ClassicCliAuthorization.parse(authorizationOutput(actualShapeURI))
    try check(parsed.url.absoluteString == actualShapeURI && parsed.userCode == actualShapeCode,"real official nested authorization shape preserves outer URL and matching 32-character code")
    for uri in [
        wrapped("https://evil.invalid/passport/open/scan_user_code/?user_code=" + actualShapeCode),
        wrapped("http://jimeng.jianying.com/passport/open/scan_user_code/?user_code=" + actualShapeCode),
        wrapped("https://jimeng.jianying.com/evil?user_code=" + actualShapeCode),
        wrapped("https://jimeng.jianying.com/passport/open/scan_user_code/?user_code=wrong"),
        actualShapeURI.replacingOccurrences(of:"/ai-tool/cli-auth?",with:"/ai-tool/cli-auth/?"),
        wrapped(scan.replacingOccurrences(of:"scan_user_code/?",with:"scan_user_code?")),
        wrapped(scan + "&user_code=" + actualShapeCode),wrapped(scan + "&other=1"),
        wrapped(scan,extra:"&verification_uri=second"),wrapped(scan,extra:"&user_code=" + actualShapeCode),
        wrapped(scan + "#fragment"),wrapped(scan,extra:"#fragment"),
        wrapped(scan.replacingOccurrences(of:"https://",with:"https://user:password@")),
        wrapped(scan.replacingOccurrences(of:".com/",with:".com:443/")),
        wrapped(scan + "&device_code=synthetic-device-session"),
        wrapped("https://jimeng.jianying.com/passport/open/scan_user_code/?user_code=synthetic-device-session"),
    ] {
        do {_ = try ClassicCliAuthorization.parse(authorizationOutput(uri));throw NativeTestFailure(description:"untrusted/mismatched nested authorization must fail")} catch DreaminaError.invalidResponse {try check(true,"nested authorization refuses foreign endpoints, credential leakage and mismatched/extra fields")}
    }
    for uri in ["http://jimeng.jianying.com/ai-tool/cli-auth","https://evil.invalid/ai-tool/cli-auth","https://jimeng.jianying.com/evil","https://jimeng.jianying.com/ai-tool/cli-auth?device_code=bad"] {
        do {_ = try ClassicCliAuthorization.parse(DreaminaOutput(status:0,data:Data("verification_uri: \(uri)\nuser_code: TEST\ndevice_code: device\n".utf8)));throw NativeTestFailure(description:"untrusted authorization URL must fail")} catch DreaminaError.invalidResponse {}
    }
    // Real process-group timeout/cancellation and oversized output, using private script fixtures.
    let hanging=root.appendingPathComponent("hang.command")
    try Data("#!/bin/sh\ntrap '' TERM\nsleep 20\n".utf8).write(to:hanging);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hanging.path)
    let start=Date()
    do {_ = try await classicCliDeadline(seconds:0.1) {try await DreaminaProcessRunner(executable:hanging).run([],timeout:10)};throw NativeTestFailure(description:"hanging command must time out")} catch DreaminaError.timedOut {}
    try check(Date().timeIntervalSince(start)<2,"global deadline cancels and reaps a real owned process group")
    let noisy=root.appendingPathComponent("output.command")
    try Data("#!/bin/sh\n/usr/bin/yes oversized\n".utf8).write(to:noisy);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:noisy.path)
    do {_ = try await DreaminaProcessRunner(executable:noisy).run([],timeout:5);throw NativeTestFailure(description:"large output must fail")} catch DreaminaError.oversized {}
    connection.shutdown()
}
@MainActor private func snapshot(_ connection:ClassicCliConnection,root:URL,name:String) throws {
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let host=NSHostingView(rootView:ClassicCliConnectionView(connection:connection).padding(20))
    host.frame=NSRect(x:0,y:0,width:900,height:330);host.layoutSubtreeIfNeeded()
    guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw DreaminaError.invalidResponse}
    host.cacheDisplay(in:host.bounds,to:bitmap)
    guard let data=bitmap.representation(using:.png,properties:[:]) else {throw DreaminaError.invalidResponse}
    try data.write(to:root.appendingPathComponent(name + ".png"))
}
