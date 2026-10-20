// Draws the Halo app icon (dark squircle + glowing ring) into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset * 1.1, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.13, green: 0.10, blue: 0.24, alpha: 1),
                        NSColor(red: 0.03, green: 0.02, blue: 0.07, alpha: 1)])!.draw(in: squircle, angle: -90)

    let center = NSPoint(x: body.midX, y: body.midY)
    let r = body.width * 0.27
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))

    let glow = NSShadow()
    glow.shadowColor = NSColor(red: 0.55, green: 0.75, blue: 1, alpha: 1)
    glow.shadowBlurRadius = s * 0.06
    NSGraphicsContext.saveGraphicsState()
    glow.set()
    ring.lineWidth = body.width * 0.07
    NSColor(red: 0.80, green: 0.90, blue: 1, alpha: 1).setStroke()
    ring.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let dot = body.width * 0.07
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appending(path: "icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appending(path: "icon_\(size)x\(size)@2x.png"))
}
