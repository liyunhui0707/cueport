import AppKit

// Original monochrome Cueport glyph, with explicit native 1x/2x templates.
let size = NSSize(width: 22, height: 18)
var entries: [[String: Any]] = []
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 22 * scale,
        pixelsHigh: 18 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(scale)); transform.concat()
    NSColor.black.setStroke(); NSColor.black.setFill()
    let port = NSBezierPath()
    port.appendArc(withCenter: NSPoint(x: 8.3, y: 9), radius: 6.1, startAngle: 45, endAngle: 315)
    port.lineWidth = 2.3; port.lineCapStyle = .round; port.stroke()
    NSBezierPath(ovalIn: NSRect(x: 16.7, y: 7.2, width: 3.6, height: 3.6)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let file = "status-" + String(scale) + "x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(file))
    entries.append(["idiom":"mac", "scale":String(scale)+"x", "filename":file])
}
let metadata: [String:Any] = ["images":entries,"info":["version":1,"author":"xcode"],"properties":["template-rendering-intent":"template"]]
try JSONSerialization.data(withJSONObject:metadata).write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Contents.json"))
