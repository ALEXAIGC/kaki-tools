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
        do {
            _ = NSApplication.shared
            try runSystemTests()
            try await runHistoryTests()
            try runDeskflowTests()
            try runSettingsTests()
            try await runAppTests()
            print("NATIVE_TESTS_PASSED \(checkCount) assertions")
        } catch { fputs("NATIVE_TESTS_FAILED \(error)\n", stderr); exit(1) }
    }
    @MainActor static func runSettingsTests() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-native-settings-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        let original: [String: Any] = ["hotkey": "Command+Option+V", "maxHistoryItems": 500, "unknownFutureSetting": ["kept": true], "windowManager": ["enabled": false, "shortcuts": ["left-half": NSNull()]]]
        try JSONSerialization.data(withJSONObject: original).write(to: file)
        let settings = AppSettings(directory: dir)
        try check(settings.hotkey == "Command+Option+V", "legacy shortcut preserved")
        try check(!settings.windowManagerEnabled && settings.windowShortcuts["left-half"] == "", "legacy disabled window manager and null shortcut preserved")
        settings.autoPaste = false; try settings.save()
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        try check(written["maxHistoryItems"] as? Int == 100, "history setting upgraded to100")
        try check((written["unknownFutureSetting"] as? [String: Bool])?["kept"] == true, "unknown settings preserved")
        try check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.pre-native.json").path), "settings backed up before migration write")
        try check(!AppSettings(directory: dir).autoPaste, "native settings persist roundtrip")
    }
}
