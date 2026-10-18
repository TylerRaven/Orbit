import AppKit
import SwiftUI

enum AmbientLevel: String, CaseIterable, Identifiable {
    case off, subtle, vivid
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var strength: Double {
        switch self {
        case .off: 0
        case .subtle: 0.55
        case .vivid: 1
        }
    }

    static var current: AmbientLevel {
        AmbientLevel(rawValue: UserDefaults.standard.string(forKey: Pref.ambient) ?? "") ?? .vivid
    }
}

extension Tab {
    /// The page's color: its theme-color, a known site color, or one derived from the domain.
    var glowHue: Double {
        if let themeHue { return themeHue }
        if let host = url?.host() { return WallpaperMood.siteHue(host) }
        return (Accent(rawValue: UserDefaults.standard.string(forKey: Pref.accent) ?? "") ?? .blue).hue
    }

    var glowColor: Color { Color(hue: glowHue, saturation: 0.75, brightness: 1) }

    /// Parses a CSS theme-color; returns nil for greys so they fall back to the site color.
    static func hue(fromCSS css: String) -> Double? {
        let s = css.trimmingCharacters(in: .whitespaces).lowercased()
        var rgb: (Double, Double, Double)?
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            if hex.count >= 6, let v = UInt32(hex.prefix(6), radix: 16) {
                rgb = (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
            }
        } else if s.hasPrefix("rgb") {
            let nums = s.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                .compactMap(Double.init).prefix(3)
            if nums.count == 3 { rgb = (nums[nums.startIndex] / 255, nums[nums.startIndex + 1] / 255, nums[nums.startIndex + 2] / 255) }
        }
        guard let (r, g, b) = rgb else { return nil }
        let c = NSColor(red: r, green: g, blue: b, alpha: 1)
        guard c.saturationComponent > 0.18, c.brightnessComponent > 0.15 else { return nil }
        return Double(c.hueComponent)
    }
}

/// Selected-tab glow: a soft halo in the page's color, a shimmer while loading,
/// and a burst of light each time a page finishes opening.
struct TabGlow: ViewModifier {
    let tab: Tab
    let selected: Bool
    var radius: CGFloat = 9
    @AppStorage(Pref.ambient) private var ambient = AmbientLevel.vivid.rawValue

    func body(content: Content) -> some View {
        let level = (AmbientLevel(rawValue: ambient) ?? .vivid).strength
        let color = tab.glowColor
        content
            .overlay {
                if tab.isLoading && level > 0 {
                    LoadingShimmer(color: color, radius: radius)
                }
            }
            .shadow(color: selected ? color.opacity(0.38 * level) : .clear, radius: 7)
            .keyframeAnimator(initialValue: 0.0, trigger: tab.glowPulse) { view, v in
                view
                    .shadow(color: color.opacity(0.95 * v * level), radius: 2 + 18 * v)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(color.opacity(0.9 * v * level), lineWidth: 1.5)
                    )
            } keyframes: { _ in
                CubicKeyframe(1, duration: 0.28)
                CubicKeyframe(0, duration: 1.5)
            }
    }
}

/// A light that races around the edge while a page loads.
struct LoadingShimmer: View {
    let color: Color
    let radius: CGFloat

    var body: some View {
        TimelineView(.animation) { ctx in
            let angle = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    AngularGradient(colors: [.clear, color.opacity(0.1), color, .white.opacity(0.9), color, color.opacity(0.1), .clear],
                                    center: .center, angle: .degrees(angle)),
                    lineWidth: 1.6)
                .blur(radius: 0.4)
        }
        .allowsHitTesting(false)
    }
}

/// Slow colored light behind the browser chrome, following the page (or what you're typing).
struct AmbientBackdrop: View {
    let hue: Double
    @AppStorage(Pref.ambient) private var ambient = AmbientLevel.vivid.rawValue

    var body: some View {
        let level = (AmbientLevel(rawValue: ambient) ?? .vivid).strength
        if level > 0 {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                let frame = WallpaperMood.shared.step(now: ctx.date, baseHue: hue, reactive: true)
                Canvas { g, size in
                    let t = frame.phase
                    let blobs: [(x: Double, y: Double, r: Double, dh: Double)] = [
                        (0.12 + 0.06 * sin(t * 0.4), 0.0, 0.55, 0),
                        (0.75 + 0.1 * cos(t * 0.33), 0.05, 0.45, 0.07),
                        (0.45 + 0.2 * sin(t * 0.21 + 2), 1.05, 0.5, -0.06),
                    ]
                    let side = max(size.width, size.height)
                    for b in blobs {
                        let center = CGPoint(x: size.width * b.x, y: size.height * b.y)
                        let r = side * b.r * frame.look.scale
                        let c = Color(hue: (frame.look.hue + b.dh + 1).truncatingRemainder(dividingBy: 1),
                                      saturation: 0.8, brightness: 1)
                            .opacity(0.22 * level * min(1.4, frame.look.intensity) * (1 + frame.energy * 0.6))
                        g.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                               with: .radialGradient(Gradient(colors: [c, c.opacity(0)]), center: center,
                                                     startRadius: 0, endRadius: r))
                    }
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// A flash of the page's color around a shape whenever a page finishes opening.
struct PageGlowPulse: ViewModifier {
    let trigger: Int
    let hue: Double
    let radius: CGFloat

    func body(content: Content) -> some View {
        let level = AmbientLevel.current.strength
        let color = Color(hue: hue, saturation: 0.75, brightness: 1)
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, v in
            view
                .shadow(color: color.opacity(0.8 * v * level), radius: 4 + 26 * v)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(color.opacity(0.85 * v * level), lineWidth: 1.5)
                        .allowsHitTesting(false)
                )
        } keyframes: { _ in
            CubicKeyframe(1, duration: 0.3)
            CubicKeyframe(0, duration: 1.6)
        }
    }
}
