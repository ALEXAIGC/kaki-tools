import Foundation
import ImageIO

@MainActor private func waitForScreenCapture(_ description: String,
    condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !condition() {
        if ProcessInfo.processInfo.systemUptime >= deadline { throw NativeTestFailure(description: description) }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private func screenCaptureTestPNG() throws -> Data {
    guard let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
        bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}

@MainActor func runScreenCaptureTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-screen-capture-test-" + UUID().uuidString)
    let captures = root.appendingPathComponent("captures")
    try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = root.appendingPathComponent("black.png")
    let png = try screenCaptureTestPNG()
    try png.write(to: fixture)

    func directoriesAreEmpty() -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: captures.path).isEmpty) == true
    }
    func runner(_ script: String) -> SystemScreenCaptureRunner {
        SystemScreenCaptureRunner(executable: URL(fileURLWithPath: "/bin/sh"), temporaryRoot: captures,
            argumentsBuilder: { ["-c", script, "kaki-screen-capture-test", $0.path, fixture.path] })
    }
    func run(_ script: String) async throws -> ScreenCaptureResult {
        let capture = runner(script)
        var result: ScreenCaptureResult?
        var callbacks = 0
        var callbackOnMain = false
        capture.capture { value in
            callbackOnMain = Thread.isMainThread
            result = value; callbacks += 1
        }
        try await waitForScreenCapture("Synthetic capture did not complete") { result != nil }
        try check(callbacks == 1 && callbackOnMain, "capture completes once on the main actor")
        try check(directoriesAreEmpty(), "completed capture removes its private files before delivery")
        return result!
    }

    if case .captured(let data) = try await run("cp \"$2\" \"$1\"") {
        try check(data == png, "capture returns the complete original PNG, including valid black content")
    } else { throw NativeTestFailure(description: "Valid synthetic black screenshot was rejected") }
    if case .captured(let data) = try await run("cp \"$2\" \"$1\"; printf 'screen capture permission denied: unrelated warning\\n' >&2") {
        try check(data == png, "successful capture remains authoritative over an unrelated diagnostic")
    } else { throw NativeTestFailure(description: "A successful capture was overridden by a diagnostic") }

    if case .cancelled = try await run("exit 0") {
        try check(true, "no file with a clean exit is a normal interactive cancellation")
    } else { throw NativeTestFailure(description: "Clean cancellation was reported as a failure") }
    if case .cancelled = try await run("exit 1") {
        try check(true, "exit one without a file or diagnostic can represent Esc")
    } else { throw NativeTestFailure(description: "Esc-like cancellation was reported as a failure") }

    if case .failed(let failure) = try await run("printf 'screen capture permission denied\\n' >&2; exit 1") {
        try check(failure.isPermissionDenied && failure.exitStatus == 1, "explicit screen permission denial is classified")
    } else { throw NativeTestFailure(description: "Explicit permission denial was ignored") }
    if case .failed(let failure) = try await run("printf 'could not create image from display\\n' >&2; exit 1") {
        try check(!failure.isPermissionDenied && failure.reason == .commandFailed,
            "generic display failures do not imply a permission denial")
    } else { throw NativeTestFailure(description: "Generic display failure was ignored") }
    if case .failed(let failure) = try await run("printf 'Operation not permitted\\n' >&2; exit 1") {
        try check(!failure.isPermissionDenied, "generic operation permission errors are not screen authorization failures")
    } else { throw NativeTestFailure(description: "Generic operation failure was ignored") }
    if case .failed(let failure) = try await run("cp \"$2\" \"$1\"; exit 1") {
        try check(failure.reason == .commandFailed && !failure.isPermissionDenied,
            "nonzero exit rejects even an otherwise valid output PNG")
    } else { throw NativeTestFailure(description: "A failed command delivered its output image") }
    if case .failed(let failure) = try await run("exit 2") {
        try check(failure.reason == .commandFailed, "unexpected exit codes are not normal cancellation")
    } else { throw NativeTestFailure(description: "Unexpected exit code was accepted") }
    if case .failed(let failure) = try await run("printf 'display unavailable\\n' >&2") {
        try check(failure.reason == .missingImage && !failure.isPermissionDenied,
            "missing output with diagnostics is a failure")
    } else { throw NativeTestFailure(description: "Missing PNG with a diagnostic was ignored") }
    for script in [": > \"$1\"", "printf 'invalid PNG' > \"$1\"", "head -c 24 \"$2\" > \"$1\""] {
        if case .failed(let failure) = try await run(script) {
            try check(failure.reason == .invalidImage, "empty, malformed, or truncated PNG output is rejected")
        } else { throw NativeTestFailure(description: "Invalid PNG was accepted or treated as a cancellation") }
    }
    if case .failed(let failure) = try await run("mkdir \"$1\"") {
        try check(failure.reason == .unreadableImage, "unreadable output reports an IO failure")
        try check(!failure.diagnostic.contains(captures.path), "IO failure diagnostics hide temporary paths")
    } else { throw NativeTestFailure(description: "Unreadable output was ignored") }

    let flood = "i=0; while [ \"$i\" -lt 1500 ]; do printf 'diagnostic %s 012345678901234567890123456789\\n' \"$1\" >&2; i=$((i + 1)); done; exit 2"
    if case .failed(let failure) = try await run(flood) {
        try check(failure.diagnostic.utf8.count <= 4096, "large child diagnostics stay bounded without a pipe deadlock")
        try check(!failure.diagnostic.contains(captures.path) && failure.diagnostic.contains("<temporary>"),
            "command diagnostics redact the private capture path")
    } else { throw NativeTestFailure(description: "Large diagnostic failure was ignored") }
    if case .failed(let failure) = try await run("i=0; while [ \"$i\" -lt 1800 ]; do printf '错误' >&2; i=$((i + 1)); done; exit 2") {
        try check(failure.diagnostic.utf8.count <= 4096, "multibyte diagnostics stay within the same byte limit")
    } else { throw NativeTestFailure(description: "Multibyte diagnostic failure was ignored") }

    let missingExecutable = SystemScreenCaptureRunner(executable: root.appendingPathComponent("nonexistent"), temporaryRoot: captures)
    var launchResult: ScreenCaptureResult?
    missingExecutable.capture { launchResult = $0 }
    if case .failed(let failure)? = launchResult {
        try check(failure.reason == .launch && failure.exitStatus == nil, "process launch failures report separately")
        try check(directoriesAreEmpty(), "launch failure removes its temporary files")
    } else { throw NativeTestFailure(description: "Missing executable was not a launch failure") }

    // Keep the child in a shell builtin so terminate cannot leave a helper process.
    let cancellable = runner("while :; do :; done")
    var cancelledCallbacks = 0
    cancellable.capture { _ in cancelledCallbacks += 1 }
    let directories = try FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil)
    try check(directories.count == 1, "interactive capture uses a dedicated temporary directory")
    let permissions = try FileManager.default.attributesOfItem(atPath: directories[0].path)[.posixPermissions] as? NSNumber
    try check(permissions?.intValue == 0o700, "capture temporary directory is accessible only to the current user")
    let errorPermissions = try FileManager.default.attributesOfItem(atPath: directories[0].appendingPathComponent("diagnostic.txt").path)[.posixPermissions] as? NSNumber
    try check(errorPermissions?.intValue == 0o600, "capture diagnostics are private")
    cancellable.capture { _ in cancelledCallbacks += 100 }
    let duplicateDirectories = try FileManager.default.contentsOfDirectory(atPath: captures.path)
    try check(duplicateDirectories.count == 1,
        "a duplicate capture does not start another child or create files")
    cancellable.cancel()
    try await waitForScreenCapture("Cancelled capture left temporary files") { directoriesAreEmpty() }
    try await Task.sleep(nanoseconds: 30_000_000)
    try check(cancelledCallbacks == 0, "cancel invalidates pending data and completion delivery")

    // A new operation may start while termination cleanup for the old one runs.
    var starts = 0
    let restartable = SystemScreenCaptureRunner(executable: URL(fileURLWithPath: "/bin/sh"), temporaryRoot: captures,
        argumentsBuilder: { file in
            starts += 1
            return ["-c", starts == 1 ? "while :; do :; done" : "cp \"$2\" \"$1\"",
                "kaki-screen-capture-test", file.path, fixture.path]
        })
    var previousCallbacks = 0
    var restartedResult: ScreenCaptureResult?
    restartable.capture { _ in previousCallbacks += 1 }
    restartable.cancel()
    restartable.capture { restartedResult = $0 }
    try await waitForScreenCapture("Capture did not restart after cancellation") { restartedResult != nil && directoriesAreEmpty() }
    if case .captured(let data)? = restartedResult {
        try check(data == png && previousCallbacks == 0, "late cancelled callbacks cannot replace a new capture")
    } else { throw NativeTestFailure(description: "Restarted capture did not return its original image") }
    print("Screen capture tests passed (synthetic child processes, no screen access or authorization changes)")
}
