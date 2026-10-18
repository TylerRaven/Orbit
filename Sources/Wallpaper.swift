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

/// Shared "mood" the wallpapers render from. Typing and hovering push targets; each frame eases toward them.
@MainActor
final class WallpaperMood {
    static let shared = WallpaperMood()

    struct Look { var hue: Double; var speed: Double; var intensity: Double; var scale: Double }

    // Where we're heading. `nil` hue = follow the accent color.
    private var targetHue: Double?
    private var target = Look(hue: 0, speed: 1, intensity: 1, scale: 1)
    private var hoverHue: Double?

    // What's on screen right now.
    private(set) var current = Look(hue: 0.6, speed: 1, intensity: 1, scale: 1)
    private(set) var phase = 0.0
    private(set) var energy = 0.0
    private var lastFrame: Date?
    private var lastResult: (look: Look, phase: Double, energy: Double)?

    /// Called each frame by the wallpaper and the ambient glow; returns the eased look plus the
    /// accumulated phase. Several views can call it in the same frame without speeding it up.
    func step(now: Date, baseHue: Double, reactive: Bool) -> (look: Look, phase: Double, energy: Double) {
        if let lastFrame, let lastResult, abs(now.timeIntervalSince(lastFrame)) < 0.004 { return lastResult }
        let dt = min(1.0 / 20, now.timeIntervalSince(lastFrame ?? now))
        lastFrame = now

        let goalHue = reactive ? (hoverHue ?? targetHue ?? baseHue) : baseHue
        let goal = reactive ? target : Look(hue: 0, speed: 1, intensity: 1, scale: 1)
        let k = 1 - exp(-dt * 2.5)

        current.hue = Self.lerpHue(current.hue, goalHue, k)
        current.speed += (goal.speed - current.speed) * k
        current.intensity += (goal.intensity - current.intensity) * k
        current.scale += (goal.scale - current.scale) * k
        energy *= exp(-dt * 1.6)

        phase += dt * current.speed * (1 + energy * 2.2)
        var look = current
        look.intensity *= 1 + energy * 0.35
        look.scale *= 1 + energy * 0.12
        lastResult = (look, phase, energy)
        return (look, phase, energy)
    }

    /// Drops any typed mood so the colors follow the page again (e.g. after opening a site).
    func settle() {
        targetHue = nil
        hoverHue = nil
        target = Look(hue: 0, speed: 1, intensity: 1, scale: 1)
    }

    static func siteHue(_ host: String) -> Double {
        keywordMood(host.lowercased())?.hue ?? hashHue(host)
    }

    /// Feed in whatever the user is typing.
    func react(to text: String) {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        energy = min(energy + 0.45, 1.8)
        guard !t.isEmpty else {
            targetHue = nil
            target = Look(hue: 0, speed: 1, intensity: 1, scale: 1)
            return
        }
        if let mood = Self.keywordMood(t) {
            targetHue = mood.hue
            target = mood
            return
        }
        // No keyword: every string still gets its own look, so typing feels alive.
        var h: UInt64 = 1_469_598_103_934_665_603
        for b in t.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        targetHue = Double(h % 360) / 360
        target = Look(hue: 0,
                      speed: 0.6 + Double((h >> 12) % 100) / 100 * 1.3,
                      intensity: 0.75 + Double((h >> 24) % 100) / 100 * 0.5,
                      scale: 0.85 + Double((h >> 36) % 100) / 100 * 0.4)
    }

    /// Hovering a link previews that site's color.
    func hover(host: String?) {
        guard let host else { hoverHue = nil; return }
        energy = min(energy + 0.25, 1.8)
        hoverHue = Self.keywordMood(host.lowercased())?.hue ?? Self.hashHue(host)
    }

    func pulse(_ amount: Double = 0.6) {
        energy = min(energy + amount, 1.8)
    }

    static func hashHue(_ s: String) -> Double {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
        return Double(h % 360) / 360
    }

