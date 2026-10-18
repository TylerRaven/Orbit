import AppKit
import Foundation
import Observation
import SQLite3

/// Bookmarks brought in from other browsers. Searchable in ⌘K; the ones from a bookmarks bar become pins.
@MainActor
@Observable
final class Bookmarks {
    static let shared = Bookmarks()
    private(set) var items: [QuickLink] = []

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bookmarks.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([QuickLink].self, from: data) { items = saved }
    }

    /// Adds new bookmarks (skipping ones already there); returns how many were new.
    @discardableResult
    func add(_ links: [QuickLink]) -> Int {
        var seen = Set(items.map(\.url))
        let fresh = links.filter { seen.insert($0.url).inserted }
        items += fresh
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.file, options: .atomic) }
        return fresh.count
    }

    func search(_ text: String, limit: Int = 6) -> [QuickLink] {
        let q = text.lowercased()
        guard !q.isEmpty else { return [] }
        return Array(items.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }.prefix(limit))
    }
}

enum Importer {
    struct Result {
        var pins = 0, bookmarks = 0, history = 0, passwords = 0
        var summary: String {
            var parts: [String] = []
            if pins > 0 { parts.append("\(pins) pins") }
            if bookmarks > 0 { parts.append("\(bookmarks) bookmarks") }
            if history > 0 { parts.append("\(history) history entries") }
            if passwords > 0 { parts.append("\(passwords) passwords") }
            return parts.isEmpty ? "Nothing new to import." : "Imported " + parts.joined(separator: ", ") + "."
        }
    }

    struct Source: Identifiable {
        let name: String
        let profile: URL
        var id: String { profile.path }
    }

