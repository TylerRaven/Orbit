import MapKit
import SwiftUI

struct QuickLink: Codable, Hashable, Identifiable {
    var title: String
    var url: String
    var id: String { url }
    var host: String { URL(string: url)?.host() ?? url }

    static let defaults: [QuickLink] = [
        QuickLink(title: "YouTube", url: "https://www.youtube.com"),
        QuickLink(title: "Gmail", url: "https://mail.google.com"),
        QuickLink(title: "GitHub", url: "https://github.com"),
        QuickLink(title: "Reddit", url: "https://www.reddit.com"),
        QuickLink(title: "Spotify", url: "https://open.spotify.com"),
        QuickLink(title: "Discord", url: "https://discord.com/app"),
    ]

    static func load(_ raw: String) -> [QuickLink] {
        guard let data = raw.data(using: .utf8), !raw.isEmpty,
              let links = try? JSONDecoder().decode([QuickLink].self, from: data) else { return defaults }
        return links
    }

    static func encode(_ links: [QuickLink]) -> String {
        String(decoding: (try? JSONEncoder().encode(links)) ?? Data(), as: UTF8.self)
    }
}

struct StartPage: View {
    var focus: FocusState<Field?>.Binding
    let accent: Accent
    var isPrivate = false
    let onSubmit: (String) -> Void

    @AppStorage(Pref.wallpaper) private var wallpaper = WallpaperStyle.aurora.rawValue
    @AppStorage(Pref.wallpaperReactive) private var reactive = true
    @AppStorage(Pref.wallpaperIntensity) private var intensity = 0.8
    @AppStorage(Pref.wallpaperImage) private var imagePath = ""
    @AppStorage(Pref.userName) private var userName = ""
    @AppStorage(Pref.showClock) private var showClock = true
    @AppStorage(Pref.showLinks) private var showLinks = true
    @AppStorage(Pref.showWeather) private var showWeather = true
    @AppStorage(Pref.showNotes) private var showNotes = true
    @AppStorage(Pref.quickLinks) private var linksRaw = ""

    private let queryState = State(initialValue: "")
    private var query: String { queryState.wrappedValue }
    private let customizingState = State(initialValue: false)
    private let editingLinksState = State(initialValue: false)

    private var style: WallpaperStyle { WallpaperStyle(rawValue: wallpaper) ?? .aurora }
    private var onDark: Bool { style != .solid }

