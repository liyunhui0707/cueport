import AppKit

// Cache the existing macOS system symbol for the menu-bar indicator. This is
// an Apple-platform resource, separate from the original app-icon geometry.
guard CommandLine.arguments.count == 2,
      let symbol = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil) else {
    fatalError("The system status symbol is unavailable")
}
let image = NSImage(size: symbol.size)
var entries: [[String: Any]] = []
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(ceil(symbol.size.width * CGFloat(scale))),
        pixelsHigh: Int(ceil(symbol.size.height * CGFloat(scale))),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(scale)); transform.concat()
    symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
    NSGraphicsContext.restoreGraphicsState()
    bitmap.size = symbol.size
    image.addRepresentation(bitmap)
    let file = "status-" + String(scale) + "x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(file))
    let rect = symbol.alignmentRect
    entries.append(["idiom":"mac", "scale":String(scale)+"x", "filename":file,
        "alignment-insets": ["left": rect.minX * CGFloat(scale),
            "bottom": rect.minY * CGFloat(scale),
            "right": (symbol.size.width - rect.maxX) * CGFloat(scale),
            "top": (symbol.size.height - rect.maxY) * CGFloat(scale)]])
}
let metadata: [String:Any] = ["images":entries,"info":["version":1,"author":"xcode"],"properties":["template-rendering-intent":"template"]]
try JSONSerialization.data(withJSONObject:metadata).write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Contents.json"))
