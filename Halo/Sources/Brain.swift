import Foundation

/// Talks to a local model through Ollama (127.0.0.1:11434). Nothing leaves the Mac.
enum Brain {
    static let api = URL(string: "http://127.0.0.1:11434/api/")!

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// Installed model names, or nil if Ollama isn't running.
    static func models() async -> [String]? {
        var req = URLRequest(url: api.appending(path: "tags"), timeoutInterval: 2)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["models"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["name"] as? String }
    }

    /// Whether a model can look at images.
    static func canSee(_ model: String) async -> Bool {
        var req = URLRequest(url: api.appending(path: "show"), timeoutInterval: 5)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let caps = obj["capabilities"] as? [String] { return caps.contains("vision") }
        // Older Ollama: look for a vision projector in the model details.
        return (obj["projector_info"] as? [String: Any]) != nil
    }

    /// Runs one turn. The reply is JSON matching `schema`; `onSay` gets the "say" text live as it streams.
    static func step(model: String, system: String, messages: [[String: Any]], schema: String,
                     onSay: @escaping @MainActor (String) -> Void) async throws -> [String: Any] {
        var req = URLRequest(url: api.appending(path: "chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        // The schema goes in as raw text so its key order survives.
        let placeholder = "__HALO_SCHEMA__"
        let body = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "system", "content": system]] + messages,
            "stream": true,
            "format": placeholder,
            "keep_alive": "30m",
            "options": ["num_ctx": 8192, "temperature": 0.3],
        ] as [String: Any])
        req.httpBody = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\"\(placeholder)\"", with: schema).utf8)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Failure("Ollama isn't answering.") }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            let msg = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? String
            throw Failure(msg ?? "Ollama said HTTP \(http.statusCode).")
        }

        var text = ""
        var lastSay = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let err = obj["error"] as? String { throw Failure(err) }
            if let piece = (obj["message"] as? [String: Any])?["content"] as? String {
                text += piece
                if let say = partialString(field: "say", in: text), say != lastSay {
                    lastSay = say
                    await onSay(say)
                }
            }
            if obj["done"] as? Bool == true { break }
        }

        if let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        // Not JSON (shouldn't happen with a schema): treat it as plain talk.
        return ["say": text.trimmingCharacters(in: .whitespacesAndNewlines), "tool": "none"]
    }

    /// Pulls a string field out of JSON that's still arriving, e.g. `{"say": "Hel` → "Hel".
    static func partialString(field: String, in json: String) -> String? {
        guard let keyRange = json.range(of: "\"\(field)\"") else { return nil }
        var i = keyRange.upperBound
        while i < json.endIndex, json[i] == " " || json[i] == ":" || json[i] == "\n" { i = json.index(after: i) }
        guard i < json.endIndex, json[i] == "\"" else { return nil }
        i = json.index(after: i)
        var out = ""
        var escaped = false
        while i < json.endIndex {
            let c = json[i]
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "u":
                    // \uXXXX
                    let hexStart = json.index(after: i)
                    if let hexEnd = json.index(hexStart, offsetBy: 4, limitedBy: json.endIndex),
                       let code = UInt32(json[hexStart..<hexEnd], radix: 16), let scalar = Unicode.Scalar(code) {
                        out.unicodeScalars.append(scalar)
                        i = json.index(before: hexEnd)
                    }
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                break
            } else {
                out.append(c)
            }
            i = json.index(after: i)
        }
        return out
    }
}
