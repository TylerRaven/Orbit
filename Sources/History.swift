import Foundation
import Observation

struct HistoryEntry: Codable, Identifiable, Hashable {
    var url: String
    var title: String
    var date: Date
    var visits: Int
    var id: String { url }
}

/// Browsing history, newest first, saved as JSON in Application Support.
@MainActor
@Observable
final class History {
    static let shared = History()
    private static let limit = 5000

    private(set) var entries: [HistoryEntry] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func record(url: URL, title: String) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        let key = url.absoluteString
        var entry = HistoryEntry(url: key, title: title, date: .now, visits: 1)
        if let i = entries.firstIndex(where: { $0.url == key }) {
            entry.visits = entries[i].visits + 1
            if title.isEmpty { entry.title = entries[i].title }
            entries.remove(at: i)
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        scheduleSave()
    }

    func search(_ text: String, limit: Int = 8) -> [HistoryEntry] {
        let q = text.lowercased()
        guard !q.isEmpty else { return Array(entries.prefix(limit)) }
        return entries
            .filter { $0.url.lowercased().contains(q) || $0.title.lowercased().contains(q) }
            .sorted { ($0.visits, $0.date) > ($1.visits, $1.date) }
            .prefix(limit)
            .map { $0 }
    }

    func clear() {
        entries = []
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.file, options: .atomic)
            }
        }
    }
}
