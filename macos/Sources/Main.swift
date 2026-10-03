import AppKit
import Darwin
import CryptoKit

@MainActor final class NativeDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?
    private var lockFD: Int32 = -1
    private var signalSources: [DispatchSourceSignal] = []
    private var environment = ProcessInfo.processInfo.environment
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let testing = environment["KAKI_NATIVE_TEST"] == "1"
        if !testing && !permitExclusiveInstance() { NSApp.terminate(nil); return }
        let stylePreview = testing && ["style-screenshot", "style-wait"].contains(environment["KAKI_NATIVE_TEST_ACTION"] ?? "")
        let baseDirectory = testing
            ? URL(fileURLWithPath: environment["KAKI_NATIVE_TEST_DIR"] ?? (NSTemporaryDirectory() + "kaki-native-isolated-" + UUID().uuidString))
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kaki Tools", isDirectory: true)
        // Each style preview gets new data even when the caller reuses its test directory.
        let directory = stylePreview ? baseDirectory.appendingPathComponent("style-preview-" + UUID().uuidString, isDirectory: true) : baseDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            lockFD = open(directory.appendingPathComponent(".native-instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { NSApp.terminate(nil); return }
            if stylePreview { try prepareStylePreview(in: directory) }
        } catch { showLaunchFailure("无法打开数据目录：" + error.localizedDescription); return }
        let app = AppController(directory: directory, testMode: testing)
        if testing, let theme = environment["KAKI_NATIVE_TEST_THEME"], ["system", "light", "dark"].contains(theme) {
            app.settings.appearance = theme; app.applyAppearance()
        }
        controller = app; app.start()
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }; source.resume(); signalSources.append(source)
        }
        if testing { runIsolatedTest(app) }
    }
    private func permitExclusiveInstance() -> Bool {
        let identifier = Bundle.main.bundleIdentifier ?? "com.openclaw.kakitools"
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }
        guard !peers.isEmpty else { return true }
        let alert = NSAlert(); alert.messageText = "Kaki Tools 已在运行"
        alert.informativeText = "请先退出已有版本，再打开原生版。两个版本同时运行会争用剪贴板与历史文件。"
        alert.addButton(withTitle: "打开已有版本"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { peers.first?.activate(options: []) }
        return false
    }
    private func showLaunchFailure(_ text: String) {
        let alert = NSAlert(); alert.messageText = "Kaki Tools 无法启动"; alert.informativeText = text; alert.runModal(); NSApp.terminate(nil)
    }
    private func runIsolatedTest(_ app: AppController) {
        let action = environment["KAKI_NATIVE_TEST_ACTION"] ?? "quit"
        if action == "style-screenshot" || action == "style-wait" {
            app.resolveCurrentItems(); app.showPanel()
            print("NATIVE_STYLE_PREVIEW " + app.store.directory.path)
            if action == "style-wait" { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                do {
                    let path = self.environment["KAKI_NATIVE_SHOT"] ?? (NSTemporaryDirectory() + "kaki-native-style.png")
                    try app.capturePanel(to: URL(fileURLWithPath: path)); print("NATIVE_SCREENSHOT " + path)
                } catch { fputs("Native style snapshot failed: \(error)\n", stderr) }
                NSApp.terminate(nil)
            }
        } else if action == "screenshot" || action == "performance" || action == "panel-wait" {
            for index in (1...100).reversed() {
                app.store.addText(index == 1 ? "欢迎使用 Kaki Tools 原生版\n剪贴板与窗口调整，轻盈地融入 macOS。" : "示例记录 \(index) · 原生剪贴板", html: index == 2 ? "<strong>示例记录 2 · 原生剪贴板</strong>" : nil, rtf: nil)
            }
            _ = app.store.createBoard("常用内容"); _ = app.store.createBoard("工作")
            if let first = app.store.items.first { app.store.togglePin(id: first.id); app.store.updateMetadata(id: first.id, tags: ["原生", "常用"], note: "仅隔离测试示例，不读取系统剪贴板") }
            if action == "screenshot", let iconURL = Bundle.main.url(forResource: "icon", withExtension: "icns"),
               let icon = NSImage(contentsOf: iconURL), let tiff = icon.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                _ = app.store.captureImage(data: png)
            }
            let start = ProcessInfo.processInfo.systemUptime
            app.showPanel()
            let firstDispatchMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
            if action == "performance" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    var timings: [Double] = []
                    for _ in 0..<20 {
                        app.hidePanel(); let tick = ProcessInfo.processInfo.systemUptime; app.showPanel()
                        timings.append((ProcessInfo.processInfo.systemUptime - tick) * 1000)
                    }
                    print("NATIVE_PERFORMANCE " + String(data: try! JSONSerialization.data(withJSONObject: ["firstPanelDispatchMs": firstDispatchMs, "reopenDispatchAverageMs": timings.reduce(0,+) / Double(timings.count), "items": app.store.items.count]), encoding: .utf8)!)
                    NSApp.terminate(nil)
                }
            } else if action != "panel-wait" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    do {
                        let path = self.environment["KAKI_NATIVE_SHOT"] ?? (NSTemporaryDirectory() + "kaki-native.png")
                        try app.capturePanel(to: URL(fileURLWithPath: path)); print("NATIVE_SCREENSHOT " + path)
                    } catch { fputs("Native snapshot failed: \(error)\n", stderr) }
                    NSApp.terminate(nil)
                }
            }
        } else if ["settings", "settings-wait", "settings-shortcuts", "settings-shortcuts-wait"].contains(action) {
            app.showSettings(section: action.hasPrefix("settings-shortcuts") ? "shortcuts" : environment["KAKI_NATIVE_TEST_SETTINGS_SECTION"])
            if action.hasSuffix("-wait") { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                guard let window = NSApp.windows.first(where: { $0.title == "Kaki Tools 设置" }), let view = window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
                view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: self.environment["KAKI_NATIVE_SHOT"] ?? (NSTemporaryDirectory() + "kaki-native-settings.png")))
                }
                NSApp.terminate(nil)
            }
        } else if action == "wait" { return }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { print("NATIVE_SMOKE_READY"); NSApp.terminate(nil) } }
    }
    private func prepareStylePreview(in directory: URL) throws {
        let images = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let textExamples = ["把本地的 Kaki Tools 升级", "KAKI · 原生剪贴板", "gh auth login -h github.com",
            "我最多使用剪贴板和调整窗口，希望启动更快，内存占用更少。", "Hello, KAKI!",
            "把代码、文字和图片，轻松放进常用收藏。", "原生体验 · 随叫随到"]
        let firstAges: [TimeInterval] = [10, 120, 16 * 60, 29 * 60, 45 * 60, 60 * 60, 4 * 60 * 60]
        let now = Date().timeIntervalSince1970
        var items: [HistoryItem] = []
        var textIndex = 0
        for index in 0..<100 {
            let age = index < firstAges.count ? firstAges[index] : Double(index) * 3600
            let timestamp = (now - age) * 1000
            if index % 4 == 3 {
                let image = try stylePreviewImage(index: index / 4)
                let id = UUID().uuidString.lowercased(), file = images.appendingPathComponent(id + ".png")
                try image.data.write(to: file, options: .atomic)
                let hash = SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined()
                items.append(HistoryItem(id: id, type: "image", createdAt: timestamp, file: file.path,
                    hash: hash, size: image.size, bytes: image.data.count))
            } else {
                let text = textIndex < textExamples.count ? textExamples[textIndex]
                    : "示例记录 \(textIndex + 1)\n仅用于界面预览，不读取系统剪贴板。"
                items.append(HistoryItem(text: text, html: textIndex == 1 ? "<strong>KAKI · 原生剪贴板</strong>" : nil,
                    createdAt: timestamp))
                textIndex += 1
            }
        }
        // Board items are independent copies, leaving history counts at 100 / 75 / 25.
        for source in [items[1], items[2], items[3]] {
            var item = source
            item.id = UUID().uuidString.lowercased(); item.board = "API"
            if let original = item.file {
                let destination = images.appendingPathComponent(item.id + ".png")
                try FileManager.default.copyItem(at: URL(fileURLWithPath: original), to: destination)
                item.file = destination.path
            }
            items.append(item)
        }
        let fixture = StylePreviewHistory(items: items, boards: ["API"])
        try JSONEncoder().encode(fixture).write(to: directory.appendingPathComponent("history.json"), options: .atomic)
    }
    private func stylePreviewImage(index: Int) throws -> (data: Data, size: ImageDimensions) {
        if index == 0, let iconURL = Bundle.main.url(forResource: "icon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL), let tiff = icon.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            return (png, ImageDimensions(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        }
        let width = 320, height = 200
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let pixels = bitmap.bitmapData else {
            throw CocoaError(.fileWriteUnknown)
        }
        let colors = [(202, 70, 1), (12, 79, 161), (67, 46, 133), (18, 100, 90), (155, 40, 72)]
        let color = colors[index % colors.count]
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bitmap.bytesPerRow + x * 4
                let highlight = (x + y + index * 7) / 12
                pixels[offset] = UInt8(min(255, color.0 + highlight))
                pixels[offset + 1] = UInt8(min(255, color.1 + highlight))
                pixels[offset + 2] = UInt8(min(255, color.2 + highlight))
                pixels[offset + 3] = 255
            }
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return (png, ImageDimensions(width: width, height: height))
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.shutdown()
        for source in signalSources { source.cancel() }; signalSources.removeAll()
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { controller?.showPanel(); return false }
}

private struct StylePreviewHistory: Encodable {
    let items: [HistoryItem]
    let boards: [String]
}

@main struct NativeMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = NativeDelegate(); application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
