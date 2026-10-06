import Foundation
import AppKit

@MainActor func runHistoryAsyncTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-history-async-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = HistoryStore(directory: root)
    initial.addText("preserved history"); initial.flush()
    let restored = HistoryStore(directory: root, deferredLoading: true)
    try check(restored.loading, "deferred startup returns before history loading completes")
    restored.addText("must not overwrite while loading"); restored.flush()
    await restored.waitUntilLoaded()
    try check(!restored.loading && restored.items.count == 1 && restored.items[0].text == "preserved history", "asynchronous load preserves the previous snapshot and blocks premature writes")
    try check(restored.contentBytes == Int64("preserved history".utf8.count), "background startup computes content capacity without trimming saved records")
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<8 { for x in 0..<8 { image.setColor(NSColor(deviceRed: 1, green: 0.4, blue: 0, alpha: 1), atX: x, y: y) } }
    let png = image.representation(using: .png, properties: [:])!
    try check(restored.captureImage(data: png), "async board fixture accepts a real image")
    restored.flush()
    let source = restored.items.first(where: { $0.type == "image" })!, board = restored.createBoard("async board")!
    await restored.addToBoardInBackground(id: source.id, board: board)
    let clone = restored.items.first(where: { $0.board == board })!
    try check(clone.file != source.file, "background board copy keeps an independent image payload")
    restored.remove(id: source.id); restored.flush()
    let copied = try Data(contentsOf: URL(fileURLWithPath: clone.file!))
    try check(copied == png, "removing the source never removes the completed background board copy")
    await restored.addToBoardInBackground(id: clone.id, board: board)
    try check(restored.items.filter { $0.board == board }.count == 1, "background board copy does not create duplicate entries")
    let failedRoot = root.appendingPathComponent("failed")
    try FileManager.default.createDirectory(at: failedRoot, withIntermediateDirectories: true)
    let corrupt = Data("unreadable snapshot".utf8)
    try corrupt.write(to: failedRoot.appendingPathComponent("history.json"))
    let failed = HistoryStore(directory: failedRoot, deferredLoading: true)
    await failed.waitUntilLoaded(); failed.addText("must not replace corruption"); failed.flush()
    let preserved = try Data(contentsOf: failedRoot.appendingPathComponent("history.json"))
    try check(failed.isReadOnly && !failed.loading && preserved == corrupt, "failed deferred loading unblocks waiters and preserves the original file")
    let oversizedMetadataRoot = root.appendingPathComponent("oversized-metadata")
    try FileManager.default.createDirectory(at: oversizedMetadataRoot, withIntermediateDirectories: true)
    let records: [[String: Any]] = (0..<2).map { ["id": "metadata-\($0)", "type": "image", "bytes": Int.max] }
    try JSONSerialization.data(withJSONObject: ["items": records, "boards": []]).write(to: oversizedMetadataRoot.appendingPathComponent("history.json"))
    let largeMetadata = HistoryStore(directory: oversizedMetadataRoot, deferredLoading: true)
    await largeMetadata.waitUntilLoaded()
    try check(!largeMetadata.isReadOnly && largeMetadata.contentBytes >= 0, "oversized legacy byte metadata cannot overflow capacity statistics")
    let controller = AppController(directory: root.appendingPathComponent("controller"), testMode: true)
    try check(controller.store.captureImage(data: png), "asynchronous clipboard image fixture")
    controller.store.flush(); controller.resolveCurrentItems()
    let id = controller.store.items[0].id
    controller.activate(id, copyOnly: true)
    for _ in 0..<100 {
        if controller.clipboard.changeCount > 0 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try check(controller.clipboard.changeCount > 0, "image activation completes through the private pasteboard after background reading")
    let before = controller.clipboard.changeCount
    controller.activate(id, copyOnly: true); controller.cancelPendingClipboardActions()
    try await Task.sleep(nanoseconds: 80_000_000)
    try check(controller.clipboard.changeCount == before, "cancelled background activation never writes stale image data")
    controller.shutdown()
}
