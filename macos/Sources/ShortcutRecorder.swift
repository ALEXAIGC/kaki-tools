import SwiftUI
import AppKit

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: String
    var onRecordingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutField {
        let field = ShortcutField()
        field.accelerator = value
        field.onRecord = { value = $0 }
        field.onRecordingChanged = onRecordingChanged
        return field
    }
    func updateNSView(_ view: ShortcutField, context: Context) {
        view.onRecord = { value = $0 }
        view.onRecordingChanged = onRecordingChanged
        view.accelerator = value
        view.isEnabled = context.environment.isEnabled
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: proposal.height ?? nsView.intrinsicContentSize.height)
    }
    static func dismantleNSView(_ view: ShortcutField, coordinator: ()) { view.cancelRecording() }
}

private final class ShortcutFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        // cellSize includes bezel padding; center the actual text line instead.
        let height = min(result.height, attributedStringValue.size().height)
        result.origin.y += (result.height - height) / 2
        result.size.height = height
        return result
    }
}

@MainActor final class ShortcutField: NSTextField {
    var onRecord: ((String) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private(set) var isRecording = false
    private var windowObservers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private weak var observedWindow: NSWindow?
    var accelerator = "" {
        didSet {
            guard accelerator != oldValue else { return }
            // An external edit (for example, Disable or Restore Defaults) ends
            // recording before another key can overwrite that edit.
            if isRecording { cancelRecording() }
            else { showValue() }
        }
    }
    override var isEnabled: Bool {
        didSet {
            if !isEnabled { cancelRecording() }
            if !isRecording { showValue() }
        }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = ShortcutFieldCell(textCell: "")
        isEditable = false; isSelectable = false; alignment = .center
        isBezeled = true; bezelStyle = .roundedBezel; focusRingType = .exterior
        usesSingleLineMode = true; lineBreakMode = .byTruncatingTail
        setAccessibilityRole(.button)
        setAccessibilityLabel("快捷键录制")
        setAccessibilityHelp("点击或用 Tab 选中后，按下组合键。Esc 取消，Delete 清除。")
        toolTip = "点击后按下组合键；Esc 取消，Delete 清除"
        showValue()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 40) }
    override var acceptsFirstResponder: Bool { isEnabled }

    private func showValue() {
        font = .systemFont(ofSize: 18, weight: .medium)
        textColor = isEnabled ? .labelColor : .disabledControlTextColor
        if let chord = HotkeyChord.parse(accelerator) {
            let label = chord.label
            let symbols: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
            let modifiers = label.prefix(while: { symbols.contains($0) }).map(String.init)
            stringValue = (modifiers + [String(label.dropFirst(modifiers.count))]).joined(separator: " ")
        } else { stringValue = accelerator.isEmpty ? "点击设置" : accelerator }
        setAccessibilityValue(stringValue)
    }
    private func showPrompt(_ hint: String = "按下组合键…") {
        font = .systemFont(ofSize: hint == "按下组合键…" ? 16 : 13, weight: .medium)
        textColor = .labelColor
        stringValue = hint
        setAccessibilityValue(hint)
    }
    override func becomeFirstResponder() -> Bool {
        guard isEnabled, super.becomeFirstResponder() else { return false }
        guard !isRecording else { return true }
        isRecording = true; showPrompt()
        // The window/menu key-equivalent path runs before keyDown. Intercept
        // only this recording field's window, leaving other windows untouched.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.isRecording, event.window === self.window,
                      self.window?.firstResponder === self else { return false }
                self.keyDown(with: event)
                return true
            }
            return consumed ? nil : event
        }
        onRecordingChanged?(true)
        return true
    }
    private func finishRecording(value: String? = nil) {
        guard isRecording else { return }
        isRecording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let value { accelerator = value; onRecord?(value) }
        showValue(); onRecordingChanged?(false)
    }
    func cancelRecording() {
        finishRecording()
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }
    static func cancelRecording(in window: NSWindow?) {
        (window?.firstResponder as? ShortcutField)?.cancelRecording()
    }
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        finishRecording(); return true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if observedWindow !== window { finishRecording() }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll(); observedWindow = window
        guard let window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if name != NSWindow.didChangeOcclusionStateNotification || window?.isVisible == false { self?.cancelRecording() }
                }
            })
        }
    }
    deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        if isRecording { showPrompt() }
    }
    override func accessibilityPerformPress() -> Bool { isEnabled && (window?.makeFirstResponder(self) ?? false) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self, event.window === window, event.type == .keyDown else { return false }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard isRecording, isEnabled, event.type == .keyDown else { return }
        if event.keyCode == 53 { cancelRecording(); return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if (event.keyCode == 51 || event.keyCode == 117), flags.isEmpty {
            finishRecording(value: ""); window?.makeFirstResponder(nil); return
        }
        if event.keyCode == 48, flags.intersection([.command, .control, .option]).isEmpty {
            finishRecording()
            if flags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }
        let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        guard !flags.intersection([.command, .control, .option]).isEmpty || functionKeys.contains(event.keyCode) else {
            showPrompt("请同时按 ⌘、⌃ 或 ⌥"); return
        }
        guard let chord = HotkeyChord.from(event: event) else { showPrompt("此按键暂不支持，请重试"); return }
        finishRecording(value: chord.accelerator); window?.makeFirstResponder(nil)
    }
}
