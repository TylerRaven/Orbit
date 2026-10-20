import AppKit
import ScreenCaptureKit

/// One look at the screen, sized for the model, plus the maths to map the model's
/// image coordinates back onto the real screen.
struct Snapshot {
    let jpegBase64: String
    let imageSize: CGSize        // pixels of the image the model sees
    let displayBounds: CGRect    // the captured display, in Quartz points
    let thumb: [UInt8]           // tiny greyscale copy, for spotting changes
    let takenAt = Date()

    func toScreen(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: displayBounds.minX + x * displayBounds.width / imageSize.width,
                y: displayBounds.minY + y * displayBounds.height / imageSize.height)
    }
    func toScreen(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        let a = toScreen(x, y), b = toScreen(x + w, y + h)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }
    func toImage(_ p: CGPoint) -> (Int, Int) {
        (Int(((p.x - displayBounds.minX) * imageSize.width / displayBounds.width).rounded()),
         Int(((p.y - displayBounds.minY) * imageSize.height / displayBounds.height).rounded()))
    }
    func toImage(_ r: CGRect) -> (Int, Int, Int, Int) {
        let a = toImage(r.origin), b = toImage(CGPoint(x: r.maxX, y: r.maxY))
        return (a.0, a.1, b.0 - a.0, b.1 - a.1)
    }

    /// 0…1: how different two looks are.
    func difference(from other: Snapshot) -> Double {
        guard thumb.count == other.thumb.count, !thumb.isEmpty else { return 1 }
        var total = 0
        for i in thumb.indices { total += abs(Int(thumb[i]) - Int(other.thumb[i])) }
        return Double(total) / Double(thumb.count * 255)
    }
}

enum Eyes {
    enum Failure: Error { case noPermission, noDisplay }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Captures the display the user is on. Halo's own windows (chat, popups, drawings)
    /// are left out so the model sees the screen as it really is.
    static func look(maxWidth: CGFloat = 1280, grid: Bool = true) async throws -> Snapshot {
        guard hasPermission else { throw Failure.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let id = await MainActor.run { Geo.displayID(of: Geo.screen(containing: NSEvent.mouseLocation)) }
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw Failure.noDisplay
        }
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])

        let bounds = CGDisplayBounds(display.displayID)
        let scale = min(1, maxWidth / bounds.width)
        let config = SCStreamConfiguration()
        config.width = Int(bounds.width * scale)
        config.height = Int(bounds.height * scale)
        config.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let size = CGSize(width: image.width, height: image.height)
        let thumb = thumbnail(image)
        let jpeg = encode(image, grid: grid)
        return Snapshot(jpegBase64: jpeg.base64EncodedString(), imageSize: size, displayBounds: bounds, thumb: thumb)
    }

    /// JPEG for the model. A faint labelled grid helps small models give accurate coordinates.
    private static func encode(_ image: CGImage, grid: Bool) -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        if grid, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let step: CGFloat = 100
            let line = NSColor(red: 1, green: 0.1, blue: 0.6, alpha: 0.28)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor(red: 1, green: 0.1, blue: 0.6, alpha: 0.85),
                .backgroundColor: NSColor.white.withAlphaComponent(0.6),
            ]
            line.setStroke()
            var x: CGFloat = step
            while x < w {
                let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: 0)); p.line(to: NSPoint(x: x, y: h)); p.lineWidth = 1; p.stroke()
                ("\(Int(x))" as NSString).draw(at: NSPoint(x: x + 2, y: h - 14), withAttributes: attrs)
                x += step
            }
            var y: CGFloat = step
            while y < h {
                // Bitmap contexts draw bottom-up; the label shows the top-down y the model should use.
                let p = NSBezierPath(); p.move(to: NSPoint(x: 0, y: h - y)); p.line(to: NSPoint(x: w, y: h - y)); p.lineWidth = 1; p.stroke()
                ("\(Int(y))" as NSString).draw(at: NSPoint(x: 2, y: h - y + 1), withAttributes: attrs)
                y += step
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) ?? Data()
    }

    private static func thumbnail(_ image: CGImage) -> [UInt8] {
        let w = 48, h = 30
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }
}
