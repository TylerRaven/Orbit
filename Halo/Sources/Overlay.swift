import AppKit
import SwiftUI

/// Something Halo has drawn on the screen. Positions are Quartz screen points.
struct Mark: Identifiable {
    enum Kind {
        case highlight(CGRect)          // soft see-through fill
        case box(CGRect)                // crisp rectangle
        case outline(CGRect)            // glowing rounded outline
        case path([CGPoint])            // freehand line
        case arrow(CGPoint, CGPoint)
        case text(CGPoint, String)      // writing on the screen
        case target(CGPoint)            // "I'm about to click here"
    }
    let id = UUID()
    var kind: Kind
    var color: Color
    var label: String?
    var created = Date()
    var lifetime: TimeInterval?         // nil = stays until cleared

    var bounds: CGRect {
        switch kind {
        case .highlight(let r), .box(let r), .outline(let r): return r
        case .path(let pts):
            let xs = pts.map(\.x), ys = pts.map(\.y)
            return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        case .arrow(let a, let b): return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        case .text(let p, let s): return CGRect(x: p.x, y: p.y, width: CGFloat(s.count) * 11, height: 30)
        case .target(let p): return CGRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48)
        }
    }

    static func color(named name: String?, default fallback: Color) -> Color {
        switch name?.lowercased() {
        case "red": .red
        case "green": .green
        case "blue": .blue
        case "yellow": .yellow
        case "orange": .orange
        case "purple": .purple
        case "pink": .pink
        case "white": .white
        case "cyan", "teal": .cyan
        default: fallback
        }
    }
}

@MainActor
@Observable
final class Overlay {
    static let shared = Overlay()

    var marks: [Mark] = []
    @ObservationIgnored private var windows: [NSWindow] = []

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Overlay.shared.rebuildWindows() }
        }
    }

    func start() {
        rebuildWindows()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { Overlay.shared.expire() }
        }
    }

    @discardableResult
    func add(_ kind: Mark.Kind, color: Color, label: String? = nil, lifetime: TimeInterval? = 30) -> UUID {
        let m = Mark(kind: kind, color: color, label: label, lifetime: lifetime)
        marks.append(m)
        syncReserved()
        return m.id
    }

    func remove(_ id: UUID?) {
        guard let id else { return }
        marks.removeAll { $0.id == id }
        syncReserved()
    }

    func clear() {
        marks.removeAll()
        syncReserved()
    }

    private func expire() {
        let now = Date()
        let before = marks.count
        marks.removeAll { m in m.lifetime.map { now.timeIntervalSince(m.created) > $0 } ?? false }
        if marks.count != before { syncReserved() }
    }

    /// Halo's own windows keep clear of whatever it's pointing at.
    private func syncReserved() {
        Focus.shared.reserved = marks.map(\.bounds)
    }

    private func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            let quartzOrigin = CGDisplayBounds(Geo.displayID(of: screen)).origin
            w.contentView = NSHostingView(rootView: OverlayCanvas(origin: quartzOrigin))
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            return w
        }
    }
}

/// Draws every mark on one screen, with a little animation as each appears.
private struct OverlayCanvas: View {
    let origin: CGPoint
    private var overlay = Overlay.shared

