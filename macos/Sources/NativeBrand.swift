import AppKit

// Shared geometric K for the menu bar and application icon. The panel keeps its KAKI wordmark.
enum NativeBrand {
    static let menuMarkRect = NSRect(x: 2.4375, y: 1.5, width: 13.125, height: 14)
    static func markPath(in rect: NSRect) -> NSBezierPath {
        let points: [(CGFloat, CGFloat)] = [
            (0, 0), (16, 0), (16, 24), (40, 0), (60, 0), (28, 32),
            (60, 64), (40, 64), (16, 40), (16, 64), (0, 64),
        ]
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let position = NSPoint(x: rect.minX + point.0 / 60 * rect.width,
                                   y: rect.minY + point.1 / 64 * rect.height)
            if index == 0 { path.move(to: position) } else { path.line(to: position) }
        }
        path.close()
        return path
    }

    static let menuImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            // Center the ink itself, with a half-point optical adjustment down.
            markPath(in: menuMarkRect).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Kaki Tools"
        return image
    }()
}
