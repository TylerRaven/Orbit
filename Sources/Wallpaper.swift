import AppKit
import SwiftUI

enum WallpaperStyle: String, CaseIterable, Identifiable {
    case aurora, lava, warp, solid, image
    var id: String { rawValue }

    var label: String {
        switch self {
        case .aurora: "Aurora"
        case .lava: "Lava"
        case .warp: "Warp"
        case .solid: "Solid"
        case .image: "Photo"
        }
    }

    var symbol: String {
        switch self {
        case .aurora: "wind"
        case .lava: "drop.fill"
        case .warp: "sparkles"
        case .solid: "square.fill"
        case .image: "photo"
        }
    }

    var isAnimated: Bool { self == .aurora || self == .lava || self == .warp }
}

/// Shared "mood" the wallpapers and glows render from. Its color follows the site you're on
/// (or the link you hover), and changes crossfade with an ease-in-out curve.
@MainActor
final class WallpaperMood {
    static let shared = WallpaperMood()

    struct Look {
        var fromHue: Double
        var toHue: Double
        /// 0…1, already eased.
        var blend: Double
        var intensity: Double
        var scale: Double

        /// A color in the current palette, offset `dh` around the wheel, mid-fade if a change is underway.
        func color(_ dh: Double, _ s: Double, _ b: Double) -> Color {
            let to = hsb(toHue + dh, s, b)
            guard blend < 1 else { return to }
            return hsb(fromHue + dh, s, b).mix(with: to, by: blend, in: .perceptual)
        }

        /// Single hue for the current mix, for starting the next fade from where this one is.
        var visibleHue: Double {
            guard blend < 1 else { return toHue }
            let mixed = NSColor(color(0, 0.8, 1)).usingColorSpace(.sRGB)
            return mixed.map { Double($0.hueComponent) } ?? toHue
        }
    }

    private static let fadeDuration = 1.3

    private var hoverHue: Double?
    private var fromHue = 0.6
    private var toHue = 0.6
    private var fadeStart: Date?
    private var started = false

    private(set) var phase = 0.0
    private(set) var energy = 0.0
    private var lastFrame: Date?
    private var lastResult: (look: Look, phase: Double, energy: Double)?

    /// Called each frame by the wallpaper and the ambient glow; several callers in the same frame share one step.
    func step(now: Date, baseHue: Double, reactive: Bool) -> (look: Look, phase: Double, energy: Double) {
        if let lastFrame, let lastResult, abs(now.timeIntervalSince(lastFrame)) < 0.004 { return lastResult }
        let dt = min(1.0 / 20, now.timeIntervalSince(lastFrame ?? now))
        lastFrame = now

        let goal = reactive ? (hoverHue ?? baseHue) : baseHue
        if !started {
            fromHue = goal; toHue = goal; started = true
        } else if Self.distance(goal, toHue) > 0.004 {
            fromHue = currentLook(now).visibleHue
            toHue = goal
            fadeStart = now
        }

        energy *= exp(-dt * 1.6)
        phase += dt * (1 + energy * 2.2)

        var look = currentLook(now)
        look.intensity = 1 + energy * 0.35
        look.scale = 1 + energy * 0.12
        lastResult = (look, phase, energy)
        return (look, phase, energy)
    }

    private func currentLook(_ now: Date) -> Look {
        var t = 1.0
        if let fadeStart {
            let x = min(1, now.timeIntervalSince(fadeStart) / Self.fadeDuration)
            t = x * x * (3 - 2 * x) // smoothstep: eases in and out
            if x >= 1 { self.fadeStart = nil; fromHue = toHue }
        }
        return Look(fromHue: fromHue, toHue: toHue, blend: t, intensity: 1, scale: 1)
    }

    /// Clears any hover preview so the colors follow the page again.
    func settle() {
        hoverHue = nil
    }

    /// Hovering a link previews that site's color.
    func hover(host: String?) {
        guard let host else { hoverHue = nil; return }
        hoverHue = Self.siteHue(host)
    }