    init(origin: CGPoint) { self.origin = origin }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: overlay.marks.isEmpty)) { tl in
            Canvas { ctx, _ in
                for m in overlay.marks { draw(m, in: &ctx, now: tl.date) }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - origin.x, y: p.y - origin.y) }
    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

    private func draw(_ m: Mark, in ctx: inout GraphicsContext, now: Date) {
        let age = now.timeIntervalSince(m.created)
        let appear = min(1, age / 0.45)                       // 0→1 while it draws on
        let eased = 1 - pow(1 - appear, 3)
        var fade = 1.0
        if let life = m.lifetime { fade = max(0, min(1, (life - age) / 0.6)) } // fades out at the end
        ctx.opacity = fade

        switch m.kind {
        case .highlight(let r):
            let rr = local(r).insetBy(dx: -4, dy: -3)
            let shape = Path(roundedRect: rr, cornerRadius: 5)
            ctx.fill(shape, with: .color(m.color.opacity(0.32 * eased)))
            ctx.fill(Path(roundedRect: CGRect(x: rr.minX, y: rr.maxY - 3, width: rr.width * eased, height: 3), cornerRadius: 1.5),
                     with: .color(m.color.opacity(0.8)))
            label(m, at: CGPoint(x: rr.minX, y: rr.minY - 6), in: &ctx)

        case .box(let r):
            let rr = local(r)
            ctx.stroke(Path(rr).trimmedPath(from: 0, to: eased), with: .color(m.color), style: StrokeStyle(lineWidth: 3, lineJoin: .miter))
            label(m, at: CGPoint(x: rr.minX, y: rr.minY - 6), in: &ctx)

        case .outline(let r):
            let rr = local(r).insetBy(dx: -6, dy: -6)
            let path = Path(roundedRect: rr, cornerRadius: 10).trimmedPath(from: 0, to: eased)
            let pulse = 0.65 + 0.35 * sin(age * 3)
            var glow = ctx
            glow.addFilter(.blur(radius: 8))
            glow.stroke(path, with: .color(m.color.opacity(0.9 * pulse)), lineWidth: 8)
            ctx.stroke(path, with: .color(m.color), lineWidth: 2.5)
            label(m, at: CGPoint(x: rr.minX, y: rr.minY - 6), in: &ctx)

        case .path(let pts):
            guard let first = pts.first else { return }
            var p = Path()
            p.move(to: local(first))
            for pt in pts.dropFirst() { p.addLine(to: local(pt)) }
            ctx.stroke(p.trimmedPath(from: 0, to: min(1, age / 0.9)), with: .color(m.color),
                       style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            label(m, at: local(first).applying(.init(translationX: 0, y: -10)), in: &ctx)

        case .arrow(let a0, let b0):
            let a = local(a0), b = local(b0)
            let tip = CGPoint(x: a.x + (b.x - a.x) * eased, y: a.y + (b.y - a.y) * eased)
            var p = Path(); p.move(to: a); p.addLine(to: tip)
            let ang = atan2(b.y - a.y, b.x - a.x)
            for side in [-1.0, 1.0] {
                p.move(to: tip)
                p.addLine(to: CGPoint(x: tip.x - 16 * cos(ang + side * 0.5), y: tip.y - 16 * sin(ang + side * 0.5)))
            }
            ctx.stroke(p, with: .color(m.color), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            label(m, at: CGPoint(x: a.x, y: a.y - 8), in: &ctx)

        case .text(let pt, let s):
            // Typed onto the screen one letter at a time.
            let shown = String(s.prefix(Int(age * 40) + 1))
            let text = ctx.resolve(Text(shown).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(m.color))
            let size = text.measure(in: CGSize(width: 600, height: 400))
            let origin = local(pt)
            let bg = CGRect(x: origin.x - 8, y: origin.y - 5, width: size.width + 16, height: size.height + 10)
            ctx.fill(Path(roundedRect: bg, cornerRadius: 9), with: .color(.black.opacity(0.62)))
            ctx.draw(text, in: CGRect(origin: origin, size: size))

        case .target(let p0):
            let p = local(p0)
            let pulse = (age.truncatingRemainder(dividingBy: 1.2)) / 1.2
            let r1 = 10 + 22 * pulse
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r1, y: p.y - r1, width: r1 * 2, height: r1 * 2)),
                       with: .color(m.color.opacity(1 - pulse)), lineWidth: 3)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(m.color))
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(.white), lineWidth: 2)
            label(m, at: CGPoint(x: p.x + 16, y: p.y - 14), in: &ctx)
        }
    }

    private func label(_ m: Mark, at p: CGPoint, in ctx: inout GraphicsContext) {
        guard let s = m.label, !s.isEmpty else { return }
        let text = ctx.resolve(Text(s).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
        let size = text.measure(in: CGSize(width: 400, height: 100))
        let r = CGRect(x: p.x, y: p.y - size.height - 4, width: size.width + 12, height: size.height + 6)
        ctx.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(m.color.opacity(0.92)))
        ctx.draw(text, in: CGRect(x: r.minX + 6, y: r.minY + 3, width: size.width, height: size.height))
    }
}
