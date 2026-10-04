import SwiftUI
import AppKit

private enum SettingsSection: String, CaseIterable, Identifiable {
    case clipboard, shortcuts, studio, downloads, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clipboard: return "剪贴板"
        case .shortcuts: return "快捷键"
        case .studio: return "账号与连接"
        case .downloads: return "下载与缓存"
        case .about: return "权限与关于"
        }
    }
    var icon: String {
        switch self {
        case .clipboard: return "clipboard"
        case .shortcuts: return "command"
        case .studio: return "person.crop.circle"
        case .downloads: return "arrow.down.to.line"
        case .about: return "lock.shield"
        }
    }
    var subtitle: String {
        switch self {
        case .clipboard: return "让常用内容随手可得。"
        case .shortcuts: return "点击按键框 → 按下组合键 → 保存生效。"
        case .studio: return "你的创作账号，一处管理。"
        case .downloads: return "原始素材的保存位置与本地空间管理。"
        case .about: return "管理系统授权，了解 Kaki Tools。"
        }
    }
}

@MainActor struct NativeSettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings
    @State private var shortcutRecording = false
    private var section: SettingsSection { SettingsSection(rawValue: controller.settingsSection) ?? .clipboard }
    private var needsSave: Bool { section == .clipboard || section == .shortcuts }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(section.title).font(.system(size: 25, weight: .bold))
                        SettingsFootnote(section.subtitle)
                    }.padding(.bottom, 4)
                    page
                }.padding(28).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
            }.safeAreaInset(edge: .bottom, spacing: 0) {
                if needsSave || !controller.message.isEmpty { footer }
            }
        }.font(.system(size: 13)).tint(SettingsStyle.accent).accentColor(SettingsStyle.accent)
            .frame(minWidth: 760, minHeight: 580)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) { SettingsWordmark(); Text("Tools").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary) }
                .padding(.top, 30).padding(.bottom, 30)
            Text("设置").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.leading, 12).padding(.bottom, 10)
            VStack(spacing: 5) {
                ForEach(SettingsSection.allCases) { item in
                    Button { controller.settingsSection = item.rawValue } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.icon).font(.system(size: 14, weight: .medium)).frame(width: 20)
                            Text(item.title).font(.system(size: 13, weight: section == item ? .semibold : .medium))
                            Spacer(minLength: 0)
                        }.foregroundStyle(section == item ? SettingsStyle.accent : Color.primary.opacity(0.75))
                            .padding(.horizontal, 12).padding(.vertical, 12)
                            .background(section == item ? SettingsStyle.accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
            Spacer()
            Divider().padding(.bottom, 16)
            HStack(spacing: 6) {
                Image(systemName: "apple.logo").font(.system(size: 11))
                Text("原生 macOS").font(.system(size: 11))
            }.foregroundStyle(.secondary)
            Text("Kaki Tools · \(SettingsStyle.version)").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 6)
        }.padding(.horizontal, 16).padding(.bottom, 22).frame(width: 184)
            .frame(maxHeight: .infinity).background(.thinMaterial)
    }
    @ViewBuilder private var page: some View {
        switch section {
        case .clipboard: clipboardPage
        case .shortcuts: shortcutsPage
        case .studio:
            AccountConnectionsView(studio: controller.studio, connector: controller.dreamina, openLibrary: controller.showStudio)
        case .downloads: downloadsPage
        case .about: aboutPage
        }
    }
    private var clipboardPage: some View {
        VStack(spacing: 18) {
            SettingsCard("外观") {
                HStack(spacing: 10) {
                    appearanceOption("跟随系统", icon: "circle.lefthalf.filled", value: "system")
                    appearanceOption("浅色", icon: "sun.max", value: "light")
                    appearanceOption("深色", icon: "moon", value: "dark")
                }
            }
            SettingsCard("使用习惯") {
                VStack(spacing: 0) {
                    switchRow("自动粘贴", detail: "选择内容后粘贴回原应用", value: $settings.autoPaste)
                    Divider()
                    switchRow("失焦隐藏", detail: "切换到其他应用时收起面板", value: $settings.hideOnBlur)
                    Divider()
                    switchRow("启动时打开剪贴板", value: $settings.showOnLaunch)
                    Divider()
                    switchRow("开机启动", value: Binding(get: { controller.launchesAtLogin }, set: { controller.setLaunchAtLogin($0) }))
                }
            }
            SettingsCard {
                HStack(spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 22)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("最近 100 条历史").font(.system(size: 13, weight: .semibold))
                        SettingsFootnote("固定与收藏独立保留。")
                    }
                    Spacer()
                    Button("清空历史…", role: .destructive) { controller.clearHistory() }
                }
            }
        }
    }
    private func appearanceOption(_ title: String, icon: String, value: String) -> some View {
        let selected = settings.appearance == value
        return Button { settings.appearance = value } label: {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 20, weight: .light)).frame(height: 24)
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 10)) }
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundStyle(selected ? SettingsStyle.accent : Color.secondary)
                .background(selected ? SettingsStyle.accent.opacity(0.065) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? SettingsStyle.accent.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 1) }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func switchRow(_ name: String, detail: String? = nil, value: Binding<Bool>) -> some View {
        SettingsRow(name, detail: detail) { Toggle(name, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small) }
    }
    private var shortcutsPage: some View {
        ShortcutSettingsView(controller: controller, settings: settings) { recording in
            shortcutRecording = recording
            controller.setShortcutRecording(recording)
        }
    }
    private var downloadsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard("下载") {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsRow("保存方式") {
                        Picker("保存方式", selection: Binding(get: { settings.downloadAskEachTime }, set: { ask in
                            if !ask && settings.downloadFolder.isEmpty { controller.chooseDownloadFolder() }
                            else { controller.setDownloadPreferences(askEachTime: ask, folder: settings.downloadFolder) }
                        })) {
                            Text("每次选择位置").tag(true)
                            Text("默认文件夹").tag(false)
                        }.labelsHidden().frame(width: 168)
                    }
                    Divider()
                    SettingsFolderRow(path: settings.downloadFolder, emptyLabel: "未选择默认文件夹", action: controller.chooseDownloadFolder)
                    SettingsFootnote("保留原始文件，重名时自动加序号。")
                }
            }
            StudioCacheSettingsView(studio: controller.studio, settings: settings, setPreferences: controller.setCachePreferences, chooseFolder: controller.chooseCacheFolder, restoreFolder: { controller.setCacheLocation(folder: "", volumeUUID: "") })
        }
    }
    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard("系统权限") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        permissionIcon("hand.raised")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("辅助功能").font(.system(size: 13, weight: .semibold))
                            SettingsFootnote("用于自动粘贴和窗口调整。")
                        }
                        Spacer()
                        SettingsStatus(title: controller.accessibilityTrusted ? "已允许" : "待授权", active: controller.accessibilityTrusted)
                    }
                    HStack {
                        if !controller.accessibilityTrusted { Button("授权辅助功能") { controller.requestAccessibility() }.buttonStyle(SettingsPrimaryButtonStyle()) }
                        Button("管理权限") { controller.openAccessibilitySettings() }
                        Spacer()
                        Button("重新检查") { controller.refreshAccessibilityPermission() }
                            .help("重新读取 macOS 辅助功能授权状态")
                    }
                    Divider()
                    HStack(spacing: 12) {
                        permissionIcon("viewfinder")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("屏幕录制").font(.system(size: 13, weight: .semibold))
                            SettingsFootnote("仅用于截图，不录制音频。")
                        }
                        Spacer()
                        SettingsStatus(title: controller.screenshotPermissionIssue ? "本次被拒绝" : (controller.screenCaptureTrusted ? "已确认" : "未确认"), active: controller.screenCaptureTrusted && !controller.screenshotPermissionIssue)
                    }
                    HStack {
                        if !controller.screenCaptureTrusted && !controller.screenCapturePermissionRequested {
                            Button("申请屏幕权限") { controller.requestScreenCapturePermission() }.buttonStyle(SettingsPrimaryButtonStyle())
                        }
                        Button("管理权限") { controller.openScreenCaptureSettings() }
                        Spacer()
                        Button("重新检查") { controller.refreshScreenCapturePermission() }
                            .help("读取当前程序的屏幕权限，不弹出系统授权框")
                    }
                    if !controller.screenCaptureTrusted || controller.screenshotPermissionIssue {
                        SettingsFootnote("已开启开关仍未确认时，请完全退出软件，再从「应用程序」重新打开。")
                    }
                    HStack {
                        Button("尝试截图") { controller.takeScreenshot(retryPermissionFailure: true) }
                        Button("复制截图诊断") { controller.copyScreenshotDiagnostics() }
                            .help("复制版本、运行位置、签名和最近截图失败原因，不包含账号或素材")
                        Spacer()
                    }
                }
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        SettingsWordmark()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Kaki Tools").font(.system(size: 18, weight: .semibold))
                            Text("版本 \(SettingsStyle.version)").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Divider()
                    SettingsFootnote("剪贴板、窗口调整、区域截图与 Studio 素材库。")
                    HStack { Label("剪贴板历史仅存本机", systemImage: "lock").font(.system(size: 12)).foregroundStyle(.secondary); Spacer(); Button("关于…") { controller.showAbout() } }
                }
            }
        }.onAppear { controller.refreshAccessibilityPermission() }
    }
    private func permissionIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 20, weight: .light)).foregroundStyle(.secondary)
            .frame(width: 40, height: 40).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
    private var footerMessage: String {
        if section == .shortcuts {
            if shortcutRecording { return "按下组合键，Esc 取消 · Delete 停用" }
            if !controller.shortcutIssues.isEmpty { return "请调整标红的快捷键，再保存。" }
        }
        return controller.message.isEmpty ? "更改后点击保存" : controller.message
    }
    private var footer: some View {
        HStack(spacing: 12) {
            if section == .shortcuts {
                Button("恢复默认") {
                    ShortcutField.cancelRecording(in: NSApp.keyWindow)
                    settings.hotkey = "CommandOrControl+Shift+V"
                    settings.studioHotkey = "Command+Shift+B"
                    settings.screenshotHotkey = "CommandOrControl+Shift+2"
                    settings.windowShortcuts = WindowManager.defaultShortcuts
                }
            }
            Text(footerMessage)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            if needsSave { Button("保存设置") { ShortcutField.cancelRecording(in: NSApp.keyWindow); controller.saveSettings() }.buttonStyle(SettingsPrimaryButtonStyle()).disabled(section == .shortcuts && !controller.shortcutIssues.isEmpty) }
        }.padding(.horizontal, 28).padding(.vertical, 15)
            .background(.bar).overlay(alignment: .top) { Divider() }
    }
}

