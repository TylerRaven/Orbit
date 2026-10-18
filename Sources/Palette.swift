import SwiftUI
import WebKit

struct PaletteItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    var subtitle = ""
    let action: () -> Void
}

/// ⌘K: one box for tabs, history, commands and search.
struct CommandPalette: View {
    let accent: Accent
    let openSettings: () -> Void
    @FocusState private var focused: Bool
    private let queryState = State(initialValue: "")
    private let indexState = State(initialValue: 0)

    private var browser: Browser { Browser.shared }
    private var query: String { queryState.wrappedValue }

    var body: some View {
        let items = results()
        let index = min(indexState.wrappedValue, max(0, items.count - 1))

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent.color)
                TextField("Search tabs, history and commands", text: queryState.projectedValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { run(items, index) }
                    .onChange(of: query) { indexState.wrappedValue = 0 }
                    .onKeyPress(.downArrow) {
                        indexState.wrappedValue = min(index + 1, items.count - 1); return .handled
                    }
                    .onKeyPress(.upArrow) {
                        indexState.wrappedValue = max(index - 1, 0); return .handled
                    }
                    .onExitCommand { close() }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            if !items.isEmpty {
                Divider().opacity(0.5)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == index)
                                    .id(i)
                                    .onTapGesture { run(items, i) }
                                    .onHover { if $0 { indexState.wrappedValue = i } }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: index) { proxy.scrollTo(index) }
                }
            }
        }
        .frame(width: 620)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .onAppear { focused = true }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if selected {
                Image(systemName: "return").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? accent.color.opacity(0.22) : .clear)
        )
        .contentShape(Rectangle())
    }

    private func run(_ items: [PaletteItem], _ i: Int) {
        guard items.indices.contains(i) else { return }
        close()
        items[i].action()
    }

    private func close() {
        browser.showPalette = false
    }

    // MARK: Results

    private func results() -> [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let lower = q.lowercased()
        var items: [PaletteItem] = []

        if !q.isEmpty, let url = Browser.resolve(q) {
            let isSearch = url == SearchEngine.current.url(for: q)
            items.append(PaletteItem(icon: isSearch ? "magnifyingglass" : "arrow.up.right",
                                     title: isSearch ? "Search \(SearchEngine.current.label) for “\(q)”" : "Go to \(q)",
                                     action: { Browser.shared.go(q) }))
        }

        if !q.isEmpty {
            let question = q.hasPrefix("?") ? String(q.dropFirst()) : q
            let page = browser.selected?.isBlank == false ? browser.selected : nil
            let ask = PaletteItem(icon: "sparkles", title: "Ask Orbit AI: “\(question)”",
                                  subtitle: page == nil ? "On-device" : "About this page") {
                Assistant.shared.ask(question, about: page)
            }
            items.insert(ask, at: q.hasPrefix("?") ? 0 : min(1, items.count))
        }

        for tab in browser.tabs where tab.id != browser.selectedID {
            if q.isEmpty || tab.displayTitle.lowercased().contains(lower)
                || (tab.url?.absoluteString.lowercased().contains(lower) ?? false) {
                items.append(PaletteItem(icon: tab.isPinned ? "pin.fill" : "square.on.square",
                                         title: tab.displayTitle, subtitle: "Switch to tab",
                                         action: { Browser.shared.select(tab) }))
            }
        }

        items += commands().filter { q.isEmpty || $0.title.lowercased().contains(lower) }

        for space in SpaceStore.shared.spaces where space.id != browser.currentSpaceID {
            if q.isEmpty || space.name.lowercased().contains(lower) || "space".contains(lower) {
                items.append(PaletteItem(icon: space.icon, title: "Switch to \(space.name)", subtitle: "Space") {
                    Browser.shared.switchSpace(to: space.id)
                })
            }
        }
        if let tab = browser.selected, tab.isPlayingVideo {
            items.insert(PaletteItem(icon: "pip.enter", title: "Picture in Picture") {
                PageAgent.shared.pictureInPicture(tab)
            }, at: 0)
        }

        for entry in History.shared.search(q, limit: q.isEmpty ? 5 : 8) {
            items.append(PaletteItem(icon: "clock.arrow.circlepath",
                                     title: entry.title.isEmpty ? entry.url : entry.title,
                                     subtitle: entry.url,
                                     action: { if let u = URL(string: entry.url) { Browser.shared.go(u.absoluteString) } }))
        }
        return items
    }

    private func commands() -> [PaletteItem] {
        let b = browser
        let tab = b.selected
        var list: [PaletteItem] = [
            PaletteItem(icon: "plus.square", title: "New Tab", subtitle: "⌘T") { b.newTab() },
            PaletteItem(icon: "eye.slash", title: "New Private Tab", subtitle: "⌘⇧N") { b.newTab(isPrivate: true) },
            PaletteItem(icon: "arrow.uturn.backward.square", title: "Reopen Closed Tab", subtitle: "⌘⇧T") { b.reopenClosedTab() },
            PaletteItem(icon: "rectangle.split.2x1", title: b.visibleSplit == nil ? "Split View" : "Close Split View",
                        subtitle: "⌃⌘S") { b.toggleSplitView() },
            PaletteItem(icon: "clock.arrow.circlepath", title: "Show History", subtitle: "⌘Y") { b.showHistory = true },
            PaletteItem(icon: "square.stack.3d.up", title: "New Space") {
                let space = SpaceStore.shared.add()
                b.switchSpace(to: space.id)
                b.editingSpace = space
            },
            PaletteItem(icon: "arrow.down.circle", title: "Downloads", subtitle: "⌥⌘L") { Downloads.shared.showPanel = true },
            PaletteItem(icon: "magnifyingglass", title: "Find in Page", subtitle: "⌘F") { b.showFind = true },
            PaletteItem(icon: "pin.circle", title: Pins.isPinned(tab?.url) ? "Unpin This Page" : "Pin This Page",
                        subtitle: "⌘D") { Pins.toggleCurrentPage() },
            PaletteItem(icon: "sparkles", title: "Orbit AI", subtitle: "⌘J") { Assistant.shared.isOpen = true },
            PaletteItem(icon: "text.badge.star", title: "Summarize Page with AI", subtitle: "⌘⇧S") {
                Assistant.shared.summarize(tab)
            },
            PaletteItem(icon: "arrow.clockwise", title: "Reload Page", subtitle: "⌘R") { tab?.webView.reload() },
            PaletteItem(icon: "sidebar.left", title: "Switch Tab Layout", subtitle: "Top ↔ Sidebar") {
                let d = UserDefaults.standard
                let side = d.string(forKey: Pref.tabLayout) == TabLayout.side.rawValue
                d.set(side ? TabLayout.top.rawValue : TabLayout.side.rawValue, forKey: Pref.tabLayout)
            },
            PaletteItem(icon: "gearshape", title: "Settings", subtitle: "⌘,", action: openSettings),
            PaletteItem(icon: "trash", title: "Clear History") { History.shared.clear() },
        ]
        if let tab {
            list.insert(PaletteItem(icon: tab.isPinned ? "pin.slash" : "pin", title: tab.isPinned ? "Unpin Tab" : "Pin Tab") {
                b.togglePin(tab)
            }, at: 1)
            list.insert(PaletteItem(icon: "xmark.square", title: "Close Tab", subtitle: "⌘W") { b.close(tab) }, at: 2)
            if let url = tab.url {
                list.append(PaletteItem(icon: "link", title: "Copy Link", subtitle: url.absoluteString) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                })
            }
            for login in tab.logins {
                list.append(PaletteItem(icon: "key.fill", title: "Fill Password", subtitle: login.username) {
                    PasswordAgent.shared.fill(login, in: tab.webView)
                })
            }
        }
        return list
    }
}

