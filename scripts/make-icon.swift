import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let shape = NSBezierPath(roundedRect: NSRect(x: 74, y: 74, width: 876, height: 876), xRadius: 192, yRadius: 192)
        NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.21, blue: 0.34, alpha: 1),
                   ending: NSColor(calibratedRed: 0.035, green: 0.065, blue: 0.14, alpha: 1))!.draw(in: shape, angle: -90)
        for (index, y) in [420.0, 638.0, 500.0, 330.0, 575.0].enumerated() {
            let x = 262 + Double(index) * 125
            NSColor.white.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 8, y: 270, width: 16, height: 484), xRadius: 8, yRadius: 8).fill()
            NSColor(calibratedRed: 0.20, green: 0.68, blue: 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 8, y: 270, width: 16, height: y - 270), xRadius: 8, yRadius: 8).fill()
            NSColor(calibratedRed: 0.87, green: 0.96, blue: 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 37, y: y - 22, width: 74, height: 44), xRadius: 14, yRadius: 14).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
