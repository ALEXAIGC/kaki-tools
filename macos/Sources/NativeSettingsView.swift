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
    var subtitle: String? {
        switch self {
        case .clipboard: return nil
        case .shortcuts: return nil
        case .studio: return nil
        case .downloads: return "原始素材的保存位置与本地空间管理。"
        case .about: return nil
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
                        Text(section.title).font(.system(size: section == .clipboard ? 17 : 19, weight: .semibold))
                        if let subtitle = section.subtitle { SettingsFootnote(subtitle) }
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
            SettingsWordmark()
                .frame(maxWidth: .infinity)
                .padding(.top, 28).padding(.bottom, 26)
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
            Text("v\(SettingsStyle.version)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .accessibilityLabel("版本 \(SettingsStyle.version)")
        }.padding(.horizontal, 14).padding(.bottom, 18).frame(width: 174)
            .frame(maxHeight: .infinity).background(.thinMaterial)
    }
    @ViewBuilder private var page: some View {
        switch section {
        case .clipboard: clipboardPage
        case .shortcuts: shortcutsPage
        case .studio:
            AccountConnectionsView(studio: controller.studio, classicCli: controller.classicCli, openLibrary: controller.showStudio)
        case .downloads: downloadsPage
        case .about: aboutPage
        }
    }
    private var clipboardPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            clipboardGroup("外观") {
                HStack(spacing: 16) {
                    Text("主题模式").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 12)
                    Picker("主题模式", selection: $settings.appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }.pickerStyle(.segmented).labelsHidden()
                        .frame(width: 252).controlSize(.regular)
                        .accessibilityLabel("主题模式")
                }.padding(.vertical, 3)
            }
            clipboardGroup("使用习惯") {
                VStack(spacing: 0) {
                    switchRow("自动粘贴", value: $settings.autoPaste)
                    Divider()
                    switchRow("失焦隐藏", value: $settings.hideOnBlur)
                    Divider()
                    switchRow("启动时打开剪贴板", value: $settings.showOnLaunch)
                    Divider()
                    switchRow("开机启动", value: Binding(get: { controller.launchesAtLogin }, set: { controller.setLaunchAtLogin($0) }))
                }
            }
            SettingsCard {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 19)).foregroundStyle(.secondary)
                    Text("最近 100 条历史").font(.system(size: 13, weight: .medium))
                    HistoryCapacityLabel(store: controller.store)
                    Spacer(minLength: 12)
                    Button("清空历史…", role: .destructive) { controller.clearHistory() }
                        .help("固定与收藏独立保留")
                }
            }
        }
    }
    private func clipboardGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .padding(.leading, 2)
            SettingsCard { content() }
        }
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
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                SettingsCard {
                    VStack(spacing: 16) {
                        permissionIcon("hand.raised")
                        Text("辅助功能").font(.system(size: 15, weight: .semibold))
                        SettingsStatus(title: controller.accessibilityTrusted ? "已允许" : "待授权", active: controller.accessibilityTrusted)
                        HStack(spacing: 10) {
                            Button(controller.accessibilityTrusted ? "管理权限" : "授权") {
                                if controller.accessibilityTrusted { controller.openAccessibilitySettings() }
                                else { controller.requestAccessibility() }
                            }.buttonStyle(SettingsPrimaryButtonStyle()).disabled(controller.permissionRepairBusy)
                            Menu {
                                Button("重新检查") { controller.refreshAccessibilityPermission() }
                                Button("修复辅助功能") { controller.repairPermission(.accessibility) }
                                    .disabled(controller.permissionRepairBusy || controller.screenshotBusy)
                            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 28) }
                                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("辅助功能更多操作")
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                SettingsCard {
                    VStack(spacing: 16) {
                        permissionIcon("viewfinder")
                        Text("屏幕录制").font(.system(size: 15, weight: .semibold))
                        SettingsStatus(title: controller.screenshotPermissionIssue ? "本次被拒绝" : (controller.screenCaptureTrusted ? "已确认" : "未确认"), active: controller.screenCaptureTrusted && !controller.screenshotPermissionIssue)
                        HStack(spacing: 10) {
                            Button(!controller.screenCaptureTrusted && !controller.screenCapturePermissionRequested ? "授权" : "尝试截图") {
                                if !controller.screenCaptureTrusted && !controller.screenCapturePermissionRequested { controller.requestScreenCapturePermission() }
                                else { controller.takeScreenshot(retryPermissionFailure: true) }
                            }.buttonStyle(SettingsPrimaryButtonStyle()).disabled(controller.permissionRepairBusy || controller.screenshotBusy)
                            Menu {
                                Button("管理权限") { controller.openScreenCaptureSettings() }
                                Button("重新检查") { controller.refreshScreenCapturePermission() }
                                Button("修复截图权限") { controller.repairPermission(.screenCapture) }
                                    .disabled(controller.permissionRepairBusy || controller.screenshotBusy)
                                Divider()
                                Button("复制截图诊断") { controller.copyScreenshotDiagnostics() }
                            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 28) }
                                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("屏幕录制更多操作")
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
            if !controller.permissionRepairMessage.isEmpty {
                Text(controller.permissionRepairMessage).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            SettingsCard {
                HStack {
                    SettingsWordmark()
                    Spacer()
                    Button("关于 Kaki Tools") { controller.showAbout() }
                }
            }
        }.onAppear { controller.refreshAccessibilityPermission(); controller.refreshScreenCapturePermission() }
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
        if !controller.message.isEmpty { return controller.message }
        return ""
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
            if !footerMessage.isEmpty {
                Text(footerMessage)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
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
                    Text(used).font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
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
                Group {
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

@MainActor private struct HistoryCapacityLabel: View {
    @ObservedObject var store: HistoryStore
    var body: some View {
        Text(ByteCountFormatter.string(fromByteCount: store.contentBytes, countStyle: .file))
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .help("记录内容容量，包含固定与文件夹内容；不含备份和预览缓存")
    }
}
