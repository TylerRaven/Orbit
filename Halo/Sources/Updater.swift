import AppKit

/// Keeps Halo up to date by itself, from GitHub Releases.
///
/// Halo shares a repo with Orbit, so its releases are tagged `halo-v0.2` (never marked "latest",
/// which belongs to Orbit). When a newer one appears, Halo downloads it, checks it's really Halo
/// signed by the same developer, waits until it isn't busy, then swaps itself and reopens.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum Status: Equatable {
        case idle, checking, upToDate, notSetUp
        case downloading(String)
        case ready(String)          // staged, waiting for Halo to be idle
        case failed(String)
    }

    var status: Status = .idle
    var auto: Bool = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(auto, forKey: "autoUpdate") }
    }

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static let tagPrefix = "halo-v"
    @ObservationIgnored private var staged: URL?

    private static var repo: String? {
        let r = (Bundle.main.object(forInfoDictionaryKey: "HaloUpdateRepo") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return r.contains("/") ? r : nil
    }

    /// HALO_UPDATE_FEED points at a local copy of the releases JSON, for testing.
    private static var testFeed: URL? { ProcessInfo.processInfo.environment["HALO_UPDATE_FEED"].flatMap(URL.init(string:)) }

    private static var feed: URL? {
        testFeed ?? repo.flatMap { URL(string: "https://api.github.com/repos/\($0)/releases?per_page=40") }
    }

    func start() {
        guard Self.feed != nil else { status = .notSetUp; return }
        Task {
            try? await Task.sleep(for: .seconds(Self.testFeed == nil ? 15 : 2))
            await check(userInitiated: false)
        }
        Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(userInitiated: false) }
        }
        // Install a staged update as soon as Halo isn't in the middle of something.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.installIfIdle() }
        }
    }

    func check(userInitiated: Bool = true) async {
        guard let feed = Self.feed else { status = .notSetUp; return }
        guard userInitiated || auto else { return }
        switch status {
        case .checking, .downloading, .ready: return
        default: break
        }
        status = .checking
        do {
            var req = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Halo/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 200 // file:// feeds have no status
            guard code == 200 else { throw Failure("GitHub answered \(code).") }
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)

            // Newest Halo release, ignoring drafts, pre-releases and Orbit's own.
            let best = releases
                .filter { !$0.draft && !$0.prerelease && $0.tag_name.hasPrefix(Self.tagPrefix) }
                .map { (version: String($0.tag_name.dropFirst(Self.tagPrefix.count)), release: $0) }
                .max { Self.isNewer($1.version, than: $0.version) }
            guard let best, Self.isNewer(best.version, than: Self.currentVersion) else {
                status = .upToDate
                return
            }
            guard let asset = best.release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
                  let url = URL(string: asset.browser_download_url) else {
                throw Failure("Halo \(best.version) has no .dmg attached.")
            }
            guard Self.testFeed != nil || (url.scheme == "https" && url.host()?.hasSuffix("github.com") == true) else {
                throw Failure("Halo \(best.version) points somewhere other than GitHub.")
            }

            status = .downloading(best.version)
            let dmg = try await download(url)
            staged = try await Task.detached { try Self.stage(dmg: dmg, expecting: best.version) }.value
            status = .ready(best.version)
            installIfIdle()
        } catch {
            status = userInitiated ? .failed((error as? Failure)?.message ?? error.localizedDescription) : .idle
        }
    }

    private func installIfIdle() {
        guard case .ready(let version) = status, let staged else { return }
        // Never restart in the middle of a task, an approval or a question.
        guard !Agent.shared.busy else { return }
        Agent.shared.noteUpdate("Updating Halo to \(version) — back in a moment.")
        do { try Self.relaunch(into: staged) }
        catch { status = .failed((error as? Failure)?.message ?? error.localizedDescription) }
    }

    // MARK: Steps

    private func download(_ url: URL) async throws -> URL {
        let (file, resp) = try await URLSession.shared.download(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw Failure("The download didn't finish.") }
        let dest = FileManager.default.temporaryDirectory.appending(path: "Halo-update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: file, to: dest)
        return dest
    }

    /// Mounts the dmg, copies Halo out and checks it's a newer Halo from the same developer.
    nonisolated private static func stage(dmg: URL, expecting version: String) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "Halo-update-\(UUID().uuidString)")
        let mount = work.appending(path: "mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: dmg)
        }
        guard let name = try fm.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
            throw Failure("The download doesn't contain Halo.")
        }
        let staged = work.appending(path: "Halo.app")
        try run("/usr/bin/ditto", [mount.appending(path: name).path, staged.path])

        let info = Bundle(url: staged)?.infoDictionary ?? [:]
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw Failure("The download isn't Halo.") }
        let got = info["CFBundleShortVersionString"] as? String ?? ""
        guard isNewer(got, than: currentVersion) else { throw Failure("The download is version \(got), expected \(version).") }

        // Same signer as this copy, so it's genuine — and macOS keeps Halo's permissions.
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        let mine = team(of: Bundle.main.bundleURL), theirs = team(of: staged)
        if let mine, mine != theirs { throw Failure("The download is signed by someone else, so it wasn't installed.") }

        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    nonisolated private static func team(of app: URL) -> String? {
        guard let out = try? run("/usr/bin/codesign", ["-dv", app.path]) else { return nil }
        return out.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { $0 == "not set" ? nil : $0 }
    }

    /// A tiny script waits for Halo to quit, swaps the bundle and reopens it.
    private static func relaunch(into staged: URL) throws {
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw Failure("Halo can't replace itself where it is. Move it to Applications.")
        }
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "$1" && /usr/bin/ditto "$2" "$1" && rm -rf "$(dirname "$2")"
        /usr/bin/open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "halo-update", target.path, staged.path]
        try p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
    }

    // MARK: Helpers

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw Failure("\((tool as NSString).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    private struct Failure: Error {
        let message: String
        init(_ m: String) { message = m }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
}
