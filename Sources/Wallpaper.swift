import AppKit
import SwiftUI

enum WallpaperStyle: String, CaseIterable, Identifiable {
    case sonic, aurora, lava, warp, solid, image
    var id: String { rawValue }

    var label: String {
        switch self {
        case .sonic: "Sonic"
        case .aurora: "Aurora"
        case .lava: "Lava"
        case .warp: "Warp"
        case .solid: "Solid"
        case .image: "Photo"
        }
    }

    var symbol: String {
        switch self {
        case .sonic: "waveform.circle"
        case .aurora: "wind"
        case .lava: "drop.fill"
        case .warp: "sparkles"
        case .solid: "square.fill"
        case .image: "photo"
        }
    }

    var isAnimated: Bool { self == .sonic || self == .aurora || self == .lava || self == .warp }
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
    private var lastBeats = 0
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
        let music = MusicListener.shared.snapshot()
        if music.beats != lastBeats {
            lastBeats = music.beats
            pulse(0.4)
        }
        energy = max(energy, Double(music.bass) * 0.5)
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
        pulse(0.5)
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
                    case .sonic: Sonic(look: frame.look, phase: frame.phase, strength: intensity,
                                       music: MusicListener.shared.snapshot())
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

/// A ring of Liquid Glass that breathes on its own and swells with whatever is playing.
/// It's real macOS glass, so it bends the colored light drifting behind it; loose glass drops
/// live in the same container, so the system melts them into the ring and pulls them apart like liquid.
private struct Sonic: View {
    let look: WallpaperMood.Look
    let phase: Double
    let strength: Double
    let music: MusicListener.Snapshot

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side * 0.24 * look.scale * (1 + Double(music.bass) * 0.06)
            let levels = Self.smooth(music.levels)
            let bass = Double(music.bass)
            let c = look.color

            ZStack {
                c(0, 0.7, 0.05)

                // Colored lights behind the glass, for it to refract. Music brightens them.
                Canvas { ctx, size in
                    ctx.blendMode = .plusLighter
                    let mid = CGPoint(x: size.width / 2, y: size.height / 2)
                    for i in 0..<5 {
                        let fi = Double(i)
                        let p = CGPoint(x: mid.x + cos(phase * 0.23 + fi * 1.3) * radius * 0.9,
                                        y: mid.y + sin(phase * 0.31 + fi * 2.1) * radius * 0.9)
                        let r = radius * (0.9 + 0.25 * sin(phase * 0.4 + fi))
                        let col = c(Double(i % 3) * 0.06 - 0.05, 0.85, (0.5 + bass * 0.6) * strength)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                 with: .radialGradient(Gradient(colors: [col, .clear]), center: p,
                                                       startRadius: 0, endRadius: r))
                    }
                }

