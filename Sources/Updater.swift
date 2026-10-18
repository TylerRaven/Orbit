import AppKit
import SwiftUI

/// Keeps Orbit up to date from GitHub Releases. The repo is `OrbitUpdateRepo` in Info.plist ("owner/name").
/// A release's tag is its version ("v1.2"), and it carries the Orbit.dmg that `./build.sh --dmg` makes.
/// Installing swaps the app bundle in place once Orbit quits, then relaunches it.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let notes: String
        let dmg: URL
    }

    enum Status: Equatable {
        case idle, checking, upToDate, notSetUp
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)

        /// Whether the window note has anything to say.
        var showsBanner: Bool { self != .idle }
    }

    var status: Status = .idle
    /// The bottom-of-window note offering the update.
    var showBanner = false

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static var repo: String? {
        let r = (Bundle.main.object(forInfoDictionaryKey: "OrbitUpdateRepo") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        return r.contains("/") ? r : nil
    }

    /// GitHub's latest-release endpoint, or ORBIT_UPDATE_FEED to test against a local copy of that JSON.
    private static var feed: URL? {
        if let test = ProcessInfo.processInfo.environment["ORBIT_UPDATE_FEED"] { return URL(string: test) }
        return repo.flatMap { URL(string: "https://api.github.com/repos/\($0)/releases/latest") }
    }

    private static let lastCheckKey = "updater.lastCheck"
    private var timer: Timer?

    /// On launch: check after a short wait, then once a day while Orbit stays open.
    func start() {
        guard Self.feed != nil else { status = .notSetUp; return }
        Task {
            try? await Task.sleep(for: .seconds(8))
            await autoCheck()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.autoCheck() }
        }
    }

    private func autoCheck() async {
        let d = UserDefaults.standard
        guard d.bool(forKey: Pref.autoUpdate) else { return }
        let last = d.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        await check(userInitiated: false)
    }

    /// Asks GitHub for the latest release. Quiet unless there's something new or the user asked.
    func check(userInitiated: Bool = true) async {
        guard let api = Self.feed else {
            status = .notSetUp
            return
        }
        switch status {
        case .checking, .downloading, .installing: return
        default: break
        }
        status = .checking
        do {
            var req = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Orbit/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { throw UpdateError("No releases published yet.") }
            guard code == 200 else { throw UpdateError("GitHub answered \(code).") }
            let json = try JSONDecoder().decode(GitHubRelease.self, from: data)
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

            let version = json.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            guard Self.isNewer(version, than: Self.currentVersion) else {
                status = .upToDate
                return
            }
            guard let asset = json.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
                  let dmg = URL(string: asset.browser_download_url) else {
                throw UpdateError("Release \(version) has no .dmg attached.")
            }
            status = .available(Release(version: version, notes: json.body ?? "", dmg: dmg))
            showBanner = true
        } catch {
            status = userInitiated ? .failed(Self.describe(error)) : .idle
        }
    }

    /// Downloads the new dmg, stages the app inside it, then quits and relaunches into it.
    func install() {
        guard case .available(let release) = status else { return }
        Task {
            do {
                status = .downloading(0)
                let dmg = try await download(release.dmg)
                status = .installing
                let staged = try await Task.detached { try Self.stage(dmg: dmg, expecting: release.version) }.value
                try Self.relaunch(into: staged)
            } catch {
                status = .failed(Self.describe(error))
            }
        }
    }

    // MARK: - Steps

    private func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                observation?.invalidate()
                if let error { return cont.resume(throwing: error) }
                guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return cont.resume(throwing: UpdateError("The download didn't finish."))
                }
                // The temp file is deleted when this handler returns, so move it somewhere of our own.
                let dest = FileManager.default.temporaryDirectory.appending(path: "Orbit-update-\(UUID().uuidString).dmg")
                do {
                    try FileManager.default.moveItem(at: file, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in
                let f = p.fractionCompleted
                Task { @MainActor in
                    if case .downloading = Updater.shared.status { Updater.shared.status = .downloading(f) }
                }
            }
            task.resume()
        }
    }

    /// Mounts the dmg, copies Orbit.app out of it and checks it really is a newer Orbit.
    nonisolated private static func stage(dmg: URL, expecting version: String) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "Orbit-update-\(UUID().uuidString)")
        let mount = work.appending(path: "mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: dmg)
        }
        guard let name = try fm.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError("The download doesn't contain Orbit.")
        }
        let staged = work.appending(path: "Orbit.app")
        try run("/usr/bin/ditto", [mount.appending(path: name).path, staged.path])

        let info = Bundle(url: staged)?.infoDictionary ?? [:]
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download isn't Orbit.")
        }
        let got = info["CFBundleShortVersionString"] as? String ?? ""
        guard isNewer(got, than: currentVersion) else {
            throw UpdateError("The download is version \(got), expected \(version).")
        }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    /// Hands off to a tiny script that waits for Orbit to quit, swaps the bundle and reopens it.
    private static func relaunch(into staged: URL) throws {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError("Orbit can't replace itself in \(parent.path). Move it to Applications first.")
        }
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "$1" && /usr/bin/ditto "$2" "$1" && rm -rf "$(dirname "$2")"
        /usr/bin/open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "orbit-update", target.path, staged.path]
        try p.run()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
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
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    private static func describe(_ error: Error) -> String {
        (error as? UpdateError)?.message ?? error.localizedDescription
    }

    private struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let body: String?
        let assets: [Asset]
    }
}

