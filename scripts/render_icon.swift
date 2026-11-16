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
        NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.86, alpha: 1).setFill(); tile.fill()
        NSShadow().set()
        NSColor(calibratedRed: 0.82, green: 0.60, blue: 0.31, alpha: 0.30).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 253, y: 253, width: 518, height: 518)); ring.lineWidth = 37; ring.stroke()
        NSColor(calibratedRed: 0.73, green: 0.40, blue: 0.10, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 438, y: 438, width: 148, height: 148)).fill()
        NSBezierPath(ovalIn: NSRect(x: 645, y: 645, width: 128, height: 128)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