                // Sand: grains of light that settle onto the pattern's quiet lines, like cymatics.
                Canvas { ctx, size in
                    let mid = CGPoint(x: size.width / 2, y: size.height / 2)
                    let field = ParticleField.shared
                    field.step(music: music, levels: levels)
                    ctx.blendMode = .plusLighter
                    let inner = radius * 0.86
                    for p in field.particles {
                        let speed = min(1, p.speed * 40)
                        let dot = 1.1 + speed * 1.6
                        let x = mid.x + p.x * inner, y = mid.y + p.y * inner
                        let col = c(speed * 0.08 - 0.02, 0.55 - speed * 0.3, (0.55 + speed * 0.45) * strength)
                        ctx.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)),
                                 with: .color(col.opacity(0.55 + speed * 0.45)))
                    }
                }

                GlassEffectContainer(spacing: radius * 0.14) {
                    ZStack {
                        GlassRing(levels: levels, phase: phase, radius: radius)
                            .fill(.clear)
                            .glassEffect(.clear.tint(c(0, 0.6, 0.85).opacity(0.18 + bass * 0.2)),
                                         in: GlassRing(levels: levels, phase: phase, radius: radius))

                        ForEach(0..<9, id: \.self) { i in
                            let drop = Self.drop(i, phase: phase, radius: radius, bass: bass)
                            Circle()
                                .fill(.clear)
                                .frame(width: drop.size, height: drop.size)
                                .glassEffect(.clear.tint(c(0.04, 0.6, 0.9).opacity(0.22)), in: Circle())
                                .offset(x: drop.offset.x, y: drop.offset.y)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                // Fresnel rim: a thin bright line where light grazes the glass edges,
                // with a faint red/blue split (dispersion) like real glass.
                ZStack {
                    GlassRing(levels: levels, phase: phase, radius: radius)
                        .stroke(Color(red: 1, green: 0.25, blue: 0.3).opacity(0.28), lineWidth: 1)
                        .offset(x: -1.2, y: -0.6)
                    GlassRing(levels: levels, phase: phase, radius: radius)
                        .stroke(Color(red: 0.2, green: 0.6, blue: 1).opacity(0.28), lineWidth: 1)
                        .offset(x: 1.2, y: 0.6)
                    GlassRing(levels: levels, phase: phase, radius: radius)
                        .stroke(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.15), .white.opacity(0.5)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 0.9)
                }
                .blendMode(.plusLighter)
                .allowsHitTesting(false)

                // A soft halo so the ring glows into the dark.
                GlassRing(levels: levels, phase: phase, radius: radius)
                    .stroke(c(0, 0.7, 1).opacity((0.25 + Double(music.loudness) * 0.5) * strength), lineWidth: 2)
                    .blur(radius: radius * 0.08)
                    .blendMode(.plusLighter)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Loose drops orbiting near the ring: they drift out, split off, and melt back in.
    private static func drop(_ i: Int, phase: Double, radius: Double, bass: Double) -> (offset: CGPoint, size: Double) {
        let fi = Double(i)
        let dir: Double = i % 2 == 0 ? 1 : -1
        let theta = phase * 0.16 * dir + fi * 0.7
        let dist = radius * (1 + 0.24 * sin(phase * 0.55 + fi * 1.9))
        let size = radius * (0.11 + 0.05 * sin(phase * 0.9 + fi) + bass * 0.06)
        return (CGPoint(x: cos(theta) * dist, y: sin(theta) * dist), size)
    }

    static func smooth(_ raw: [Float]) -> [Double] {
        var levels = raw.map(Double.init)
        for _ in 0..<3 {
            levels = levels.indices.map { i in
                (levels[max(0, i - 1)] + levels[i] * 2 + levels[min(levels.count - 1, i + 1)]) / 4
            }
        }
        return levels
    }
}

/// Cymatics: particles slide toward the still lines of a vibrating plate, F(r, θ) = cos(nθ)·sin(mπr).
/// Pitch picks the pattern (m rings, n spokes), loudness shakes the grains, and beats throw them outward.
@MainActor
final class ParticleField {
    static let shared = ParticleField()

    struct Particle { var x: Double; var y: Double; var vx = 0.0; var vy = 0.0; var speed = 0.0 }

    private(set) var particles: [Particle]
    private var m = 2.0, n = 4.0
    private var lastBeats = 0
    private var lastStep: Date?

    private init() {
        var rng = SystemRandomNumberGenerator()
        particles = (0..<1600).map { _ in
            let r = sqrt(Double.random(in: 0...1, using: &rng)) * 0.95
            let a = Double.random(in: 0...(2 * .pi), using: &rng)
            return Particle(x: r * cos(a), y: r * sin(a))
        }
    }

    func step(music: MusicListener.Snapshot, levels: [Double]) {
        let now = Date()
        let dt = min(1.0 / 20, now.timeIntervalSince(lastStep ?? now))
        lastStep = now
        guard dt > 0 else { return }

        // Where the sound sits picks the pattern: bassy = few rings, bright = many spokes.
        let total = max(0.0001, levels.reduce(0, +))
        let centroid = levels.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element } / total / Double(max(1, levels.count - 1))
        let treble = levels.suffix(levels.count / 3).reduce(0, +) / total
        let targetM = 1.5 + centroid * 4
        let targetN = 2 + (treble * 12).rounded()
        m += (targetM - m) * min(1, dt * 0.8)
        n += (targetN - n) * min(1, dt * 0.8)

        let loud = Double(music.loudness)
        let kick = music.beats != lastBeats
        lastBeats = music.beats
        let jitter = 0.002 + loud * 0.03
        let pull = 2.4

        for i in particles.indices {
            var p = particles[i]
            let r = max(0.0001, (p.x * p.x + p.y * p.y).squareRoot())
            let a = atan2(p.y, p.x)

            // Slide down the gradient of F² toward the still (nodal) lines.
            let f = cos(n * a) * sin(m * .pi * r)
            let dfdr = cos(n * a) * m * .pi * cos(m * .pi * r)
            let dfda = -n * sin(n * a) * sin(m * .pi * r) / r
            let gr = 2 * f * dfdr, ga = 2 * f * dfda
            let gx = gr * cos(a) - ga * sin(a)
            let gy = gr * sin(a) + ga * cos(a)
            p.vx += -gx * pull * dt + Double.random(in: -jitter...jitter)
            p.vy += -gy * pull * dt + Double.random(in: -jitter...jitter)

            // A beat throws the sand outward.
            if kick {
                let push = 0.012 + Double(music.bass) * 0.03
                p.vx += cos(a) * push * Double.random(in: 0.4...1)
                p.vy += sin(a) * push * Double.random(in: 0.4...1)
            }

            p.vx *= 0.86
            p.vy *= 0.86
            p.x += p.vx
            p.y += p.vy

            // Stay inside the ring.
            let nr = (p.x * p.x + p.y * p.y).squareRoot()
            if nr > 0.97 {
                p.x *= 0.97 / nr
                p.y *= 0.97 / nr
                p.vx *= -0.3
                p.vy *= -0.3
            }
            p.speed = (p.vx * p.vx + p.vy * p.vy).squareRoot()
            particles[i] = p
        }
    }
}

