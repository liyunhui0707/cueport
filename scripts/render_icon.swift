import AppKit

// Original vector geometry, rasterized by AppKit for the macOS app bundle.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = AffineTransform(scale: factor)
        let affine = NSAffineTransform(transform: transform); affine.concat()
        NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
        let tile = NSBezierPath(roundedRect: NSRect(x: 74, y: 74, width: 876, height: 876), xRadius: 205, yRadius: 205)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.16); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        NSColor(calibratedRed: 0.965, green: 0.937, blue: 0.894, alpha: 1).setFill(); tile.fill()
        NSShadow().set()
        // Original Cueport mark: an open C-shaped port and an incoming cue.
        let markScale = NSAffineTransform(); markScale.scale(by: 1024 / 96); markScale.concat()
        NSColor(srgbRed: 0.110, green: 0.333, blue: 0.322, alpha: 1).setStroke()
        let port = NSBezierPath()
        port.appendArc(withCenter: NSPoint(x: 46, y: 48), radius: 24, startAngle: 45, endAngle: 315)
        port.lineWidth = 8.5; port.lineCapStyle = .round; port.stroke()
        NSColor(srgbRed: 0.835, green: 0.541, blue: 0.208, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 71, y: 42.5, width: 11, height: 11)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
