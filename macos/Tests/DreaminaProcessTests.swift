import Foundation
import Darwin

@MainActor func runDreaminaProcessLifecycleTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-cli-process-lifecycle-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("owned-fixture.py")
    try Data("""
    #!/usr/bin/python3
    import os,signal,sys,time,json
    mode=sys.argv[1]
    if mode=='normal':
        print(json.dumps({'argv':sys.argv[2:],'stdinEmpty':sys.stdin.buffer.read()==b''}))
    elif mode=='exit':
        print('exit-data',flush=True)
        sys.exit(7)
    elif mode=='exact':
        sys.stdout.buffer.write(b'x'*(2*1024*1024))
    elif mode=='flood':
        sys.stdout.buffer.write(b'x'*(2*1024*1024))
        sys.stdout.buffer.flush()
        sys.stderr.buffer.write(b'e'*(1024*1024))
        sys.stderr.buffer.flush()
        time.sleep(3)
    elif mode in ('inherited','timeout','cancel'):
        child=os.fork()
        if child==0:
            signal.signal(signal.SIGTERM,signal.SIG_IGN)
            time.sleep(3)
            os._exit(0)
        if mode!='inherited': signal.signal(signal.SIGTERM,signal.SIG_IGN)
        with open(sys.argv[2]+'.pending','w') as f:
            f.write(str(os.getpid())+' '+str(child))
        os.replace(sys.argv[2]+'.pending',sys.argv[2])
        if mode=='inherited':
            print('parent-finished',flush=True)
            os._exit(0)
        time.sleep(3)
    elif mode=='survivor':
        time.sleep(8)
    elif mode=='moved-parent':
        os.setpgid(0,os.getpgid(os.getppid()))
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        time.sleep(3)
    elif mode=='signal-defaults':
        with open(sys.argv[2]+'.pending','w') as f:
            f.write(json.dumps({'termDefault':signal.getsignal(signal.SIGTERM)==signal.SIG_DFL,
                'hupDefault':signal.getsignal(signal.SIGHUP)==signal.SIG_DFL,
                'blocked':list(signal.pthread_sigmask(signal.SIG_BLOCK,[]))}))
        os.replace(sys.argv[2]+'.pending',sys.argv[2])
        time.sleep(3)
    elif mode=='immediate':
        with open(sys.argv[2],'w') as f: f.write('unexpected-launch')
        time.sleep(3)
    """.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let runner = DreaminaProcessRunner(executable: script)
    let literal = "literal; $(touch must-not-exist)"
    let normal = try await runner.run(["normal", literal, "two words"], timeout: 2)
    let json = try JSONSerialization.jsonObject(with: normal.data) as? [String: Any]
    try check(normal.status == 0 && json?["argv"] as? [String] == [literal, "two words"] && json?["stdinEmpty"] as? Bool == true,
              "owned process preserves literal argv and null stdin")
    let failed = try await runner.run(["exit"], timeout: 2)
    try check(failed.status == 7 && String(data: failed.data, encoding: .utf8) == "exit-data\n", "CLI runner preserves nonzero status and final output")
    let exact = try await runner.run(["exact"], timeout: 2)
    try check(exact.data.count == 2 * 1024 * 1024, "CLI runner accepts output exactly at its two MiB limit")

    let inheritedMarker = directory.appendingPathComponent("inherited.pids")
    let inheritedStart = DispatchTime.now().uptimeNanoseconds
    let inherited = try await runner.run(["inherited", inheritedMarker.path], timeout: 1)
    let inheritedElapsed = Double(DispatchTime.now().uptimeNanoseconds - inheritedStart) / 1_000_000_000
    try check(inherited.status == 0 && String(data: inherited.data, encoding: .utf8) == "parent-finished\n" && inheritedElapsed < 0.8,
              "completed parent returns promptly while its descendant retains stdout")
    try await assertDreaminaFixtureProcessesExited(inheritedMarker)

    let survivor = Process()
    survivor.executableURL = script; survivor.arguments = ["survivor"]
    survivor.standardInput = FileHandle.nullDevice; survivor.standardOutput = FileHandle.nullDevice; survivor.standardError = FileHandle.nullDevice
    try survivor.run()
    defer { if survivor.isRunning { survivor.terminate() }; survivor.waitUntilExit() }
    let timeoutMarker = directory.appendingPathComponent("timeout.pids")
    let timeoutStart = DispatchTime.now().uptimeNanoseconds
    do {
        _ = try await runner.run(["timeout", timeoutMarker.path], timeout: 1)
        throw NativeTestFailure(description: "Inherited stdout ignored CLI deadline")
    } catch DreaminaError.timedOut {}
    let timeoutElapsed = Double(DispatchTime.now().uptimeNanoseconds - timeoutStart) / 1_000_000_000
    try check(timeoutElapsed < 2.3, "deadline bounds parent and descendants even when both ignore TERM")
    try await assertDreaminaFixtureProcessesExited(timeoutMarker)
    try check(survivor.isRunning, "CLI cleanup never signals a separately launched process")
    let movedStart = DispatchTime.now().uptimeNanoseconds
    do { _ = try await runner.run(["moved-parent"], timeout: 1); throw NativeTestFailure(description: "Moved parent ignored deadline") }
    catch DreaminaError.timedOut {}
    try check(Double(DispatchTime.now().uptimeNanoseconds - movedStart) / 1_000_000_000 < 2.3,
              "owned parent is stopped even if it moves into the launching app's group")
    try check(survivor.isRunning, "runner never signals the parent's new unrelated process group")

    let signalsMarker = directory.appendingPathComponent("signal-defaults.json")
    let previousTERM = signal(SIGTERM, SIG_IGN), previousHUP = signal(SIGHUP, SIG_IGN)
    let signalTask = Task { try await runner.run(["signal-defaults", signalsMarker.path], timeout: 10) }
    defer { signal(SIGTERM, previousTERM); signal(SIGHUP, previousHUP) }
    for _ in 0..<500 {
        if FileManager.default.fileExists(atPath: signalsMarker.path) { break }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    let signalInfo = try JSONSerialization.jsonObject(with: Data(contentsOf: signalsMarker)) as? [String: Any]
    try check(signalInfo?["termDefault"] as? Bool == true && signalInfo?["hupDefault"] as? Bool == true && (signalInfo?["blocked"] as? [Int])?.isEmpty == true,
              "CLI resets ignored app TERM/HUP dispositions and inherits no blocked signals")
    let signalsStart = DispatchTime.now().uptimeNanoseconds
    signalTask.cancel()
    do { _ = try await signalTask.value; throw NativeTestFailure(description: "Default-signal fixture ignored cancellation") }
    catch is CancellationError {}
    try check(Double(DispatchTime.now().uptimeNanoseconds - signalsStart) / 1_000_000_000 < 0.18,
              "default TERM cancellation finishes without waiting for the KILL grace period")
    signal(SIGTERM, previousTERM); signal(SIGHUP, previousHUP)

    let cancelMarker = directory.appendingPathComponent("cancel.pids")
    let cancelled = Task { try await runner.run(["cancel", cancelMarker.path], timeout: 10) }
    for _ in 0..<500 {
        if FileManager.default.fileExists(atPath: cancelMarker.path) { break }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    try check(FileManager.default.fileExists(atPath: cancelMarker.path), "cancel fixture reaches the inherited-pipe state")
    let cancelStart = DispatchTime.now().uptimeNanoseconds
    cancelled.cancel()
    do { _ = try await cancelled.value; throw NativeTestFailure(description: "Inherited stdout ignored cancellation") }
    catch is CancellationError {}
    let cancelElapsed = Double(DispatchTime.now().uptimeNanoseconds - cancelStart) / 1_000_000_000
    try check(cancelElapsed < 1.2, "cancellation completes promptly independently of descendant pipe EOF")
    try await assertDreaminaFixtureProcessesExited(cancelMarker)
    try check(survivor.isRunning, "cancellation remains scoped to the invocation's process group")

    let floodStart = DispatchTime.now().uptimeNanoseconds
    do { _ = try await runner.run(["flood"], timeout: 5); throw NativeTestFailure(description: "CLI flood accepted") }
    catch DreaminaError.oversized {}
    try check(Double(DispatchTime.now().uptimeNanoseconds - floodStart) / 1_000_000_000 < 1.2,
              "combined stdout/stderr over the limit aborts without waiting for a sleeping producer")
    let immediateMarker = directory.appendingPathComponent("immediate.marker")
    let invalid = directory.appendingPathComponent("invalid-executable")
    try Data("not an executable format".utf8).write(to: invalid)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: invalid.path)
    let descriptors = dreaminaOpenDescriptorCount()
    for _ in 0..<8 {
        let task = Task { try await runner.run(["immediate", immediateMarker.path], timeout: 10) }
        task.cancel()
        do { _ = try await task.value; throw NativeTestFailure(description: "Immediate cancellation ignored") }
        catch is CancellationError {}
        _ = try await runner.run(["normal"], timeout: 2)
        do { _ = try await DreaminaProcessRunner(executable: invalid).run([], timeout: 2); throw NativeTestFailure(description: "Invalid executable format accepted") }
        catch is POSIXError {}
    }
    try check(!FileManager.default.fileExists(atPath: immediateMarker.path), "immediate cancellation never launches an executable")
    try check(dreaminaOpenDescriptorCount() <= descriptors, "normal runs, immediate cancellations and failed spawns release every owned descriptor")
    print("Dreamina process lifecycle tests passed (private processes, inherited pipes, bounded cancellation)")
}

private func dreaminaOpenDescriptorCount() -> Int {
    (0..<min(getdtablesize(), 4096)).reduce(0) { $0 + (fcntl($1, F_GETFD) >= 0 ? 1 : 0) }
}
@MainActor private func assertDreaminaFixtureProcessesExited(_ marker: URL) async throws {
    let pids = try String(contentsOf: marker, encoding: .utf8).split(separator: " ").compactMap { Int32($0) }
    try check(pids.count == 2, "fixture records only its invocation parent and descendant IDs")
    for _ in 0..<200 {
        if pids.allSatisfy({ kill($0, 0) != 0 && errno == ESRCH }) { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try check(pids.allSatisfy { kill($0, 0) != 0 && errno == ESRCH }, "invocation cleanup reaps the parent and stops its inherited-pipe descendant")
}
