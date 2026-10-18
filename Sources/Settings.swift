import SwiftUI

/// UserDefaults keys and choices for everything in Settings (⌘,).
enum Pref {
    static let tabLayout = "tabLayout"
    static let searchEngine = "searchEngine"
    static let accent = "accent"
    static let restoreTabs = "restoreTabs"
    static let blockAds = "blockAds"
    static let offerPasswords = "offerPasswords"
    static let ambient = "ambient"
    static let aiCloud = "aiCloud"
    static let pins = "pins"
    static let showPinsBar = "showPinsBar"

    // Start page
    static let wallpaper = "wallpaper"
    static let wallpaperReactive = "wallpaperReactive"
    static let wallpaperIntensity = "wallpaperIntensity"
    static let wallpaperImage = "wallpaperImage"
    static let userName = "userName"
    static let showClock = "showClock"
    static let showLinks = "showLinks"
    static let showWeather = "showWeather"
    static let showNotes = "showNotes"
    static let weatherCity = "weatherCity"
    static let fahrenheit = "fahrenheit"
    static let quickLinks = "quickLinks"
    static let notes = "notes"

    static func register() {
        UserDefaults.standard.register(defaults: [
            tabLayout: TabLayout.top.rawValue,
            searchEngine: SearchEngine.google.rawValue,
            accent: Accent.blue.rawValue,
            restoreTabs: true,
            blockAds: true,
            offerPasswords: true,
            ambient: AmbientLevel.vivid.rawValue,
            aiCloud: true,
            showPinsBar: true,
            wallpaper: WallpaperStyle.aurora.rawValue,
            wallpaperReactive: true,
            wallpaperIntensity: 0.8,
            showClock: true,
            showLinks: true,
            showWeather: true,
            showNotes: true,
            weatherCity: "London",
        ])
    }
}

enum TabLayout: String, CaseIterable, Identifiable {
    case top, side
    var id: String { rawValue }
    var label: String { self == .top ? "Top" : "Sidebar" }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, brave
    var id: String { rawValue }

    var label: String {
        switch self {
        case .google: "Google"
        case .duckduckgo: "DuckDuckGo"
        case .bing: "Bing"
        case .brave: "Brave Search"
        }
    }

    func url(for query: String) -> URL? {
        let base = switch self {
        case .google: "https://www.google.com/search"
        case .duckduckgo: "https://duckduckgo.com/"
        case .bing: "https://www.bing.com/search"
        case .brave: "https://search.brave.com/search"
        }
        var c = URLComponents(string: base)!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url
    }

    static var current: SearchEngine {
        SearchEngine(rawValue: UserDefaults.standard.string(forKey: Pref.searchEngine) ?? "") ?? .google
    }
}

enum Accent: String, CaseIterable, Identifiable {
    case blue, purple, pink, orange, green, graphite
    var id: String { rawValue }

    var colors: (Color, Color) {
        switch self {
        case .blue: (Color(red: 0.25, green: 0.47, blue: 1.0), Color(red: 0.36, green: 0.72, blue: 1.0))
        case .purple: (Color(red: 0.49, green: 0.33, blue: 1.0), Color(red: 0.76, green: 0.45, blue: 1.0))
        case .pink: (Color(red: 1.0, green: 0.27, blue: 0.55), Color(red: 1.0, green: 0.52, blue: 0.68))
        case .orange: (Color(red: 1.0, green: 0.50, blue: 0.10), Color(red: 1.0, green: 0.72, blue: 0.30))
        case .green: (Color(red: 0.12, green: 0.72, blue: 0.45), Color(red: 0.35, green: 0.86, blue: 0.55))
        case .graphite: (Color(white: 0.42), Color(white: 0.62))
        }
    }

    var color: Color { colors.0 }
    var gradient: LinearGradient {
        LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            LookSettings()
                .tabItem { Label("Look", systemImage: "paintpalette") }
            ScrollView { StartPageSettings().padding(22) }
                .frame(height: 520)
                .tabItem { Label("Start Page", systemImage: "sparkles.rectangle.stack") }
            PasswordSettings()
                .tabItem { Label("Passwords", systemImage: "key") }
        }
        .frame(width: 480)
    }
}

struct GeneralSettings: View {
    @AppStorage(Pref.searchEngine) private var searchEngine = SearchEngine.google.rawValue
    @AppStorage(Pref.restoreTabs) private var restoreTabs = true
    @AppStorage(Pref.blockAds) private var blockAds = true
    @AppStorage(Pref.offerPasswords) private var offerPasswords = true
    @AppStorage(Pref.aiCloud) private var aiCloud = true