    /// A burst of energy, e.g. when a page finishes opening.
    func pulse(_ amount: Double = 0.6) {
        energy = min(energy + amount, 1.8)
    }

    static func siteHue(_ host: String) -> Double {
        let h = host.lowercased()
        return siteHues.first { entry in entry.words.contains { h.contains($0) } }?.hue ?? hashHue(host)
    }

    static func hashHue(_ s: String) -> Double {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
        return Double(h % 360) / 360
    }

    private static let siteHues: [(words: [String], hue: Double)] = [
        (["youtube", "netflix"], 0.0),
        (["reddit", "amazon", "soundcloud"], 0.06),
        (["spotify", "whatsapp", "duolingo"], 0.38),
        (["twitter", "x.com", "facebook", "linkedin", "bsky", "paypal"], 0.58),
        (["google"], 0.6),
        (["discord", "twitch"], 0.7),
        (["github", "notion", "apple"], 0.76),
        (["instagram", "tiktok", "pinterest", "dribbble"], 0.93),
    ]

    private static func distance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }
}

// MARK: - Renderer

struct LiveWallpaper: View {
    let style: WallpaperStyle
    let accent: Accent
    let intensity: Double
    let reactive: Bool
    let imagePath: String

    var body: some View {
        switch style {
        case .solid:
            Color(nsColor: .windowBackgroundColor)
                .overlay(RadialGradient(colors: [accent.color.opacity(0.18), .clear],
                                        center: .top, startRadius: 0, endRadius: 520))
        case .image:
            if let image = WallpaperImage.load(imagePath) {
                Image(nsImage: image).resizable().scaledToFill()
                    .overlay(Color.black.opacity(0.18))
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        default:
            TimelineView(.animation) { ctx in
                let frame = WallpaperMood.shared.step(now: ctx.date, baseHue: accent.hue, reactive: reactive)
                Group {
                    switch style {
                    case .aurora: Aurora(look: frame.look, phase: frame.phase, strength: intensity)
                    case .lava: Lava(look: frame.look, phase: frame.phase, strength: intensity)
                    default: Warp(look: frame.look, phase: frame.phase, energy: frame.energy, strength: intensity)
                    }
                }
            }
            .background(Color.black)
        }
    }
}

private func hsb(_ hue: Double, _ s: Double, _ b: Double) -> Color {
    var h = hue.truncatingRemainder(dividingBy: 1)
    if h < 0 { h += 1 }
    return Color(hue: h, saturation: min(1, max(0, s)), brightness: min(1, max(0, b)))
}

/// Flowing mesh gradient, like northern lights.
private struct Aurora: View {
    let look: WallpaperMood.Look
    let phase: Double
    let strength: Double

    var body: some View { mesh() }