    var body: some View {
        ZStack {
            LiveWallpaper(style: style, accent: accent, intensity: intensity,
                          reactive: reactive, imagePath: imagePath)

            VStack(spacing: 26) {
                Spacer(minLength: 20)
                if isPrivate { privateNote }
                if showClock { clock }
                searchField
                Text("Tip: start with ? to ask Orbit AI")
                    .font(.system(size: 11, weight: .medium))
                    .opacity(query.hasPrefix("?") ? 0.9 : 0)
                    .offset(y: -14)
                    .animation(.easeOut(duration: 0.2), value: query.hasPrefix("?"))
                if showLinks { links }
                Spacer(minLength: 20)
                if showWeather || showNotes {
                    HStack(alignment: .top, spacing: 14) {
                        if showWeather { WeatherCard() }
                        if showNotes { NotesCard() }
                    }
                    .frame(maxWidth: 640)
                }
            }
            .padding(28)
            .foregroundStyle(onDark ? Color.white : Color.primary)
        }
        .overlay(alignment: .topTrailing) {
            Button { customizingState.wrappedValue.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(onDark ? Color.white : Color.primary)
            .glassEffect(.regular.interactive(), in: Circle())
            .padding(14)
            .help("Customise start page")
            .popover(isPresented: customizingState.projectedValue, arrowEdge: .bottom) {
                StartPageSettings()
                    .padding(18)
                    .frame(width: 330)
            }
        }
        .environment(\.colorScheme, onDark ? .dark : .light)
    }

    // MARK: Pieces

    private var privateNote: some View {
        VStack(spacing: 6) {
            Label("Private tab", systemImage: "eye.slash.fill")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("No history, no saved session, no password saving. Cookies and site data vanish when you close your last private tab. Ads, trackers, third-party cookies and tracking links are blocked.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .opacity(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 4) {
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 76, weight: .thin, design: .rounded))
                    .monospacedDigit()
                Text(greeting(at: ctx.date))
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .opacity(0.85)
            }
            .shadow(color: .black.opacity(onDark ? 0.25 : 0), radius: 10, y: 2)
        }
    }

    private func greeting(at date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let part = switch hour {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Up late"
        }
        let name = userName.trimmingCharacters(in: .whitespaces)
        let day = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return name.isEmpty ? "\(part) · \(day)" : "\(part), \(name) · \(day)"
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .opacity(0.7)
            TextField("Search", text: queryState.projectedValue)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused(focus, equals: .start)
                .onSubmit {
                    onSubmit(query)
                    if query.hasPrefix("?") { queryState.wrappedValue = "" }
                }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .glassEffect(.regular.interactive(), in: Capsule())
        .overlay(
            Capsule().strokeBorder(focus.wrappedValue == .start ? accent.color : .clear, lineWidth: 2)
        )
        .frame(maxWidth: 580)
    }

    private var links: some View {
        let items = QuickLink.load(linksRaw)
        let editing = editingLinksState.wrappedValue
        return VStack(spacing: 10) {
            HStack(spacing: 14) {
                ForEach(items) { link in
                    QuickLinkTile(link: link, editing: editing) {
                        linksRaw = QuickLink.encode(items.filter { $0 != link })
                    }
                }
                if editing || items.isEmpty {
                    AddLinkTile { new in linksRaw = QuickLink.encode(items + [new]) }
                }
            }
            Button(editing ? "Done" : "Edit shortcuts") { editingLinksState.wrappedValue.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .opacity(0.6)
        }
    }
}

// MARK: - Quick links

struct QuickLinkTile: View {
    let link: QuickLink
    let editing: Bool
    let onRemove: () -> Void
    private let hoverState = State(initialValue: false)

    var body: some View {
        Button {
            guard !editing, let url = URL(string: link.url) else { return }
            WallpaperMood.shared.pulse(1.0)
            Browser.shared.selected?.load(url)
        } label: {
            VStack(spacing: 7) {
                SiteIcon(host: link.host, title: link.title)
                    .frame(width: 30, height: 30)
                    .frame(width: 58, height: 58)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .scaleEffect(hoverState.wrappedValue && !editing ? 1.08 : 1)
                    .overlay(alignment: .topTrailing) {
                        if editing {
                            Button(action: onRemove) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                        }
                    }
                Text(link.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(width: 70)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25), value: hoverState.wrappedValue)
        .onHover { inside in
            hoverState.wrappedValue = inside
            WallpaperMood.shared.hover(host: inside ? link.host : nil)
        }
        .contextMenu {
            Button("Open in New Tab") { if let url = URL(string: link.url) { Browser.shared.newTab(url: url) } }
            Button("Remove", role: .destructive, action: onRemove)
        }
    }
}

struct AddLinkTile: View {
    let onAdd: (QuickLink) -> Void
    private let showingState = State(initialValue: false)
    private let titleState = State(initialValue: "")
    private let urlState = State(initialValue: "")

