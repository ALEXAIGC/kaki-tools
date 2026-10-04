import AppKit
import SwiftUI
import Combine
import ImageIO
import UniformTypeIdentifiers

private func clipboardPreviewPNG(variant: Int) throws -> Data {
    let width = 320, height = 180
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 15 + variant * 13, y: 15, width: 15, height: height - 30))
    let data = NSMutableData()
    guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}

@MainActor private func clipboardPreviewMarkerPixels(_ host: NSView) throws -> Int {
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    // Decode the PNG into ordinary eight-bit RGBA. The caching bitmap may use
    // a color space or component format that colorAt cannot sample reliably.
    guard let data = bitmap.representation(using: .png, properties: [:]),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadUnknown) }
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard drawn else { throw CocoaError(.fileReadUnknown) }
    let scale = Double(image.width) / Double(host.bounds.width)
    let left = Int(160 * scale), right = min(image.width, Int(310 * scale))
    var count = 0
    for y in stride(from: 0, to: image.height, by: 2) {
        for x in stride(from: left, to: right, by: 2) {
            let index = (y * image.width + x) * 4
            let r = pixels[index], g = pixels[index + 1], b = pixels[index + 2]
            if (r > 180 && g < 130 && b > 180) || (r < 150 && g > 180 && b > 180) { count += 1 }
        }
    }
    return count
}

@MainActor private func waitForClipboardPreview(_ description: String,
    condition: () throws -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !(try condition()) {
        if ProcessInfo.processInfo.systemUptime >= deadline { throw NativeTestFailure(description: description) }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor func runClipboardPreviewTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-clipboard-preview-" + UUID().uuidString)
    let controller = AppController(directory: directory, testMode: true, accessibilityPermissionCheck: { _ in false })
    defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
    controller.settings.appearance = "light"
    let store = controller.store
    // Hold the real worker queue so SwiftUI must first render a pending item.
    guard let queue = Mirror(reflecting: store).children.first(where: { $0.label == "queue" })?.value as? DispatchQueue else {
        throw NativeTestFailure(description: "Clipboard preview fixture cannot pause the history worker")
    }
    var suspended = false
    let panel = ClipboardPanel(contentRect: NSRect(x: -20000, y: -20000, width: 1040, height: 332),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true; panel.isExcludedFromWindowsMenu = true
    let host = NSHostingView(rootView: ClipboardView(controller: controller, store: store))
    host.frame = NSRect(x: 0, y: 0, width: 1040, height: 332)
    panel.contentView = host
    var events: [String: Int] = [:]
    let subscription = store.thumbnailChanges.sink { events[$0, default: 0] += 1 }
    defer {
        if suspended { queue.resume() }
        subscription.cancel(); panel.orderOut(nil); panel.contentView = nil; panel.close()
    }
    panel.orderBack(nil)
    NotificationCenter.default.post(name: .kakiPanelShown, object: controller)
    try await Task.sleep(nanoseconds: 80_000_000)
    queue.suspend(); suspended = true
    let firstPNG = try clipboardPreviewPNG(variant: 0)
    try check(store.captureImage(data: firstPNG), "preview fixture accepts a synthetic image")
    let firstID = store.items[0].id
    try await waitForClipboardPreview("Pending card did not enter the real ClipboardView") {
        controller.visibleItems.first?.id == firstID
    }
    try await Task.sleep(nanoseconds: 80_000_000)
    try check(store.isPending(id: firstID) && controller.visibleItems[0].hash == nil,
        "card renders the pending snapshot before background image completion")
    let pendingMarkerPixels = try clipboardPreviewMarkerPixels(host)
    try check(pendingMarkerPixels == 0, "pending card displays a placeholder")
    try await Task.sleep(nanoseconds: 80_000_000)
    queue.resume(); suspended = false
    // No flush or direct thumbnail request: only the actual card callbacks can
    // start decoding and produce the second notification after completion.
    try await waitForClipboardPreview("Completed visible image never requested its thumbnail from the card") {
        events[firstID, default: 0] >= 2
    }
    try await waitForClipboardPreview("Completed visible image kept its placeholder") {
        try clipboardPreviewMarkerPixels(host) > 100
    }
    try check(events[firstID] == 2, "visible card receives completion and thumbnail-ready notifications")

    panel.orderOut(nil)
    NotificationCenter.default.post(name: .kakiPanelHidden, object: controller)
    queue.suspend(); suspended = true
    let secondPNG = try clipboardPreviewPNG(variant: 1)
    try check(store.captureImage(data: secondPNG), "hidden preview fixture accepts a distinct image")
    let secondID = store.items[0].id
    try await waitForClipboardPreview("Hidden pending card did not update its item snapshot") {
        controller.visibleItems.first?.id == secondID
    }
    try await Task.sleep(nanoseconds: 80_000_000)
    queue.resume(); suspended = false
    try await waitForClipboardPreview("Hidden image did not complete asynchronously") { !store.isPending(id: secondID) }
    try await Task.sleep(nanoseconds: 80_000_000)
    for _ in 0..<3 {
        panel.orderBack(nil)
        NotificationCenter.default.post(name: .kakiPanelShown, object: controller)
        try await waitForClipboardPreview("Showing the panel lost the latest image preview") {
            guard events[secondID, default: 0] >= 2 else { return false }
            return try clipboardPreviewMarkerPixels(host) > 100
        }
        panel.orderOut(nil)
        NotificationCenter.default.post(name: .kakiPanelHidden, object: controller)
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    try check(events[secondID] == 2, "hiding and showing reuses the completed thumbnail without extra decode events")
    panel.contentView = NSView(frame: host.frame)
    try await Task.sleep(nanoseconds: 80_000_000)
    panel.contentView = host
    panel.orderBack(nil)
    NotificationCenter.default.post(name: .kakiPanelShown, object: controller)
    try await waitForClipboardPreview("Remounting the existing hosting view lost its image preview") {
        try clipboardPreviewMarkerPixels(host) > 100
    }
    try check(events[secondID] == 2, "remounting reloads the cached current item")
}