/// Glass note at the bottom of the window offering a new version, with download progress.
struct UpdateBanner: View {
    let accent: Accent
    private var updater: Updater { .shared }

    var body: some View {
        HStack(spacing: 12) {
            OrbitMarkSmall()
            switch updater.status {
            case .available(let release):
                Text("Orbit \(release.version) is ready")
                    .font(.system(size: 12.5, weight: .medium))
                Button("Later") { updater.showBanner = false }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Update & Restart") { updater.install() }
                    .buttonStyle(.borderedProminent)
                    .tint(accent.color)
                    .controlSize(.small)
            case .downloading(let f):
                Text("Downloading update…")
                    .font(.system(size: 12.5, weight: .medium))
                ProgressView(value: f)
                    .frame(width: 110)
                    .tint(accent.color)
            case .installing:
                Text("Installing — Orbit will reopen")
                    .font(.system(size: 12.5, weight: .medium))
                ProgressView().controlSize(.small)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .leading)
                Button("Close") { updater.showBanner = false }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            case .checking:
                Text("Checking for updates…")
                    .font(.system(size: 12.5, weight: .medium))
                ProgressView().controlSize(.small)
            case .upToDate:
                Text("Orbit \(Updater.currentVersion) is up to date")
                    .font(.system(size: 12.5, weight: .medium))
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        updater.showBanner = false
                    }
            case .notSetUp:
                Text("Updates aren't set up for this copy of Orbit")
                    .font(.system(size: 12.5, weight: .medium))
                Button("Close") { updater.showBanner = false }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 12))
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(minHeight: 44)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
        .animation(.easeOut(duration: 0.2), value: updater.status)
    }
}

/// The Updates section in General settings.
struct UpdateSettings: View {
    @AppStorage(Pref.autoUpdate) private var autoUpdate = true
    private var updater: Updater { .shared }

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $autoUpdate)
            LabeledContent("Orbit \(Updater.currentVersion)") {
                HStack(spacing: 8) {
                    statusText.foregroundStyle(.secondary)
                    switch updater.status {
                    case .available:
                        Button("Update & Restart") { updater.install() }
                    case .checking, .downloading, .installing, .notSetUp:
                        EmptyView()
                    default:
                        Button("Check Now") { Task { await updater.check() } }
                    }
                }
            }
        }
    }

    @ViewBuilder private var statusText: some View {
        switch updater.status {
        case .checking: Text("Checking…")
        case .upToDate: Text("Up to date")
        case .notSetUp: Text("No update source set")
        case .available(let r): Text("\(r.version) available")
        case .downloading(let f): Text("Downloading \(Int(f * 100))%")
        case .installing: Text("Installing…")
        case .failed(let m): Text(m).lineLimit(2)
        case .idle: EmptyView()
        }
    }
}