    private static let moods: [(words: [String], look: Look)] = [
        (["fire", "lava", "hot", "burn", "angry", "rage"], Look(hue: 0.02, speed: 2.0, intensity: 1.25, scale: 1.15)),
        (["youtube", "netflix", "red"], Look(hue: 0.0, speed: 1.3, intensity: 1.1, scale: 1.05)),
        (["sunset", "summer", "peach", "orange", "reddit", "amazon"], Look(hue: 0.06, speed: 1.0, intensity: 1.1, scale: 1.1)),
        (["gold", "sun", "yellow", "honey", "banana"], Look(hue: 0.13, speed: 1.0, intensity: 1.1, scale: 1.0)),
        (["forest", "nature", "green", "leaf", "spotify", "grass"], Look(hue: 0.36, speed: 0.8, intensity: 1.0, scale: 1.05)),
        (["ocean", "sea", "water", "rain", "wave", "blue"], Look(hue: 0.56, speed: 0.6, intensity: 0.95, scale: 1.2)),
        (["twitter", "x.com", "facebook", "linkedin"], Look(hue: 0.58, speed: 0.9, intensity: 1.0, scale: 1.0)),
        (["storm", "thunder", "chaos", "hyper", "fast", "speed"], Look(hue: 0.66, speed: 3.2, intensity: 1.35, scale: 0.9)),
        (["discord", "twitch", "purple", "galaxy", "space", "night", "star"], Look(hue: 0.74, speed: 0.55, intensity: 1.05, scale: 1.1)),
        (["github", "code", "dev", "terminal"], Look(hue: 0.78, speed: 0.7, intensity: 0.85, scale: 0.95)),
        (["love", "pink", "cute", "heart", "instagram", "tiktok"], Look(hue: 0.93, speed: 1.1, intensity: 1.1, scale: 1.05)),
        (["chill", "calm", "sleep", "lofi", "relax", "zen"], Look(hue: 0.62, speed: 0.25, intensity: 0.7, scale: 1.25)),
    ]

    private static func keywordMood(_ text: String) -> Look? {
        for mood in moods where mood.words.contains(where: { text.contains($0) }) {
            return mood.look
        }
        return nil
    }

    private static func lerpHue(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var d = b - a
        if d > 0.5 { d -= 1 } else if d < -0.5 { d += 1 }
        let r = a + d * t
        return r < 0 ? r + 1 : (r >= 1 ? r - 1 : r)
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
        let h = look.hue
        let v = 0.55 * strength * look.intensity
        let shift = 0.06 * sin(phase * 0.5)
        let colors: [Color] = [
            hsb(h - 0.08, 0.9, v * 0.5), hsb(h, 0.85, v * 0.8), hsb(h + 0.08 + shift, 0.9, v * 0.6), hsb(h + 0.15, 0.9, v * 0.4),
            hsb(h + 0.05, 0.8, v * 0.7), hsb(h + shift, 0.75, v * 1.2), hsb(h + 0.12, 0.8, v * 1.1), hsb(h - 0.05, 0.9, v * 0.6),
            hsb(h + 0.5, 0.6, v * 0.35), hsb(h - 0.1 - shift, 0.85, v * 0.9), hsb(h + 0.02, 0.9, v * 1.0), hsb(h + 0.2, 0.8, v * 0.5),
            hsb(h, 0.9, v * 0.2), hsb(h + 0.1, 0.9, v * 0.35), hsb(h - 0.05, 0.9, v * 0.3), hsb(h + 0.15, 0.9, v * 0.2),
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
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(hsb(look.hue, 0.9, 0.12)))
            ctx.blendMode = .plusLighter
            let side = max(size.width, size.height)
            for i in 0..<7 {
                let fi = Double(i)
                let speed = 0.35 + fi * 0.07
                let x = size.width * (0.5 + 0.38 * sin(phase * speed + fi * 1.9))
                let y = size.height * (0.5 + 0.34 * cos(phase * speed * 0.8 + fi * 2.7))
                let r = side * (0.22 + 0.06 * sin(phase * 0.6 + fi)) * look.scale
                let color = hsb(look.hue + Double(i % 3) * 0.06 - 0.06, 0.85,
                                0.55 * strength * look.intensity)
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
                     with: .radialGradient(Gradient(colors: [hsb(look.hue, 0.8, 0.35 * strength * look.intensity), .clear]),
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
                let tint = hsb(look.hue + (i % 5 == 0 ? 0.08 : 0), i % 3 == 0 ? 0.5 : 0.15, 1)
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