/// ⌘F: find in the current page.
struct FindBar: View {
    let tab: Tab
    let accent: Accent
    @FocusState private var focused: Bool
    private let textState = State(initialValue: "")
    private let foundState = State<Bool?>(initialValue: nil)

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in page", text: textState.projectedValue)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { find(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onChange(of: textState.wrappedValue) { find(backwards: false) }
                .onExitCommand { Browser.shared.showFind = false }
            if foundState.wrappedValue == false {
                Text("Not found").font(.system(size: 11)).foregroundStyle(.red)
            }
            NavButton(symbol: "chevron.up", help: "Previous (⇧↩)", enabled: true) { find(backwards: true) }
            NavButton(symbol: "chevron.down", help: "Next (↩)", enabled: true) { find(backwards: false) }
            NavButton(symbol: "xmark", help: "Close (esc)", enabled: true) { Browser.shared.showFind = false }
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: 40)
        .glassEffect(.regular, in: Capsule())
        .onAppear { focused = true }
    }

    private func find(backwards: Bool) {
        let text = textState.wrappedValue
        guard !text.isEmpty else { foundState.wrappedValue = nil; return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        tab.webView.find(text, configuration: config) { result in
            MainActor.assumeIsolated { foundState.wrappedValue = result.matchFound }
        }
    }
}

/// "Save password?" banner after logging in somewhere.
struct PasswordBanner: View {
    let offer: PasswordOffer
    let accent: Accent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent.color)
                .frame(width: 32, height: 32)
                .background(Circle().fill(accent.color.opacity(0.18)))
            VStack(alignment: .leading, spacing: 1) {
                Text(offer.isUpdate ? "Update saved password?" : "Save this password?")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(offer.login.username.isEmpty ? "No username" : offer.login.username) · \(offer.login.host)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Never") {
                PasswordAgent.neverSave.append(offer.login.host)
                Browser.shared.passwordOffer = nil
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            Button("Not now") { Browser.shared.passwordOffer = nil }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Button(offer.isUpdate ? "Update" : "Save") {
                PasswordStore.save(offer.login, password: offer.password)
                Browser.shared.passwordOffer = nil
                for tab in Browser.shared.tabs { tab.refreshLogins() }
            }
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
}