    var body: some View {
        Button { showingState.wrappedValue = true } label: {
            VStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 58, height: 58)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("Add")
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: showingState.projectedValue) {
            VStack(alignment: .leading, spacing: 10) {
                Text("New shortcut").font(.headline)
                TextField("Name", text: titleState.projectedValue)
                TextField("Address", text: urlState.projectedValue)
                    .onSubmit(add)
                HStack {
                    Spacer()
                    Button("Add", action: add)
                        .keyboardShortcut(.defaultAction)
                        .disabled(urlState.wrappedValue.isEmpty)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(16)
            .frame(width: 260)
        }
    }

    private func add() {
        guard let url = Browser.resolve(urlState.wrappedValue) else { return }
        let title = titleState.wrappedValue.trimmingCharacters(in: .whitespaces)
        onAdd(QuickLink(title: title.isEmpty ? (url.host() ?? url.absoluteString) : title, url: url.absoluteString))
        titleState.wrappedValue = ""
        urlState.wrappedValue = ""
        showingState.wrappedValue = false
    }
}

/// A site's touch icon, falling back to its favicon, then its first letter.
struct SiteIcon: View {
    let host: String
    let title: String

    var body: some View {
        AsyncImage(url: URL(string: "https://\(host)/apple-touch-icon.png")) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else if phase.error != nil {
                AsyncImage(url: URL(string: "https://\(host)/favicon.ico")) { p in
                    if let image = p.image { image.resizable().interpolation(.high) } else { letter }
                }
            } else {
                letter
            }
        }
    }

    private var letter: some View {
        Text(String(title.prefix(1)).uppercased())
            .font(.system(size: 18, weight: .bold, design: .rounded))
    }
}

// MARK: - Widgets

struct NotesCard: View {
    @AppStorage(Pref.notes) private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Notes", systemImage: "note.text")
                .font(.system(size: 12, weight: .semibold))
                .opacity(0.75)
            TextEditor(text: $notes)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(height: 74)
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("Jot something down…").font(.system(size: 13)).opacity(0.45)
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct WeatherCard: View {
    @AppStorage(Pref.weatherCity) private var city = "London"
    @AppStorage(Pref.fahrenheit) private var fahrenheit = false
    private let weather = Weather.shared

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: weather.report?.symbol ?? "cloud")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 34))
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                if let r = weather.report {
                    Text(temp(r.now)).font(.system(size: 28, weight: .light, design: .rounded))
                    Text("\(r.place) · H \(temp(r.high))  L \(temp(r.low))")
                        .font(.system(size: 12)).opacity(0.75).lineLimit(1)
                } else {
                    Text(weather.failed ? "No weather" : "…").font(.system(size: 22, weight: .light))
                    Text(city).font(.system(size: 12)).opacity(0.75)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 240, height: 108, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: city) {
            try? await Task.sleep(for: .milliseconds(500)) // wait for typing to settle
            if !Task.isCancelled { await weather.load(city: city) }
        }
    }

    private func temp(_ c: Double) -> String {
        "\(Int((fahrenheit ? c * 9 / 5 + 32 : c).rounded()))°"
    }
}

/// Current weather from Open-Meteo (free, no key), cached for 20 minutes.
@MainActor
@Observable
final class Weather {
    static let shared = Weather()

    struct Report { let place: String; let now: Double; let high: Double; let low: Double; let symbol: String }

    private(set) var report: Report?
    private(set) var failed = false
    @ObservationIgnored private var loaded: (city: String, at: Date)?

    func load(city: String) async {
        if let loaded, loaded.city == city, Date.now.timeIntervalSince(loaded.at) < 1200, report != nil { return }
        failed = false
        do {
            guard let place = try await Self.place(for: city) else {
                failed = report == nil
                return
            }

            var fc = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            fc.queryItems = [
                .init(name: "latitude", value: "\(place.latitude)"),
                .init(name: "longitude", value: "\(place.longitude)"),
                .init(name: "current", value: "temperature_2m,weather_code,is_day"),
                .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
                .init(name: "timezone", value: "auto"),
                .init(name: "forecast_days", value: "1"),
            ]
            let (fdata, _) = try await URLSession.shared.data(from: fc.url!)
            let f = try JSONDecoder().decode(ForecastResponse.self, from: fdata)
            report = Report(place: place.name, now: f.current.temperature_2m,
                            high: f.daily.temperature_2m_max.first ?? f.current.temperature_2m,
                            low: f.daily.temperature_2m_min.first ?? f.current.temperature_2m,
                            symbol: Self.symbol(code: f.current.weather_code, day: f.current.is_day == 1))
            loaded = (city, .now)
        } catch {
            failed = report == nil // keep showing the last good reading if a refresh fails
        }
    }

