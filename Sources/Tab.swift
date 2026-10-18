import AppKit
import Observation
import WebKit

/// One browser tab. Keeps its WKWebView alive so switching is instant, until it's been idle for a
/// while: then it sleeps (the page is unloaded to free memory) and wakes, history and all, when opened.
@MainActor
@Observable
final class Tab: NSObject, Identifiable {
    let id = UUID()
    private(set) var webView: WKWebView
    /// Unloaded to save memory; wakes when selected.
    private(set) var isAsleep = false
    @ObservationIgnored var lastActive = Date()
    @ObservationIgnored private let configuration: WKWebViewConfiguration
    @ObservationIgnored private var savedState: Any?
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
    var spaceID: UUID?
    /// Link under the mouse, for the status pill.
    var hoveredLink: URL?
    /// A real (unmuted, visible) video is playing, so picture-in-picture is offered.
    var isPlayingVideo = false
    /// The page has a real article, so reading mode is offered.
    var readerAvailable = false
    /// Detected page language when it differs from yours, so translation is offered.
    var pageLanguage: Locale.Language?
    var isTranslated = false
    var isTranslating = false
    /// From the page's <meta name="theme-color">, when it has a real color.
    var themeHue: Double?
    /// Bumped whenever a page finishes opening, to fire the tab glow.
    var glowPulse = 0
    /// Saved logins for the current site, for the key button.
    var logins: [Login] = []
    var isMuted = false
    /// Page zoom; saved per site (except in private tabs) by `setZoom`.
    var zoom: Double = 1 { didSet { webView.pageZoom = zoom } }
    /// Dark mode in a private tab, which isn't saved to the site's settings.
    var privateDark = false
    var isUsingCamera = false
    var isUsingMicrophone = false
    /// On a call: never put to sleep.
    var isCapturing: Bool { isUsingCamera || isUsingMicrophone }

    @ObservationIgnored weak var browser: Browser?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []

    /// The last address this tab was asked to open. Kept even if loading fails,
    /// so the tab, the address bar and the saved session never lose it.
    var requestedURL: URL?
    /// Why the last page couldn't open, for the error card.
    var loadError: String?
    @ObservationIgnored private var retriedAfterFailure = false

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = (url ?? requestedURL)?.host() { return host }
        return "New Tab"
    }

    /// The address to show and save: where the tab is, or where it was trying to go.
    var currentURL: URL? { url ?? requestedURL }

    var isBlank: Bool { url == nil && requestedURL == nil && !isLoading }

    init(browser: Browser, configuration: WKWebViewConfiguration? = nil, isPrivate: Bool = false) {
        self.browser = browser
        self.isPrivate = isPrivate
        self.configuration = configuration ?? browser.makeConfiguration(isPrivate: isPrivate)
        webView = OrbitWebView(frame: .zero, configuration: self.configuration)
        super.init()
        attach()
    }

    /// Hooks the current web view up to this tab (delegates and property observers).
    private func attach() {
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
            webView.observe(\.cameraCaptureState, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.isUsingCamera = wv.cameraCaptureState == .active }
            },
            webView.observe(\.microphoneCaptureState, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.isUsingMicrophone = wv.microphoneCaptureState == .active }
            },
        ]
    }

    func load(_ url: URL) {
        requestedURL = url
        loadError = nil
        if isAsleep { savedState = nil; wake() }
        webView.load(URLRequest(url: url))
    }

    // MARK: Sleeping

    /// A tab restored at launch: shows its title and address but loads nothing until opened.
    func prepareAsleep(url: URL, title: String, icon: URL? = nil) {
        requestedURL = url
        self.title = title
        faviconURL = icon
        isAsleep = true
        observers.removeAll()
    }

    /// Unloads the page to free memory. Back/forward history is kept for when it wakes.
    func sleep() {
        guard !isAsleep, currentURL != nil else { return }
        savedState = webView.interactionState
        let keepTitle = title, keepURL = url, keepIcon = faviconURL
        teardown()
        webView = OrbitWebView(frame: .zero, configuration: configuration)
        isAsleep = true
        title = keepTitle
        url = keepURL
        faviconURL = keepIcon
        isLoading = false
        isPlayingVideo = false
    }

    /// Brings a sleeping tab back exactly where it was.
    func wake() {
        guard isAsleep else { return }
        isAsleep = false
        attach()
        if let savedState {
            webView.interactionState = savedState
            self.savedState = nil
        } else if let target = requestedURL, webView.url == nil {
            webView.load(URLRequest(url: target))
        }
    }

    /// Called when the tab is shown.
    func activate() {
        lastActive = Date()
        wake()
    }

    func retry() {
        retriedAfterFailure = false
        if let target = requestedURL { load(target) }
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
        SiteTools.apply(to: self)
    }

    func refreshLogins() {
        // Never offer saved passwords on a page that would send them unencrypted.
        guard let url = webView.url, url.scheme == "https" || url.host() == "localhost" else { logins = []; return }
        logins = url.host().map(PasswordStore.logins(for:)) ?? []
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

        // Sites you've turned ad blocking off for.
        if navigationAction.targetFrame?.isMainFrame == true {
            SiteTools.updateBlocking(for: self, host: navigationAction.request.url?.host())
        }

        // Hand non-web links (mailto:, zoommtg:, etc.) to macOS, but only after asking,
        // so a page can't launch apps on its own.
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            ExternalApps.open(url, from: webView.url,
                              userClicked: navigationAction.navigationType == .linkActivated)
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
        if let url = webView.url { requestedURL = url }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        // Cancelled loads (a newer navigation, a download) aren't failures.
        if ns.code == NSURLErrorCancelled || (ns.domain == "WebKitErrorDomain" && ns.code == 102) { return }
        if !retriedAfterFailure, requestedURL != nil {
            retriedAfterFailure = true // one quiet retry, e.g. the network waking up after launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.loadError == nil, let target = self.requestedURL else { return }
                self.webView.load(URLRequest(url: target))
            }
            return
        }
        loadError = ns.localizedDescription
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

    /// Camera/microphone: use the site's saved choice, otherwise ask with a banner.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let host = origin.host
        guard let browser, !host.isEmpty else { return decisionHandler(.deny) }
        let request = MediaRequest(host: host, camera: type != .microphone, microphone: type != .camera,
                                   fromPrivateTab: isPrivate, decide: decisionHandler)
        if let saved = request.remembered { return decisionHandler(saved) }
        // A newer request replaces an unanswered one.
        browser.mediaRequest?.decide(.deny)
        if browser.selectedID != id { browser.select(self) }
        browser.mediaRequest = request
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
