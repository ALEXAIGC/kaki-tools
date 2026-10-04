import AppKit
import ApplicationServices

struct WindowLayout: Identifiable {
    enum Group: String, CaseIterable, Identifiable {
        case halves, quarters, thirds, other
        var id: String { rawValue }
        var settingsTitle: String {
            switch self { case .halves: return "半屏"; case .quarters: return "四分屏"; case .thirds: return "三分屏"; case .other: return "其他布局" }
        }
    }
    let id: String
    let label: String
    let fractions: [Double]
    let group: Group
    let defaultShortcut: String
    var settingsLabel: String { id == "maximize" ? "铺满窗口" : label }
    init(id: String, label: String, fractions: [Double], group: Group = .other, defaultShortcut: String = "") {
        self.id = id; self.label = label; self.fractions = fractions; self.group = group; self.defaultShortcut = defaultShortcut
    }
}

struct WindowScreenArea {
    let frame: CGRect
    let workArea: CGRect
}

struct WindowRequestTicket {
    let generation: UInt64
    let deadline: TimeInterval
}

// Cancellation must take effect immediately, even while the serial AX queue is
// waiting for a slow application. The monotonic clock is independent of wall time.
final class WindowRequestGate {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func begin(timeout: TimeInterval) -> WindowRequestTicket {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return WindowRequestTicket(generation: generation, deadline: now() + (timeout.isFinite ? max(0, timeout) : 0))
    }

    func cancel() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func isCurrent(_ ticket: WindowRequestTicket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard ticket.generation == generation else { return false }
        guard now() < ticket.deadline else { generation &+= 1; return false }
        return true
    }
}

final class WindowManager {
    static let layouts: [WindowLayout] = [
        WindowLayout(id: "left-half", label: "左半屏", fractions: [0, 0, 0.5, 1], group: .halves, defaultShortcut: "Control+Alt+Left"),
        WindowLayout(id: "right-half", label: "右半屏", fractions: [0.5, 0, 0.5, 1], group: .halves, defaultShortcut: "Control+Alt+Right"),
        WindowLayout(id: "top-half", label: "上半屏", fractions: [0, 0, 1, 0.5], group: .halves, defaultShortcut: "Control+Alt+Up"),
        WindowLayout(id: "bottom-half", label: "下半屏", fractions: [0, 0.5, 1, 0.5], group: .halves, defaultShortcut: "Control+Alt+Down"),
        WindowLayout(id: "top-left", label: "左上 1/4", fractions: [0, 0, 0.5, 0.5], group: .quarters, defaultShortcut: "Control+Alt+U"),
        WindowLayout(id: "top-right", label: "右上 1/4", fractions: [0.5, 0, 0.5, 0.5], group: .quarters, defaultShortcut: "Control+Alt+I"),
        WindowLayout(id: "bottom-left", label: "左下 1/4", fractions: [0, 0.5, 0.5, 0.5], group: .quarters, defaultShortcut: "Control+Alt+J"),
        WindowLayout(id: "bottom-right", label: "右下 1/4", fractions: [0.5, 0.5, 0.5, 0.5], group: .quarters, defaultShortcut: "Control+Alt+K"),
        WindowLayout(id: "left-third", label: "左 1/3", fractions: [0, 0, 1.0 / 3, 1], group: .thirds, defaultShortcut: "Control+Alt+D"),
        WindowLayout(id: "center-third", label: "中 1/3", fractions: [1.0 / 3, 0, 1.0 / 3, 1], group: .thirds, defaultShortcut: "Control+Alt+F"),
        WindowLayout(id: "right-third", label: "右 1/3", fractions: [2.0 / 3, 0, 1.0 / 3, 1], group: .thirds, defaultShortcut: "Control+Alt+G"),
        WindowLayout(id: "left-two-thirds", label: "左 2/3", fractions: [0, 0, 2.0 / 3, 1], group: .thirds, defaultShortcut: "Control+Alt+E"),
        WindowLayout(id: "right-two-thirds", label: "右 2/3", fractions: [1.0 / 3, 0, 2.0 / 3, 1], group: .thirds, defaultShortcut: "Control+Alt+T"),
        WindowLayout(id: "maximize", label: "最大化", fractions: [0, 0, 1, 1], group: .other, defaultShortcut: "Control+Alt+Return"),
        WindowLayout(id: "center", label: "居中", fractions: [0.125, 0.1, 0.75, 0.8], group: .other, defaultShortcut: "Control+Alt+C"),
    ]

    static let defaultShortcuts = Dictionary(uniqueKeysWithValues: layouts.map { ($0.id, $0.defaultShortcut) })
    static let menuGroups: [WindowLayout.Group] = [.other, .halves, .quarters, .thirds]
    static func layouts(in group: WindowLayout.Group) -> [WindowLayout] { layouts.filter { $0.group == group } }

