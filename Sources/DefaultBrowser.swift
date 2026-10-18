import AppKit
import SwiftUI

/// Making Orbit the default browser, and asking about it politely.
@MainActor
enum DefaultBrowser {
    private static let neverKey = "defaultBrowser.neverAsk"
    private static let lastAskedKey = "defaultBrowser.lastAsked"

    static var isDefault: Bool {
        guard let url = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// macOS shows its own "Use Orbit as your default browser?" confirmation.
    static func makeDefault() {
        let app = Bundle.main.bundleURL
        Task {
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http")
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https")
        }
    }

    /// A few seconds after launch, offer once (at most once a day, never if told not to).
    static func considerAsking() {
        let d = UserDefaults.standard
        guard !isDefault, !d.bool(forKey: neverKey) else { return }
        let last = d.object(forKey: lastAskedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        Task {
            try? await Task.sleep(for: .seconds(6))
            // Don't interrupt: skip if they're typing in the address bar or a panel is open.
            let b = Browser.shared
            guard !b.showPalette, !b.showHistory, b.peek == nil, b.editingSpace == nil else { return }
            d.set(Date(), forKey: lastAskedKey)
            b.showDefaultPrompt = true
        }
    }

    static func neverAsk() {
        UserDefaults.standard.set(true, forKey: neverKey)
    }
}

/// Small glass note at the bottom of the window. Slides away on its own after a while.
struct DefaultBrowserPrompt: View {
    let accent: Accent

    var body: some View {
        HStack(spacing: 12) {
            OrbitMarkSmall()
            Text("Make Orbit your default browser?")
                .font(.system(size: 12.5, weight: .medium))
            Button("Not now") { Browser.shared.showDefaultPrompt = false }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Button("Don't ask") {
                DefaultBrowser.neverAsk()
                Browser.shared.showDefaultPrompt = false
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            Button("Make default") {
                DefaultBrowser.makeDefault()
                Browser.shared.showDefaultPrompt = false
            }
            .buttonStyle(.borderedProminent)
            .tint(accent.color)
            .controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 44)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
        .task {
            try? await Task.sleep(for: .seconds(20))
            Browser.shared.showDefaultPrompt = false
        }
    }
}

/// The ringed planet in a tiny black circle.
struct OrbitMarkSmall: View {
    var body: some View {
        ZStack {
            Circle().fill(.black)
            Circle().fill(.white).frame(width: 9, height: 9)
            Ellipse().stroke(.white, lineWidth: 1.4).frame(width: 18, height: 6).rotationEffect(.degrees(-22))
        }
        .frame(width: 24, height: 24)
    }
}