    /// Chrome-family browsers installed on this Mac (they all store data the same way).
    static func chromiumSources() -> [Source] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let known: [(String, String)] = [
            ("Chrome", "Google/Chrome/Default"),
            ("Opera", "com.operasoftware.Opera/Default"),
            ("Opera", "com.operasoftware.Opera"),
            ("Opera Air", "com.operasoftware.OperaAir/Default"),
            ("Opera GX", "com.operasoftware.OperaGX/Default"),
            ("Brave", "BraveSoftware/Brave-Browser/Default"),
            ("Edge", "Microsoft Edge/Default"),
            ("Arc", "Arc/User Data/Default"),
            ("Vivaldi", "Vivaldi/Default"),
        ]
        var found: [Source] = []
        for (name, path) in known {
            let profile = base.appendingPathComponent(path)
            let has = ["Bookmarks", "History"].contains { FileManager.default.fileExists(atPath: profile.appendingPathComponent($0).path) }
            if has, !found.contains(where: { $0.name == name }) { found.append(Source(name: name, profile: profile)) }
        }
        return found
    }

    // MARK: Chrome-family

    @MainActor
    static func importChromium(_ source: Source) -> Result {
        var result = Result()
        let bookmarksFile = source.profile.appendingPathComponent("Bookmarks")
        if let data = try? Data(contentsOf: bookmarksFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let roots = json["roots"] as? [String: Any] {
            var bar: [QuickLink] = [], all: [QuickLink] = []
            func walk(_ node: [String: Any], into list: inout [QuickLink]) {
                if node["type"] as? String == "url", let url = node["url"] as? String, url.hasPrefix("http") {
                    list.append(QuickLink(title: node["name"] as? String ?? url, url: url))
                }
                for child in node["children"] as? [[String: Any]] ?? [] { walk(child, into: &list) }
            }
            if let barNode = roots["bookmark_bar"] as? [String: Any] {
                // Only the top level of the bar becomes pins; folders inside it are just bookmarks.
                for child in barNode["children"] as? [[String: Any]] ?? [] where child["type"] as? String == "url" {
                    if let url = child["url"] as? String, url.hasPrefix("http") {
                        bar.append(QuickLink(title: child["name"] as? String ?? url, url: url))
                    }
                }
                walk(barNode, into: &all)
            }
            for (key, value) in roots where key != "bookmark_bar" {
                if let node = value as? [String: Any] { walk(node, into: &all) }
            }
            result.pins = addPins(bar)
            result.bookmarks = Bookmarks.shared.add(all)
        }
        result.history = importChromiumHistory(source.profile.appendingPathComponent("History"))
        return result
    }

    /// Reads Chrome-family history (an SQLite file the browser keeps locked, so we read a copy).
    @MainActor
    private static func importChromiumHistory(_ file: URL) -> Int {
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-import-\(UUID().uuidString).db")
        guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else { return 0 }
        defer { try? FileManager.default.removeItem(at: copy) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT 3000"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        var entries: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let u = sqlite3_column_text(stmt, 0) else { continue }
            let url = String(cString: u)
            guard url.hasPrefix("http") else { continue }
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let visits = Int(sqlite3_column_int(stmt, 2))
            // Chrome time: microseconds since 1601-01-01.
            let micros = sqlite3_column_int64(stmt, 3)
            let date = Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600)
            entries.append(HistoryEntry(url: url, title: title, date: date, visits: max(1, visits)))
        }
        return History.shared.merge(entries)
    }

    // MARK: Bookmarks file (Safari, Firefox, anything)

    /// Netscape bookmark HTML, the format every browser exports.
    @MainActor
    static func importBookmarksFile(_ file: URL) -> Result {
        var result = Result()
        guard let html = try? String(contentsOf: file, encoding: .utf8) else { return result }
        var bar: [QuickLink] = [], all: [QuickLink] = []
        var depth = 0
        var barDepth: Int?
        let barNames = ["favorites", "favourites", "favorites bar", "favourites bar", "bookmarks bar", "bookmarks toolbar"]
        let link = try! NSRegularExpression(pattern: #"<A[^>]*HREF="([^"]+)"[^>]*>(.*?)</A>"#, options: [.caseInsensitive])
        let folder = try! NSRegularExpression(pattern: #"<H3([^>]*)>(.*?)</H3>"#, options: [.caseInsensitive])

        for line in html.components(separatedBy: .newlines) {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = folder.firstMatch(in: line, range: range) {
                let attrs = ns.substring(with: m.range(at: 1)).lowercased()
                let name = decode(ns.substring(with: m.range(at: 2))).lowercased()
                if attrs.contains("personal_toolbar_folder") || barNames.contains(name) { barDepth = depth + 1 }
            }
            if line.range(of: "<DL", options: .caseInsensitive) != nil { depth += 1 }
            if line.range(of: "</DL", options: .caseInsensitive) != nil {
                if depth == barDepth { barDepth = nil }
                depth -= 1
            }
            if let m = link.firstMatch(in: line, range: range) {
                let url = decode(ns.substring(with: m.range(at: 1)))
                guard url.hasPrefix("http") else { continue }
                let title = decode(ns.substring(with: m.range(at: 2)))
                let item = QuickLink(title: title.isEmpty ? url : title, url: url)
                all.append(item)
                if let barDepth, depth == barDepth { bar.append(item) }
            }
        }
        result.pins = addPins(bar)
        result.bookmarks = Bookmarks.shared.add(all)
        return result
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    @MainActor
    private static func addPins(_ links: [QuickLink]) -> Int {
        var pins = Pins.load()
        var seen = Set(pins.map(\.url))
        let fresh = links.prefix(30).filter { seen.insert($0.url).inserted }
        pins += fresh
        Pins.save(pins)
        return fresh.count
    }

    // MARK: Passwords (CSV from Chrome, Safari or Apple Passwords)

    @MainActor
    static func importPasswordsFile(_ file: URL) -> Result {
        var result = Result()
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return result }
        let rows = parseCSV(text)
        guard let header = rows.first?.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }) else { return result }
        func column(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
        guard let urlCol = column(["url", "website", "login_uri"]),
              let userCol = column(["username", "user name", "login", "login_username"]),
              let passCol = column(["password", "login_password"]) else { return result }

        for row in rows.dropFirst() where row.count > max(urlCol, userCol, passCol) {
            let raw = row[urlCol].trimmingCharacters(in: .whitespaces)
            let url = URL(string: raw.contains("://") ? raw : "https://" + raw)
            guard let host = url?.host(), !row[passCol].isEmpty else { continue }
            PasswordStore.save(Login(host: host, username: row[userCol]), password: row[passCol])
            result.passwords += 1
        }
        for tab in Browser.shared.tabs { tab.refreshLogins() }
        return result
    }

    /// Minimal CSV reader: commas, quoted fields, doubled quotes, newlines inside quotes.
    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n")).makeIterator()
        var pending: Character?
        while let c = pending ?? chars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    @MainActor
    static func chooseFile(types: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types.compactMap { .init(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
