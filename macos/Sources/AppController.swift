import AppKit
import SwiftUI
import Combine
import ApplicationServices
import ServiceManagement

@MainActor final class AppController: NSObject, ObservableObject {
    enum Filter: String, CaseIterable { case all = "全部", text = "文本", image = "图片", pinned = "固定" }
    let store: HistoryStore
    let settings: AppSettings
    let clipboard: ClipboardService
    let deskflow: DeskflowService
    let windows = WindowManager()
    let hotkeys = HotkeyManager()
    let log: NativeLog
    let testMode: Bool
    @Published var query = "" { didSet { if query != oldValue { selectedID = nil; refreshItems() } } }
    @Published var filter: Filter = .all { didSet { if filter != oldValue { selectedID = nil; refreshItems() } } }
    @Published var board: String? { didSet { if board != oldValue { selectedID = nil; refreshItems() } } }
    @Published private(set) var visibleItems: [HistoryItem] = []
    @Published var selectedID: String?
    @Published var message = "" { didSet { scheduleMessageClear() } }
    @Published var effectiveHotkey = ""
    @Published var settingsSection = "clipboard"
    @Published var screenshotBusy = false
    private var panel: ClipboardPanel?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var previousApp: NSRunningApplication?
    private var subscriptions = Set<AnyCancellable>()
    private var eventMonitor: Any?
    private var searchTask: DispatchWorkItem?
    private var messageClearTask: DispatchWorkItem?
    private var messageClearGeneration = 0
    private let messageLifetime: TimeInterval
    private var searchGeneration = 0
    private var pasteGeneration = 0
    private var arrangementGeneration = 0
    private var screenshotProcess: Process?
    private var lastBindings: [String: String] = [:]
    private var failedShortcutActions = Set<String>()
    private var shuttingDown = false
    private var shortcutRecording = false

