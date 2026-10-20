import AppKit

/// Two coordinate systems meet in this app:
///  • "Quartz" (global, top-left origin of the main display, y grows down) — used by
///    screenshots, mouse/keyboard events and the Accessibility API.
///  • "Cocoa" (global, bottom-left origin of the main display, y grows up) — used by windows.
/// Everything the AI sees and draws is in Quartz; windows get converted at the edge.
enum Geo {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cocoa(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func quartz(_ r: CGRect) -> CGRect { cocoa(r) } // the flip is its own inverse

    static func cocoa(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
    static func quartz(_ p: CGPoint) -> CGPoint { cocoa(p) }

    /// The mouse, in Quartz coordinates.
    static var mouse: CGPoint { quartz(NSEvent.mouseLocation) }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// The screen containing a Cocoa point (falls back to the main screen).
    static func screen(containing p: CGPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    func overlapArea(_ other: CGRect) -> CGFloat {
        let i = intersection(other)
        return i.isNull ? 0 : i.width * i.height
    }
    func distance(to other: CGRect) -> CGFloat {
        let dx = max(0, max(other.minX - maxX, minX - other.maxX))
        let dy = max(0, max(other.minY - maxY, minY - other.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }
}
