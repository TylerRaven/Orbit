import SwiftUI
import WebKit

enum Field: Hashable { case address, start }

struct ContentView: View {
    let browser = Browser.shared
    @AppStorage(Pref.tabLayout) private var tabLayout = TabLayout.top.rawValue
    @AppStorage(Pref.accent) private var accentRaw = Accent.blue.rawValue
    @AppStorage(Pref.showPinsBar) private var showPinsBar = true
    @FocusState private var focus: Field?
    // Plain State storage: the @State macro plugin only ships with full Xcode.
    private let addressState = State(initialValue: "")
    private var address: String {
        get { addressState.wrappedValue }
        nonmutating set { addressState.wrappedValue = newValue }
    }

    @Environment(\.openSettings) private var openSettings

    private var accent: Accent { Accent(rawValue: accentRaw) ?? .blue }

    /// Color everything glows with: the page's color, or the accent on the start page.
    private var pageHue: Double {
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
            }
        }
        .animation(.easeOut(duration: 0.15), value: browser.showPalette)
        .ignoresSafeArea()
        .onChange(of: browser.focusAddressRequest) {
            focus = browser.selected?.isBlank == true ? .start : .address
        }
        .onChange(of: browser.selectedID) { syncAddress(force: true) }
        .onChange(of: browser.selected?.url) { syncAddress() }
        .onChange(of: browser.selected?.isLoading) { syncAddress() }
    }

    /// Mirrors the tab's URL into the address bar, unless the user is mid-edit on the same tab.
    private func syncAddress(force: Bool = false) {
        if force || focus != .address {
            address = browser.selected?.url?.absoluteString ?? ""
        }
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
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
                ForEach(browser.tabs.filter(\.isPinned)) { tab in
                    PinnedTab(tab: tab, selected: tab.id == browser.selectedID)
                }
                if browser.pinnedCount > 0 {
                    Capsule().fill(Color.primary.opacity(0.15)).frame(width: 1.5, height: 16).padding(.horizontal, 3)
                }
                ForEach(browser.tabs.filter { !$0.isPinned }) { tab in
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
            .frame(height: 28)
            .padding(.top, 3)
            .padding(.trailing, 10)

            HStack(spacing: 6) {
                navButtons
                addressBar
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
                .padding([.horizontal, .bottom], 10)
        }
    }

    private var sideLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Spacer()
                    navButtons
                    aiButton
                }
                .frame(height: 30)
                .padding(.top, 2)

                addressBar

                if showPinsBar {
                    PinsBar(vertical: true)
                        .padding(.top, 2)
                }

                if browser.pinnedCount > 0 {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(browser.tabs.filter(\.isPinned)) { tab in
                            PinnedTab(tab: tab, selected: tab.id == browser.selectedID, wide: true)
                        }
                    }
                    .padding(.top, 4)
                }

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(browser.tabs.filter { !$0.isPinned }) { tab in
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
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .frame(width: 232)

            card
                .padding([.vertical, .trailing], 10)
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
            Image(systemName: browser.selected?.url?.scheme == "https" ? "lock.fill" : "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            TextField("Search", text: addressState.projectedValue)
                .textFieldStyle(.plain)
                .focused($focus, equals: .address)
                .onSubmit { submit(address) }
                .onExitCommand {
                    address = browser.selected?.url?.absoluteString ?? ""
                    focus = nil
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
                .strokeBorder(focus == .address ? accent.color
                              : Color(hue: pageHue, saturation: 0.7, brightness: 1).opacity(0.3 * AmbientLevel.current.strength),
                              lineWidth: focus == .address ? 2 : 1)
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

    /// The rounded page card.
    private var card: some View {
        webArea
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
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
            .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
            .animation(.easeInOut(duration: 1.3)) {
                $0.shadow(color: Color(hue: pageHue, saturation: 0.75, brightness: 1)
                              .opacity(0.28 * AmbientLevel.current.strength), radius: 22)
            }
            .modifier(PageGlowPulse(trigger: browser.selected?.glowPulse ?? 0, hue: pageHue, radius: 12))
    }

    @ViewBuilder
    private var webArea: some View {
        if let tab = browser.selected {
            ZStack {
                WebViewHost(webView: tab.webView)
                if tab.isBlank {
                    StartPage(focus: $focus, accent: accent, onSubmit: submit)
                        .id(tab.id) // fresh search box per tab
                }
            }
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
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
        .frame(height: 28)
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
            .frame(width: wide ? nil : 34, height: wide ? 34 : 28)
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

struct TabMenu: View {
    let tab: Tab

    var body: some View {
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { Browser.shared.togglePin(tab) }
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
        .frame(height: 34)
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

    func makeNSView(context: Context) -> WebContainer { WebContainer() }
    func updateNSView(_ container: WebContainer, context: Context) { container.show(webView) }
}

final class WebContainer: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

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
