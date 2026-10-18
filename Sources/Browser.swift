import AppKit
import Observation
import WebKit

@MainActor
@Observable
final class Browser {
    static let shared = Browser()

    var tabs: [Tab] = []
    var selectedID: UUID?
    /// Bumped to ask the UI to focus the address bar.
    var focusAddressRequest = 0
    var passwordOffer: PasswordOffer?
    var showPalette = false
    var showFind = false

    var selected: Tab? { tabs.first { $0.id == selectedID } }

    @ObservationIgnored private var restoring = false
    @ObservationIgnored private static var blockRules: WKContentRuleList?

    private init() {}

    // MARK: Configuration

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Present as Safari so sites serve their full desktop experience.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        if let rules = blockRules, UserDefaults.standard.bool(forKey: Pref.blockAds) {
            config.userContentController.add(rules)
        }
        PasswordAgent.shared.install(in: config.userContentController)
        return config
    }

    /// Compiles the ad/tracker block list once, then applies it to every open tab.
    func loadBlocker() {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "orbit-blocklist-v1",
            encodedContentRuleList: Blocklist.json
        ) { list, error in
            MainActor.assumeIsolated {
                guard let list else {
                    if let error { NSLog("Orbit blocklist failed: \(error)") }
                    return
                }
                Browser.blockRules = list
                self.setBlocking(UserDefaults.standard.bool(forKey: Pref.blockAds))
            }
        }
    }

    /// Turns the blocker on/off for every open tab; takes effect on the next page load.
    func setBlocking(_ on: Bool) {
        guard let rules = Browser.blockRules else { return }
        for tab in tabs {
            let controller = tab.webView.configuration.userContentController
            controller.remove(rules)
            if on { controller.add(rules) }
        }
    }

    // MARK: Tabs

    @discardableResult
    func newTab(url: URL? = nil, configuration: WKWebViewConfiguration? = nil, select: Bool = true,
                pinned: Bool = false) -> Tab {
        let tab = Tab(browser: self, configuration: configuration)
        tab.isPinned = pinned
        if pinned {
            tabs.insert(tab, at: tabs.firstIndex { !$0.isPinned } ?? tabs.count)
        } else if let current = selected, let i = tabs.firstIndex(where: { $0.id == current.id }), !select {
            tabs.insert(tab, at: max(i + 1, pinnedCount))
        } else {
            tabs.append(tab)
        }
        if select {
            selectedID = tab.id
            if url == nil && configuration == nil { focusAddressRequest += 1 }
        }
        if let url { tab.load(url) }
        saveSession()
        return tab
    }

    func close(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: i)
        tab.teardown()
        if tabs.isEmpty {
            newTab()
        } else if selectedID == tab.id {
            selectedID = tabs[min(i, tabs.count - 1)].id
        }
        saveSession()
    }

    func closeSelected() {
        if let tab = selected { close(tab) }
    }

    var pinnedCount: Int { tabs.filter(\.isPinned).count }

    func togglePin(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: i)
        tab.isPinned.toggle()
        // Pinned tabs live at the front; unpinning drops it right after them.
        tabs.insert(tab, at: pinnedCount)
        saveSession()
    }

    func select(_ tab: Tab) {
        selectedID = tab.id
    }

    func select(index: Int) {
        guard !tabs.isEmpty else { return }
        selectedID = tabs[min(index, tabs.count - 1)].id
    }

    func selectLast() {
        selectedID = tabs.last?.id
    }

    func cycle(_ step: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == selectedID }), !tabs.isEmpty else { return }
        selectedID = tabs[(i + step + tabs.count) % tabs.count].id
    }

    // MARK: Navigation

    func go(_ input: String) {
        guard let url = Self.resolve(input) else { return }
        if let tab = selected { tab.load(url) } else { newTab(url: url) }
    }

    static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        let looksLikeHost = !text.contains(" ") && (
            text.range(of: #"^[^\s/]+\.[a-zA-Z]{2,}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil ||
            text.range(of: #"^(localhost|\d{1,3}(\.\d{1,3}){3})(:\d+)?(/.*)?$"#, options: .regularExpression) != nil
        )
        if looksLikeHost {
            let scheme = text.hasPrefix("localhost") || text.first?.isNumber == true ? "http" : "https"
            return URL(string: "\(scheme)://\(text)")
        }
        return SearchEngine.current.url(for: text)
    }

    // MARK: Session

    func saveSession() {
        guard !restoring else { return }
        let urls = tabs.filter { !$0.isPinned }.compactMap { $0.url?.absoluteString }
        UserDefaults.standard.set(urls, forKey: "sessionTabs")
        UserDefaults.standard.set(tabs.filter(\.isPinned).compactMap { $0.url?.absoluteString }, forKey: "pinnedTabs")
        UserDefaults.standard.set(tabs.firstIndex { $0.id == selectedID } ?? 0, forKey: "sessionSelected")
    }

    func restoreSession() {
        restoring = true
        let saved = UserDefaults.standard.bool(forKey: Pref.restoreTabs)
            ? UserDefaults.standard.stringArray(forKey: "sessionTabs") ?? [] : []
        let urls = saved.compactMap(URL.init(string:))
        // Pinned tabs always come back, whatever the reopen setting says.
        for url in (UserDefaults.standard.stringArray(forKey: "pinnedTabs") ?? []).compactMap(URL.init(string:)) {
            newTab(url: url, select: false, pinned: true)
        }
        for url in urls { newTab(url: url, select: false) }
        restoring = false
        if tabs.isEmpty {
            newTab()
        } else {
            select(index: UserDefaults.standard.integer(forKey: "sessionSelected"))
        }
    }
}