    private func mesh() -> MeshGradient {
        let t = Float(phase)
        let a = Float(0.09 * look.scale)
        func wobble(_ x: Float, _ y: Float, _ i: Float) -> SIMD2<Float> {
            SIMD2(x + sin(t * 0.9 + i * 1.7) * a, y + cos(t * 0.7 + i * 2.3) * a)
        }
        let points: [SIMD2<Float>] = [
            [0, 0], [0.33, 0], [0.66, 0], [1, 0],
            [0, 0.33], wobble(0.33, 0.33, 1), wobble(0.66, 0.33, 2), [1, 0.33],
            [0, 0.66], wobble(0.33, 0.66, 3), wobble(0.66, 0.66, 4), [1, 0.66],
            [0, 1], [0.33, 1], [0.66, 1], [1, 1],
        ]
        let c = look.color
        let v = 0.55 * strength * look.intensity
        let shift = 0.06 * sin(phase * 0.5)
        let colors: [Color] = [
            c(-0.08, 0.9, v * 0.5), c(0, 0.85, v * 0.8), c(0.08 + shift, 0.9, v * 0.6), c(0.15, 0.9, v * 0.4),
            c(0.05, 0.8, v * 0.7), c(shift, 0.75, v * 1.2), c(0.12, 0.8, v * 1.1), c(-0.05, 0.9, v * 0.6),
            c(0.5, 0.6, v * 0.35), c(-0.1 - shift, 0.85, v * 0.9), c(0.02, 0.9, v * 1.0), c(0.2, 0.8, v * 0.5),
            c(0, 0.9, v * 0.2), c(0.1, 0.9, v * 0.35), c(-0.05, 0.9, v * 0.3), c(0.15, 0.9, v * 0.2),
        ]
        return MeshGradient(width: 4, height: 4, points: points, colors: colors, smoothsColors: true)
    }
}

/// Soft glowing blobs drifting around and blending into each other.
private struct Lava: View {
    let look: WallpaperMood.Look
    let phase: Double
    let strength: Double

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(look.color(0, 0.9, 0.12)))
            ctx.blendMode = .plusLighter
            let side = max(size.width, size.height)
            for i in 0..<7 {
                let fi = Double(i)
                let speed = 0.35 + fi * 0.07
                let x = size.width * (0.5 + 0.38 * sin(phase * speed + fi * 1.9))
                let y = size.height * (0.5 + 0.34 * cos(phase * speed * 0.8 + fi * 2.7))
                let r = side * (0.22 + 0.06 * sin(phase * 0.6 + fi)) * look.scale
                let color = look.color(Double(i % 3) * 0.06 - 0.06, 0.85, 0.55 * strength * look.intensity)
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect),
                         with: .radialGradient(Gradient(colors: [color, color.opacity(0)]),
                                               center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
            }
        }
    }
}

/// Stars rushing past; typing kicks it into hyperspace.
private struct Warp: View {
    let look: WallpaperMood.Look
    let phase: Double
    let energy: Double
    let strength: Double

    private static let stars: [(x: Double, y: Double, z: Double)] = {
        var rng = SystemRandomNumberGenerator()
        return (0..<420).map { _ in
            (Double.random(in: -1...1, using: &rng), Double.random(in: -1...1, using: &rng),
             Double.random(in: 0...1, using: &rng))
        }
    }()

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let glowR = max(size.width, size.height) * 0.6 * look.scale
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR, width: glowR * 2, height: glowR * 2)),
                     with: .radialGradient(Gradient(colors: [look.color(0, 0.8, 0.35 * strength * look.intensity), .clear]),
                                           center: c, startRadius: 0, endRadius: glowR))

            let travel = phase * 0.25
            let streak = 0.012 + energy * 0.05
            for (i, s) in Self.stars.enumerated() {
                var z = (s.z - travel).truncatingRemainder(dividingBy: 1)
                if z <= 0 { z += 1 }
                let z2 = min(1, z + streak)
                let p1 = CGPoint(x: c.x + s.x / z * c.x * 0.5, y: c.y + s.y / z * c.y * 0.5)
                let p2 = CGPoint(x: c.x + s.x / z2 * c.x * 0.5, y: c.y + s.y / z2 * c.y * 0.5)
                let alpha = min(1, (1 - z) * 1.4) * strength
                let tint = look.color(i % 5 == 0 ? 0.08 : 0, i % 3 == 0 ? 0.5 : 0.15, 1)
                var line = Path()
                line.move(to: p2)
                line.addLine(to: p1)
                ctx.stroke(line, with: .color(tint.opacity(alpha)), lineWidth: max(0.6, (1 - z) * 2.4 * look.scale))
            }
        }
    }
}

enum WallpaperImage {
    private static var cache: (path: String, image: NSImage)?

    static func load(_ path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let cache, cache.path == path { return cache.image }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache = (path, image)
        return image
    }

    /// Lets the user pick a photo and copies it into Orbit's support folder.
    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let src = panel.url else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("wallpaper-\(UUID().uuidString.prefix(6)).\(src.pathExtension)")
        guard (try? FileManager.default.copyItem(at: src, to: dest)) != nil else { return nil }
        cache = nil
        return dest.path
    }
}

extension Accent {
    var hue: Double {
        switch self {
        case .blue: 0.61
        case .purple: 0.73
        case .pink: 0.93
        case .orange: 0.07
        case .green: 0.42
        case .graphite: 0.62
        }
    }
}
