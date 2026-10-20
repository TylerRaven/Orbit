import AppKit
import Foundation
import Observation

/// Ollama: free AI models that run locally, for Macs without Apple Intelligence.
/// Orbit can install the Ollama app, download a model sized to this Mac, and chat with it
/// over Ollama's local API (127.0.0.1:11434). Nothing leaves the Mac.
@MainActor
@Observable
final class Ollama {
    static let shared = Ollama()

    enum State: Equatable {
        case checking
        case notInstalled
        case installing(String)
        case notRunning
        case starting
        case noModel
        case downloading(Double)
        case ready(String)
        case failed(String)
    }

    struct ModelChoice {
        let name: String
        let label: String
        let size: String
    }

    private(set) var state: State = .checking
    var model: String? { if case .ready(let m) = state { m } else { nil } }

    nonisolated private static let api = URL(string: "http://127.0.0.1:11434/api/")!
    private static let modelKey = "ollamaModel"

    // MARK: Picking a model for this Mac

    /// Gemma 3 sized to the Mac's memory. Intel Macs run on the CPU, so they stay small.
    static var recommended: ModelChoice {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        var isAppleSilicon = false
        #if arch(arm64)
        isAppleSilicon = true
        #endif
        switch gb {
        case ..<12: return ModelChoice(name: "gemma3:1b", label: "Gemma 3 (small)", size: "0.8 GB")
        case ..<24: return ModelChoice(name: "gemma3:4b", label: "Gemma 3 (medium)", size: "3.3 GB")
        case ..<48 where isAppleSilicon: return ModelChoice(name: "gemma3:12b", label: "Gemma 3 (large)", size: "8.1 GB")
        default:
            return isAppleSilicon ? ModelChoice(name: "gemma3:27b", label: "Gemma 3 (extra large)", size: "17 GB")
                                  : ModelChoice(name: "gemma3:4b", label: "Gemma 3 (medium)", size: "3.3 GB")
        }
    }

    static var memoryDescription: String {
        "\(Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())) GB"
    }

    // MARK: State

    /// Works out where Ollama stands: installed? running? has a model?
    func refresh() async {
        if case .installing = state { return }
        if case .downloading = state { return }
        if let models = await Self.installedModels() {
            let saved = UserDefaults.standard.string(forKey: Self.modelKey)
            if let pick = models.first(where: { $0 == saved }) ?? models.first(where: { $0.hasPrefix("gemma3") }) ?? models.first {
                state = .ready(pick)
            } else {
                state = .noModel
            }
        } else {
            state = Self.appURL != nil || Self.cliURL != nil ? .notRunning : .notInstalled
        }
    }

    /// Starts Ollama if it's installed but not running, then waits for it.
    func start() async {
        state = .starting
        if let app = Self.appURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: config)
        } else if let cli = Self.cliURL {
            let p = Process()
            p.executableURL = cli
            p.arguments = ["serve"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
        for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(1))
            if await Self.installedModels() != nil { return await refresh() }
        }
        state = .failed("Ollama didn't start. Try opening the Ollama app yourself.")
    }

    // MARK: Installing Ollama

    /// Downloads the official Ollama app, checks it's genuinely signed by Ollama and notarized
    /// by Apple, puts it in Applications and starts it.
    func install() async {
        state = .installing("Downloading Ollama…")
        do {
            let (zip, response) = try await URLSession.shared.download(from: URL(string: "https://ollama.com/download/Ollama-darwin.zip")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw OllamaError("The download didn't finish.") }
            state = .installing("Checking the download…")
            let app = try await Task.detached { try Self.unpackAndVerify(zip) }.value

            state = .installing("Installing…")
            let fm = FileManager.default
            var dest = URL(fileURLWithPath: "/Applications/Ollama.app")
            if !fm.isWritableFile(atPath: "/Applications") {
                let user = fm.homeDirectoryForCurrentUser.appending(path: "Applications")
                try fm.createDirectory(at: user, withIntermediateDirectories: true)
                dest = user.appending(path: "Ollama.app")
            }
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: app, to: dest)
            await start()
        } catch {
            state = .failed((error as? OllamaError)?.message ?? "Couldn't install Ollama: \(error.localizedDescription)")
        }
    }

    nonisolated private static func unpackAndVerify(_ zip: URL) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appending(path: "Ollama-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        try? FileManager.default.removeItem(at: zip)
        let app = work.appending(path: "Ollama.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw OllamaError("The download doesn't contain Ollama.") }
        // Only install a Developer ID app that Apple has notarized, with Ollama's bundle ID.
        let assessment = try run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", app.path])
        guard assessment.contains("accepted"), assessment.contains("Notarized Developer ID") else {
            throw OllamaError("The Ollama download didn't pass Apple's security check, so it wasn't installed.")
        }
        guard Bundle(url: app)?.bundleIdentifier == "com.electron.ollama" || Bundle(url: app)?.bundleIdentifier?.hasPrefix("com.ollama") == true else {
            throw OllamaError("The download isn't the Ollama app, so it wasn't installed.")
        }
        return app
    }

    // MARK: Downloading a model

    func downloadModel(_ choice: ModelChoice) async {
        state = .downloading(0)
        do {
            var req = URLRequest(url: Self.api.appending(path: "pull"))
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: ["model": choice.name, "stream": true])
            req.timeoutInterval = 3600
            let (bytes, _) = try await URLSession.shared.bytes(for: req)
            for try await line in bytes.lines {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let err = obj["error"] as? String { throw OllamaError("Ollama couldn't download the model: \(err)") }
                if let total = obj["total"] as? Double, total > 0, let done = obj["completed"] as? Double {
                    state = .downloading(done / total)
                }
                if obj["status"] as? String == "success" {
                    UserDefaults.standard.set(choice.name, forKey: Self.modelKey)
                    state = .ready(choice.name)
                    return
                }
            }
            await refresh()
        } catch {
            state = .failed((error as? OllamaError)?.message ?? "The model download stopped: \(error.localizedDescription)")
        }
    }

    // MARK: Chatting

    /// Streams a reply from the model, yielding the whole answer so far each time.
    nonisolated static func chat(model: String, messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: api.appending(path: "chat"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 600
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model, "messages": messages, "stream": true,
                        "options": ["num_ctx": 8192],
                    ] as [String: Any])
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw OllamaError("Ollama isn't answering. Is it still running?")
                    }
                    var text = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                        if let err = obj["error"] as? String { throw OllamaError(err) }
                        if let piece = (obj["message"] as? [String: Any])?["content"] as? String {
                            text += piece
                            continuation.yield(text)
                        }
                        if obj["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Helpers

    nonisolated private static func installedModels() async -> [String]? {
        var req = URLRequest(url: api.appending(path: "tags"), timeoutInterval: 2)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    private static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama")
            ?? ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"]
                .map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var cliURL: URL? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
            .map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
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
        guard p.terminationStatus == 0 else { throw OllamaError(text.isEmpty ? "\(tool) failed" : text) }
        return text
    }
}

struct OllamaError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
