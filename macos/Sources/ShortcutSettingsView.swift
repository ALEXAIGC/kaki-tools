import SwiftUI
import AppKit

@MainActor struct ShortcutSettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings
    var onRecordingChanged: (Bool) -> Void
    @State private var group: WindowLayout.Group = .halves
    private var issues: [String: String] { controller.shortcutIssues }

    init(controller: AppController, settings: AppSettings, group: WindowLayout.Group = .halves,
         onRecordingChanged: @escaping (Bool) -> Void) {
        self.controller = controller; self.settings = settings; self.onRecordingChanged = onRecordingChanged
        _group = State(initialValue: group)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                modifier("⌘", "Command")
                modifier("⌥", "Option")
                modifier("⌃", "Control")
                modifier("⇧", "Shift")
                Spacer(minLength: 0)
            }.accessibilityElement(children: .combine)

            SettingsCard("常用操作") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 184), spacing: 10)], spacing: 10) {
                    tile("剪贴板", icon: "clipboard", action: "panel", value: $settings.hotkey)
                    tile("素材库", icon: "photo.on.rectangle.angled", action: "studio", value: $settings.studioHotkey)
                    tile("区域截图", icon: "viewfinder", action: "screenshot", value: $settings.screenshotHotkey)
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("窗口调整").font(.system(size: 14, weight: .semibold))
                            Text("作用于当前窗口 · 需要辅助功能权限").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Toggle("窗口调整", isOn: Binding(get: { settings.windowManagerEnabled }, set: {
                            finishRecording(); settings.windowManagerEnabled = $0
                        })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    Divider()
                    Picker("窗口布局分类", selection: Binding(get: { group }, set: {
                        finishRecording(); group = $0
                    })) {
                        ForEach(WindowLayout.Group.allCases) { item in
                            Text(groupTitle(item) + (groupHasIssue(item) ? " !" : "")).tag(item)
                        }
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.large)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                        ForEach(WindowManager.layouts(in: group)) { layout in
                            ShortcutSettingTile(title: layout.settingsLabel, issue: issues["window:" + layout.id],
                                                value: Binding(get: { settings.windowShortcuts[layout.id] ?? layout.defaultShortcut },
                                                               set: { settings.windowShortcuts[layout.id] = $0 }),
                                                onRecordingChanged: onRecordingChanged) {
                                WindowLayoutGlyph(layout: layout).frame(width: 26, height: 19)
                            }
                        }
                    }.disabled(!settings.windowManagerEnabled)
                    if !settings.windowManagerEnabled {
                        Text("保存后停用窗口快捷键。").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func finishRecording() { ShortcutField.cancelRecording(in: NSApp.keyWindow) }
    private func groupTitle(_ value: WindowLayout.Group) -> String {
        value == .other ? "铺满 / 居中" : value.settingsTitle
    }
    private func groupHasIssue(_ value: WindowLayout.Group) -> Bool {
        WindowManager.layouts(in: value).contains { issues["window:" + $0.id] != nil }
    }
    private func modifier(_ glyph: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(glyph).font(.system(size: 16, weight: .medium))
            Text(title).font(.system(size: 11))
        }.foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(glyph + "，" + title)
    }
    private func tile(_ title: String, icon: String, action: String, value: Binding<String>) -> some View {
        ShortcutSettingTile(title: title, issue: issues[action], value: value, onRecordingChanged: onRecordingChanged) {
            Image(systemName: icon).font(.system(size: 16)).frame(width: 20, height: 19)
        }
    }
}

private struct ShortcutSettingTile<Icon: View>: View {
    let title: String
    let issue: String?
    @Binding var value: String
    let onRecordingChanged: (Bool) -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var recording = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                icon().foregroundStyle(.secondary).accessibilityHidden(true)
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Button("停用") {
                    ShortcutField.cancelRecording(in: NSApp.keyWindow); value = ""
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.vertical, 3).disabled(value.isEmpty && !recording)
                    .help("停用" + title + "快捷键，保存后生效").accessibilityLabel("停用" + title + "快捷键")
            }
            ShortcutRecorder(value: $value) {
                recording = $0; onRecordingChanged($0)
            }
                .frame(height: 42).accessibilityLabel(title + "快捷键")
            if let issue {
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(issue == nil ? Color.primary.opacity(0.045) : Color.red.opacity(0.4), lineWidth: 1).allowsHitTesting(false) }
    }
}

private struct WindowLayoutGlyph: View {
    let layout: WindowLayout
    var body: some View {
        Canvas { context, size in
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            context.stroke(Path(roundedRect: frame, cornerRadius: 3), with: .foreground, lineWidth: 1)
            let area = frame.insetBy(dx: 3, dy: 3), f = layout.fractions
            let rect = CGRect(x: area.minX + f[0] * area.width, y: area.minY + f[1] * area.height, width: f[2] * area.width, height: f[3] * area.height)
            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(SettingsStyle.accent.opacity(0.7)))
        }.accessibilityHidden(true)
    }
}
