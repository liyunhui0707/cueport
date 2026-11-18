import AppKit

@main struct Check {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        guard let bundle = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1])),
              let cached = bundle.image(forResource: "AARStatusIndicator"), cached.isTemplate,
              cached.size == NSSize(width: 22, height: 18) else {
            fatalError("Packaged Cueport status template is missing, incorrectly sized or not a template")
        }
        var checks: [[String: Int]] = []
        for scale in [1, 2] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 22 * scale,
                pixelsHigh: 18 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let transform = NSAffineTransform(); transform.scale(by: CGFloat(scale)); transform.concat()
            cached.draw(in: NSRect(origin: .zero, size: cached.size)); NSGraphicsContext.restoreGraphicsState()
            func alpha(_ x: Int, _ y: Int) -> Int { Int(bitmap.bitmapData![y * bitmap.bytesPerRow + x * 4 + 3]) }
            let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
            guard (0..<width).allSatisfy({ alpha($0, 0) == 0 && alpha($0, height - 1) == 0 }),
                  (0..<height).allSatisfy({ alpha(0, $0) == 0 && alpha(width - 1, $0) == 0 }),
                  alpha(8 * scale, 9 * scale) == 0,
                  alpha(18 * scale, 9 * scale) > 200 else { fatalError("Cueport status mark is clipped or its port/cue is missing") }
            let count = (0..<height).reduce(0) { total, y in total + (0..<width).filter { alpha($0, y) > 127 }.count }
            guard count > 50 * scale * scale && count < 160 * scale * scale else { fatalError("Cueport status mark has unexpected coverage") }
            checks.append(["scale": scale, "opaque_pixels": count])
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["template": true, "size": "22x18", "checks": checks], options: [.sortedKeys]), as: UTF8.self))
    }
}