/// A wobbly band: outer and inner edges follow the music, wound opposite ways so the middle is a hole.
private struct GlassRing: Shape {
    let levels: [Double]
    let phase: Double
    let radius: Double

    func path(in rect: CGRect) -> Path {
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        let n = 160
        func level(_ theta: Double) -> Double {
            let u = theta < .pi ? theta / .pi : (2 * .pi - theta) / .pi
            let pos = u * Double(levels.count - 1)
            let k = min(levels.count - 2, Int(pos))
            return levels[k] + (levels[k + 1] - levels[k]) * (pos - Double(k))
        }
        func point(_ i: Int, outer: Bool) -> CGPoint {
            let theta = Double(i % n) / Double(n) * 2 * .pi
            let lv = level(theta)
            let center = radius * (1 + 0.045 * sin(theta * 3 + phase * 0.5) + 0.025 * sin(theta * 5 - phase * 0.7) + lv * 0.08)
            let half = radius * (0.07 + lv * 0.07 + 0.015 * sin(theta * 4 + phase * 0.9))
            let r = outer ? center + half : center - half
            return CGPoint(x: mid.x + cos(theta - .pi / 2) * r, y: mid.y + sin(theta - .pi / 2) * r)
        }
        var path = Path()
        path.move(to: point(0, outer: true))
        for i in 1...n { path.addLine(to: point(i, outer: true)) }
        path.closeSubpath()
        path.move(to: point(0, outer: false))
        for i in stride(from: n, through: 0, by: -1) { path.addLine(to: point(i, outer: false)) }
        path.closeSubpath()
        return path
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
        case .teal: 0.53
        case .purple: 0.73
        case .pink: 0.93
        case .orange: 0.07
        case .green: 0.42
        case .graphite: 0.62
        }
    }
}