    init(directory: URL, testMode: Bool, messageLifetime: TimeInterval = 5) {
        self.testMode = testMode
        self.messageLifetime = messageLifetime.isFinite && messageLifetime > 0 ? messageLifetime : 5
        settings = AppSettings(directory: directory)
        store = HistoryStore(directory: directory, limit: 100)
        clipboard = ClipboardService(store: store, pasteboard: testMode ? NSPasteboard(name: NSPasteboard.Name("kaki-native-test-" + UUID().uuidString)) : .general)
        deskflow = DeskflowService(userData: directory)
        log = NativeLog(directory: directory)
        super.init()
        store.onError = { [weak self] text in self?.report(text) }
        windows.onError = { [weak self] text in self?.report(text) }
        store.$items.combineLatest(store.$boards).receive(on: RunLoop.main).sink { [weak self] _, _ in
            self?.refreshItems()
        }.store(in: &subscriptions)
        settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyAppearance() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        refreshItems()
        applyAppearance()
    }
    func start() {
        log.write("原生应用启动 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
        buildStatusItem()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true, event.window == self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
        if !testMode {
            clipboard.start(interval: settings.pollInterval)
            _ = registerShortcuts(allowFallback: true)
            if settings.showOnLaunch { showPanel() }
        }
        if let error = settings.loadError { report(error) }
        if let error = store.lastError { report(error) }
    }
    private func scheduleMessageClear() {
        messageClearTask?.cancel(); messageClearTask = nil
        messageClearGeneration += 1
        guard !message.isEmpty && !shuttingDown else { return }
        let generation = messageClearGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.shuttingDown, self.messageClearGeneration == generation else { return }
            self.messageClearTask = nil; self.message = ""
        }
        messageClearTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + messageLifetime, execute: work)
    }
    func report(_ text: String) {
        message = text; log.write(text)
    }
    func refreshItems() {
        searchTask?.cancel(); searchGeneration += 1
        let generation = searchGeneration, items = store.items, query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let board = board, filter = filter
        let work = DispatchWorkItem { [weak self] in
            let result = Self.matchingItems(items, query: query, board: board, filter: filter)
            DispatchQueue.main.async {
                guard let self, self.searchGeneration == generation else { return }
                self.visibleItems = result
                if !result.contains(where: { $0.id == self.selectedID }) { self.selectedID = result.first?.id }
            }
        }
        searchTask = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (query.isEmpty ? 0 : 0.06), execute: work)
    }
    nonisolated static func matchingItems(_ items: [HistoryItem], query: String, board: String?, filter: Filter) -> [HistoryItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { matches($0, normalizedQuery: query, board: board, filter: filter) }
    }
    private nonisolated static func matches(_ item: HistoryItem, normalizedQuery query: String, board: String?, filter: Filter) -> Bool {
        guard item.board == board else { return false }
        if filter == .text && item.type != "text" { return false }
        if filter == .image && item.type != "image" { return false }
        if filter == .pinned && !item.pinned { return false }
        return query.isEmpty || [item.text ?? "", item.note ?? "", (item.tags ?? []).joined(separator: " ")].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
    nonisolated static func boardCounts(_ items: [HistoryItem], board: String?) -> [Filter: Int] {
        var result: [Filter: Int] = [.all: 0, .text: 0, .image: 0, .pinned: 0]
        for item in items where item.board == board {
            result[.all, default: 0] += 1
            if item.type == "text" { result[.text, default: 0] += 1 }
            if item.type == "image" { result[.image, default: 0] += 1 }
            if item.pinned { result[.pinned, default: 0] += 1 }
        }
        return result
    }
    var currentBoardCounts: [Filter: Int] { Self.boardCounts(store.items, board: board) }
    var selectedItem: HistoryItem? {
        guard let selectedID, let item = store.items.first(where: { $0.id == selectedID }) else { return nil }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.matches(item, normalizedQuery: query, board: board, filter: filter) ? item : nil
    }
    var canPasteSelected: Bool {
        guard let item = selectedItem else { return false }
        return !store.isPending(id: item.id)
    }
    var canPasteSelectedAsPlainText: Bool { canPasteSelected && selectedItem?.type == "text" }
    var canPinSelected: Bool { selectedItem != nil && !store.isReadOnly }
    var canDeleteSelected: Bool { selectedItem != nil && !store.isReadOnly }
    func selectItem(_ id: String) {
        resolveCurrentItems()
        if visibleItems.contains(where: { $0.id == id }) { selectedID = id }
    }
    func activateSelected(plainText: Bool = false, copyOnly: Bool = false) {
        resolveCurrentItems()
        guard let item = selectedItem, !plainText || item.type == "text" else { return }
        activate(item.id, plainText: plainText, copyOnly: copyOnly)
    }
    func toggleSelectedPin() {
        resolveCurrentItems()
        guard canPinSelected, let item = selectedItem else { return }
        store.togglePin(id: item.id)
        resolveCurrentItems()
    }
    func deleteSelected() {
        resolveCurrentItems()
        guard canDeleteSelected, let item = selectedItem,
              let index = visibleItems.firstIndex(where: { $0.id == item.id }) else { return }
        store.remove(id: item.id)
        resolveCurrentItems()
        if !visibleItems.isEmpty { selectedID = visibleItems[min(index, visibleItems.count - 1)].id }
    }
    func focusSearch() { NotificationCenter.default.post(name: .kakiFocusSearch, object: self) }
    func resolveCurrentItems() {
        // Rendering is debounced; actions always resolve the latest canonical state.
        searchTask?.cancel(); searchGeneration += 1
        visibleItems = Self.matchingItems(store.items, query: query, board: board, filter: filter)
        if !visibleItems.contains(where: { $0.id == selectedID }) { selectedID = visibleItems.first?.id }
    }
    func selectRelative(_ step: Int) {
        resolveCurrentItems()
        guard !visibleItems.isEmpty else { return }
        let index = visibleItems.firstIndex { $0.id == selectedID } ?? 0
        selectedID = visibleItems[max(0, min(visibleItems.count - 1, index + step))].id
    }
    func showPanel() {
        pasteGeneration += 1
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        if panel == nil {
            let p = ClipboardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true; p.level = .floating
            p.hidesOnDeactivate = false; p.isOpaque = false; p.backgroundColor = .clear
            p.hasShadow = true; p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.controller = self
            let host = NSHostingView(rootView: ClipboardView(controller: self, store: store))
            p.contentView = host; panel = p
        }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first!
        let work = screen.visibleFrame
        panel?.setFrame(Self.panelFrame(workArea: work), display: true)
        panel?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .kakiPanelShown, object: self)
        log.write("剪贴板面板显示")
    }
    nonisolated static func panelFrame(workArea: NSRect) -> NSRect {
        NSRect(x: workArea.minX, y: workArea.minY, width: workArea.width, height: min(332, workArea.height))
    }
    func hidePanel(restoreFocus: Bool = false) {
        pasteGeneration += 1; panel?.orderOut(nil)
        NotificationCenter.default.post(name: .kakiPanelHidden, object: self)
        if restoreFocus, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApp?.activate(options: [])
        }
    }
    func panelLostFocus() {
        if settings.hideOnBlur && settingsWindow?.isKeyWindow != true { hidePanel() }
    }
    func activate(_ id: String, plainText: Bool = false, copyOnly: Bool = false) {
        resolveCurrentItems()
        if store.isPending(id: id) { report("图片正在后台处理，完成后即可使用。"); return }
        guard visibleItems.contains(where: { $0.id == id }), let item = store.item(id: id) else { return }
        let target = previousApp, frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let eligible = frontPID == target?.processIdentifier || frontPID == ProcessInfo.processInfo.processIdentifier
        guard let count = clipboard.write(item: item, plainText: plainText) else { report("复制失败，原历史已保留。"); return }
        store.touch(id: id)
        hidePanel()
        guard !testMode, settings.autoPaste, !copyOnly, eligible, let target, !target.isTerminated else { return }
        guard WindowManager.accessibilityTrusted(prompt: false) else {
            report("内容已复制；允许辅助功能后可以自动粘贴。"); return
        }
        pasteGeneration += 1; let generation = pasteGeneration
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier { target.activate(options: []) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.pasteGeneration == generation, !self.shuttingDown,
                  self.clipboard.matchesWrite(count), !target.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
            let source = CGEventSource(stateID: .hidSystemState)
            let pasteKey = HotkeyChord.pasteKeyCode()
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: pasteKey, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: pasteKey, keyDown: false) else { return }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
    }
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        if event.keyCode == 53 { hidePanel(restoreFocus: true); return true }
        let selectionKeys: Set<UInt16> = [36, 76, 123, 124, 125, 126, 51, 117]
        if selectionKeys.contains(event.keyCode) || flags.contains(.command) { resolveCurrentItems() }
        if flags.contains(.command), let char = event.charactersIgnoringModifiers, let digit = Int(char), digit >= 1, digit <= 9 {
            if visibleItems.count >= digit { activate(visibleItems[digit - 1].id, plainText: flags.contains(.shift)) }
            return true
        }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" { focusSearch(); return true }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "p" { toggleSelectedPin(); return true }
        if flags.contains(.command), event.charactersIgnoringModifiers == "," { showSettings(); return true }
        if event.keyCode == 36 || event.keyCode == 76 {
            if let selectedID { activate(selectedID, plainText: flags.contains(.shift)) }; return true
        }
        let editor = panel?.firstResponder as? NSTextView
        let editing = editor != nil
        let caret = editor?.selectedRange()
        let leftEdge = !editing || query.isEmpty || (caret?.length == 0 && caret?.location == 0)
        let rightEdge = !editing || query.isEmpty || (caret?.length == 0 && caret?.location == editor?.string.utf16.count)
        if (event.keyCode == 123 && leftEdge) || event.keyCode == 126 { selectRelative(-1); return true }
        if (event.keyCode == 124 && rightEdge) || event.keyCode == 125 { selectRelative(1); return true }
        if !editing && (event.keyCode == 51 || event.keyCode == 117) { deleteSelected(); return true }
        return false
    }
    private func shortcutBindings(panelShortcut: String) -> [String: String] {
        var result = ["panel": panelShortcut, "screenshot": settings.screenshotHotkey]
        if settings.windowManagerEnabled {
            for (key, value) in WindowManager.defaultShortcuts.merging(settings.windowShortcuts, uniquingKeysWith: { _, new in new }) {
                if !value.isEmpty { result["window:" + key] = value }
            }
        }
        return result.filter { !$0.value.isEmpty }
    }
    @discardableResult func registerShortcuts(allowFallback: Bool) -> [String] {
        guard !testMode else {
            effectiveHotkey = settings.hotkey
            lastBindings = shortcutBindings(panelShortcut: settings.hotkey)
            failedShortcutActions = []; rebuildMenu(); return []
        }
        var candidate = settings.hotkey, bindings = shortcutBindings(panelShortcut: candidate)
        var failures = hotkeys.register(bindings: bindings) { [weak self] action in self?.performHotkey(action) }
        if allowFallback && failures.contains("panel") {
            for fallback in settings.fallbackHotkeys {
                candidate = fallback; bindings = shortcutBindings(panelShortcut: candidate)
                failures = hotkeys.register(bindings: bindings) { [weak self] action in self?.performHotkey(action) }
                if !failures.contains("panel") { break }
            }
        }
        if failures.isEmpty {
            lastBindings = bindings; effectiveHotkey = candidate; failedShortcutActions = []
        } else if allowFallback {
            effectiveHotkey = failures.contains("panel") ? "快捷键未注册" : candidate
            lastBindings = bindings; failedShortcutActions = Set(failures)
            report("快捷键注册失败：" + failures.joined(separator: "、"))
        }
        rebuildMenu(); return failures
    }
    private func performHotkey(_ action: String) {
        guard !shortcutRecording && !shuttingDown else { return }
        if action == "panel" { panel?.isVisible == true ? hidePanel(restoreFocus: true) : showPanel() }
        else if action == "screenshot" { takeScreenshot() }
        else if action.hasPrefix("window:") { arrangeWindow(String(action.dropFirst(7))) }
    }
    func arrangeWindow(_ key: String) {
        arrangementGeneration += 1; let generation = arrangementGeneration
        windows.cancel()
        let front = NSWorkspace.shared.frontmostApplication
        let frontPID = front?.processIdentifier
        let target = frontPID == ProcessInfo.processInfo.processIdentifier ? previousApp : front
        if panel?.isVisible == true {
            hidePanel(restoreFocus: true)
            guard let target, !target.isTerminated else { return }
            target.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, !self.shuttingDown, self.arrangementGeneration == generation, !target.isTerminated else { return }
                self.windows.arrange(key, targetPID: target.processIdentifier)
            }
        } else if let frontPID { windows.arrange(key, targetPID: frontPID) }
    }
    func setShortcutRecording(_ recording: Bool) {
        guard recording != shortcutRecording else { return }
        shortcutRecording = recording
        guard !testMode && !shuttingDown else { return }
        if recording { hotkeys.unregisterAll() }
        else {
            let failures = hotkeys.register(bindings: lastBindings) { [weak self] action in self?.performHotkey(action) }
            if !failures.isEmpty { report("快捷键恢复失败：" + failures.joined(separator: "、")) }
        }
    }
    func saveSettings() {
        let previousBindings = lastBindings, previousEffectiveHotkey = effectiveHotkey
        let previousFailures = failedShortcutActions
        let failures = registerShortcuts(allowFallback: false)
        guard failures.isEmpty else {
            _ = hotkeys.register(bindings: previousBindings) { [weak self] action in self?.performHotkey(action) }
            report("快捷键已被占用或格式无效，设置尚未保存。"); return
        }
        do { try settings.save(); applyAppearance(); message = "设置已保存。" }
        catch {
            if !testMode { _ = hotkeys.register(bindings: previousBindings) { [weak self] action in self?.performHotkey(action) } }
            lastBindings = previousBindings; effectiveHotkey = previousEffectiveHotkey; failedShortcutActions = previousFailures
            rebuildMenu(); report("设置保存失败：" + error.localizedDescription)
        }
    }
    func setAppearance(_ appearance: String) {
        guard ["system", "light", "dark"].contains(appearance) else { return }
        // A toolbar theme change must not save unregistered shortcut drafts from Settings.
        let saved = AppSettings(directory: store.directory)
        if let error = saved.loadError { report(error); return }
        saved.appearance = appearance
        do { try saved.save(); settings.appearance = appearance; applyAppearance() }
        catch { report("主题保存失败：" + error.localizedDescription) }
    }
    func applyAppearance() {
        NSApp.appearance = settings.appearance == "dark" ? NSAppearance(named: .darkAqua) : settings.appearance == "light" ? NSAppearance(named: .aqua) : nil
    }
    func showSettings(section: String? = nil) {
        if let section, ["clipboard", "shortcuts", "deskflow", "about"].contains(section) { settingsSection = section }
        hidePanel()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Kaki Tools 设置"; window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 600, height: 540)
            window.contentView = NSHostingView(rootView: NativeSettingsView(controller: self, settings: settings, deskflow: deskflow))
            settingsWindow = window
        }
        settingsWindow?.center(); settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func takeScreenshot() {
        guard !screenshotBusy && !testMode else { return }
        hidePanel(restoreFocus: true); settingsWindow?.orderOut(nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kaki-shot-\(UUID().uuidString).png")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-s", "-x", file.path]
        screenshotBusy = true; screenshotProcess = process
        process.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: file) }
                guard let self, !self.shuttingDown, self.screenshotProcess === child else { return }
                self.screenshotProcess = nil; self.screenshotBusy = false
                guard child.terminationStatus == 0, let data = try? Data(contentsOf: file, options: .mappedIfSafe), !data.isEmpty else { return }
                let accepted = self.store.captureImage(data: data)
                _ = self.clipboard.writeImage(data)
                if accepted { self.message = "截图已复制，正在保存到历史。" }
            }
        }
        do { try process.run() } catch { screenshotProcess = nil; screenshotBusy = false; report("无法截图：" + error.localizedDescription) }
    }
    func createBoard() { prompt(title: "新建收藏", value: "") { [weak self] name in self?.store.createBoard(name) } }
    func renameBoard(_ name: String) { prompt(title: "重命名收藏", value: name) { [weak self] value in guard let self else { return }
        self.store.renameBoard(name, to: value)
        let renamed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.store.boards.contains(renamed) { self.board = renamed } } }
    func deleteBoard(_ name: String) {
        if confirm("删除收藏“\(name)”？", detail: "其中的收藏副本会删除，普通历史中的原记录不受影响。") {
            store.deleteBoard(name); if board == name { board = nil }
        }
    }
    func editMetadata(_ id: String) {
        guard let item = store.item(id: id) else { return }
        let alert = NSAlert(); alert.messageText = "标签与备注"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let box = NSStackView(); box.orientation = .vertical; box.spacing = 10
        let tags = NSTextField(string: (item.tags ?? []).joined(separator: "、")); tags.placeholderString = "标签，用逗号分隔"
        let note = NSTextField(string: item.note ?? ""); note.placeholderString = "备注"
        box.addArrangedSubview(tags); box.addArrangedSubview(note); box.frame = NSRect(x: 0, y: 0, width: 360, height: 70)
        alert.accessoryView = box
        if alert.runModal() == .alertFirstButtonReturn {
            let values = tags.stringValue.components(separatedBy: CharacterSet(charactersIn: ",，、"))
            store.updateMetadata(id: id, tags: values, note: note.stringValue)
        }
    }
    func clearHistory() {
        if confirm("清空普通历史？", detail: "包括固定项；收藏中的独立副本会保留。") { store.clearHistory() }
    }
    func requestAccessibility() { _ = WindowManager.accessibilityTrusted(prompt: true) }
    func openAccessibilitySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    func setLaunchAtLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; message = "开机启动设置已更新。" }
        catch { report("开机启动设置失败：" + error.localizedDescription) }
    }
    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    private func prompt(title: String, value: String, action: (String) -> Void) {
        let alert = NSAlert(); alert.messageText = title
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 280, height: 26); alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { action(field.stringValue) }
    }
    private func confirm(_ title: String, detail: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.title = "K"
            button.font = NSFont.systemFont(ofSize: 16, weight: .heavy)
            button.toolTip = "Kaki Tools · 剪贴板与窗口调整"
            button.setAccessibilityLabel("Kaki Tools")
        }
        rebuildMenu()
    }
    private func rebuildMenu() {
        guard let statusItem else { return }
        statusItem.menu = makeStatusMenu()
    }
    private func shortcutMenuTitle(_ title: String, action: String) -> String {
        if failedShortcutActions.contains(action) { return title + "（快捷键未注册）" }
        guard let accelerator = lastBindings[action], let chord = HotkeyChord.parse(accelerator) else { return title + "（未设置快捷键）" }
        return title + "    " + chord.label
    }
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开剪贴板", action: #selector(menuShowPanel), keyEquivalent: "")
        let shortcut = NSMenuItem(title: shortcutMenuTitle("快捷键：", action: "panel"), action: nil, keyEquivalent: ""); shortcut.isEnabled = false; menu.addItem(shortcut)
        menu.addItem(.separator())
        let arrange = NSMenuItem(title: "调整窗口", action: nil, keyEquivalent: ""), layouts = NSMenu()
        for layout in WindowManager.layouts {
            let item = NSMenuItem(title: shortcutMenuTitle(layout.label, action: "window:" + layout.id), action: #selector(menuArrange(_:)), keyEquivalent: ""); item.representedObject = layout.id; item.target = self; layouts.addItem(item)
        }
        layouts.addItem(.separator())
        let edit = NSMenuItem(title: "调整快捷键…", action: #selector(menuShortcutSettings), keyEquivalent: ""); edit.target = self
        layouts.addItem(edit)
        arrange.submenu = layouts; menu.addItem(arrange)
        menu.addItem(withTitle: shortcutMenuTitle("区域截图", action: "screenshot"), action: #selector(menuScreenshot), keyEquivalent: "")
        menu.addItem(withTitle: "快捷键设置…", action: #selector(menuShortcutSettings), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(menuSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "辅助功能权限…", action: #selector(menuPermissions), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "关于 Kaki Tools", action: #selector(menuAbout), keyEquivalent: "")
        menu.addItem(withTitle: "退出 Kaki Tools", action: #selector(menuQuit), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }
    @objc private func menuShowPanel() { showPanel() }
    @objc private func menuArrange(_ sender: NSMenuItem) { if let key = sender.representedObject as? String { arrangeWindow(key) } }
    @objc private func menuScreenshot() { takeScreenshot() }
    @objc private func menuSettings() { showSettings() }
    @objc private func menuShortcutSettings() { showSettings(section: "shortcuts") }
    @objc private func menuPermissions() { requestAccessibility(); openAccessibilitySettings() }
    func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let description = version + (build.map { $0 == version ? "" : " (" + $0 + ")" } ?? "") + " · 原生 macOS"
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Kaki Tools", .applicationVersion: description,
            .credits: NSAttributedString(string: "剪贴板 · 窗口调整 · 原生截图\nSwift / AppKit / SwiftUI")])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func menuAbout() { showAbout() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    func shutdown() {
        guard !shuttingDown else { return }; shuttingDown = true
        pasteGeneration += 1; arrangementGeneration += 1; searchGeneration += 1; searchTask?.cancel()
        messageClearGeneration += 1; messageClearTask?.cancel(); messageClearTask = nil
        clipboard.stop(); hotkeys.unregisterAll(); windows.cancel(); deskflow.shutdown()
        if let process = screenshotProcess, process.isRunning { process.terminate() }; screenshotProcess = nil
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        store.flush(); log.write("原生应用正常退出"); log.flush()
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
    }
    var panelIsVisible: Bool { panel?.isVisible == true }
    func capturePanel(to file: URL) throws {
        showPanel()
        guard let view = panel?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: file)
    }
}

final class ClipboardPanel: NSPanel {
    weak var controller: AppController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() { super.resignKey(); controller?.panelLostFocus() }
}
extension Notification.Name {
    static let kakiPanelShown = Notification.Name("KakiPanelShown")
    static let kakiPanelHidden = Notification.Name("KakiPanelHidden")
    static let kakiFocusSearch = Notification.Name("KakiFocusSearch")
}
