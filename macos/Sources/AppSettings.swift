import Foundation
import Combine

@MainActor final class AppSettings: ObservableObject {
    @Published var hotkey = "CommandOrControl+Shift+V"
    @Published var screenshotHotkey = "CommandOrControl+Shift+2"
    @Published var autoPaste = true
    @Published var hideOnBlur = true
    @Published var showOnLaunch = true
    @Published var windowManagerEnabled = true
    @Published var appearance = "system"
    @Published var windowShortcuts: [String: String] = [:]
    var fallbackHotkeys = ["Command+Option+V", "CommandOrControl+Shift+B"]
    var pollInterval: TimeInterval = 0.12
    private var raw: [String: Any] = [:]
    private let file: URL
    private(set) var loadError: String?
    init(directory: URL) {
        file = directory.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                guard let values = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
                    throw NSError(domain: "KakiSettings", code: 1, userInfo: [NSLocalizedDescriptionKey: "设置文件格式无效"])
                }
                raw = values
                hotkey = values["hotkey"] as? String ?? hotkey
                screenshotHotkey = values["screenshotHotkey"] as? String ?? screenshotHotkey
                autoPaste = values["autoPaste"] as? Bool ?? autoPaste
                hideOnBlur = values["hideOnBlur"] as? Bool ?? hideOnBlur
                showOnLaunch = values["showOnLaunch"] as? Bool ?? showOnLaunch
                appearance = values["nativeAppearance"] as? String ?? (values["theme"] as? String ?? appearance)
                fallbackHotkeys = values["fallbackHotkeys"] as? [String] ?? fallbackHotkeys
                pollInterval = max(0.08, min(1, (values["pollIntervalMs"] as? Double ?? 120) / 1000))
                if let window = values["windowManager"] as? [String: Any] {
                    windowManagerEnabled = window["enabled"] as? Bool ?? true
                    for (key, value) in window["shortcuts"] as? [String: Any] ?? [:] {
                        windowShortcuts[key] = value as? String ?? ""
                    }
                }
            } catch { loadError = "设置读取失败，原文件已保留：\(error.localizedDescription)" }
        }
    }
    func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: file.path) {
            let backup = file.deletingLastPathComponent().appendingPathComponent("settings.pre-native.json")
            if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: file, to: backup) }
        }
        raw["hotkey"] = hotkey; raw["screenshotHotkey"] = screenshotHotkey
        raw["autoPaste"] = autoPaste; raw["hideOnBlur"] = hideOnBlur
        raw["showOnLaunch"] = showOnLaunch; raw["maxHistoryItems"] = 100
        raw["nativeAppearance"] = appearance; raw["pollIntervalMs"] = Int(pollInterval * 1000)
        var window = raw["windowManager"] as? [String: Any] ?? [:]
        window["enabled"] = windowManagerEnabled
        window["shortcuts"] = windowShortcuts.mapValues { $0.isEmpty ? NSNull() as Any : $0 as Any }
        raw["windowManager"] = window
        try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        loadError = nil
    }
}
