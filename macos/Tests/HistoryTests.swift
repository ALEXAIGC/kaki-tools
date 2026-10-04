import Foundation
import Combine
import AppKit
import ImageIO
import UniformTypeIdentifiers

private func historyTestPNG(width: Int = 2, height: Int = 1) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let pixels = [UInt8](repeating: 180, count: width * height * 4)
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    try check(CGImageDestinationFinalize(destination), "test PNG encoding")
    return data as Data
}
private func historyTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-native-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
func runHistoryTests() async throws {
    try await runHistoryPersistenceOrderingTests()
    try await runThumbnailNotificationTests()
    let manager = FileManager.default
    let directory = try historyTestDirectory()
    defer { try? manager.removeItem(at: directory) }
    let store = HistoryStore(directory: directory)
    try check(!store.isReadOnly, "new store is writable")
    store.addText("same", html: "<b>same</b>", rtf: "{\\rtf1 same}")
    let originalID = store.items[0].id
    store.addText("same")
    try check(store.items.count == 1 && store.items[0].html == nil && store.items[0].rtf == nil, "same text removes stale rich data")
    store.togglePin(id: originalID)
    let board = store.createBoard(" saved ")!
    store.addToBoard(id: originalID, board: board)
    let cloneID = store.items[0].id
    store.updateMetadata(id: cloneID, tags: [" Work ", "work", "中文"], note: " board note ")
    try check(store.items[0].tags == ["Work", "中文"] && store.items[0].note == "board note", "metadata normalization")
    for index in 0..<130 { store.addText("history-\(index)") }
    try check(store.items.filter { $0.board == nil && !$0.pinned }.count == 100, "ordinary history cap")
    try check(store.items.contains { $0.id == originalID } && store.items.contains { $0.id == cloneID }, "pins and boards excluded from cap")
    store.addText(String(repeating: "x", count: 1200) + "全文结尾")
    try check(AppController.matchingItems(store.items, query: "全文结尾", board: nil, filter: .all).count == 1 &&
              AppController.matchingItems(store.items, query: "board note", board: board, filter: .all).count == 1, "full text and notes search")
    store.renameBoard(board, to: "renamed")
    try check(store.items.first { $0.id == cloneID }?.board == "renamed", "board rename updates records")
    store.clearHistory()
    try check(store.items.count == 1 && store.items[0].id == cloneID, "clear preserves independent board record")
    store.flush()
    let reloaded = HistoryStore(directory: directory)
    try check(reloaded.items == store.items && reloaded.boards == store.boards, "JSON round trip")
    try check(manager.fileExists(atPath: directory.appendingPathComponent("native-import-backup/history.json").path), "first import backup")
    reloaded.deleteBoard("renamed"); reloaded.flush()

    let legacyDirectory = try historyTestDirectory()
    defer { try? manager.removeItem(at: legacyDirectory) }
    let legacyImages = legacyDirectory.appendingPathComponent("images", isDirectory: true)
    try manager.createDirectory(at: legacyImages, withIntermediateDirectories: true)
    let png = try historyTestPNG()
    let legacyImage = legacyImages.appendingPathComponent("legacy.png")
    try png.write(to: legacyImage)
    let legacyPreview = "data:image/png;base64," + png.base64EncodedString()
    let legacyItems: [[String: Any]] = [
        ["id": "legacy-image", "type": "image", "file": "/old/location/legacy.png", "thumb": legacyPreview,
         "createdAt": 12, "pinned": true, "hash": "legacy-sha1", "size": ["width": 2, "height": 1], "bytes": png.count],
        ["id": "legacy-text", "type": "text", "text": "legacy", "createdAt": 11],
    ]
    let legacyData = try JSONSerialization.data(withJSONObject: ["items": legacyItems, "boards": []])
    try legacyData.write(to: legacyDirectory.appendingPathComponent("history.json"))
    let legacy = HistoryStore(directory: legacyDirectory)
    try check(!legacy.isReadOnly && legacy.items.count == 2, "legacy optional defaults decode")
    try check(legacy.items[0].file == legacyImage.path, "legacy image path relocates")
    try check(legacy.thumbnail(for: legacy.items[0]) != nil, "legacy embedded data URL thumbnail")
    let backedUpPNG = try Data(contentsOf: legacyDirectory.appendingPathComponent("native-import-backup/images/legacy.png"))
    try check(backedUpPNG == png, "image import backup preserves data")
    legacy.flush()

    let corruptedDirectory = try historyTestDirectory()
    defer { try? manager.removeItem(at: corruptedDirectory) }
    let corrupted = Data("broken original".utf8)
    try corrupted.write(to: corruptedDirectory.appendingPathComponent("history.json"))
    let brokenStore = HistoryStore(directory: corruptedDirectory)
    try check(brokenStore.isReadOnly && brokenStore.lastError != nil, "unrecoverable JSON is read only")
    brokenStore.addText("must not overwrite"); brokenStore.flush()
    let preservedJSON = try Data(contentsOf: corruptedDirectory.appendingPathComponent("history.json"))
    try check(preservedJSON == corrupted, "corrupted original never overwritten")
    try legacyData.write(to: corruptedDirectory.appendingPathComponent("history.backup.json"))
    let recovered = HistoryStore(directory: corruptedDirectory)
    try check(!recovered.isReadOnly && recovered.items.count == 2, "valid backup recovery")
    let recoveryFiles = try manager.contentsOfDirectory(atPath: corruptedDirectory.path)
    try check(recoveryFiles.contains { $0.hasPrefix("history.unreadable.") }, "unreadable source preserved")
    recovered.flush()
    let missingPrimaryDirectory = try historyTestDirectory()
    defer { try? manager.removeItem(at: missingPrimaryDirectory) }
    try legacyData.write(to: missingPrimaryDirectory.appendingPathComponent("history.backup.json"))
    let missingPrimary = HistoryStore(directory: missingPrimaryDirectory)
    try check(!missingPrimary.isReadOnly && missingPrimary.items.count == 2, "missing primary recovers valid backup")
    missingPrimary.flush()

    let imageDirectory = try historyTestDirectory()
    defer { try? manager.removeItem(at: imageDirectory) }
    let images = HistoryStore(directory: imageDirectory, limit: 1)
    images.addText("old text")
    try check(images.captureImage(data: png), "capture PNG")
    let imageID = images.items[0].id
    try check(images.isPending(id: imageID) && images.item(id: imageID) == nil,
              "Pending image lookup returns immediately without draining the worker queue")
    let pendingBoard = images.createBoard("pending")!
    images.addToBoard(id: imageID, board: pendingBoard)
    try check(!images.items.contains { $0.board == pendingBoard } && images.lastError?.contains("正在处理") == true,
              "Pending image cannot create an incomplete board clone and asks for retry")
    images.deleteBoard(pendingBoard)
    images.flush()
    try check(!images.isPending(id: imageID) && images.item(id: imageID) != nil,
              "Completed image becomes available after the explicit flush barrier")
    try check(images.items.count == 1 && images.items[0].id == imageID && images.pendingImageBytes == 0, "image commits before history trimming and returns budget")
    let imageFile = images.items[0].file!
    let savedPNG = try Data(contentsOf: URL(fileURLWithPath: imageFile))
    try check(savedPNG == png, "PNG original bytes unchanged")
    let imageBoard = images.createBoard("images")!
    images.addToBoard(id: imageID, board: imageBoard)
    let boardImage = images.items[0]
    images.remove(id: imageID)
    try check(boardImage.file != imageFile && manager.fileExists(atPath: boardImage.file!), "independent image board clone")
    try check(images.captureImage(data: png), "repeat capture")
    images.flush()
    try check(images.captureImage(data: png), "duplicate capture")
    images.flush()
    try check(images.items.filter { $0.board == nil }.count == 1, "full SHA256 image dedup")
    let removeID = images.items[0].id
    let otherPNG = try historyTestPNG(width: 3)
    try check(images.captureImage(data: otherPNG), "capture to cancel")
    let cancelled = images.items[0]
    images.remove(id: cancelled.id); images.flush()
    try check(!images.items.contains { $0.id == cancelled.id } && !manager.fileExists(atPath: cancelled.file!), "late worker cannot resurrect removed capture")
    try check(images.items.contains { $0.id == removeID }, "cancel preserves prior capture")
    if images.thumbnail(for: boardImage) == nil {
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(images.thumbnail(for: boardImage) != nil, "background thumbnail delivered")
    }
    images.flush()
    let tiff = NSBitmapImageRep(data: png)!.representation(using: .tiff, properties: [:])!
    try check(images.captureImage(data: tiff), "TIFF capture admitted")
    images.flush()
    let tiffRecord = images.items.first { $0.board == nil }!
    let normalized = try Data(contentsOf: URL(fileURLWithPath: tiffRecord.file!))
    let normalizedSource = CGImageSourceCreateWithData(normalized as CFData, nil)!
    try check(CGImageSourceGetType(normalizedSource) as String? == UTType.png.identifier, "TIFF normalizes to PNG off main thread")

    let budgetDirectory = try historyTestDirectory()
    defer { try? manager.removeItem(at: budgetDirectory) }
    let budget = HistoryStore(directory: budgetDirectory, imageBudget: png.count * 2)
    try check(budget.captureImage(data: png) && budget.captureImage(data: png), "two reserved PNG captures")
    try check(!budget.captureImage(data: png), "pending lifecycle budget rejects overflow")
    let pendingID = budget.items[0].id
    budget.remove(id: pendingID)
    try check(budget.captureImage(data: png), "cancel returns queue reservation")
    budget.flush(); try check(budget.pendingImageBytes == 0, "flush returns every reservation")
    try check(!budget.captureImage(data: Data("not an image".utf8)), "invalid image rejected")
    budget.flush()

    let failedDirectory = try historyTestDirectory()
    defer { try? manager.removeItem(at: failedDirectory) }
    let failedStore = HistoryStore(directory: failedDirectory, limit: 1)
    failedStore.addText("must survive failed image")
    try manager.removeItem(at: failedDirectory.appendingPathComponent("images"))
    try Data("not a directory".utf8).write(to: failedDirectory.appendingPathComponent("images"))
    try check(failedStore.captureImage(data: png), "valid image admitted before write failure")
    failedStore.flush()
    try check(failedStore.items.count == 1 && failedStore.items[0].text == "must survive failed image", "failed image never trims old history")
    try check(failedStore.pendingImageBytes == 0, "failed write returns budget")

    let clipboardDirectory = try historyTestDirectory()
    defer { try? manager.removeItem(at: clipboardDirectory) }
    let clipboardStore = HistoryStore(directory: clipboardDirectory)
    let pasteboard = NSPasteboard(name: .init("kaki-native-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let clipboard = ClipboardService(store: clipboardStore, pasteboard: pasteboard)
    let rich = HistoryItem(text: "rich\ntext", html: "<b>rich</b>", rtf: "{\\rtf1 rich}")
    let count = clipboard.write(item: rich)!
    try check(clipboard.matchesWrite(count), "own write guard matches")
    try check(pasteboard.string(forType: .html) == rich.html && pasteboard.data(forType: .rtf) == Data(rich.rtf!.utf8), "atomic rich clipboard formats")
    clipboard.captureNow(); try check(clipboardStore.items.isEmpty, "own write not recaptured")
    pasteboard.clearContents(); pasteboard.setString("external immediately", forType: .string)
    try check(!clipboard.matchesWrite(count), "external change cancels old write guard")
    clipboard.captureNow(); try check(clipboardStore.items[0].text == "external immediately", "external copy immediately after own write captured")
    pasteboard.clearContents(); pasteboard.setString("same formatting", forType: .string)
    pasteboard.setString("<i>same formatting</i>", forType: .html)
    clipboard.captureNow()
    pasteboard.clearContents(); pasteboard.setString("same formatting", forType: .string)
    clipboard.captureNow()
    try check(clipboardStore.items[0].html == nil, "clipboard recopy replaces rich formats")
    let imageCount = clipboard.writeImage(png)!
    try check(clipboard.matchesWrite(imageCount) && pasteboard.data(forType: .png) == png, "screenshot writes with same source guard")
    clipboard.captureNow(); try check(clipboardStore.items[0].type == "text", "own screenshot not recaptured")
    pasteboard.clearContents(); pasteboard.setData(png, forType: .png)
    clipboard.captureNow(); clipboardStore.flush()
    try check(clipboardStore.items[0].type == "image", "external PNG captured")
    let selectedImage = clipboardStore.items[0]
    try check(clipboard.write(item: selectedImage) != nil && pasteboard.data(forType: .png) == png, "stored PNG clipboard playback")
    // RTF may contain a non-UTF8 ANSI code page or literal \bin bytes. Keep
    // that representation exactly, including across persistence and dedup updates.
    var ansiRTF = Data("{\\rtf1\\ansi\\ansicpg1252 caf".utf8)
    ansiRTF.append(0xE9)
    ansiRTF.append(Data("}".utf8))
    let ansiEntry = NSPasteboardItem()
    ansiEntry.setString("café", forType: .string)
    ansiEntry.setData(ansiRTF, forType: .rtf)
    pasteboard.clearContents(); pasteboard.writeObjects([ansiEntry])
    clipboard.captureNow()
    let capturedANSI = clipboardStore.items[0]
    try check(capturedANSI.rtfData == ansiRTF && capturedANSI.rtf == nil && capturedANSI.hasRichText,
              "Non-UTF8 RTF is captured as bytes and remains rich text")
    try check(clipboard.write(item: capturedANSI) != nil && pasteboard.data(forType: .rtf) == ansiRTF,
              "ANSI RTF playback never transcodes bytes")
    clipboardStore.flush()
    let rtfReloaded = HistoryStore(directory: clipboardDirectory)
    let restoredANSI = rtfReloaded.items.first { $0.id == capturedANSI.id }!
    try check(restoredANSI.rtfData == ansiRTF, "Raw RTF survives base64 JSON persistence")
    _ = clipboard.write(item: restoredANSI)
    try check(pasteboard.data(forType: .rtf) == ansiRTF, "Persisted ANSI RTF replays byte-for-byte")
    rtfReloaded.flush()

    var binaryRTF = Data("{\\rtf1\\ansi\\bin4 ".utf8)
    binaryRTF.append(contentsOf: [0x00, 0x80, 0xFF, 0x7F])
    binaryRTF.append(Data("}".utf8))
    let binaryEntry = NSPasteboardItem()
    binaryEntry.setString("café", forType: .string)
    binaryEntry.setData(binaryRTF, forType: .rtf)
    pasteboard.clearContents(); pasteboard.writeObjects([binaryEntry])
    clipboard.captureNow()
    let capturedBinary = clipboardStore.items[0]
    try check(capturedBinary.id == capturedANSI.id && capturedBinary.rtfData == binaryRTF,
              "Same text replaces its old raw rich-format bytes")
    try check(clipboard.write(item: capturedBinary) != nil && pasteboard.data(forType: .rtf) == binaryRTF,
              "Binary RTF playback preserves zero and invalid UTF8 bytes")
    clipboardStore.addText("café", rtf: "{\\rtf1 legacy}")
    try check(clipboardStore.items[0].rtfData == nil && clipboardStore.items[0].rtf != nil,
              "Legacy format replacement clears old raw RTF")
    clipboardStore.addText("café", rtfData: binaryRTF)
    try check(clipboardStore.items[0].rtf == nil && clipboardStore.items[0].rtfData == binaryRTF,
              "Raw format replacement clears old legacy RTF")
    clipboardStore.addText("café")
    try check(clipboardStore.items[0].rtf == nil && clipboardStore.items[0].rtfData == nil,
              "Plain recopy clears both rich-format representations")
    let legacyRTFJSON = try JSONSerialization.data(withJSONObject: ["id": "legacy-rtf", "type": "text",
                                                                 "text": "legacy", "rtf": "{\\rtf1 legacy}"])
    let legacyRTFItem = try JSONDecoder().decode(HistoryItem.self, from: legacyRTFJSON)
    try check(legacyRTFItem.rtfData == nil && legacyRTFItem.rtf == "{\\rtf1 legacy}",
              "Old JSON RTF strings decode without a raw-data field")
    try check(clipboard.write(item: legacyRTFItem) != nil && pasteboard.data(forType: .rtf) == Data("{\\rtf1 legacy}".utf8),
              "Old RTF strings retain their compatibility writer")
    let rawPlain = clipboard.write(item: capturedBinary, plainText: true)!
    try check(clipboard.matchesWrite(rawPlain) && pasteboard.data(forType: .rtf) == nil,
              "Plain playback also strips raw RTF")

    let plain = clipboard.write(item: rich, plainText: true)!
    try check(clipboard.matchesWrite(plain) && pasteboard.data(forType: .html) == nil && pasteboard.data(forType: .rtf) == nil, "plain text playback strips formatting")
    clipboard.stop(); clipboardStore.flush()
    print("History/clipboard tests passed (temporary data and private pasteboard)")
}

@MainActor private func runThumbnailNotificationTests() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-thumbnail-events-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(directory: dir)
    let png = try historyTestPNG(width: 5)
    let reused = try ImageCodec.png(png)
    try check(reused == png, "already normalized PNG preserves exact bytes and canonical hash input")
    var events: [String] = [], delivered: NSImage?
    let observer = store.thumbnailChanges.sink { id in
        events.append(id)
        if let item = store.item(id: id) { delivered = store.thumbnail(for: item) }
    }
    defer { observer.cancel() }
    try check(store.captureImage(data: png), "pending thumbnail fixture admitted")
    let pending = store.items[0]
    try check(store.thumbnail(for: pending) == nil, "pending image has no premature thumbnail request")
    store.flush()
    for _ in 0..<200 { if delivered != nil { break }; try await Task.sleep(nanoseconds: 1_000_000) }
    try check(delivered != nil && events == [pending.id, pending.id], "image completion and thumbnail completion notify only the matching ID and deliver immediately")
    let count = events.count
    store.addText("unrelated text"); store.updateMetadata(id: pending.id, tags: ["tag"], note: "note"); store.togglePin(id: pending.id)
    try await Task.sleep(nanoseconds: 10_000_000)
    try check(events.count == count, "unrelated history edits do not trigger thumbnail notifications")
    try check(store.captureImage(data: png), "canonical duplicate fixture admitted")
    let duplicateID = store.items[0].id
    store.flush()
    try check(!store.items.contains(where: { $0.id == duplicateID }) && !events.contains(duplicateID), "dedup removes pending duplicate without publishing a stale thumbnail ID")
    let removedPNG = try historyTestPNG(width: 7)
    try check(store.captureImage(data: removedPNG), "deleted thumbnail fixture admitted")
    let removedID = store.items[0].id
    store.flush(); store.remove(id: removedID)
    let beforeLate = events.filter { $0 == removedID }.count
    try await Task.sleep(nanoseconds: 20_000_000)
    try check(events.filter { $0 == removedID }.count == beforeLate && !store.items.contains(where: { $0.id == removedID }), "late thumbnail completion cannot publish or resurrect a deleted item")
    let evictions = HistoryStore(directory: dir.appendingPathComponent("evictions"))
    for width in 1...25 { let data = try historyTestPNG(width: width); try check(evictions.captureImage(data: data), "thumbnail LRU fixture admitted") }
    evictions.flush()
    let first = evictions.items[0]
    for item in evictions.items {
        _ = evictions.thumbnail(for: item)
        for _ in 0..<200 { if evictions.thumbnail(for: item) != nil { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        try check(evictions.thumbnail(for: item) != nil, "asynchronous thumbnail cache delivers each image")
    }
    try check(evictions.thumbnail(for: first) == nil, "twenty-fifth thumbnail evicts the first of the 24-image cache")
    for _ in 0..<200 { if evictions.thumbnail(for: first) != nil { break }; try await Task.sleep(nanoseconds: 1_000_000) }
    try check(evictions.thumbnail(for: first) != nil, "evicted thumbnail can be requested and delivered again")
    store.flush(); evictions.flush()
}

@MainActor private func runHistoryPersistenceOrderingTests() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-history-order-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(directory: dir)
    let large = String(repeating: "大文本📝", count: 150_000)
    store.addText(large + "-old")
    try await Task.sleep(nanoseconds: 300_000_000)
    for value in 0..<20 { store.addText("revision-" + String(value)) }
    let board = store.createBoard("保留")!
    let retained = store.items[0].id
    store.addToBoard(id: retained, board: board)
    store.togglePin(id: retained)
    store.addText(large + "-final")
    let png = try historyTestPNG(width: 8)
    try check(store.captureImage(data: png), "image worker interleaves with automatic history snapshots")
    let cancelledPNG = try historyTestPNG(width: 9)
    try check(store.captureImage(data: cancelledPNG), "second concurrent image snapshot fixture admitted")
    let cancelled = store.items[0]
    store.remove(id: cancelled.id)
    store.flush()
    let expected = store.items
    let disk = dir.appendingPathComponent("history.json")
    let immediate = try Data(contentsOf: disk)
    try await Task.sleep(nanoseconds: 350_000_000)
    let later = try Data(contentsOf: disk)
    try check(immediate == later, "older queued snapshots and completion callbacks cannot overwrite flushed final history")
    let restored = HistoryStore(directory: dir)
    try check(restored.items == expected && restored.boards == [board], "rapid edits plus flush reload retain exact values, order, fixed items and board copies")
    try check(restored.items.contains(where: { $0.text == large + "-final" }), "large UTF-8 text retains complete content without truncation")
    try check(!restored.items.contains(where: { $0.id == cancelled.id }) && !FileManager.default.fileExists(atPath: cancelled.file!), "cancelled pending image never enters final serialized history")
    try check(restored.items.filter { $0.type == "image" }.allSatisfy { $0.hash != nil && ($0.bytes ?? 0) > 0 && $0.file.map { FileManager.default.fileExists(atPath: $0) } == true }, "persisted images always refer to completed payloads and canonical hashes")
    try check(restored.pendingImageBytes == 0 && !restored.isReadOnly, "final image snapshots reload without pending reservations or format migration")
    let automatic = HistoryStore(directory: dir.appendingPathComponent("automatic"))
    automatic.addText(large)
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: automatic.directory.appendingPathComponent("history.json").path) { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    let autoReload = HistoryStore(directory: automatic.directory)
    try check(autoReload.items.first?.text == large, "automatic background encoding atomically saves full large text without explicit flush")
    automatic.flush(); restored.flush()
}