    /// City → coordinates via Apple Maps, remembered so it only has to work once per city.
    private static func place(for city: String) async throws -> (name: String, latitude: Double, longitude: Double)? {
        let key = "weatherPlace." + city.lowercased()
        if let saved = UserDefaults.standard.array(forKey: key), saved.count == 3,
           let name = saved[0] as? String, let lat = saved[1] as? Double, let lon = saved[2] as? Double {
            return (name, lat, lon)
        }
        var item: MKMapItem?
        for attempt in 0..<3 where item == nil {
            if attempt > 0 { try await Task.sleep(for: .seconds(2)) }
            item = try? await MKGeocodingRequest(addressString: city)?.mapItems.first
        }
        guard let item else { return nil }
        let c = item.location.coordinate
        let name = item.name ?? city
        UserDefaults.standard.set([name, c.latitude, c.longitude], forKey: key)
        return (name, c.latitude, c.longitude)
    }

    private static func symbol(code: Int, day: Bool) -> String {
        switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
        struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
        let current: Current
        let daily: Daily
    }
}

// MARK: - Customise panel (also used in Settings)

struct StartPageSettings: View {
    @AppStorage(Pref.wallpaper) private var wallpaper = WallpaperStyle.aurora.rawValue
    @AppStorage(Pref.wallpaperReactive) private var reactive = true
    @AppStorage(Pref.wallpaperIntensity) private var intensity = 0.8
    @AppStorage(Pref.wallpaperImage) private var imagePath = ""
    @AppStorage(Pref.userName) private var userName = ""
    @AppStorage(Pref.showClock) private var showClock = true
    @AppStorage(Pref.showLinks) private var showLinks = true
    @AppStorage(Pref.showWeather) private var showWeather = true
    @AppStorage(Pref.showNotes) private var showNotes = true
    @AppStorage(Pref.weatherCity) private var city = "London"
    @AppStorage(Pref.fahrenheit) private var fahrenheit = false
    @AppStorage(Pref.musicGlow) private var musicGlow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Wallpaper").font(.headline)
            HStack(spacing: 8) {
                ForEach(WallpaperStyle.allCases) { style in
                    Button {
                        if style == .image, let path = WallpaperImage.choose() { imagePath = path }
                        if style != .image || !imagePath.isEmpty { wallpaper = style.rawValue }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: style.symbol).font(.system(size: 15))
                                .frame(width: 46, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(wallpaper == style.rawValue ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(wallpaper == style.rawValue ? Color.accentColor : .clear, lineWidth: 1.5)
                                )
                            Text(style.label).font(.system(size: 10))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Toggle("Glows with the link you point at", isOn: $reactive)
            Toggle("Glow to music on every wallpaper", isOn: $musicGlow)
            if wallpaper == WallpaperStyle.sonic.rawValue || musicGlow {
                Text("Reacts to anything your Mac plays. macOS will ask once to allow system audio; you can change it in System Settings › Privacy & Security › Screen & System Audio Recording.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Intensity")
                Slider(value: $intensity, in: 0.3...1.4)
            }

            Divider()
            Text("Widgets").font(.headline)
            TextField("Your name", text: $userName)
                .textFieldStyle(.roundedBorder)
            Toggle("Clock and greeting", isOn: $showClock)
            Toggle("Shortcuts", isOn: $showLinks)
            Toggle("Notes", isOn: $showNotes)
            Toggle("Weather", isOn: $showWeather)
            if showWeather {
                HStack {
                    TextField("City", text: $city)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $fahrenheit) {
                        Text("°C").tag(false)
                        Text("°F").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 90)
                    .labelsHidden()
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}
