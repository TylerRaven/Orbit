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
    var showHistory = false
    /// Link being previewed with ⌥-hover, in its own temporary web view.
    var peek: Tab?
    var showDefaultPrompt = false
    var editingSpace: Space?

    /// The Space whose tabs are showing.
    var currentSpaceID: UUID = {
        let saved = UserDefaults.standard.string(forKey: "currentSpace").flatMap(UUID.init(uuidString:))
        let spaces = SpaceStore.shared.spaces
        return spaces.first { $0.id == saved }?.id ?? spaces[0].id
    }()

    /// Tabs in the current Space, in order.
    var spaceTabs: [Tab] { tabs.filter { $0.spaceID == currentSpaceID } }
    var currentSpace: Space? { SpaceStore.shared.space(currentSpaceID) }
    @ObservationIgnored private var lastSelected: [UUID: UUID] = [:]

    /// Two tabs shown side by side. Visible whenever one of them is the selected tab.
    var split: (left: UUID, right: UUID)?
    /// Share of the width the left page gets in split view.
    var splitRatio = 0.5

    var selected: Tab? { tabs.first { $0.id == selectedID } }

    /// The pair to show side by side right now, if the selected tab is part of a split.
    var visibleSplit: (left: Tab, right: Tab)? {
        guard let split, selectedID == split.left || selectedID == split.right,
              let l = tabs.first(where: { $0.id == split.left }),
              let r = tabs.first(where: { $0.id == split.right }) else { return nil }
        return (l, r)
    }

    /// Recently closed pages, newest last, for ⌘⇧T. Private tabs are never remembered.
    @ObservationIgnored private var recentlyClosed: [(url: URL, index: Int)] = []

    @ObservationIgnored private var restoring = false
    @ObservationIgnored private static var blockRules: WKContentRuleList?
    @ObservationIgnored private static var privacyRules: WKContentRuleList?
    /// In-memory cookies/storage shared by private tabs; thrown away when the last one closes.
    @ObservationIgnored private var privateStore: WKWebsiteDataStore?

    private init() {}

    // MARK: Configuration

    func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        if isPrivate {
            if privateStore == nil { privateStore = .nonPersistent() }
            config.websiteDataStore = privateStore!
        } else {
            config.websiteDataStore = .default()
        }
        // Present as Safari so sites serve their full desktop experience.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        if let rules = Self.blockRules, isPrivate || UserDefaults.standard.bool(forKey: Pref.blockAds) {
            config.userContentController.add(rules)
        }
        if isPrivate { Self.addPrivacyProtections(to: config.userContentController) }
        PasswordAgent.shared.install(in: config.userContentController)
        PageAgent.shared.install(in: config.userContentController)
        return config
    }

    /// Private tabs: no third-party cookies, and tell sites not to sell or share data (Global Privacy Control).
    private static func addPrivacyProtections(to controller: WKUserContentController) {
        if let privacyRules { controller.add(privacyRules) }
        controller.addUserScript(WKUserScript(
            source: "try { Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', { get: () => true }); } catch (_) {}",
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
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
        let privacy = #"[{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block-cookies"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "orbit-private-v1", encodedContentRuleList: privacy
        ) { list, _ in
            MainActor.assumeIsolated {
                guard let list else { return }
                Browser.privacyRules = list
                for tab in self.tabs where tab.isPrivate { tab.webView.configuration.userContentController.add(list) }
            }
        }
    }

    /// Turns the blocker on/off for every open tab; takes effect on the next page load.
    func setBlocking(_ on: Bool) {
        guard let rules = Browser.blockRules else { return }
        for tab in tabs where !tab.isPrivate { // private tabs always block
            let controller = tab.webView.configuration.userContentController
            controller.remove(rules)
            if on { controller.add(rules) }
        }
    }

    // MARK: Tabs

    @discardableResult
    func newTab(url: URL? = nil, configuration: WKWebViewConfiguration? = nil, select: Bool = true,
                pinned: Bool = false, isPrivate: Bool = false) -> Tab {
        let tab = Tab(browser: self, configuration: configuration, isPrivate: isPrivate)
        tab.isPinned = pinned
        tab.spaceID = currentSpaceID
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
        if !tab.isPrivate, let url = tab.url {
            recentlyClosed.append((url, i))
            if recentlyClosed.count > 30 { recentlyClosed.removeFirst() }
        }
        if let split, split.left == tab.id || split.right == tab.id { self.split = nil }
        tabs.remove(at: i)
        tab.teardown()
        if tab.isPrivate && !tabs.contains(where: \.isPrivate) {
            privateStore = nil // last private tab gone: its cookies and storage go with it
        }
        let remaining = spaceTabs
        if remaining.isEmpty {
            newTab()
        } else if selectedID == tab.id {
            // Next tab in the same space, else the one before.
            let next = tabs[i...].first { $0.spaceID == currentSpaceID } ?? remaining.last!
            selectedID = next.id
        }
        saveSession()
    }

    // MARK: Spaces

    func switchSpace(to id: UUID) {
        guard id != currentSpaceID, SpaceStore.shared.space(id) != nil else { return }
        if let selectedID { lastSelected[currentSpaceID] = selectedID }
        currentSpaceID = id
        UserDefaults.standard.set(id.uuidString, forKey: "currentSpace")
        let inSpace = spaceTabs
        if let last = lastSelected[id], inSpace.contains(where: { $0.id == last }) {
            selectedID = last
        } else if let first = inSpace.first(where: { !$0.isPinned }) ?? inSpace.first {
            selectedID = first.id
        } else {
            newTab()
        }
        WallpaperMood.shared.pulse(0.8)
        saveSession()
    }

    func switchSpace(index: Int) {
        let spaces = SpaceStore.shared.spaces
        if spaces.indices.contains(index) { switchSpace(to: spaces[index].id) }
    }

    func move(_ tab: Tab, to space: Space) {
        guard tab.spaceID != space.id else { return }
        let wasSelected = tab.id == selectedID
        tab.spaceID = space.id
        if let split, split.left == tab.id || split.right == tab.id { self.split = nil }
        if wasSelected {
            if let next = spaceTabs.first { selectedID = next.id } else { newTab() }
        }
        saveSession()
    }

    /// Deleting a space moves its tabs into the first remaining space.
    func deleteSpace(_ space: Space) {
        let store = SpaceStore.shared
        guard store.spaces.count > 1 else { return }
        store.remove(space)
        let fallback = store.spaces[0].id
        for tab in tabs where tab.spaceID == space.id { tab.spaceID = fallback }
        if currentSpaceID == space.id {
            currentSpaceID = fallback
            switchSpaceAfterDelete()
        }
        saveSession()
    }

    private func switchSpaceAfterDelete() {
        UserDefaults.standard.set(currentSpaceID.uuidString, forKey: "currentSpace")
        if let first = spaceTabs.first { selectedID = first.id } else { newTab() }
    }

    // MARK: Peek

    func openPeek(_ url: URL, from source: Tab) {
        if let peek {
            peek.load(url)
        } else {
            let tab = Tab(browser: self, isPrivate: source.isPrivate)
            tab.spaceID = currentSpaceID
            tab.load(url)
            peek = tab
        }
    }

    func closePeek() {
        peek?.teardown()
        peek = nil
    }

    /// Turns the preview into a real tab.
    func promotePeek() {
        guard let url = peek?.url else { return closePeek() }
        closePeek()
        newTab(url: url)
    }

    func closeSelected() {
        if let tab = selected { close(tab) }
    }

    var canReopenClosedTab: Bool { !recentlyClosed.isEmpty }

    /// Brings back the most recently closed tab where it was.
    func reopenClosedTab() {
        guard let last = recentlyClosed.popLast() else { return }
        let tab = newTab(url: last.url)
        if let i = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: i)
            tabs.insert(tab, at: min(max(last.index, pinnedCount), tabs.count))
            tab.spaceID = currentSpaceID
        }
        saveSession()
    }

    // MARK: Split view

    /// Shows `other` next to the selected tab (or the next tab, or a new one).
    func splitView(with other: Tab? = nil) {
        guard let current = selected else { return }
        let partner = other.flatMap { $0.id == current.id ? nil : $0 }
            ?? tabs.first { $0.id != current.id && !$0.isPinned && tabs.firstIndex(of: $0)! > tabs.firstIndex(of: current)! }
            ?? newTab(select: false, isPrivate: current.isPrivate)
        split = (current.id, partner.id)
        splitRatio = 0.5
    }

    func toggleSplitView() {
        if visibleSplit != nil { split = nil } else { splitView() }
    }

    var pinnedCount: Int { tabs.filter(\.isPinned).count }
    var spacePinnedCount: Int { spaceTabs.filter(\.isPinned).count }

    func togglePin(_ tab: Tab) {
        guard !tab.isPrivate, let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: i)
        tab.isPinned.toggle()
        // Pinned tabs live at the front; unpinning drops it right after them.
        tabs.insert(tab, at: pinnedCount)
        saveSession()
    }

    func select(_ tab: Tab) {
        if let space = tab.spaceID, space != currentSpaceID {
            if let selectedID { lastSelected[currentSpaceID] = selectedID }
            currentSpaceID = space
            UserDefaults.standard.set(space.uuidString, forKey: "currentSpace")
        }
        selectedID = tab.id
    }

    func select(index: Int) {
        let list = spaceTabs
        guard !list.isEmpty else { return }
        selectedID = list[min(index, list.count - 1)].id
    }

    func selectLast() {
        selectedID = spaceTabs.last?.id
    }

    func cycle(_ step: Int) {
        let list = spaceTabs
        guard let i = list.firstIndex(where: { $0.id == selectedID }), !list.isEmpty else { return }
        selectedID = list[(i + step + list.count) % list.count].id
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

    /// Saved as [{url, space, pinned}] so every tab comes back in its Space.
    func saveSession() {
        guard !restoring else { return }
        let entries: [[String: String]] = tabs.filter { !$0.isPrivate }.compactMap { tab in
            guard let url = tab.url else { return nil }
            return ["url": url.absoluteString, "space": tab.spaceID?.uuidString ?? "", "pinned": tab.isPinned ? "1" : "0"]
        }
        UserDefaults.standard.set(entries, forKey: "session.v2")
        UserDefaults.standard.set(spaceTabs.firstIndex { $0.id == selectedID } ?? 0, forKey: "sessionSelected")
    }

    func restoreSession() {
        restoring = true
        let d = UserDefaults.standard
        var entries = d.array(forKey: "session.v2") as? [[String: String]]
        if entries == nil { // carry over tabs saved before Spaces existed
            entries = (d.stringArray(forKey: "pinnedTabs") ?? []).map { ["url": $0, "pinned": "1"] }
                + (d.stringArray(forKey: "sessionTabs") ?? []).map { ["url": $0, "pinned": "0"] }
        }
        let reopenAll = d.bool(forKey: Pref.restoreTabs)
        let home = currentSpaceID
        for entry in entries ?? [] {
            guard let url = entry["url"].flatMap(URL.init(string:)) else { continue }
            let pinned = entry["pinned"] == "1"
            // Pinned tabs always come back, whatever the reopen setting says.
            guard pinned || reopenAll else { continue }
            let space = entry["space"].flatMap(UUID.init(uuidString:)).flatMap { SpaceStore.shared.space($0)?.id } ?? home
            currentSpaceID = space
            newTab(url: url, select: false, pinned: pinned)
        }
        currentSpaceID = home
        restoring = false
        if spaceTabs.isEmpty {
            newTab()
        } else {
            select(index: d.integer(forKey: "sessionSelected"))
        }
    }
}
