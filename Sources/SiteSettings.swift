import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// What you've decided for each site: camera and microphone, which apps it may open, zoom,
/// dark mode and ad blocking. Private tabs read these but never save new choices.
@MainActor
@Observable
final class SiteSettings {
    static let shared = SiteSettings()

    enum Permission: String, Codable, CaseIterable, Identifiable {
        case ask, allow, block
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    struct Prefs: Codable, Equatable {
        var camera: Permission = .ask
        var microphone: Permission = .ask
        /// URL schemes (zoommtg, slack…) this site may open without asking.
        var apps: [String] = []
        var zoom: Double = 1
        var dark = false
        var blockingOff = false

        var isDefault: Bool { self == Prefs() }
    }

    private static let key = "siteSettings"
    private var all: [String: Prefs]

    private init() {
        all = (UserDefaults.standard.data(forKey: Self.key))
            .flatMap { try? JSONDecoder().decode([String: Prefs].self, from: $0) } ?? [:]
    }

    subscript(host: String) -> Prefs {
        get { all[Self.normalize(host)] ?? Prefs() }
        set {
            let h = Self.normalize(host)
            all[h] = newValue.isDefault ? nil : newValue
            if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: Self.key) }
        }
    }

    /// Sites with anything changed, for Settings.
    var customizedHosts: [String] { all.keys.sorted() }

    func reset(_ host: String) { self[host] = Prefs() }

    private static func normalize(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

// MARK: - Opening other apps

/// Links like zoommtg:// or slack:// open another app. Orbit asks first, so a page can't launch
/// apps by itself; "Always allow" remembers it for that site.
@MainActor
enum ExternalApps {
    /// Schemes that only start something you'd expect after clicking (writing an email, a call).
    private static let harmless: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio"]

    static func open(_ url: URL, from page: URL?, userClicked: Bool) {
        guard let scheme = url.scheme?.lowercased(),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        let host = page?.host()
        if userClicked && harmless.contains(scheme) { NSWorkspace.shared.open(url); return }
        if let host, SiteSettings.shared[host].apps.contains(scheme) { NSWorkspace.shared.open(url); return }

        let appName = FileManager.default.displayName(atPath: app.path)
            .replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = "Open \(appName)?"
        alert.informativeText = "\(host ?? "This page") wants to open \(appName)."
        alert.icon = NSWorkspace.shared.icon(forFile: app.path)
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let isPrivate = Browser.shared.selected?.isPrivate ?? true
        if host != nil && !isPrivate {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Always allow \(host!) to open \(appName)"
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let host, alert.suppressionButton?.state == .on {
            SiteSettings.shared[host].apps.append(scheme)
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Camera & microphone

/// A site asking for the camera and/or microphone, waiting on the banner.
struct MediaRequest: Identifiable, Equatable {
    let id = UUID()
    let host: String
    let camera: Bool
    let microphone: Bool
    let fromPrivateTab: Bool
    let decide: (WKPermissionDecision) -> Void

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    var what: String {
        switch (camera, microphone) {
        case (true, true): "camera and microphone"
        case (true, false): "camera"
        default: "microphone"
        }
    }

    /// The saved choice, if every device asked for has one.
    @MainActor var remembered: WKPermissionDecision? {
        let p = SiteSettings.shared[host]
        let wanted = [camera ? p.camera : nil, microphone ? p.microphone : nil].compactMap { $0 }
        if wanted.contains(.block) { return .deny }
        if wanted.allSatisfy({ $0 == .allow }) { return .grant }
        return nil
    }

    @MainActor func answer(_ allow: Bool, remember: Bool) {
        if remember && !fromPrivateTab {
            let choice: SiteSettings.Permission = allow ? .allow : .block
            if camera { SiteSettings.shared[host].camera = choice }
            if microphone { SiteSettings.shared[host].microphone = choice }
        }
        decide(allow ? .grant : .deny)
    }
}

/// Glass banner at the top of the page: "zoom.us wants to use your camera".
struct MediaPermissionBanner: View {
    let request: MediaRequest
    let accent: Accent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: request.camera ? "video.fill" : "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent.color)
                .frame(width: 32, height: 32)
                .background(Circle().fill(accent.color.opacity(0.18)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Use your \(request.what)?")
                    .font(.system(size: 13, weight: .semibold))
                Text(request.host)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Block") { finish(false) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Button("Allow Once") { finish(true, remember: false) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Button("Allow") { finish(true) }
                .buttonStyle(.borderedProminent)
                .tint(accent.color)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 54)
        .frame(maxWidth: 540)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }

    private func finish(_ allow: Bool, remember: Bool = true) {
        request.answer(allow, remember: remember)
        Browser.shared.mediaRequest = nil
    }
}

// MARK: - Per-page tools: dark mode, mute, zoom, blocking

@MainActor
enum SiteTools {
    static let world = WKContentWorld.world(name: "OrbitSite")

    /// Re-applies a site's saved choices; called when a page commits and whenever they change.
    static func apply(to tab: Tab) {
        guard let host = tab.webView.url?.host() else { return }
        let prefs = SiteSettings.shared[host]
        if !tab.isPrivate || prefs.zoom != 1 { tab.zoom = prefs.zoom }
        setDark(prefs.dark || tab.privateDark, in: tab)
        if tab.isMuted { setMuted(true, in: tab) }
    }

    /// Zooms the page and remembers it for the site (not in private tabs).
    static func setZoom(_ value: Double, in tab: Tab) {
        let z = min(3, max(0.3, (value * 10).rounded() / 10))
        if !tab.isPrivate, let host = tab.webView.url?.host() { SiteSettings.shared[host].zoom = z }
        tab.zoom = z
    }

    /// Blocking is per tab: drop the rule list before a page on an excepted site loads.
    static func updateBlocking(for tab: Tab, host: String?) {
        guard let rules = Browser.blockRules, !tab.isPrivate,
              UserDefaults.standard.bool(forKey: Pref.blockAds) else { return }
        let controller = tab.webView.configuration.userContentController
        controller.remove(rules)
        if !(host.map { SiteSettings.shared[$0].blockingOff } ?? false) { controller.add(rules) }
    }

    static func toggleDark(_ tab: Tab) {
        guard let host = tab.webView.url?.host() else { return }
        let on: Bool
        if tab.isPrivate { tab.privateDark.toggle(); on = tab.privateDark }
        else { SiteSettings.shared[host].dark.toggle(); on = SiteSettings.shared[host].dark }
        setDark(on, in: tab)
    }

    static func toggleMute(_ tab: Tab) {
        tab.isMuted.toggle()
        setMuted(tab.isMuted, in: tab)
    }

    /// Dark pages by inverting the page and flipping media back, so photos and video look right.
    static func setDark(_ on: Bool, in tab: Tab) {
        let js = """
        let s = document.getElementById('orbit-dark');
        if (!on) { if (s) s.remove(); return; }
        if (!s) { s = document.createElement('style'); s.id = 'orbit-dark'; (document.head || document.documentElement).appendChild(s); }
        s.textContent = `html { filter: invert(0.92) hue-rotate(180deg) !important; background: #fff !important; }
          img, video, picture, canvas, iframe, embed, object, svg image,
          [style*="background-image"] { filter: invert(1) hue-rotate(180deg) !important; }`;
        """
        tab.webView.callAsyncJavaScript(js, arguments: ["on": on], in: nil, in: world) { _ in }
    }

    /// Silences every audio/video element, including ones the page adds later.
    static func setMuted(_ on: Bool, in tab: Tab) {
        let js = """
        const set = () => document.querySelectorAll('audio, video').forEach(m => { m.muted = on; });
        set();
        if (window.__orbitMuteObserver) { window.__orbitMuteObserver.disconnect(); window.__orbitMuteObserver = null; }
        if (on) {
          window.__orbitMuteObserver = new MutationObserver(set);
          window.__orbitMuteObserver.observe(document.documentElement, { childList: true, subtree: true });
        }
        """
        tab.webView.callAsyncJavaScript(js, arguments: ["on": on], in: nil, in: world) { _ in }
    }
}

// MARK: - Screenshots

@MainActor
enum Screenshot {
    /// Saves the visible part of the page, or the whole page, to Downloads and copies it.
    static func take(_ tab: Tab, fullPage: Bool) {
        Task {
            do {
                let image: NSImage
                if fullPage {
                    // A one-page PDF of the whole page, drawn into a bitmap.
                    let data = try await tab.webView.pdf(configuration: WKPDFConfiguration())
                    guard let pdf = NSPDFImageRep(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                    let scale: CGFloat = 2
                    let size = NSSize(width: pdf.bounds.width * scale, height: pdf.bounds.height * scale)
                    guard size.height < 30_000 else { throw CocoaError(.fileWriteOutOfSpace) }
                    image = NSImage(size: size, flipped: false) { rect in pdf.draw(in: rect) }
                } else {
                    image = try await tab.webView.takeSnapshot(configuration: nil)
                }
                guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                let stamp = formatter.string(from: Date())
                let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                let file = folder.appending(path: "Orbit Screenshot \(stamp).png")
                try png.write(to: file)

                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                Browser.shared.toast = Toast(text: fullPage ? "Full page saved and copied" : "Screenshot saved and copied",
                                             file: file)
            } catch {
                Browser.shared.toast = Toast(text: "Couldn't take that screenshot", file: nil)
            }
        }
    }
}

struct Toast: Equatable {
    let id = UUID()
    let text: String
    let file: URL?
}

/// Small note at the bottom of the page that goes away by itself.
struct ToastView: View {
    let toast: Toast
    let accent: Accent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.file == nil ? "exclamationmark.triangle.fill" : "camera.viewfinder")
                .foregroundStyle(toast.file == nil ? Color.orange : accent.color)
            Text(toast.text).font(.system(size: 12.5, weight: .medium))
            if let file = toast.file {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .buttonStyle(.plain).foregroundStyle(accent.color)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
        .task(id: toast.id) {
            try? await Task.sleep(for: .seconds(3.5))
            if Browser.shared.toast == toast { Browser.shared.toast = nil }
        }
    }
}

// MARK: - Site controls popover

/// Opens from the lock in the address bar: everything about this one site in one place.
struct SiteControls: View {
    let tab: Tab
    let accent: Accent
    @AppStorage(Pref.blockAds) private var blockAds = true

    private var host: String { tab.webView.url?.host() ?? "" }
    private var settings: SiteSettings { .shared }
    private var prefs: SiteSettings.Prefs { settings[host] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            permissionRow("Camera", icon: "video", inUse: tab.isUsingCamera, value: prefs.camera) {
                settings[host].camera = $0
            }
            permissionRow("Microphone", icon: "mic", inUse: tab.isUsingMicrophone, value: prefs.microphone) {
                settings[host].microphone = $0
            }
            Divider()
            HStack {
                Label("Zoom", systemImage: "plus.magnifyingglass")
                Spacer()
                Button { setZoom(tab.zoom - 0.1) } label: { Image(systemName: "minus") }
                Text("\(Int((tab.zoom * 100).rounded()))%")
                    .monospacedDigit().frame(width: 44)
                    .onTapGesture { setZoom(1) }
                    .help("Click to reset")
                Button { setZoom(tab.zoom + 0.1) } label: { Image(systemName: "plus") }
            }
            toggle("Dark mode", icon: "moon", isOn: tab.isPrivate ? tab.privateDark : prefs.dark) {
                if tab.isPrivate { tab.privateDark = $0 } else { settings[host].dark = $0 }
                SiteTools.setDark($0, in: tab)
            }
            if blockAds && !tab.isPrivate {
                toggle("Block ads and trackers", icon: "shield.lefthalf.filled", isOn: !prefs.blockingOff) {
                    settings[host].blockingOff = !$0
                    SiteTools.updateBlocking(for: tab, host: host)
                    tab.webView.reload()
                }
            }
            toggle("Mute this tab", icon: "speaker.slash", isOn: tab.isMuted) { _ in SiteTools.toggleMute(tab) }
            if !prefs.apps.isEmpty {
                Divider()
                Text("Can open apps").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(prefs.apps, id: \.self) { scheme in
                    HStack {
                        Text(scheme + "://").font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button("Remove") { settings[host].apps.removeAll { $0 == scheme } }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            if !prefs.isDefault {
                Divider()
                Button("Reset this site") {
                    settings.reset(host)
                    SiteTools.updateBlocking(for: tab, host: host)
                    SiteTools.apply(to: tab)
                }
                .buttonStyle(.plain).foregroundStyle(accent.color)
            }
        }
        .font(.system(size: 12.5))
        .buttonStyle(.borderless)
        .padding(16)
        .frame(width: 290)
    }

    private var header: some View {
        let secure = tab.webView.hasOnlySecureContent && tab.url?.scheme == "https"
        return HStack(spacing: 10) {
            Image(systemName: secure ? "lock.fill" : "lock.open.fill")
                .foregroundStyle(secure ? Color.green : Color.orange)
                .frame(width: 28, height: 28)
                .background(Circle().fill((secure ? Color.green : Color.orange).opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(host).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(secure ? "Connection is secure" : "Connection is not secure")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(_ title: String, icon: String, inUse: Bool, value: SiteSettings.Permission,
                               set: @escaping (SiteSettings.Permission) -> Void) -> some View {
        HStack {
            Label(title, systemImage: inUse ? icon + ".fill" : icon)
                .foregroundStyle(inUse ? Color.red : Color.primary)
            Spacer()
            Picker("", selection: Binding(get: { value }, set: set)) {
                ForEach(SiteSettings.Permission.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(tab.isPrivate)
        }
    }

    private func toggle(_ title: String, icon: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) { Label(title, systemImage: icon) }
            .toggleStyle(.switch)
            .controlSize(.mini)
    }

    private func setZoom(_ value: Double) { SiteTools.setZoom(value, in: tab) }
}