struct SettingsFolderRow: View {
    let path: String
    var emptyLabel = "未选择文件夹"
    var busy = false
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").font(.system(size: 17)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(path.isEmpty ? emptyLabel : URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if !path.isEmpty { Text(path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(busy ? "切换中…" : "选择…", action: action).disabled(busy)
        }.padding(.vertical, 7)
    }
}

@MainActor private struct StudioCacheSettingsView: View {
    @ObservedObject var studio: StudioStore
    @ObservedObject var settings: AppSettings
    let setPreferences: (Int, Int) -> Void
    let chooseFolder: () -> Void
    let restoreFolder: () -> Void
    @State private var capacity = "1"
    @State private var unit = 1024
    @State private var days = "7"
    @State private var validation = ""
    private var unavailable: Bool { studio.cacheClearing || studio.cacheChanging || studio.mediaBusy }
    private var used: String { studio.cacheBytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: studio.cacheBytes, countStyle: .binary) }
    private var limit: String { ByteCountFormatter.string(fromByteCount: Int64(settings.studioCacheLimitMB) * 1024 * 1024, countStyle: .binary) }
    var body: some View {
        SettingsCard("本地缓存") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(used).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(settings.studioCacheLimitMB > 0 ? "/ \(limit)" : "缓存已停用").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(studio.cacheClearing ? "清理中…" : "清理缓存") { Task { await studio.clearMaterialCache() } }
                        .disabled(unavailable || studio.cacheBytes == 0)
                }
                if settings.studioCacheLimitMB > 0 {
                    ProgressView(value: min(1, max(0, Double(studio.cacheBytes) / (Double(settings.studioCacheLimitMB) * 1024 * 1024))))
                        .accessibilityLabel("缓存空间占用")
                }
                Text("\(studio.cacheFiles) 个缓存文件").font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                SettingsFolderRow(path: studio.cacheLocation, busy: studio.cacheChanging, action: chooseFolder).disabled(unavailable)
                if !settings.studioCacheFolder.isEmpty { Button("恢复默认位置", action: restoreFolder).buttonStyle(.link).font(.system(size: 11)).disabled(unavailable) }
                if !studio.cacheAvailable { SettingsFootnote("缓存盘不可用，暂时在线读取。") }
                Divider()
                SettingsRow("启用本地缓存") {
                    Toggle("启用本地缓存", isOn: Binding(get: { settings.studioCacheLimitMB > 0 }, set: { value in
                        if value { apply() } else { setPreferences(0, settings.studioCacheDays) }
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(unavailable)
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("容量上限").font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            TextField("容量", text: $capacity).textFieldStyle(.roundedBorder).frame(width: 74).onSubmit(apply)
                            Picker("单位", selection: Binding(get: { unit }, set: { newUnit in
                                if let value = Double(capacity), value.isFinite { capacity = String(format: "%g", value * Double(unit) / Double(newUnit)) }
                                unit = newUnit
                            })) { Text("MB").tag(1); Text("GB").tag(1024) }.labelsHidden().frame(width: 70)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("自动清理").font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack(spacing: 7) {
                            TextField("天数", text: $days).textFieldStyle(.roundedBorder).frame(width: 74).onSubmit(apply)
                            Text("天未使用").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack { SettingsFootnote("达到上限时，先清理较久未使用的缓存。"); Spacer(); Button("应用", action: apply) }
                }.disabled(unavailable || settings.studioCacheLimitMB == 0)
                if !validation.isEmpty { SettingsFootnote(validation) }
                else if !studio.cacheMessage.isEmpty { SettingsFootnote(studio.cacheMessage) }
                SettingsFootnote("清理不影响已下载文件和剪贴板。")
            }
        }.task { loadDraft(); await studio.refreshCacheStats() }
            .onChange(of: settings.studioCacheLimitMB) { _ in loadDraft() }
            .onChange(of: settings.studioCacheDays) { _ in loadDraft() }
    }
    private func loadDraft() {
        let limit = settings.studioCacheLimitMB > 0 ? settings.studioCacheLimitMB : 1024
        unit = limit >= 1024 ? 1024 : 1
        capacity = String(format: "%g", Double(limit) / Double(unit)); days = String(settings.studioCacheDays)
    }
    private func apply() {
        guard let value = Double(capacity.trimmingCharacters(in: .whitespaces)), value.isFinite, value > 0,
              value * Double(unit) >= 1, value * Double(unit) <= 1_048_576,
              let age = Int(days.trimmingCharacters(in: .whitespaces)), (1...3650).contains(age) else {
            validation = "容量为 1 MB–1 TB，清理时间为 1–3650 天。"; return
        }
        validation = ""
        setPreferences(Int((value * Double(unit)).rounded()), age)
    }
}
