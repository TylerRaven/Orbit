// Draws the Orbit app icon (black squircle + ringed planet) into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func ringPath(center: NSPoint, width: CGFloat, height: CGFloat, angle: CGFloat, front: Bool) -> NSBezierPath {
    // Half of a tilted ellipse: the front half passes in front of the planet.
    let path = NSBezierPath()
    path.appendArc(withCenter: .zero, radius: 1, startAngle: front ? 180 : 0, endAngle: front ? 360 : 180)
    var t = AffineTransform()
    t.translate(x: center.x, y: center.y)
    t.rotate(byDegrees: angle)
    t.scale(x: width / 2, y: height / 2)
    path.transform(using: t)
    return path
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // macOS icon grid: 824/1024 body with a soft shadow.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset * 1.1, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(white: 0.20, alpha: 1),
        NSColor(white: 0.02, alpha: 1),
    ])!.draw(in: squircle, angle: -90)

    let center = NSPoint(x: body.midX, y: body.midY)
    let ringW = body.width * 0.74, ringH = body.width * 0.25, tilt: CGFloat = 22
    let lineW = body.width * 0.05

    let back = ringPath(center: center, width: ringW, height: ringH, angle: tilt, front: false)
    back.lineWidth = lineW
    back.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.7).setStroke()
    back.stroke()

    let r = body.width * 0.19
    let planet = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    NSColor.white.setFill()
    planet.fill()

    let front = ringPath(center: center, width: ringW, height: ringH, angle: tilt, front: true)
    front.lineWidth = lineW
    front.lineCapStyle = .round
    NSColor.white.setStroke()
    front.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
