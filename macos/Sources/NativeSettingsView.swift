import SwiftUI
import AppKit

struct NativeSettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings
    @ObservedObject var deskflow: DeskflowService
    var body: some View {
        TabView(selection: $controller.settingsSection) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heading("剪贴板", subtitle: "普通历史保留最近100条，固定与收藏单独保留。")
                    GroupBox("使用习惯") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("选择后自动粘贴回原应用", isOn: $settings.autoPaste)
                            Toggle("面板失去焦点时自动隐藏", isOn: $settings.hideOnBlur)
                            Toggle("启动时显示剪贴板面板", isOn: $settings.showOnLaunch)
                            Toggle("开机启动", isOn: Binding(get: { controller.launchesAtLogin }, set: { controller.setLaunchAtLogin($0) }))
                            Picker("外观", selection: $settings.appearance) {
                                Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                            }.pickerStyle(.segmented)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Button("清空普通历史…", role: .destructive) { controller.clearHistory() }
                        Spacer(); Button("保存设置") { controller.saveSettings() }.buttonStyle(.borderedProminent)
                    }
                    Text(controller.message).font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }.tabItem { Label("剪贴板", systemImage: "clipboard") }.tag("clipboard")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    heading("全局快捷键", subtitle: "在其他应用中也能触发。点击快捷键框，按下新组合键，再保存设置。")
                    GroupBox("剪贴板与截图") {
                        VStack(alignment: .leading, spacing: 12) {
                            shortcutRow("呼出剪贴板", value: $settings.hotkey)
                            shortcutRow("区域截图", value: $settings.screenshotHotkey)
                            Text("区域截图：按快捷键后拖拽框选范围；Esc 取消。截图复制到剪贴板并加入历史。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(10)
                    }
                    Divider()
                    Text("窗口调整").font(.headline)
                    Text("需要辅助功能权限。快捷键作用于当前应用的窗口。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("启用窗口调整快捷键", isOn: $settings.windowManagerEnabled)
                    ForEach(WindowManager.layouts) { layout in
                        shortcutRow(layout.label, value: Binding(get: {
                            settings.windowShortcuts[layout.id] ?? WindowManager.defaultShortcuts[layout.id] ?? ""
                        }, set: { settings.windowShortcuts[layout.id] = $0 }))
                    }
                }.padding(24)
            }.safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("恢复默认") {
                            settings.hotkey = "CommandOrControl+Shift+V"
                            settings.screenshotHotkey = "CommandOrControl+Shift+2"
                            settings.windowShortcuts = WindowManager.defaultShortcuts
                        }
                        Spacer(); Button("保存设置") { controller.saveSettings() }.buttonStyle(.borderedProminent)
                    }
                    if !controller.message.isEmpty { Text(controller.message).font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 24).padding(.vertical, 12)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .top) { Divider() }
            }.tabItem { Label("快捷键", systemImage: "keyboard") }.tag("shortcuts")
            DeskflowSettingsView(service: deskflow).tabItem { Label("跨屏协同", systemImage: "display.2") }.tag("deskflow")
            VStack(alignment: .leading, spacing: 18) {
                heading("权限", subtitle: "自动粘贴和窗口调整需要辅助功能权限。")
                Label(WindowManager.accessibilityTrusted(prompt: false) ? "辅助功能已允许" : "辅助功能尚未允许", systemImage: "hand.raised")
                Button("请求辅助功能权限") { controller.requestAccessibility() }
                Button("打开系统隐私设置") { controller.openAccessibilitySettings() }
                Divider()
                Text("区域截图使用 macOS 自带的选区工具；首次截图时按系统提示允许屏幕录制。剪贴板读取同样由系统管理访问权限。").foregroundStyle(.secondary)
                Spacer()
                Text("Kaki Tools \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") · 原生 macOS").font(.caption).foregroundStyle(.secondary)
            }.padding(24).tabItem { Label("权限与关于", systemImage: "lock.shield") }.tag("about")
        }.frame(minWidth: 600, minHeight: 520).padding(8).background(Color(nsColor: .windowBackgroundColor))
    }
    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.title2.bold()); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
    }
    private func shortcutRow(_ name: String, value: Binding<String>) -> some View {
        HStack {
            Text(name); Spacer()
            ShortcutRecorder(value: value, onRecordingChanged: controller.setShortcutRecording).frame(width: 190, height: 28)
            Button { value.wrappedValue = "" } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("停用此快捷键")
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: String
    var onRecordingChanged: (Bool) -> Void
    func makeNSView(context: Context) -> ShortcutField {
        let field = ShortcutField(); field.onRecord = { value = $0 }; field.onRecordingChanged = onRecordingChanged; return field
    }
    func updateNSView(_ view: ShortcutField, context: Context) { view.accelerator = value; view.onRecord = { value = $0 }; view.onRecordingChanged = onRecordingChanged }
    static func dismantleNSView(_ view: ShortcutField, coordinator: ()) { view.cancelRecording() }
}
final class ShortcutField: NSTextField {
    var onRecord: ((String) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private var recording = false
    private var windowObservers: [NSObjectProtocol] = []
    var accelerator = "" { didSet { if !recording { showValue() } } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); isEditable = false; isSelectable = false; alignment = .center
        isBezeled = true; bezelStyle = .roundedBezel; focusRingType = .exterior
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    private func showValue() { stringValue = HotkeyChord.parse(accelerator)?.label ?? (accelerator.isEmpty ? "未设置" : accelerator) }
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        recording = true; stringValue = "按快捷键…"; onRecordingChanged?(true); return true
    }
    private func finishRecording() {
        guard recording else { return }
        recording = false; showValue(); onRecordingChanged?(false)
    }
    func cancelRecording() {
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        finishRecording()
    }
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        finishRecording(); return true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }; windowObservers.removeAll()
        guard let window else { finishRecording(); return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.cancelRecording() }
            })
        }
    }
    deinit { for observer in windowObservers { NotificationCenter.default.removeObserver(observer) } }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); stringValue = "按快捷键…" }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.makeFirstResponder(nil); stringValue = HotkeyChord.parse(accelerator)?.label ?? (accelerator.isEmpty ? "未设置" : accelerator); return }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false || Set<UInt16>([122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]).contains(event.keyCode),
              let chord = HotkeyChord.from(event: event) else { NSSound.beep(); return }
        onRecord?(chord.accelerator); window?.makeFirstResponder(nil)
    }
}
