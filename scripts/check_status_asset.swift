import AppKit

@main struct Check {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let source = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)!
        let cached = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1]))!.image(forResource: "AARStatusIndicator")!
        let catalogTemplate = cached.isTemplate
        cached.isTemplate = true
        func pixels(_ image: NSImage, _ scale: Int) -> NSBitmapImageRep {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(source.size.width * CGFloat(scale))),
                pixelsHigh: Int(ceil(source.size.height * CGFloat(scale))), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let transform = NSAffineTransform(); transform.scale(by: CGFloat(scale)); transform.concat()
            image.draw(in: NSRect(origin: .zero, size: source.size)); NSGraphicsContext.restoreGraphicsState()
            return bitmap
        }
        var comparisons: [[String: Int]] = []
        for scale in [1, 2] {
            let a = pixels(source, scale), b = pixels(cached, scale)
            var changed = 0, maximum = 0
            for y in 0..<a.pixelsHigh { for x in 0..<a.pixelsWide {
                let delta = abs(Int(a.bitmapData![y*a.bytesPerRow+x*4+3])-Int(b.bitmapData![y*b.bytesPerRow+x*4+3]))
                if delta > 0 { changed += 1 }; maximum = max(maximum, delta)
            }}
            comparisons.append(["scale": scale, "different_alpha_pixels": changed, "maximum_alpha_difference": maximum])
        }
        guard source.size == cached.size, source.alignmentRect == cached.alignmentRect,
              catalogTemplate, comparisons.allSatisfy({ $0["different_alpha_pixels"] == 0 }) else {
            fatalError("Packaged status template differs from its source glyph, alignment or scale")
        }
        let result: [String: Any] = ["source_size": NSStringFromSize(source.size), "cached_size": NSStringFromSize(cached.size),
            "source_alignment": NSStringFromRect(source.alignmentRect), "cached_alignment": NSStringFromRect(cached.alignmentRect),
            "catalog_template_metadata": catalogTemplate, "comparisons": comparisons]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self))
    }
}
