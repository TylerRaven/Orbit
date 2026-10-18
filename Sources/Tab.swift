import AppKit
import Observation
import WebKit

/// One browser tab. Owns its WKWebView for its whole life so switching tabs is instant.
@MainActor
@Observable
final class Tab: NSObject, Identifiable {
    let id = UUID()
    let webView: WKWebView
    /// Private tabs keep nothing: no history, no saved session, no password offers, throwaway cookies.
    let isPrivate: Bool

    var title = ""
    var url: URL?
    var faviconURL: URL?
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    var isPinned = false
    /// From the page's <meta name="theme-color">, when it has a real color.
    var themeHue: Double?
    /// Bumped whenever a page finishes opening, to fire the tab glow.
    var glowPulse = 0
    /// Saved logins for the current site, for the key button.
    var logins: [Login] = []

    @ObservationIgnored weak var browser: Browser?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host() { return host }
        return "New Tab"
    }

    var isBlank: Bool { url == nil && !isLoading }

    init(browser: Browser, configuration: WKWebViewConfiguration? = nil, isPrivate: Bool = false) {
        self.browser = browser
        self.isPrivate = isPrivate
        webView = OrbitWebView(frame: .zero, configuration: configuration ?? browser.makeConfiguration(isPrivate: isPrivate))
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.underPageBackgroundColor = .clear

        observers = [
            webView.observe(\.title, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.title = wv.title ?? "" }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.url = wv.url
                    self?.browser?.saveSession()
                }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.isLoading = wv.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.progress = wv.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward }
            },
        ]
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func teardown() {
        observers.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    private func refreshFavicon() {
        let js = """
        [(document.querySelector('link[rel~="icon"]') || document.querySelector('link[rel="apple-touch-icon"]') || {}).href || '',
         (document.querySelector('meta[name="theme-color"]') || {}).content || '']
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let parts = result as? [String] ?? []
                self.themeHue = parts.count > 1 ? Tab.hue(fromCSS: parts[1]) : nil
                if let s = parts.first, !s.isEmpty, let icon = URL(string: s) {
                    self.faviconURL = icon
                } else if let url = self.url, let scheme = url.scheme, let host = url.host() {
                    self.faviconURL = URL(string: "\(scheme)://\(host)/favicon.ico")
                }
            }
        }
    }
}

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshFavicon()
        if !isPrivate, let url = webView.url { History.shared.record(url: url, title: webView.title ?? "") }
        glowPulse += 1
        if browser?.selectedID == id {
            WallpaperMood.shared.settle()
            WallpaperMood.shared.pulse(0.7)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        faviconURL = nil
        refreshLogins()
    }

    func refreshLogins() {
        logins = webView.url?.host().map(PasswordStore.logins(for:)) ?? []
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }

        // Private tabs strip tracking junk (utm_, fbclid, gclid…) from links before loading them.
        if isPrivate, navigationAction.targetFrame?.isMainFrame == true,
           (navigationAction.request.httpMethod ?? "GET") == "GET",
           let url = navigationAction.request.url, let clean = Tracking.clean(url) {
            webView.load(URLRequest(url: clean))
            return (.cancel, preferences)
        }

        // Cmd-click / middle-click opens a background tab.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2,
           let url = navigationAction.request.url {
            browser?.newTab(url: url, select: false)
            return (.cancel, preferences)
        }

        // Hand non-web links (mailto:, zoommtg:, etc.) to macOS.
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = Downloads.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = Downloads.shared
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - Popups, dialogs

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open become new tabs.
        guard let browser else { return nil }
        let tab = browser.newTab(configuration: configuration, select: true, isPrivate: isPrivate)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "This page says"
        alert.informativeText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "This page says"
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
