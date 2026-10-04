import AppKit
import SwiftUI
import Combine
import ApplicationServices
import ServiceManagement
import Security
import CryptoKit

@MainActor final class AppController: NSObject, ObservableObject, NSWindowDelegate {
    enum Filter: String, CaseIterable { case all = "全部", text = "文本", image = "图片", pinned = "固定" }
    let store: HistoryStore
    let settings: AppSettings
    let clipboard: ClipboardService
    let windows = WindowManager()
    let hotkeys = HotkeyManager()
    let log: NativeLog
    let studio: StudioStore
    let dreamina: DreaminaConnector
    let testMode: Bool
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            if Self.normalizedQuery(query) != Self.normalizedQuery(oldValue) { selectedID = nil }
            refreshItems()
        }
    }
    @Published var filter: Filter = .all { didSet { if filter != oldValue { selectedID = nil; refreshItems() } } }
    @Published var board: String? { didSet { if board != oldValue { selectedID = nil; refreshItems() } } }
    @Published private(set) var visibleItems: [HistoryItem] = []
    @Published private(set) var searching = false
    @Published private var textPresentations: [String: ClipboardTextPresentation] = [:]
    @Published var selectedID: String?
    @Published var message = "" { didSet { scheduleMessageClear() } }
    @Published var effectiveHotkey = ""
    @Published var settingsSection = "clipboard"
    @Published var screenshotBusy = false
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var screenCaptureTrusted = false
    @Published private(set) var screenCapturePermissionRequested = false
    @Published private(set) var screenshotPermissionIssue = false
    private let accessibilityPermissionCheck: (Bool) -> Bool
    private let screenCapturePermissionCheck: (Bool) -> Bool
    private let screenshotRunner: ScreenCaptureRunning?
    private var panel: ClipboardPanel?
    private var settingsWindow: NSWindow?
    private var studioWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var previousApp: NSRunningApplication?
    private var panelTarget: NSRunningApplication?
    private var focusContext = ClipboardFocusContext()
    private var subscriptions = Set<AnyCancellable>()
    private var eventMonitor: Any?
    private var searchTask: DispatchWorkItem?
    private var searchCancellation: ClipboardSearchCancellation?
    private let searchQueue = DispatchQueue(label: "com.kakitools.search", qos: .userInitiated)
    private let presentationQueue = DispatchQueue(label: "com.kakitools.text-preview", qos: .utility)
    private var presentationTickets: [String: UUID] = [:]
    private struct SearchKey: Equatable {
        let revision: Int
        let query: String
        let board: String?
        let filter: Filter
    }
    private var resolvedSearch: SearchKey?
    private var requestedSearch: SearchKey?
    private var resultItems: [String: HistoryItem] = [:]
    private var pendingSelectionActions: [(key: SearchKey, focus: Int, action: () -> Void)] = []
    private var countsRevision = -1
    private var countsBoard: String?
    private var cachedCounts: [Filter: Int] = [:]
    private var messageClearTask: DispatchWorkItem?
    private var messageClearGeneration = 0
    private let messageLifetime: TimeInterval
    private var searchGeneration = 0
    private var pasteGeneration = 0
    private var arrangementGeneration = 0
    private var screenshotGeneration = 0
    private var lastScreenshotFailure: ScreenCaptureFailure?
    private var lastBindings: [String: String] = [:]
    private var failedShortcutActions = Set<String>()
    private var shuttingDown = false
    private var shortcutRecording = false

    init(directory: URL, testMode: Bool, messageLifetime: TimeInterval = 5, studioTransport: StudioTransport = StudioURLTransport(), dreaminaRunner: DreaminaRunning? = nil, accessibilityPermissionCheck: @escaping (Bool) -> Bool = { WindowManager.accessibilityTrusted(prompt: $0) }, screenCapturePermissionCheck: ((Bool) -> Bool)? = nil, screenshotRunner: ScreenCaptureRunning? = nil) {
        self.testMode = testMode
        self.accessibilityPermissionCheck = accessibilityPermissionCheck
        self.screenCapturePermissionCheck = screenCapturePermissionCheck ?? (testMode ? { _ in false } : { prompt in
            prompt ? CGRequestScreenCaptureAccess() : CGPreflightScreenCaptureAccess()
        })
        self.screenshotRunner = screenshotRunner ?? (testMode ? nil : SystemScreenCaptureRunner())
        self.messageLifetime = messageLifetime.isFinite && messageLifetime > 0 ? messageLifetime : 5
        settings = AppSettings(directory: directory)
        store = HistoryStore(directory: directory, limit: 100)
        clipboard = ClipboardService(store: store, pasteboard: testMode ? NSPasteboard(name: NSPasteboard.Name("kaki-native-test-" + UUID().uuidString)) : .general)
        log = NativeLog(directory: directory)
        studio = StudioStore(directory: directory, credentials: testMode ? StudioMemoryCredentials() : StudioKeychain(), transport: studioTransport, cacheLimitMB: settings.studioCacheLimitMB, cacheDays: settings.studioCacheDays, cacheFolder: settings.studioCacheFolder, cacheVolumeUUID: settings.studioCacheVolumeUUID)
        dreamina = DreaminaConnector(directory: directory, runner: dreaminaRunner ?? (testMode ? DreaminaUnavailableRunner() : nil))
        super.init()
        store.onError = { [weak self] text in self?.report(text) }
        windows.onError = { [weak self] text in self?.report(text) }
        store.$items.combineLatest(store.$boards).receive(on: RunLoop.main).sink { [weak self] _, _ in
            self?.refreshItems()
            self?.pruneTextPresentations()
        }.store(in: &subscriptions)
        studio.$user.combineLatest(studio.$environment).sink { [weak self] user, environment in
            self?.dreamina.setOwner(user.map { KakiConnectionOwner(environment: environment.rawValue, userID: $0.id) })
        }.store(in: &subscriptions)
        settings.$appearance.removeDuplicates().sink { [weak self] value in
            self?.applyAppearance(value)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.refreshAccessibilityPermission()
            self?.refreshScreenCapturePermission()
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification).sink { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow, window === self.settingsWindow else { return }
            self.refreshAccessibilityPermission()
            self.refreshScreenCapturePermission()
        }.store(in: &subscriptions)
        refreshAccessibilityPermission()
        refreshScreenCapturePermission()
        refreshItems()
    }
    func start() {
        studio.startCacheMaintenance()
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
    private var currentSearch: SearchKey {
        SearchKey(revision: store.revision, query: Self.normalizedQuery(query), board: board, filter: filter)
    }
    private nonisolated static func normalizedQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    func refreshItems() {
        guard !shuttingDown else { return }
        let key = currentSearch
        pendingSelectionActions.removeAll { $0.key != key }
        if resolvedSearch == key {
            if requestedSearch != nil {
                searchTask?.cancel(); searchCancellation?.cancel(); searchGeneration += 1
                requestedSearch = nil
            }
            searching = false
            if selectedID.flatMap({ resultItems[$0] }) == nil { selectedID = visibleItems.first?.id }
            return
        }
        guard requestedSearch != key else { return }
        searchTask?.cancel(); searchGeneration += 1
        searchCancellation?.cancel()
        let generation = searchGeneration, items = store.items
        let cancellation = ClipboardSearchCancellation(); searchCancellation = cancellation
        requestedSearch = key
        // Empty search only compares small metadata; it never walks the text bodies.
        if key.query.isEmpty {
            commitSearch(Self.matchingItems(items, query: "", board: key.board, filter: key.filter), key: key)
            return
        }
        searching = true
        let work = DispatchWorkItem { [weak self] in
            var result: [HistoryItem] = []
            for item in items {
                guard !cancellation.isCancelled else { return }
                if Self.matches(item, normalizedQuery: key.query, board: key.board, filter: key.filter) { result.append(item) }
            }
            guard !cancellation.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self, !self.shuttingDown, self.searchGeneration == generation, self.currentSearch == key else { return }
                self.commitSearch(result, key: key)
            }
        }
        searchTask = work
        searchQueue.asyncAfter(deadline: .now() + 0.06, execute: work)
    }
    private func commitSearch(_ result: [HistoryItem], key: SearchKey) {
        resolvedSearch = key; requestedSearch = nil
        resultItems = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        visibleItems = result; searching = false
        if selectedID.flatMap({ resultItems[$0] }) == nil { selectedID = result.first?.id }
        let pending = pendingSelectionActions; pendingSelectionActions.removeAll()
        for intent in pending where intent.key == key && intent.focus == pasteGeneration {
            // A preceding action can change history and start another search.
            // Preserve keyboard order, including the selection repair after deletion.
            withCurrentItems(intent.action)
        }
    }
    private func withCurrentItems(_ action: @escaping () -> Void) {
        guard !shuttingDown else { return }
        if resolveCurrentItems() { action() }
        else { pendingSelectionActions.append((currentSearch, pasteGeneration, action)) }
    }
    private func pruneTextPresentations() {
        let ids = Set(store.items.map(\.id))
        textPresentations = textPresentations.filter { ids.contains($0.key) }
        presentationTickets = presentationTickets.filter { ids.contains($0.key) }
    }
    func requestTextPresentation(_ item: HistoryItem) {
        guard !shuttingDown, item.type == "text", textPresentations[item.id] == nil, presentationTickets[item.id] == nil else { return }
        let id = item.id, text = item.text ?? "", ticket = UUID()
        presentationTickets[id] = ticket
        presentationQueue.async { [weak self] in
            let value = ClipboardTextPresentation(text)
            DispatchQueue.main.async {
                guard let self, !self.shuttingDown, self.presentationTickets[id] == ticket else { return }
                self.presentationTickets[id] = nil
                guard self.store.items.contains(where: { $0.id == id && $0.text == text }) else { return }
                self.textPresentations[id] = value
            }
        }
    }
    func summary(for item: HistoryItem) -> String {
        textPresentations[item.id]?.summary ?? ClipboardTextPresentation.summary(item.text ?? "", scanLimit: 4096)
    }
    func textCount(for item: HistoryItem) -> Int? { textPresentations[item.id]?.utf16Count }
    private func recordExternalFocus() {
        let front = NSWorkspace.shared.frontmostApplication, own = ProcessInfo.processInfo.processIdentifier
        let revision = focusContext.revision
        focusContext.enter(frontPID: front?.processIdentifier, ownPID: own)
        if focusContext.revision != revision { previousApp = front }
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
    var currentBoardCounts: [Filter: Int] {
        if countsRevision != store.revision || countsBoard != board {
            cachedCounts = Self.boardCounts(store.items, board: board)
            countsRevision = store.revision; countsBoard = board
        }
        return cachedCounts
    }
    var selectedItem: HistoryItem? {
        guard resolvedSearch == currentSearch, let selectedID else { return nil }
        return resultItems[selectedID]
    }
    var canPasteSelected: Bool {
        guard let item = selectedItem else { return false }
        return !store.isPending(id: item.id)
    }
    var canPasteSelectedAsPlainText: Bool { canPasteSelected && selectedItem?.type == "text" }
    var canPinSelected: Bool { selectedItem != nil && !store.isReadOnly }
    var canDeleteSelected: Bool { selectedItem != nil && !store.isReadOnly }
    func selectItem(_ id: String) {
        guard resolveCurrentItems(), resultItems[id] != nil, selectedID != id else { return }
        selectedID = id
    }
    func activateSelected(plainText: Bool = false, copyOnly: Bool = false) {
        withCurrentItems { [weak self] in
            guard let self, let item = self.selectedItem, !plainText || item.type == "text" else { return }
            self.activate(item.id, plainText: plainText, copyOnly: copyOnly)
        }
    }
    func toggleSelectedPin() {
        withCurrentItems { [weak self] in
            guard let self, self.canPinSelected, let item = self.selectedItem else { return }
            self.store.togglePin(id: item.id); self.refreshItems()
        }
    }
    func deleteSelected() {
        withCurrentItems { [weak self] in
            guard let self, self.canDeleteSelected, let item = self.selectedItem,
                  let index = self.visibleItems.firstIndex(where: { $0.id == item.id }) else { return }
            self.store.remove(id: item.id)
            self.withCurrentItems { [weak self] in
                guard let self, !self.visibleItems.isEmpty else { return }
                self.selectedID = self.visibleItems[min(index, self.visibleItems.count - 1)].id
            }
        }
    }
    func focusSearch() { NotificationCenter.default.post(name: .kakiFocusSearch, object: self) }
    @discardableResult func resolveCurrentItems() -> Bool {
        guard !shuttingDown else { return false }
        refreshItems()
        return resolvedSearch == currentSearch
    }
    func selectRelative(_ step: Int) {
        withCurrentItems { [weak self] in
            guard let self, !self.visibleItems.isEmpty else { return }
            let index = self.visibleItems.firstIndex { $0.id == self.selectedID } ?? 0
            self.selectedID = self.visibleItems[max(0, min(self.visibleItems.count - 1, index + step))].id
        }
    }
    func showPanel() {
        cancelPendingClipboardActions()
        recordExternalFocus()
        panelTarget = previousApp?.processIdentifier == focusContext.externalPID ? previousApp : nil
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
        cancelPendingClipboardActions(); panel?.orderOut(nil)
        panelTarget = nil
        NotificationCenter.default.post(name: .kakiPanelHidden, object: self)
        if restoreFocus, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApp?.activate(options: [])
        }
    }
    func panelLostFocus() {
        if settings.hideOnBlur && settingsWindow?.isKeyWindow != true { hidePanel() }
    }
    func cancelPendingClipboardActions() {
        pasteGeneration += 1
        pendingSelectionActions.removeAll()
    }
    func activate(_ id: String, plainText: Bool = false, copyOnly: Bool = false) {
        guard resolveCurrentItems() else {
            withCurrentItems { [weak self] in self?.activate(id, plainText: plainText, copyOnly: copyOnly) }
            return
        }
        if store.isPending(id: id) { report("图片正在后台处理，完成后即可使用。"); return }
        guard visibleItems.contains(where: { $0.id == id }), let item = store.item(id: id) else { return }
        let target = panelTarget, frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
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
        if flags.contains(.command), let char = event.charactersIgnoringModifiers, let digit = Int(char), digit >= 1, digit <= 9 {
            withCurrentItems { [weak self] in
                guard let self, self.visibleItems.count >= digit else { return }
                self.activate(self.visibleItems[digit - 1].id, plainText: flags.contains(.shift))
            }
            return true
        }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" { focusSearch(); return true }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "p" { toggleSelectedPin(); return true }
        if flags.contains(.command), event.charactersIgnoringModifiers == "," { showSettings(); return true }
        if event.keyCode == 36 || event.keyCode == 76 {
            activateSelected(plainText: flags.contains(.shift)); return true
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
        var result = ["panel": panelShortcut, "studio": settings.studioHotkey, "screenshot": settings.screenshotHotkey]
        if settings.windowManagerEnabled {
            for (key, value) in WindowManager.defaultShortcuts.merging(settings.windowShortcuts, uniquingKeysWith: { _, new in new }) {
                if !value.isEmpty { result["window:" + key] = value }
            }
        }
        return result.filter { !$0.value.isEmpty }
    }
    nonisolated static func availableFallbacks(_ candidates: [String], bindings: [String: String]) -> [String] {
        let occupied = Set(bindings.filter { $0.key != "panel" }.values.compactMap(HotkeyChord.parse))
        var used = Set<HotkeyChord>()
        return candidates.filter {
            guard let chord = HotkeyChord.parse($0), !occupied.contains(chord) else { return false }
            return used.insert(chord).inserted
        }
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
            for fallback in Self.availableFallbacks(settings.fallbackHotkeys, bindings: bindings) {
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
        else if action == "studio" { studioWindow?.isKeyWindow == true ? hideStudio(restoreFocus: true) : showStudio() }
        else if action == "screenshot" { takeScreenshot() }
        else if action.hasPrefix("window:") { arrangeWindow(String(action.dropFirst(7))) }
    }
    func arrangeWindow(_ key: String) {
        arrangementGeneration += 1; let generation = arrangementGeneration
        windows.cancel()
        let front = NSWorkspace.shared.frontmostApplication
        let frontPID = front?.processIdentifier
        if panel?.isVisible != true, frontPID == ProcessInfo.processInfo.processIdentifier {
            guard let window = NSApp.keyWindow, window === settingsWindow || window === studioWindow else {
                report("请先选择要调整的窗口。"); return
            }
            _ = arrangeLocalWindow(window, key: key)
            return
        }
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
    @discardableResult func arrangeLocalWindow(_ window: NSWindow, key: String) -> Bool {
        guard let layout = WindowManager.layouts.first(where: { $0.id == key }), let primary = NSScreen.screens.first,
              let screen = window.screen ?? NSScreen.main else { return false }
        let axWork = WindowManager.accessibilityRect(screen.visibleFrame, primaryScreenFrame: primary.frame)
        let axFrame = WindowManager.targetRect(layout, workArea: axWork)
        guard !axFrame.isNull else { return false }
        let frame = WindowManager.accessibilityRect(axFrame, primaryScreenFrame: primary.frame)
        window.setFrame(frame, display: true)
        return true
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
    var shortcutIssues: [String: String] { ShortcutValidation.issues(in: shortcutBindings(panelShortcut: settings.hotkey)) }
    func saveSettings() {
        let issues = shortcutIssues
        guard issues.isEmpty else {
            let action = issues.keys.sorted().first!
            report(ShortcutValidation.title(for: action) + "：" + issues[action]! + "。请调整后保存。")
            return
        }
        let previousBindings = lastBindings, previousEffectiveHotkey = effectiveHotkey
        let previousFailures = failedShortcutActions
        let failures = registerShortcuts(allowFallback: false)
        guard failures.isEmpty else {
            if !testMode { _ = hotkeys.register(bindings: previousBindings) { [weak self] action in self?.performHotkey(action) } }
            report("快捷键已被占用或格式无效，设置尚未保存。"); return
        }
        do { try settings.save(); message = "设置已保存。" }
        catch {
            if !testMode { _ = hotkeys.register(bindings: previousBindings) { [weak self] action in self?.performHotkey(action) } }
            lastBindings = previousBindings; effectiveHotkey = previousEffectiveHotkey; failedShortcutActions = previousFailures
            rebuildMenu(); report("设置保存失败：" + error.localizedDescription)
        }
    }
    func setAppearance(_ appearance: String) {
        guard ["system", "light", "dark"].contains(appearance) else { return }
        do {
            _ = try AppSettings.updateSaved(.appearance(appearance), directory: store.directory)
            settings.appearance = appearance
        }
        catch { report("主题保存失败：" + error.localizedDescription) }
    }
    private func applyAppearance(_ value: String) {
        // Published emits before the stored property changes; use its new value.
        NSApp.appearance = value == "dark" ? NSAppearance(named: .darkAqua) : value == "light" ? NSAppearance(named: .aqua) : nil
    }
    func showSettings(section: String? = nil) {
        recordExternalFocus()
        refreshAccessibilityPermission()
        refreshScreenCapturePermission()
        if let section, ["clipboard", "shortcuts", "studio", "downloads", "about"].contains(section) { settingsSection = section }
        hidePanel()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Kaki Tools 设置"; window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 608)
            window.contentView = NSHostingView(rootView: NativeSettingsView(controller: self, settings: settings))
            settingsWindow = window
        }
        settingsWindow?.center(); settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showStudio() {
        recordExternalFocus()
        hidePanel()
        if studioWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Kaki Tools · Studio 素材库"; window.isReleasedWhenClosed = false; window.delegate = self
            window.minSize = NSSize(width: 700, height: 520)
            window.contentView = NSHostingView(rootView: StudioLibraryView(studio: studio,
                copyMaterial: { [weak self] asset in self?.copyStudioMaterial(asset) },
                copyReferences: { [weak self] ids in self?.copyStudioReferences(ids) },
                downloadMaterials: { [weak self] ids in self?.downloadStudioMaterials(ids) },
                openDownloadSettings: { [weak self] in self?.showSettings(section: "downloads") },
                close: { [weak self] in self?.hideStudio(restoreFocus: true) }))
            studioWindow = window
        }
        studioWindow?.center(); studioWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        studio.setLibraryActive(true)
    }
    func copyStudioMaterial(_ asset: StudioAsset) {
        studio.copyMaterial(asset, consumeImage: { [weak self] data in
            guard let self, self.clipboard.writeImage(data) != nil else { return false }
            _ = self.store.captureImage(data: data)
            self.hideStudio(restoreFocus: true)
            return true
        }, consumeFile: { [weak self] file in
            guard let self, self.clipboard.writeMaterialFile(file) != nil else { return false }
            self.hideStudio(restoreFocus: true)
            return true
        })
    }
    func setDownloadPreferences(askEachTime: Bool, folder: String) {
        do {
            _ = try AppSettings.updateSaved(.downloads(askEachTime: askEachTime, folder: folder), directory: store.directory)
            settings.downloadAskEachTime = askEachTime; settings.downloadFolder = folder
            message = "下载设置已保存。"
        } catch { report("下载设置保存失败：" + error.localizedDescription) }
    }
    func setCachePreferences(limitMB: Int, days: Int) {
        do {
            let saved = try AppSettings.updateSaved(.cachePolicy(limitMB: limitMB, days: days), directory: store.directory)
            settings.studioCacheLimitMB = saved.studioCacheLimitMB; settings.studioCacheDays = saved.studioCacheDays
            Task { await studio.configureCache(limitMB: saved.studioCacheLimitMB, days: saved.studioCacheDays) }
            message = "缓存设置已保存。"
        } catch { report("缓存设置保存失败：" + error.localizedDescription) }
    }
    func chooseCacheFolder() {
        guard !studio.mediaBusy, !studio.cacheChanging else { return }
        let panel = NSOpenPanel(); panel.title = "选择缓存磁盘或文件夹"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.prompt = "用作缓存位置"
        panel.message = "将在所选位置创建 Kaki Tools Cache 文件夹。切换位置时清理原缓存。"
        if !settings.studioCacheFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: settings.studioCacheFolder) }
        panel.begin { [weak self] response in
            guard response == .OK, let self, let folder = panel.url else { return }
            let selected = folder.resolvingSymlinksInPath()
            let volume = (try? selected.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? ""
            self.setCacheLocation(folder: selected.path, volumeUUID: volume)
        }
    }
    func setCacheLocation(folder: String, volumeUUID: String) {
        Task { [weak self] in
            guard let self else { return }
            let saved = AppSettings(directory: self.store.directory)
            if let error = saved.loadError { self.report(error); return }
            let oldFolder = saved.studioCacheFolder, oldVolume = saved.studioCacheVolumeUUID
            do {
                try await self.studio.changeCacheLocation(folder: folder, volumeUUID: volumeUUID)
                do { _ = try AppSettings.updateSaved(.cacheLocation(folder: folder, volumeUUID: volumeUUID), directory: self.store.directory) }
                catch {
                    try? await self.studio.changeCacheLocation(folder: oldFolder, volumeUUID: oldVolume)
                    throw error
                }
                self.settings.studioCacheFolder = folder; self.settings.studioCacheVolumeUUID = volumeUUID
                self.message = "缓存位置已保存。"
            } catch { self.report("缓存位置切换失败：" + error.localizedDescription) }
        }
    }
    func chooseDownloadFolder() {
        let panel = NSOpenPanel(); panel.title = "选择默认下载文件夹"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.prompt = "选择"
        if !settings.downloadFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: settings.downloadFolder) }
        panel.begin { [weak self] response in
            guard response == .OK, let self, let folder = panel.url else { return }
            self.setDownloadPreferences(askEachTime: false, folder: folder.path)
        }
    }
    func downloadStudioMaterials(_ ids: [String]) {
        guard !studio.mediaBusy, !ids.isEmpty else { return }
        let revision = studio.sessionRevision
        if !settings.downloadAskEachTime && !settings.downloadFolder.isEmpty {
            let directory = URL(fileURLWithPath: settings.downloadFolder, isDirectory: true)
            if StudioMediaFiles.isWritableDirectory(directory) { studio.download(ids: ids, to: directory); return }
            studio.setMessage("默认文件夹不可用，请重新选择下载位置。")
        }
        if ids.count == 1, let asset = studio.assets.first(where: { $0.id == ids[0] }) {
            Task { [weak self] in
                guard let self, let filename = await self.studio.suggestedFilename(asset), self.studio.sessionRevision == revision else { return }
                let panel = NSSavePanel(); panel.title = "下载素材"; panel.nameFieldStringValue = filename
                panel.begin { [weak self] response in
                    guard response == .OK, let self, self.studio.sessionRevision == revision, let file = panel.url else { return }
                    self.studio.download(asset, destination: file)
                }
            }
        } else {
            let panel = NSOpenPanel(); panel.title = "下载 \(ids.count) 项素材"
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true; panel.prompt = "下载到此处"
            panel.begin { [weak self] response in
                guard response == .OK, let self, self.studio.sessionRevision == revision, let directory = panel.url else { return }
                self.studio.download(ids: ids, to: directory)
            }
        }
    }
    func hideStudio(restoreFocus: Bool = false) {
        studio.setLibraryActive(false); studioWindow?.orderOut(nil)
        if !testMode, restoreFocus, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApp?.activate(options: [])
        }
    }
    func copyStudioReferences(_ ids: [String]) {
        guard !studio.mediaBusy else { studio.setMessage("正在读取素材，请稍候再操作。"); return }
        do {
            let text = try studio.referenceText(ids: ids)
            guard clipboard.writeStudioReferences(text) != nil else { throw StudioError.invalidResponse }
            studio.dismissMessage()
            hideStudio(restoreFocus: true)
        } catch { studio.setMessage("素材引用未能复制，请重新选择后重试。") }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === studioWindow { studio.setLibraryActive(true) }
    }
    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === studioWindow { studio.setLibraryActive(false) }
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === studioWindow { studio.setLibraryActive(false) }
    }
    func takeScreenshot(retryPermissionFailure: Bool = false) {
        guard !shuttingDown, !screenshotBusy, let screenshotRunner else { return }
        refreshScreenCapturePermission()
        // Preflight alone can lag a changed grant. Only an actual denial suppresses
        // automatic retries; an explicit settings action can still try the tool.
        if screenshotPermissionIssue && !retryPermissionFailure {
            report("屏幕权限尚未生效。已开启开关的话，请完全退出 Kaki Tools 后重新打开。")
            showSettings(section: "about")
            return
        }
        hidePanel(restoreFocus: true); settingsWindow?.orderOut(nil); hideStudio()
        screenshotBusy = true; screenshotGeneration += 1
        let generation = screenshotGeneration
        log.write("截图开始：系统预检=\(screenCaptureTrusted)，版本=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")，位置=\(Bundle.main.bundleURL.path)")
        screenshotRunner.capture { [weak self] result in
            guard let self, !self.shuttingDown, self.screenshotGeneration == generation else { return }
            self.screenshotBusy = false
            switch result {
            case .captured(let data):
                self.screenCaptureTrusted = true; self.screenshotPermissionIssue = false; self.lastScreenshotFailure = nil
                let accepted = self.store.captureImage(data: data)
                let copied = self.clipboard.writeImage(data) != nil
                self.log.write("截图完成：图片字节=\(data.count)，历史已接收=\(accepted)，剪贴板写入=\(copied)")
                if copied { self.message = accepted ? "截图已复制，正在保存到历史。" : "截图已复制；未能加入历史，请查看日志。" }
                else { self.report("截图已完成，但写入剪贴板失败，请重试。") }
            case .cancelled:
                self.log.write("区域截图已取消或未选择区域。")
            case .failed(let failure):
                self.lastScreenshotFailure = failure
                self.refreshScreenCapturePermission()
                self.log.write("截图失败：原因=\(failure.reason)，退出码=\(failure.exitStatus.map(String.init) ?? "无")，系统预检=\(self.screenCaptureTrusted)，诊断=\(failure.diagnostic)")
                if failure.isPermissionDenied {
                    self.screenshotPermissionIssue = true
                    self.report("macOS 拒绝了本次截图。请检查屏幕录制权限；已开启时，完全退出后重新打开。")
                    self.showSettings(section: "about")
                } else {
                    self.report("截图未完成。请在设置 → 权限与关于复制截图诊断，检查失败原因。")
                }
            }
        }
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
        cancelPendingClipboardActions()
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
    func refreshAccessibilityPermission() {
        let trusted = accessibilityPermissionCheck(false)
        if accessibilityTrusted != trusted { accessibilityTrusted = trusted }
    }
    func requestAccessibility() {
        _ = accessibilityPermissionCheck(true)
        refreshAccessibilityPermission()
    }
    func openAccessibilitySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    func refreshScreenCapturePermission() {
        let trusted = screenCapturePermissionCheck(false)
        let newlyGranted = trusted && !screenCaptureTrusted
        if screenCaptureTrusted != trusted { screenCaptureTrusted = trusted }
        // A grant transition can repair an earlier denial. A still-true preflight
        // must not erase an actual tool denial just by opening the settings page.
        if newlyGranted { screenshotPermissionIssue = false }
    }
    func requestScreenCapturePermission() {
        guard !shuttingDown, !screenshotBusy else { return }
        refreshScreenCapturePermission()
        guard !screenCaptureTrusted else { return }
        guard !screenCapturePermissionRequested else {
            report("本次运行已申请屏幕权限。已开启开关的话，请完全退出后重新打开。")
            return
        }
        screenCapturePermissionRequested = true
        let granted = screenCapturePermissionCheck(true)
        refreshScreenCapturePermission()
        if granted { screenCaptureTrusted = true; screenshotPermissionIssue = false }
        log.write("主动申请屏幕权限：系统返回=\(granted)，当前状态=\(screenCaptureTrusted)")
        if !screenCaptureTrusted { message = "请在屏幕录制设置中允许 Kaki Tools；已开启时，完全退出后重新打开。" }
    }
    func openScreenCaptureSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    var screenshotDiagnostics: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        var lines = ["Kaki Tools 截图诊断", "版本：\(version) (\(build))", "系统：\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "应用标识：\(Bundle.main.bundleIdentifier ?? "未打包测试进程")", "运行位置：\(Bundle.main.bundleURL.path)",
            "屏幕权限系统预检：\(screenCaptureTrusted ? "已确认" : "未确认（不等同于设置开关关闭）")",
            "本次运行主动申请权限：\(screenCapturePermissionRequested ? "是" : "否")"]
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
           let values = information as? [String: Any] {
            lines.append("签名标识：\(values[kSecCodeInfoIdentifier as String] as? String ?? "unknown")")
            lines.append("签名团队：\(values[kSecCodeInfoTeamIdentifier as String] as? String ?? "本地签名或无团队")")
            if let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first,
               let name = SecCertificateCopySubjectSummary(leaf) {
                lines.append("签名证书：\(name)")
                let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
                lines.append("证书 SHA-256：\(fingerprint)")
            }
        }
        if let failure = lastScreenshotFailure {
            lines.append("最近截图失败：\(failure.reason)，退出码 \(failure.exitStatus.map(String.init) ?? "无")")
            lines.append("系统诊断：\(failure.diagnostic)")
        } else { lines.append("最近截图失败：无记录") }
        return lines.joined(separator: "\n")
    }
    func copyScreenshotDiagnostics() {
        refreshScreenCapturePermission()
        let text = screenshotDiagnostics
        if clipboard.write(item: HistoryItem(text: text)) != nil { message = "截图诊断已复制。" }
        else { report("未能复制截图诊断，请重试。") }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; message = "开机启动设置已更新。" }
        catch { report("开机启动设置失败：" + error.localizedDescription) }
    }
    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    private func prompt(title: String, value: String, action: (String) -> Void) {
        cancelPendingClipboardActions()
        let alert = NSAlert(); alert.messageText = title
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 280, height: 26); alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { action(field.stringValue) }
    }
    private func confirm(_ title: String, detail: String) -> Bool {
        cancelPendingClipboardActions()
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.title = ""
            button.image = NativeBrand.menuImage
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "Kaki Tools · 剪贴板与窗口调整"
            button.setAccessibilityLabel("Kaki Tools")
        }
        rebuildMenu()
    }
    private func rebuildMenu() {
        guard let statusItem else { return }
        statusItem.menu = makeStatusMenu()
    }
    private func menuItem(_ title: String, selector: Selector, shortcutAction: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        if let action = shortcutAction {
            if failedShortcutActions.contains(action) {
                item.toolTip = "快捷键未注册，请在设置 → 快捷键中调整。"
            } else if let accelerator = lastBindings[action], let chord = HotkeyChord.parse(accelerator) {
                item.keyEquivalent = chord.menuKeyEquivalent
                item.keyEquivalentModifierMask = chord.menuModifierFlags
            }
        }
        return item
    }
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("打开剪贴板", selector: #selector(menuShowPanel), shortcutAction: "panel"))
        menu.addItem(menuItem("打开素材库", selector: #selector(menuShowStudio), shortcutAction: "studio"))
        let arrange = NSMenuItem(title: "调整窗口", action: nil, keyEquivalent: ""), layouts = NSMenu()
        for (index, group) in WindowManager.menuGroups.enumerated() {
            if index > 0 { layouts.addItem(.separator()) }
            for layout in WindowManager.layouts(in: group) {
                let item = menuItem(layout.label, selector: #selector(menuArrange(_:)), shortcutAction: "window:" + layout.id)
                item.representedObject = layout.id; layouts.addItem(item)
            }
        }
        arrange.submenu = layouts; menu.addItem(arrange)
        menu.addItem(menuItem("区域截图", selector: #selector(menuScreenshot), shortcutAction: "screenshot"))
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(menuSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "退出 Kaki Tools", action: #selector(menuQuit), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }
    @objc private func menuShowPanel() { showPanel() }
    @objc private func menuShowStudio() { showStudio() }
    @objc private func menuArrange(_ sender: NSMenuItem) { if let key = sender.representedObject as? String { arrangeWindow(key) } }
    @objc private func menuScreenshot() { takeScreenshot() }
    @objc private func menuSettings() { showSettings() }
    func showAbout() {
        recordExternalFocus()
        hidePanel()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let description = version + (build.map { $0 == version ? "" : " (" + $0 + ")" } ?? "") + " · 原生 macOS"
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Kaki Tools", .applicationVersion: description,
            .credits: NSAttributedString(string: "剪贴板 · 窗口调整 · 原生截图\nSwift / AppKit / SwiftUI")])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    func shutdown() {
        guard !shuttingDown else { return }; shuttingDown = true
        hidePanel()
        settingsWindow?.orderOut(nil); studioWindow?.orderOut(nil)
        pasteGeneration += 1; arrangementGeneration += 1; searchGeneration += 1; searchTask?.cancel()
        searchCancellation?.cancel(); pendingSelectionActions.removeAll()
        subscriptions.removeAll()
        presentationTickets.removeAll(); textPresentations.removeAll()
        messageClearGeneration += 1; messageClearTask?.cancel(); messageClearTask = nil
        studio.shutdown()
        dreamina.shutdown()
        clipboard.stop(); hotkeys.unregisterAll(); windows.cancel()
        screenshotGeneration += 1; screenshotRunner?.cancel(); screenshotBusy = false
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
