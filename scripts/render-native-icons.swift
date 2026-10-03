import AppKit

@main struct RenderNativeIcons {
    static func bitmap(size: Int, draw: () -> Void) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.imageInterpolation = .high
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(size) / 1024); transform.concat()
        draw()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    static func applicationIcon() {
        let tile = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832), xRadius: 186, yRadius: 186)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 22; shadow.shadowOffset = NSSize(width: 0, height: -8); shadow.set()
        NSColor(calibratedWhite: 0.1, alpha: 1).setFill(); tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(calibratedRed: 0.15, green: 0.17, blue: 0.19, alpha: 1),
                   ending: NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.08, alpha: 1))!
            .draw(in: tile, angle: -90)
        tile.lineWidth = 2; NSColor.white.withAlphaComponent(0.10).setStroke(); tile.stroke()
        let mark = NativeBrand.markPath(in: NSRect(x: 278, y: 262, width: 468.75, height: 500))
        NSGradient(starting: NSColor(calibratedRed: 1, green: 0.54, blue: 0.16, alpha: 1),
                   ending: NSColor(calibratedRed: 1, green: 0.34, blue: 0.015, alpha: 1))!
            .draw(in: mark, angle: -90)
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileWriteInvalidFileName) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = output.appendingPathComponent("Kaki Tools.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                let data = try bitmap(size: points * scale, draw: applicationIcon)
                try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
            }
        }
        try bitmap(size: 256, draw: applicationIcon).write(to: output.appendingPathComponent("app-icon-preview.png"))
        // Enlarged ink preview of the same menu-bar drawing, on light and dark.
        for (name, background, foreground) in [("light", NSColor.white, NSColor.black),
                                               ("dark", NSColor(calibratedWhite: 0.12, alpha: 1), NSColor.white)] {
            let data = try bitmap(size: 256) {
                background.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
                let transform = NSAffineTransform()
                transform.translateX(by: 242, yBy: 242); transform.scale(by: 30); transform.concat()
                foreground.setFill()
                NativeBrand.markPath(in: NativeBrand.menuMarkRect).fill()
            }
            try data.write(to: output.appendingPathComponent("menu-icon-\(name).png"))
        }
    }
}
