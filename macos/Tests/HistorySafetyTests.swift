import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

private func historySafetyDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-history-safety-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
private func historySafetyPNG(width: Int) throws -> Data {
    let pixels = Data(repeating: 180, count: width * 4)
    let image = CGImage(width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: CGDataProvider(data: pixels as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    try check(CGImageDestinationFinalize(destination), "controlled history PNG fixture encodes")
    return output as Data
}
@MainActor func runHistoryImageSafetyTests() async throws {
    try await runHistoryImageLifetimeTests()
    try runHistoryImageDeletionTests()
}

final class HistoryImageTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var began = false
    let resume = DispatchSemaphore(value: 0)
    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return began }
    func process(_ data: Data) throws -> Data {
        lock.lock(); calls += 1
        let first = calls == 1
        if first { began = true }
        lock.unlock()
        if first { resume.wait() }
        return try ImageCodec.png(data)
    }
}

@MainActor private func runHistoryImageLifetimeTests() async throws {
    let manager = FileManager.default
    let directory = try historySafetyDirectory()
    defer { try? manager.removeItem(at: directory) }
    let png = try historySafetyPNG(width: 12)
    let size = try ImageCodec.dimensions(png)
    let reservation = max(png.count, size.width * size.height * 8)
    let gate = HistoryImageTestGate()
    defer { gate.resume.signal() }
    let store = HistoryStore(directory: directory, imageBudget: reservation * 2,
                             imageProcessor: { try gate.process($0) })
    let startRevision = store.revision
    try check(store.captureImage(data: png), "controlled running image admitted")
    let running = store.items[0]
    for _ in 0..<200 {
        if gate.hasStarted { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    try check(gate.hasStarted, "image decoder runs behind the controlled worker seam")
    try check(store.revision > startRevision, "image insert advances the synchronous history revision")
    let insertedRevision = store.revision
    store.remove(id: running.id)
    try check(store.revision > insertedRevision && !store.isPending(id: running.id), "remove advances revision and hides canceled item immediately")
    try check(store.pendingImageBytes == reservation, "canceled running decoder remains charged while it owns its input")
    try check(store.captureImage(data: png), "one queued capture fits beside the canceled running reservation")
    let queued = store.items[0]
    try check(!store.captureImage(data: png), "running canceled plus queued image cannot exceed the memory budget")
    store.remove(id: queued.id)
    try check(store.pendingImageBytes == reservation, "queued cancellation promptly releases only its unstarted reservation")
    try check(store.captureImage(data: png), "released queued reservation admits its replacement")
    gate.resume.signal()
    store.flush()
    try check(store.pendingImageBytes == 0 && store.items.count == 1, "drained worker returns every reservation exactly once and publishes only the replacement")
    try check(!manager.fileExists(atPath: running.file! + ".pending") && !manager.fileExists(atPath: queued.file! + ".pending"), "canceled running and queued temporary payloads are discarded")
    try await Task.sleep(nanoseconds: 20_000_000)
    try check(store.pendingImageBytes == 0 && store.items.count == 1, "late callbacks cannot return the budget twice or resurrect canceled captures")
    let beforeBoard = store.revision
    _ = store.createBoard("revision")
    try check(store.revision > beforeBoard, "board mutations also advance the synchronous history revision")
    let beforeText = store.revision
    store.addText("revision text")
    try check(store.revision > beforeText, "text mutation advances the synchronous history revision")
    let unchanged = store.revision
    store.addText("revision text")
    try check(store.revision == unchanged, "identical head recopy does not invalidate resolved search results")
    store.flush()
}

@MainActor private func runHistoryImageDeletionTests() throws {
    let manager = FileManager.default
    let directory = try historySafetyDirectory()
    defer { try? manager.removeItem(at: directory) }
    let store = HistoryStore(directory: directory)
    let png = try historySafetyPNG(width: 14)
    try check(store.captureImage(data: png), "index-first deletion image fixture admitted")
    store.flush()
    let item = store.items[0], index = directory.appendingPathComponent("history.json")
    let original = try Data(contentsOf: index)
    let payload = URL(fileURLWithPath: item.file!)
    try Data("preview".utf8).write(to: URL(fileURLWithPath: payload.path + ".thumb"))
    store.remove(id: item.id)
    try check(manager.fileExists(atPath: payload.path), "deletion retains payload until the index commit barrier")
    let crashReload = HistoryStore(directory: directory)
    try check(crashReload.items.contains { $0.id == item.id } && manager.fileExists(atPath: crashReload.items[0].file!), "restart before commit restores an intact image from the previous index")
    let backup = directory.appendingPathComponent("history.backup.json")
    try original.write(to: backup)
    try manager.removeItem(at: index)
    try manager.createDirectory(at: index, withIntermediateDirectories: false)
    store.flush()
    try check(store.lastError != nil && manager.fileExists(atPath: payload.path), "failed atomic index write leaves removed image payload available to recovery")
    let preservedBackup = try Data(contentsOf: backup)
    try check(preservedBackup == original, "failed index write never mutates the recovery backup")
    try manager.removeItem(at: index)
    let failedReload = HistoryStore(directory: directory)
    try check(!failedReload.isReadOnly && failedReload.items.first?.id == item.id &&
              manager.fileExists(atPath: failedReload.items.first!.file!), "backup recovery after a failed deletion commit still resolves the original image")
    try original.write(to: index)
    store.flush()
    let primary = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! [String: Any]
    try check((primary["items"] as? [[String: Any]])?.isEmpty == true && manager.fileExists(atPath: payload.path), "committed deletion retains files referenced by a valid backup")
    try Data("unreadable backup".utf8).write(to: backup)
    store.flush()
    try check(manager.fileExists(atPath: payload.path), "unreadable existing backup conservatively postpones reclamation")
    try manager.removeItem(at: backup)
    store.addText("cleanup trigger"); store.flush()
    try check(!manager.fileExists(atPath: payload.path) && !manager.fileExists(atPath: payload.path + ".thumb"), "unreferenced payload and sidecar are reclaimed only after a successful index commit")
    let importedImage = try Data(contentsOf: directory.appendingPathComponent("native-import-backup/images/" + payload.lastPathComponent))
    try check(importedImage == png, "independent one-time import backup image is preserved")

    let orphanDirectory = try historySafetyDirectory()
    defer { try? manager.removeItem(at: orphanDirectory) }
    let images = orphanDirectory.appendingPathComponent("images", isDirectory: true)
    try manager.createDirectory(at: images, withIntermediateDirectories: true)
    let orphan = images.appendingPathComponent(UUID().uuidString.lowercased() + ".png")
    let unrelated = images.appendingPathComponent("unrelated-legacy.png")
    try png.write(to: orphan); try png.write(to: unrelated)
    try JSONSerialization.data(withJSONObject: ["items": [], "boards": []]).write(to: orphanDirectory.appendingPathComponent("history.json"))
    let restarted = HistoryStore(directory: orphanDirectory)
    try check(manager.fileExists(atPath: orphan.path), "startup orphan cleanup also waits for a validated index commit")
    restarted.flush()
    try check(!manager.fileExists(atPath: orphan.path) && manager.fileExists(atPath: unrelated.path), "post-commit crash orphan recovery only reclaims managed image filenames")
}