    var body: some View {
        Form {
            Picker("Search engine", selection: $searchEngine) {
                ForEach(SearchEngine.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Toggle("Block ads and trackers", isOn: $blockAds)
                .onChange(of: blockAds) { Browser.shared.setBlocking(blockAds) }
            Toggle("Reopen tabs from last time", isOn: $restoreTabs)
            Toggle("Offer to save passwords", isOn: $offerPasswords)
            LabeledContent("History") {
                Button("Clear History") { History.shared.clear() }
            }
            Section("Orbit AI") {
                LabeledContent("Model") {
                    Text(Assistant.shared.unavailableReason ?? "Apple Intelligence, on this Mac")
                        .foregroundStyle(.secondary)
                }
                Toggle("Use Private Cloud Compute when available", isOn: $aiCloud)
                    .help("Apple's private servers handle longer pages. Falls back to on-device automatically.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct LookSettings: View {
    @AppStorage(Pref.tabLayout) private var tabLayout = TabLayout.top.rawValue
    @AppStorage(Pref.accent) private var accent = Accent.blue.rawValue
    @AppStorage(Pref.ambient) private var ambient = AmbientLevel.vivid.rawValue
    @AppStorage(Pref.showPinsBar) private var showPinsBar = true

    var body: some View {
        Form {
            Picker("Tabs", selection: $tabLayout) {
                ForEach(TabLayout.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)

            Toggle("Show pins bar", isOn: $showPinsBar)

            Picker("Glow effects", selection: $ambient) {
                ForEach(AmbientLevel.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)

            LabeledContent("Accent") {
                HStack(spacing: 10) {
                    ForEach(Accent.allCases) { a in
                        Circle()
                            .fill(a.gradient)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.white, lineWidth: accent == a.rawValue ? 2.5 : 0))
                            .shadow(color: accent == a.rawValue ? a.color.opacity(0.6) : .clear, radius: 4)
                            .onTapGesture { accent = a.rawValue }
                            .help(a.rawValue.capitalized)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PasswordSettings: View {
    private let loginsState = State(initialValue: PasswordStore.all())
    private let searchState = State(initialValue: "")
    private let revealedState = State(initialValue: [String: String]())

    var body: some View {
        let search = searchState.wrappedValue.lowercased()
        let logins = loginsState.wrappedValue.filter {
            search.isEmpty || $0.host.contains(search) || $0.username.lowercased().contains(search)
        }
        VStack(spacing: 0) {
            TextField("Search passwords", text: searchState.projectedValue)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            if logins.isEmpty {
                ContentUnavailableView("No saved passwords", systemImage: "key",
                                       description: Text("Log in to a site and Orbit will offer to save it."))
                    .frame(height: 300)
            } else {
                List(logins) { login in
                    HStack(spacing: 10) {
                        SiteIcon(host: login.host, title: login.host)
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(login.host).font(.system(size: 13, weight: .medium))
                            Text(revealedState.wrappedValue[login.id] ?? login.username)
                                .font(.system(size: 11, design: revealedState.wrappedValue[login.id] == nil ? .default : .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            toggleReveal(login)
                        } label: {
                            Image(systemName: revealedState.wrappedValue[login.id] == nil ? "eye" : "eye.slash")
                        }
                        .buttonStyle(.borderless)
                        .help("Show password")
                        Button {
                            copy(login)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy password")
                        Button(role: .destructive) {
                            PasswordStore.delete(login)
                            loginsState.wrappedValue = PasswordStore.all()
                            for tab in Browser.shared.tabs { tab.refreshLogins() }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete")
                    }
                    .padding(.vertical, 3)
                }
                .frame(height: 320)
            }
        }
        .onAppear { loginsState.wrappedValue = PasswordStore.all() }
    }

    private func toggleReveal(_ login: Login) {
        if revealedState.wrappedValue[login.id] != nil {
            revealedState.wrappedValue[login.id] = nil
            return
        }
        Task {
            guard await PasswordStore.authenticate(reason: "show the password for \(login.host)"),
                  let pw = PasswordStore.password(for: login) else { return }
            revealedState.wrappedValue[login.id] = pw
        }
    }

    private func copy(_ login: Login) {
        Task {
            guard await PasswordStore.authenticate(reason: "copy the password for \(login.host)"),
                  let pw = PasswordStore.password(for: login) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pw, forType: .string)
        }
    }
}
