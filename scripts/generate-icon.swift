import AppKit
import Foundation

// Original Nearby artwork, drawn entirely with public AppKit vector APIs.
let destination = CommandLine.arguments.dropFirst().first ?? "Nearby.iconset"
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func drawIcon(pixels: Int, fileName: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 34
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()
    NSGradient(starting: color(0.94, 0.98, 1), ending: color(0.42, 0.65, 0.98))!.draw(in: tile, angle: -70)
    NSGraphicsContext.restoreGraphicsState()
    color(1, 1, 1, 0.72).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    // Clear, rounded screen silhouette with a light glint and subtle depth.
    let phone = NSBezierPath(roundedRect: NSRect(x: 308, y: 204, width: 320, height: 616), xRadius: 64, yRadius: 64)
    NSGraphicsContext.saveGraphicsState()
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowColor = color(0.05, 0.15, 0.32, 0.30)
    shadow.set()
    color(0.11, 0.20, 0.34).setFill()
    phone.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(1, 1, 1, 0.65).setStroke()
    phone.lineWidth = 3
    phone.stroke()
    let screen = NSBezierPath(roundedRect: NSRect(x: 322, y: 220, width: 292, height: 584), xRadius: 51, yRadius: 51)
    NSGradient(starting: color(0.78, 0.94, 1), ending: color(0.08, 0.37, 0.86))!.draw(in: screen, angle: -55)
    NSGraphicsContext.saveGraphicsState()
    screen.addClip()
    let halo = NSBezierPath(ovalIn: NSRect(x: 420, y: 175, width: 360, height: 440))
    NSGradient(starting: color(0.68, 0.91, 1, 0.9), ending: color(0.20, 0.54, 0.96, 0.15))!.draw(in: halo, angle: 20)
    let reflection = NSBezierPath()
    reflection.move(to: NSPoint(x: 320, y: 640))
    reflection.curve(to: NSPoint(x: 630, y: 410), controlPoint1: NSPoint(x: 500, y: 730), controlPoint2: NSPoint(x: 500, y: 490))
    reflection.line(to: NSPoint(x: 630, y: 820))
    reflection.line(to: NSPoint(x: 320, y: 820))
    reflection.close()
    color(1, 1, 1, 0.18).setFill()
    reflection.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0.08, 0.16, 0.29).setFill()
    NSBezierPath(ovalIn: NSRect(x: 458, y: 779, width: 20, height: 20)).fill()

    // Two concise wireless arcs communicate the connection without a badge.
    for radius: CGFloat in [65, 112] {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: 648, y: 508), radius: radius, startAngle: -48, endAngle: 48)
        arc.lineCapStyle = .round
        arc.lineWidth = 22
        color(1, 1, 1, 0.96).setStroke()
        arc.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent(fileName))
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(pixels: size, fileName: "icon_\(size)x\(size).png")
    try drawIcon(pixels: size * 2, fileName: "icon_\(size)x\(size)@2x.png")
}
