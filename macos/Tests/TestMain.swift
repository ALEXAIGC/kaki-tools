import Foundation
import AppKit

struct NativeTestFailure: Error, CustomStringConvertible {
    let description: String
}
private var checkCount = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
    checkCount += 1
    if !condition() { throw NativeTestFailure(description: "\(file):\(line): \(message)") }
}

@main struct NativeTests {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        do {
            _ = NSApplication.shared
            try runSystemTests()
            try runShortcutRecorderTests()
            try await runClipboardPreviewTests()
            try await runHistoryTests()
            try runSettingsTests()
            try runShortcutValidationTests()
            try await runAppTests()
            try runPermissionRefreshTests()
            try await runScreenCapturePermissionTests()
            try await runScreenCaptureTests()
            try await runStudioFailureTests()
            try await runStudioTests()
            try await runStudioVideoTests()
            try await runStudioCacheTests()
            try await runDreaminaTests()
            try await runClassicCliTests()
            try await runClassicDiagnosticsTests()
            try await runClassicFiveModesTests()
            try await runClassicModernTests()
            print("NATIVE_TESTS_PASSED \(checkCount) assertions")
        } catch { fputs("NATIVE_TESTS_FAILED \(error)\n", stderr); exit(1) }
    }
    @MainActor static func runSettingsTests() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-native-settings-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        let original: [String: Any] = ["hotkey": "Command+Option+V", "maxHistoryItems": 500, "fallbackHotkeys": ["Command+Shift+B", "Command+Option+V"], "unknownFutureSetting": ["kept": true], "windowManager": ["enabled": false, "shortcuts": ["left-half": NSNull()]]]
        try JSONSerialization.data(withJSONObject: original).write(to: file)
        let settings = AppSettings(directory: dir)
        try check(settings.hotkey == "Command+Option+V", "legacy shortcut preserved")
        try check(!settings.windowManagerEnabled && settings.windowShortcuts["left-half"] == "", "legacy disabled window manager and null shortcut preserved")
        try check(settings.studioHotkey == "Command+Shift+B" && settings.fallbackHotkeys == ["Command+Option+V"], "library default owns Command Shift B instead of clipboard fallback")
        try check(settings.downloadAskEachTime && settings.downloadFolder.isEmpty, "existing installations keep asking for a download location")
        try check(settings.studioCacheLimitMB == 1024 && settings.studioCacheDays == 7, "cache defaults to one GiB and seven idle days")
        settings.studioCacheLimitMB = 1536; settings.studioCacheDays = 17
        settings.studioCacheFolder = dir.path; settings.studioCacheVolumeUUID = "selected-volume"
        settings.downloadAskEachTime = false; settings.downloadFolder = dir.path
        settings.studioHotkey = "Command+Option+B"
        settings.autoPaste = false; try settings.save()
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        try check(written["maxHistoryItems"] as? Int == 100, "history setting upgraded to100")
        try check((written["unknownFutureSetting"] as? [String: Bool])?["kept"] == true, "unknown settings preserved")
        try check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.pre-native.json").path), "settings backed up before migration write")
        try check(AppSettings(directory: dir).studioHotkey == "Command+Option+B", "custom library shortcut persists")
        try check(!AppSettings(directory: dir).downloadAskEachTime && AppSettings(directory: dir).downloadFolder == dir.path, "default download folder and prompt mode persist")
        try check(AppSettings(directory: dir).studioCacheLimitMB == 1536 && AppSettings(directory: dir).studioCacheDays == 17, "cache capacity and idle expiry persist")
        try check(AppSettings(directory: dir).studioCacheFolder == dir.path && AppSettings(directory: dir).studioCacheVolumeUUID == "selected-volume", "chosen cache disk and volume identity persist")
        try check(AppSettings.cacheLimit(50 * 1024) == 50 * 1024 && AppSettings.cacheDays(365) == 365, "custom cache capacity and cleanup periods accept user-selected values")
        try check(AppSettings.cacheLimit(-1) == 1024 && AppSettings.cacheDays(0) == 7, "invalid cache policy values fall back to bounded defaults")
        try check(!AppSettings(directory: dir).autoPaste, "native settings persist roundtrip")
    }
}