    var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "com.openclaw.kakitools.windows", qos: .userInitiated)
    private let gate = WindowRequestGate()
    private let operationTimeout: TimeInterval
    private static let messageTimeout: Float = 0.2

    init(operationTimeout: TimeInterval = 2) {
        self.operationTimeout = operationTimeout
    }

    static func accessibilityTrusted(prompt: Bool = false) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
    }

    // AppKit has a bottom-left origin. AX uses the primary display's top-left;
    // using the union of every display would shift coordinates on stacked screens.
    static func accessibilityRect(_ rect: CGRect, primaryScreenFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    static func targetRect(_ layout: WindowLayout, workArea: CGRect) -> CGRect {
        let f = layout.fractions
        guard f.count == 4, f.allSatisfy({ $0.isFinite }), f[2] > 0, f[3] > 0,
              !workArea.isNull, !workArea.isInfinite,
              [workArea.minX, workArea.minY, workArea.width, workArea.height].allSatisfy({ $0.isFinite }),
              workArea.width > 0, workArea.height > 0 else { return .null }
        return CGRect(x: (workArea.minX + CGFloat(f[0]) * workArea.width).rounded(),
                      y: (workArea.minY + CGFloat(f[1]) * workArea.height).rounded(),
                      width: (CGFloat(f[2]) * workArea.width).rounded(),
                      height: (CGFloat(f[3]) * workArea.height).rounded())
    }

    static func matchingScreen(for window: CGRect, screens: [WindowScreenArea]) -> WindowScreenArea? {
        var best: WindowScreenArea?
        var bestArea: CGFloat = -1
        var bestDistance = CGFloat.infinity
        for screen in screens {
            let intersection = window.intersection(screen.frame)
            let area = intersection.isNull ? 0 : max(0, intersection.width * intersection.height)
            let x = min(max(window.midX, screen.frame.minX), screen.frame.maxX)
            let y = min(max(window.midY, screen.frame.minY), screen.frame.maxY)
            let distance = pow(window.midX - x, 2) + pow(window.midY - y, 2)
            if area > bestArea || (area == bestArea && distance < bestDistance) {
                best = screen
                bestArea = area
                bestDistance = distance
            }
        }
        return best
    }

    func cancel() { gate.cancel() }

    func arrange(_ key: String, targetPID: pid_t? = nil) {
        guard let layout = Self.layouts.first(where: { $0.id == key }) else { return }
        let ticket = gate.begin(timeout: operationTimeout)
        let captureScreens = { [weak self] in
            guard let self, self.gate.isCurrent(ticket), let primary = NSScreen.screens.first else { return }
            let screens = NSScreen.screens.map {
                WindowScreenArea(frame: Self.accessibilityRect($0.frame, primaryScreenFrame: primary.frame),
                                 workArea: Self.accessibilityRect($0.visibleFrame, primaryScreenFrame: primary.frame))
            }
            self.queue.async { [weak self] in
                self?.execute(layout, targetPID: targetPID, screens: screens, ticket: ticket)
            }
        }
        if Thread.isMainThread { captureScreens() }
        else { DispatchQueue.main.async(execute: captureScreens) }
    }

    private func report(_ message: String, ticket: WindowRequestTicket) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.gate.isCurrent(ticket) else { return }
            self.onError?(message)
        }
    }

    private func execute(_ layout: WindowLayout, targetPID: pid_t?, screens: [WindowScreenArea], ticket: WindowRequestTicket) {
        guard gate.isCurrent(ticket) else { return }
        guard Self.accessibilityTrusted() else {
            report("请在系统设置 → 隐私与安全性 → 辅助功能中允许 Kaki Tools 调整窗口。", ticket: ticket)
            return
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != getpid(), targetPID == nil || targetPID == pid else { return }
        guard let window = Self.focusedWindow(pid: pid), let frame = Self.windowRect(window) else {
            report("无法读取当前应用窗口；该应用可能不支持系统窗口调整。", ticket: ticket)
            return
        }
        guard let screen = Self.matchingScreen(for: frame, screens: screens) else { return }
        let target = Self.targetRect(layout, workArea: screen.workArea)
        guard !target.isNull, target.width > 0, target.height > 0 else { return }
        var size = target.size
        var position = target.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let positionValue = AXValueCreate(.cgPoint, &position) else { return }
        var sizeSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable)
        let setSize = sizeSettable.boolValue

        // Revalidate PID and the same AX reference before every write, including
        // after the preceding application's reply stalled. Never target a new window.
        var sizeError = AXError.success
        if setSize {
            guard stillFocused(window, pid: pid, ticket: ticket) else { return }
            sizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        guard stillFocused(window, pid: pid, ticket: ticket) else { return }
        let positionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        // Moving between displays can change the application's minimum size.
        if setSize {
            guard stillFocused(window, pid: pid, ticket: ticket) else { return }
            sizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        guard gate.isCurrent(ticket) else { return }
        if sizeError != .success || positionError != .success {
            report("该窗口无法完成调整（系统错误 \(sizeError.rawValue)/\(positionError.rawValue)）。", ticket: ticket)
        }
    }

    private func stillFocused(_ window: AXUIElement, pid: pid_t, ticket: WindowRequestTicket) -> Bool {
        guard gate.isCurrent(ticket), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = Self.focusedWindow(pid: pid), CFEqual(focused, window) else { return false }
        return gate.isCurrent(ticket) && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messageTimeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, messageTimeout)
        return window
    }

    private static func windowRect(_ window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
