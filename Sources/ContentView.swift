import SwiftUI
import WebKit

enum Field: Hashable { case address, start }

struct ContentView: View {
    let browser = Browser.shared
    @AppStorage(Pref.tabLayout) private var tabLayout = TabLayout.top.rawValue
    @AppStorage(Pref.accent) private var accentRaw = Accent.blue.rawValue
    @AppStorage(Pref.showPinsBar) private var showPinsBar = true
    @AppStorage(Pref.pageBorder) private var pageBorder = false
    @FocusState private var focus: Field?
    // Plain State storage: the @State macro plugin only ships with full Xcode.
    private let addressState = State(initialValue: "")
    private var address: String {
        get { addressState.wrappedValue }
        nonmutating set { addressState.wrappedValue = newValue }
    }

    @Environment(\.openSettings) private var openSettings

    /// The current Space's color, or the accent from Settings.
    private var accent: Accent { Accent(rawValue: browser.currentSpace?.accent ?? accentRaw) ?? .blue }

    /// Color everything glows with: the page's color, or the accent on the start page.
    private var pageHue: Double {
        if browser.selected?.isPrivate == true { return Tab.privateHue }
        guard let tab = browser.selected, !tab.isBlank else { return accent.hue }
        return tab.glowHue
    }

    var body: some View {
        Group {
            if tabLayout == TabLayout.side.rawValue { sideLayout } else { topLayout }
        }
        .background {
            ZStack {
                VisualEffect()
                AmbientBackdrop(hue: pageHue)
                TranslationHost()
            }
            .ignoresSafeArea()
        }
        .overlay {
            if browser.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18)
                        .onTapGesture { browser.showPalette = false }
                    CommandPalette(accent: accent, openSettings: { openSettings() })
                        .padding(.top, 110)
                }
                .transition(.opacity)
            } else if let space = browser.editingSpace {
                ZStack {
                    Color.black.opacity(0.18)
                        .onTapGesture { browser.editingSpace = nil }
                    SpaceEditor(space: space).id(space.id)
                }
                .transition(.opacity)
            } else if browser.showHistory {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18)
                        .onTapGesture { browser.showHistory = false }
                    HistoryPanel(accent: accent)
                        .padding(.top, 90)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: browser.showPalette)
        .animation(.easeOut(duration: 0.15), value: browser.showHistory)
        .ignoresSafeArea()
        .onChange(of: browser.focusAddressRequest) {
            focus = browser.selected?.isBlank == true ? .start : .address
        }
        .onChange(of: browser.selected?.url) { Reader.shared.close() }
        .onChange(of: browser.selectedID) { old, _ in
            syncAddress(force: true)
            Reader.shared.close()
            // Leaving a tab mid-video pops the video out so it keeps playing on top.
            if UserDefaults.standard.bool(forKey: Pref.autoPiP),
               let previous = browser.tabs.first(where: { $0.id == old }), previous.isPlayingVideo,
               browser.visibleSplit.map({ $0.left.id != previous.id && $0.right.id != previous.id }) ?? true {
                PageAgent.shared.pictureInPicture(previous)
            }
        }
        .onChange(of: browser.selected?.url) { syncAddress() }
        .onChange(of: browser.selected?.isLoading) { syncAddress() }
    }

    /// Mirrors the tab's URL into the address bar, unless the user is mid-edit on the same tab.
    private func syncAddress(force: Bool = false) {
        if force || focus != .address {
            address = browser.selected?.currentURL?.absoluteString ?? ""
        }
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("??") {
            // "??question" asks about every tab in this Space.
            Assistant.shared.askAboutTabs(String(trimmed.dropFirst(2)))
            address = browser.selected?.url?.absoluteString ?? ""
            focus = nil
            return
        }
        if trimmed.hasPrefix("?") {
            // "?question" asks Orbit AI instead of searching.
            let tab = browser.selected
            Assistant.shared.ask(String(trimmed.dropFirst()), about: tab?.isBlank == false ? tab : nil)
            address = tab?.url?.absoluteString ?? ""
            focus = nil
            return
        }
        browser.go(text)
        focus = nil
        if let wv = browser.selected?.webView { wv.window?.makeFirstResponder(wv) }
    }

    // MARK: Layouts

    private var topLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Color.clear.frame(width: 74) // traffic lights
                if SpaceStore.shared.spaces.count > 1 {
                    SpaceSwitcher()
                        .padding(.trailing, 4)
                }
                ForEach(browser.spaceTabs.filter(\.isPinned)) { tab in
                    PinnedTab(tab: tab, selected: tab.id == browser.selectedID)
                }
                if browser.spacePinnedCount > 0 {
                    Capsule().fill(Color.primary.opacity(0.15)).frame(width: 1.5, height: 16).padding(.horizontal, 3)
                }
                ForEach(browser.spaceTabs.filter { !$0.isPinned }) { tab in
                    TopTab(tab: tab, selected: tab.id == browser.selectedID)
                        .frame(minWidth: 44, maxWidth: 220)
                }
                Button { browser.newTab() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverStyle())
                .foregroundStyle(.secondary)
                .help("New Tab (⌘T)")
                Spacer(minLength: 24)
            }
            .frame(height: 32)
            .padding(.top, 1)
            .padding(.trailing, 10)

            HStack(spacing: 6) {
                navButtons
                addressBar
                if !Downloads.shared.items.isEmpty { DownloadsButton(accent: accent) }
                aiButton
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, showPinsBar ? 4 : 8)

            if showPinsBar {
                PinsBar()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            card
                .padding([.horizontal, .bottom], pageBorder ? 10 : 0)
        }
    }

    private var sideLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Spacer()
                    navButtons
                    if !Downloads.shared.items.isEmpty { DownloadsButton(accent: accent) }
                    aiButton
                }
                .frame(height: 30)
                .padding(.top, 2)

                addressBar

                if showPinsBar {
                    PinsBar(vertical: true)
                        .padding(.top, 2)
                }

                if browser.spacePinnedCount > 0 {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(browser.spaceTabs.filter(\.isPinned)) { tab in
                            PinnedTab(tab: tab, selected: tab.id == browser.selectedID, wide: true)
                        }
                    }
                    .padding(.top, 4)
                }

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(browser.spaceTabs.filter { !$0.isPinned }) { tab in
                            TabRow(tab: tab, selected: tab.id == browser.selectedID)
                        }
                    }
                }
                .scrollIndicators(.never)
                .padding(.top, 4)

                Button {
                    browser.newTab()
                } label: {
                    Label("New Tab", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverStyle())
                .foregroundStyle(.secondary)

                if SpaceStore.shared.spaces.count > 1 {
                    SpaceSwitcher(compact: false)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .frame(width: 232)

            card
                .padding([.vertical, .trailing], pageBorder ? 10 : 0)
        }
    }

    // MARK: Shared pieces

    private var aiButton: some View {
        let open = Assistant.shared.isOpen
        return Button { Assistant.shared.toggle() } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(open ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: open)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("Orbit AI (⌘J)")
    }

    private var navButtons: some View {
        HStack(spacing: 2) {
            NavButton(symbol: "chevron.left", help: "Back (⌘[)", enabled: browser.selected?.canGoBack == true) {
                browser.selected?.webView.goBack()
            }
            NavButton(symbol: "chevron.right", help: "Forward (⌘])", enabled: browser.selected?.canGoForward == true) {
                browser.selected?.webView.goForward()
            }
            NavButton(symbol: browser.selected?.isLoading == true ? "xmark" : "arrow.clockwise",
                      help: "Reload (⌘R)", enabled: browser.selected != nil) {
                guard let tab = browser.selected else { return }
                if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() }
            }
        }
        .padding(3)
        .glassEffect(.regular, in: Capsule())
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: browser.selected?.isPrivate == true ? "eye.slash.fill"
                  : browser.selected?.url?.scheme == "https" ? "lock.fill" : "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(browser.selected?.isPrivate == true ? AnyShapeStyle(Color(hue: Tab.privateHue, saturation: 0.6, brightness: 1)) : AnyShapeStyle(.secondary))
                .frame(width: 14)
                .help(browser.selected?.isPrivate == true ? "Private tab: nothing is saved" : "")
            TextField(browser.selected?.isPrivate == true ? "Search privately" : "Search", text: addressState.projectedValue)
                .textFieldStyle(.plain)
                .focused($focus, equals: .address)
                .onSubmit { submit(address) }
                .onExitCommand {
                    address = browser.selected?.url?.absoluteString ?? ""
                    focus = nil
                }
            if let tab = browser.selected, let language = tab.pageLanguage {
                Button {
                    if tab.isTranslated { Translator.showOriginal(tab) } else { browser.translating = tab }
                } label: {
                    if tab.isTranslating {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "translate").font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab.isTranslated ? AnyShapeStyle(accent.color) : AnyShapeStyle(.secondary))
                .help(tab.isTranslated ? "Show original" : "Translate from \(Translator.name(of: language))")
            }
            if let tab = browser.selected, tab.readerAvailable {
                Button {
                    if Reader.shared.article != nil { Reader.shared.close() } else { Reader.shared.open(tab) }
                } label: {
                    Image(systemName: "text.page").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Reader.shared.article != nil ? AnyShapeStyle(accent.color) : AnyShapeStyle(.secondary))
                .help("Reading mode (⇧⌘R)")
            }
            if let tab = browser.selected, tab.isPlayingVideo {
                Button { PageAgent.shared.pictureInPicture(tab) } label: {
                    Image(systemName: "pip.enter").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent.color)
                .help("Picture in Picture")
                .transition(.scale.combined(with: .opacity))
            }
            if let tab = browser.selected, !tab.logins.isEmpty {
                Menu {
                    ForEach(tab.logins) { login in
                        Button(login.username.isEmpty ? "(no username)" : login.username) {
                            PasswordAgent.shared.fill(login, in: tab.webView)
                        }
                    }
                } label: {
                    Image(systemName: "key.fill").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(accent.color)
                .help("Fill saved password (⌘\\)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(focus == .address ? accent.color : .clear, lineWidth: 2)
                .animation(.easeInOut(duration: 1.3), value: pageHue)
        )
        .modifier(PageGlowPulse(trigger: browser.selected?.glowPulse ?? 0, hue: pageHue, radius: 11))
        .overlay(alignment: .bottom) {
            if let tab = browser.selected, tab.isLoading {
                ProgressLine(progress: tab.progress, accent: accent)
                    .padding(.horizontal, 10)
            }
        }
        .animation(.easeOut(duration: 0.15), value: focus)
    }

    /// Which page corners are rounded. Edge to edge, only the corners that meet the browser chrome
    /// are rounded; the window's own corners clip the rest.
    private var pageCorners: RectangleCornerRadii {
        let r: CGFloat = 12
        if pageBorder { return .init(topLeading: r, bottomLeading: r, bottomTrailing: r, topTrailing: r) }
        if tabLayout == TabLayout.side.rawValue { return .init(topLeading: r, bottomLeading: r) }
        return .init(topLeading: r, topTrailing: r)
    }

    /// The page area: edge to edge by default, or an inset card with "Border around pages".
    private var card: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: pageCorners, style: .continuous)
        return webArea
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(pageBorder ? 0.08 : 0)))
            .overlay(alignment: .top) {
                if let offer = browser.passwordOffer {
                    PasswordBanner(offer: offer, accent: accent)
                        .padding(12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                if browser.showFind, let tab = browser.selected {
                    FindBar(tab: tab, accent: accent)
                        .padding(12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let link = browser.selected?.hoveredLink, browser.peek == nil {
                    LinkPill(url: link)
                        .padding(10)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if browser.showDefaultPrompt {
                    DefaultBrowserPrompt(accent: accent)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay {
                if Reader.shared.article != nil {
                    ReaderPanel(accent: accent)
                        .clipShape(UnevenRoundedRectangle(cornerRadii: pageCorners, style: .continuous))
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: Reader.shared.article != nil)
            .overlay {
                if let peek = browser.peek {
                    PeekPanel(tab: peek, accent: accent)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.12), value: browser.selected?.hoveredLink)
            .animation(.spring(duration: 0.35), value: browser.showDefaultPrompt)
            .animation(.spring(duration: 0.3), value: browser.peek?.id)
            .overlay(alignment: .trailing) {
                if Assistant.shared.isOpen {
                    AIPanel(accent: accent, tab: browser.selected)
                        .padding(12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: browser.passwordOffer)
            .animation(.spring(duration: 0.3), value: browser.showFind)
            .animation(.spring(duration: 0.35), value: Assistant.shared.isOpen)
            .shadow(color: .black.opacity(pageBorder ? 0.14 : 0), radius: 10, y: 3)
            .modifier(PageGlowPulse(trigger: browser.selected?.glowPulse ?? 0, hue: pageHue, radius: 12, fadesDown: true))
    }

    @ViewBuilder
    private var webArea: some View {
        if let pair = browser.visibleSplit {
            splitPages(pair.left, pair.right)
        } else if let tab = browser.selected {
            page(tab, corners: pageCorners)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    private func page(_ tab: Tab, corners: RectangleCornerRadii) -> some View {
        ZStack {
            WebViewHost(webView: tab.webView, corners: corners) {
                if browser.selectedID != tab.id { browser.select(tab) }
            }
            if let error = tab.loadError {
                LoadErrorCard(tab: tab, message: error, accent: accent)
            }
            if tab.isBlank {
                StartPage(focus: $focus, accent: tab.isPrivate ? .purple : accent,
                          isPrivate: tab.isPrivate, onSubmit: submit)
                    .id(tab.id) // fresh search box per tab
                    .clipShape(UnevenRoundedRectangle(cornerRadii: corners, style: .continuous))
                    .simultaneousGesture(TapGesture().onEnded {
                        if browser.selectedID != tab.id { browser.select(tab) }
                    })
            }
        }
    }

    /// Two pages side by side with a glass divider you can drag. Clicking a side makes it the active tab.
    private func splitPages(_ left: Tab, _ right: Tab) -> some View {
        GeometryReader { geo in
            let gap: CGFloat = 8
            let leftWidth = max(200, min(geo.size.width - 200, geo.size.width * browser.splitRatio - gap / 2))
            let r: CGFloat = 12
            let outer = pageCorners
            HStack(spacing: 0) {
                page(left, corners: .init(topLeading: outer.topLeading, bottomLeading: outer.bottomLeading,
                                          bottomTrailing: r, topTrailing: r))
                    .frame(width: leftWidth)
                    .overlay(alignment: .top) { activeLine(left) }

                Capsule()
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 4, height: 44)
                    .frame(width: gap)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        let x = value.location.x + leftWidth
                        browser.splitRatio = min(0.8, max(0.2, x / geo.size.width))
                    })
                    .onTapGesture(count: 2) { browser.splitRatio = 0.5 }
                    .help("Drag to resize, double-click to even out")

                page(right, corners: .init(topLeading: r, bottomLeading: r,
                                           bottomTrailing: outer.bottomTrailing, topTrailing: outer.topTrailing))
                    .overlay(alignment: .top) { activeLine(right) }
            }
        }
    }

    /// Thin accent line on top of the active half of a split.
    private func activeLine(_ tab: Tab) -> some View {
        Capsule()
            .fill(accent.color)
            .frame(width: 60, height: 3)
            .padding(.top, 4)
            .opacity(browser.selectedID == tab.id ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: browser.selectedID)
            .allowsHitTesting(false)
    }
}

// MARK: - Pieces

struct TopTab: View {
    let tab: Tab
    let selected: Bool
    private let hoverState = State(initialValue: false)
    private var hovering: Bool { hoverState.wrappedValue }

    var body: some View {
        HStack(spacing: 7) {
            Favicon(tab: tab)
            if tab.isPrivate { PrivateBadge() }
            if let split = Browser.shared.split, split.left == tab.id || split.right == tab.id {
                Image(systemName: "rectangle.split.2x1.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("In split view")
            }
            Text(tab.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovering || selected {
                Button {
                    Browser.shared.close(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverStyle(radius: 5))
                .foregroundStyle(.secondary)
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(!selected && hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .glassEffect(selected ? .regular.interactive() : .identity,
                     in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .modifier(TabGlow(tab: tab, selected: selected))
        .contentShape(Rectangle())
        .onTapGesture { Browser.shared.select(tab) }
        .onHover { hoverState.wrappedValue = $0 }
        .help(tab.displayTitle)
        .contextMenu { TabMenu(tab: tab) }
    }
}

struct PinnedTab: View {
    let tab: Tab
    let selected: Bool
    var wide = false
    private let hoverState = State(initialValue: false)

    var body: some View {
        Favicon(tab: tab)
            .frame(width: wide ? nil : 34, height: wide ? 38 : 32)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(!selected && hoverState.wrappedValue ? Color.primary.opacity(0.06)
                          : wide && !selected ? Color.primary.opacity(0.05) : .clear)
            )
            .glassEffect(selected ? .regular.interactive() : .identity,
                         in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .modifier(TabGlow(tab: tab, selected: selected))
            .contentShape(Rectangle())
            .onTapGesture { Browser.shared.select(tab) }
            .onHover { hoverState.wrappedValue = $0 }
            .help(tab.displayTitle)
            .contextMenu { TabMenu(tab: tab) }
    }
}

struct PrivateBadge: View {
    var body: some View {
        Image(systemName: "eye.slash.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color(hue: Tab.privateHue, saturation: 0.55, brightness: 1))
            .help("Private tab")
    }
}

struct TabMenu: View {
    let tab: Tab

    var body: some View {
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { Browser.shared.togglePin(tab) }
            .disabled(tab.isPrivate)
        if let url = tab.url, !tab.isPrivate {
            Button("Open in Private Tab") { Browser.shared.newTab(url: url, isPrivate: true) }
        }
        if let split = Browser.shared.split, split.left == tab.id || split.right == tab.id {
            Button("Close Split View") { Browser.shared.split = nil }
        } else if Browser.shared.selectedID != tab.id {
            Button("Open in Split View") { Browser.shared.splitView(with: tab) }
        }
        if SpaceStore.shared.spaces.count > 1 {
            Menu("Move to Space") {
                ForEach(SpaceStore.shared.spaces.filter { $0.id != tab.spaceID }) { space in
                    Button { Browser.shared.move(tab, to: space) } label: { Label(space.name, systemImage: space.icon) }
                }
            }
        }
        Button("Reload") { tab.webView.reload() }
        Button("Duplicate") { Browser.shared.newTab(url: tab.url) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url?.absoluteString ?? "", forType: .string)
        }
        .disabled(tab.url == nil)
        Divider()
        Button("Close Tab") { Browser.shared.close(tab) }
    }
}

struct TabRow: View {
    let tab: Tab
    let selected: Bool
    private let hoverState = State(initialValue: false)
    private var hovering: Bool { hoverState.wrappedValue }

    var body: some View {
        HStack(spacing: 9) {
            Favicon(tab: tab)
            if tab.isPrivate { PrivateBadge() }
            Text(tab.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovering || selected {
                Button {
                    Browser.shared.close(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverStyle(radius: 6))
                .foregroundStyle(.secondary)
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(!selected && hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .glassEffect(selected ? .regular.interactive() : .identity,
                     in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .modifier(TabGlow(tab: tab, selected: selected))
        .contentShape(Rectangle())
        .onTapGesture { Browser.shared.select(tab) }
        .onHover { hoverState.wrappedValue = $0 }
        .contextMenu { TabMenu(tab: tab) }
    }
}

struct Favicon: View {
    let tab: Tab

    var body: some View {
        Group {
            if tab.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            } else if let url = tab.faviconURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().interpolation(.high)
                    } else {
                        letter
                    }
                }
            } else {
                letter
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .opacity(tab.isAsleep ? 0.45 : 1)
        .saturation(tab.isAsleep ? 0.2 : 1)
        .help(tab.isAsleep ? "Sleeping to save memory: wakes when you open it" : "")
    }

    private var letter: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(0.1))
            .overlay(
                Text(String(tab.displayTitle.prefix(1)).uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            )
    }
}

struct NavButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverStyle())
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }
}

struct HoverStyle: ButtonStyle {
    var radius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, radius: radius)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let radius: CGFloat
        private let hoverState = State(initialValue: false)

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hoverState.wrappedValue ? 0.07 : 0))
                )
                .onHover { hoverState.wrappedValue = $0 }
        }
    }
}

struct ProgressLine: View {
    let progress: Double
    let accent: Accent

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(LinearGradient(colors: [accent.colors.0, accent.colors.1], startPoint: .leading, endPoint: .trailing))
                .frame(width: max(8, geo.size.width * progress), height: 2)
                .animation(.easeOut(duration: 0.2), value: progress)
        }
        .frame(height: 2)
    }
}

/// Hosts the selected tab's WKWebView in a layer-clipped, rounded container.
/// (SwiftUI clip shapes don't reach AppKit views, so the rounding happens here.)
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    var corners = RectangleCornerRadii(topLeading: 12, bottomLeading: 12, bottomTrailing: 12, topTrailing: 12)
    /// Called when the user clicks into this page (used by split view to switch the active side).
    var onActivate: (() -> Void)? = nil

    func makeNSView(context: Context) -> WebContainer { WebContainer() }
    func updateNSView(_ container: WebContainer, context: Context) {
        container.show(webView)
        container.round(corners)
        container.onActivate = onActivate
    }
}

final class WebContainer: NSView {
    var onActivate: (() -> Void)?
    private var clickMonitor: Any?

    // WKWebView swallows clicks, so watch for them at the app level instead.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard window != nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, event.window === self.window,
               self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                self.onActivate?()
            }
            return event
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    /// Rounds only the corners that have a radius (the layer isn't flipped, so "min Y" is the bottom).
    func round(_ c: RectangleCornerRadii) {
        var mask: CACornerMask = []
        if c.topLeading > 0 { mask.insert(.layerMinXMaxYCorner) }
        if c.topTrailing > 0 { mask.insert(.layerMaxXMaxYCorner) }
        if c.bottomLeading > 0 { mask.insert(.layerMinXMinYCorner) }
        if c.bottomTrailing > 0 { mask.insert(.layerMaxXMinYCorner) }
        layer?.cornerRadius = max(c.topLeading, c.topTrailing, c.bottomLeading, c.bottomTrailing)
        layer?.maskedCorners = mask
    }

    func show(_ webView: WKWebView) {
        guard webView.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Where a hovered link goes, in a small glass pill at the bottom of the page.
struct LinkPill: View {
    let url: URL

    var body: some View {
        let host = url.host() ?? ""
        let rest = url.absoluteString.components(separatedBy: host).dropFirst().joined(separator: host)
        (Text(host).fontWeight(.semibold) + Text(rest).foregroundStyle(.secondary))
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .frame(maxWidth: 520, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .glassEffect(.regular, in: Capsule())
            .allowsHitTesting(false)
    }
}

/// ⌥-hover a link: the page opens in a floating glass window over the one you're on.
struct PeekPanel: View {
    let tab: Tab
    let accent: Accent

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .onTapGesture { Browser.shared.closePeek() }
            GeometryReader { geo in
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Favicon(tab: tab)
                        Text(tab.displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(tab.url?.host() ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Open in New Tab") { Browser.shared.promotePeek() }
                            .buttonStyle(.borderedProminent)
                            .tint(accent.color)
                            .controlSize(.small)
                        NavButton(symbol: "xmark", help: "Close (esc)", enabled: true) { Browser.shared.closePeek() }
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 6)
                    .frame(height: 42)
                    WebViewHost(webView: tab.webView,
                                corners: .init(bottomLeading: 14, bottomTrailing: 14))
                        .overlay(alignment: .top) {
                            if tab.isLoading { ProgressLine(progress: tab.progress, accent: accent) }
                        }
                }
                .frame(width: geo.size.width * 0.78, height: geo.size.height * 0.84)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onExitCommand { Browser.shared.closePeek() }
    }
}

/// Shown instead of a blank page when a site can't be reached.
struct LoadErrorCard: View {
    let tab: Tab
    let message: String
    let accent: Accent

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(accent.gradient)
                Text("Couldn't open \(tab.requestedURL?.host() ?? "this page")")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Try Again") { tab.retry() }
                    .buttonStyle(.borderedProminent)
                    .tint(accent.color)
            }
            .padding(30)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }
}
