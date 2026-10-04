import Foundation

enum ShortcutValidation {
    static func title(for action: String) -> String {
        switch action {
        case "panel": return "剪贴板"
        case "studio": return "素材库"
        case "screenshot": return "区域截图"
        default:
            if action.hasPrefix("window:"), let layout = WindowManager.layouts.first(where: { "window:" + $0.id == action }) {
                return layout.settingsLabel
            }
            return action
        }
    }

    // This checks only enabled app bindings. System-wide availability is still
    // determined by Carbon when the user saves; no registration happens here.
    static func issues(in bindings: [String: String]) -> [String: String] {
        var issues: [String: String] = [:]
        var chords: [HotkeyChord: [String]] = [:]
        for action in bindings.keys.sorted() {
            guard let value = bindings[action], !value.isEmpty else { continue }
            guard let chord = HotkeyChord.parse(value) else {
                issues[action] = "无法识别，请重新录制"
                continue
            }
            chords[chord, default: []].append(action)
        }
        for actions in chords.values where actions.count > 1 {
            for action in actions {
                issues[action] = "与" + actions.filter { $0 != action }.map { title(for: $0) }.joined(separator: "、") + "重复"
            }
        }
        return issues
    }
}
