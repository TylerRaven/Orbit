import AppKit
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, halo, step, note }
    let id = UUID()
    var role: Role
    var text: String
    var symbol: String? = nil      // for step/note rows
    var noticed = false            // Halo spoke up on its own
}

/// The assistant: chats, looks at the screen, draws on it, asks questions in popups, and
/// carries out tasks one approved step at a time.
@MainActor
@Observable
final class Agent {
    static let shared = Agent()

    // What the chat shows
    var messages: [ChatMessage] = []
    var busy = false
    var status = ""

    // Settings
    var model: String = UserDefaults.standard.string(forKey: "model") ?? "" {
        didSet { UserDefaults.standard.set(model, forKey: "model"); Task { await checkModel() } }
    }
    var watching: Bool = UserDefaults.standard.object(forKey: "watching") as? Bool ?? true {
        didSet { UserDefaults.standard.set(watching, forKey: "watching") }
    }
    var glanceEvery: Double = UserDefaults.standard.object(forKey: "glanceEvery") as? Double ?? 45 {
        didSet { UserDefaults.standard.set(glanceEvery, forKey: "glanceEvery") }
    }
    var showGrid: Bool = UserDefaults.standard.object(forKey: "grid") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showGrid, forKey: "grid") }
    }

    // Model state
    var installed: [String] = []
    var ollamaRunning = false
    var modelCanSee = false

    @ObservationIgnored private var history: [[String: Any]] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var snap: Snapshot?
    @ObservationIgnored private var allowRest = false
    @ObservationIgnored private var lastGlance = Date()
    @ObservationIgnored private var lastGlanceSnap: Snapshot?
    @ObservationIgnored private var lastUserActivity = Date()

    /// Called when Halo speaks up on its own while the chat is hidden.
    @ObservationIgnored var onNotice: ((String) -> Void)?

    private init() {}

    func start() {
        Task { await checkModel() }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { Agent.shared.maybeGlance() }
        }
    }

    // MARK: Model

    func checkModel() async {
        guard let list = await Brain.models() else {
            ollamaRunning = false
            installed = []
            return
        }
        ollamaRunning = true
        installed = list
        if model.isEmpty || !list.contains(model) {
            // Prefer a model that can see.
            var pick: String?
            for m in list where await Brain.canSee(m) { pick = m; break }
            if let p = pick ?? list.first, p != model { model = p; return }
        }
        modelCanSee = model.isEmpty ? false : await Brain.canSee(model)
    }

    // MARK: Chat

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if busy { stop() }
        lastUserActivity = Date()
        messages.append(ChatMessage(role: .user, text: text))
        allowRest = false
        task = Task { await run(userText: text) }
    }

    func stop() {
        task?.cancel()
        task = nil
        Popups.cancelPending()
        busy = false
        status = ""
        if let i = messages.lastIndex(where: { $0.role == .halo }), messages[i].text.isEmpty { messages.remove(at: i) }
    }

    func clearChat() {
        stop()
        messages.removeAll()
        history.removeAll()
        Overlay.shared.clear()
    }

    private func run(userText: String) async {
        busy = true
        defer { busy = false; status = "" }
        await checkModel()
        guard ollamaRunning else {
            messages.append(ChatMessage(role: .note, text: "Ollama isn't running. Open the Ollama app (or run `ollama serve`) and try again.", symbol: "exclamationmark.triangle"))
            return
        }
        guard !model.isEmpty else {
            messages.append(ChatMessage(role: .note, text: "No model installed yet. Pull one with Ollama, then pick it in Halo's settings.", symbol: "exclamationmark.triangle"))
            return
        }

        var first: [String: Any] = ["role": "user"]
        var context = "[\(contextLine())]"
        if modelCanSee, let s = await look() {
            first["images"] = [s.jpegBase64]
            context += " [Screenshot attached: \(Int(s.imageSize.width))×\(Int(s.imageSize.height))]"
        }
        first["content"] = "\(context)\n\n\(userText)"
        history.append(first)

        var lastStep = "", repeats = 0
        for _ in 0..<40 {
            if Task.isCancelled { return }
            guard let step = await think(system: systemPrompt(glance: false), schema: Self.schema(glance: false)) else { return }
            let tool = (step["tool"] as? String) ?? "none"
            if tool == "none" || tool == "done" { return }
            // Small models can get stuck doing the same thing over and over.
            // Compare the action only — the wording of "say" often changes while the action doesn't.
            var action = step
            action["say"] = nil
            let signature = (try? JSONSerialization.data(withJSONObject: action, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            repeats = signature == lastStep ? repeats + 1 : 0
            lastStep = signature
            if repeats >= 2 {
                messages.append(ChatMessage(role: .note, text: "Halo kept repeating the same step, so it stopped. A bigger model would do better here.", symbol: "arrow.trianglehead.2.clockwise"))
                return
            }
            let result = await perform(tool, step)
            if Task.isCancelled { return }
            var msg: [String: Any] = ["role": "user", "content": "[Result of \(tool)] \(result.text)"]
            if let s = result.snap { msg["images"] = [s.jpegBase64] }
            history.append(msg)
        }
        messages.append(ChatMessage(role: .note, text: "Stopped after 40 steps so it doesn't run forever.", symbol: "hand.raised"))
    }

    /// One call to the model; streams the "say" text into a chat bubble.
    private func think(system: String, schema: String, glance: Bool = false) async -> [String: Any]? {
        status = "Thinking…"
        trimHistory()
        let bubble = ChatMessage(role: .halo, text: "", noticed: glance)
        if !glance { messages.append(bubble) }
        let id = bubble.id
        do {
            let step = try await Brain.step(model: model, system: system, messages: history, schema: schema) { [weak self] say in
                guard let self, !glance, let i = self.messages.firstIndex(where: { $0.id == id }) else { return }
                self.messages[i].text = say
            }
            let say = (step["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = messages.firstIndex(where: { $0.id == id }) {
                if say.isEmpty { messages.remove(at: i) } else { messages[i].text = say }
            }
            // Keep the model's own JSON in the history so it stays in format.
            if let data = try? JSONSerialization.data(withJSONObject: step), let raw = String(data: data, encoding: .utf8) {
                history.append(["role": "assistant", "content": raw])
            }
            return step
        } catch {
            if let i = messages.firstIndex(where: { $0.id == id }), messages[i].text.isEmpty { messages.remove(at: i) }
            if !(error is CancellationError) && !Task.isCancelled {
                messages.append(ChatMessage(role: .note, text: "The model hit a problem: \(error)", symbol: "exclamationmark.triangle"))
            }
            return nil
        }
    }

    /// Only the newest screenshot is sent with each request (they're big), and old turns drop off.
    private func trimHistory() {
        if history.count > 36 { history.removeFirst(history.count - 36) }
        while let first = history.first, first["role"] as? String == "assistant" { history.removeFirst() }
        if let last = history.lastIndex(where: { $0["images"] != nil }) {
            for i in history.indices where i != last && history[i]["images"] != nil {
                history[i]["images"] = nil
                history[i]["content"] = (history[i]["content"] as? String ?? "") + " [old screenshot removed]"
            }
        }
    }

    private func look() async -> Snapshot? {
        status = "Looking…"
        do {
            let s = try await Eyes.look(grid: showGrid)
            snap = s
            return s
        } catch {
            return nil
        }
    }

    private func contextLine() -> String {
        let f = Focus.shared
        f.update()
        var parts = ["Front app: \(f.frontAppName.isEmpty ? "unknown" : f.frontAppName)"]
        if let s = snap {
            let m = s.toImage(Geo.mouse)
            parts.append("mouse at (\(m.0), \(m.1))")
            if let c = f.caret { let p = s.toImage(c.origin); parts.append("text cursor at (\(p.0), \(p.1))") }
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE d MMM, HH:mm"
        parts.append(fmt.string(from: Date()))
        return parts.joined(separator: ", ")
    }

    // MARK: Tools

    private struct Result {
        var text: String
        var snap: Snapshot? = nil
    }

    private func num(_ step: [String: Any], _ key: String) -> Double? {
        if let d = step[key] as? Double { return d }
        if let i = step[key] as? Int { return Double(i) }
        if let n = step[key] as? NSNumber { return n.doubleValue }
        if let s = step[key] as? String { return Double(s) }
        return nil
    }

    private func str(_ step: [String: Any], _ key: String) -> String? {
        guard let s = step[key] as? String, !s.isEmpty else { return nil }
        return s
    }

    private func currentSnap() async -> Snapshot? {
        if let s = snap, Date().timeIntervalSince(s.takenAt) < 120 { return s }
        return await look()
    }

    private func perform(_ tool: String, _ step: [String: Any]) async -> Result {
        let label = str(step, "label")

        switch tool {
        case "look":
            guard modelCanSee else { return Result(text: "This model can't see images. Use `elements` instead.") }
            guard let s = await look() else { return Result(text: "Couldn't capture the screen (Screen Recording permission may be off).") }
            return Result(text: "Fresh screenshot attached (\(Int(s.imageSize.width))×\(Int(s.imageSize.height))). \(contextLine())", snap: s)

        case "elements":
            status = "Reading the window…"
            guard Hands.hasPermission else { return Result(text: "Accessibility permission is off, so I can't read the window.") }
            guard let s = await currentSnap() else { return Result(text: "Couldn't capture the screen.") }
            let (app, items) = await UIElements.scanFrontWindow()
            if items.isEmpty { return Result(text: "No readable controls found in \(app).") }
            let lines = items.map { it -> String in
                let (x, y, w, h) = s.toImage(it.frame)
                return "- \(it.role) \"\(it.label)\" x:\(x) y:\(y) w:\(w) h:\(h) (centre \(x + w / 2),\(y + h / 2))"
            }
            note("list.bullet.rectangle", "Read \(items.count) controls in \(app)")
            return Result(text: "Controls in \(app) (screenshot coordinates):\n" + lines.joined(separator: "\n"))

        case "highlight", "box", "outline":
            guard let s = await currentSnap(), let r = rect(step, s) else { return Result(text: "Need x, y, w, h.") }
            let kind: Mark.Kind = tool == "highlight" ? .highlight(r) : tool == "box" ? .box(r) : .outline(r)
            Overlay.shared.add(kind, color: Mark.color(named: str(step, "color"), default: tool == "box" ? .red : tool == "outline" ? .cyan : .yellow), label: label, lifetime: 40)
            return Result(text: "Drawn.")

        case "arrow":
            guard let s = await currentSnap(), let x = num(step, "x"), let y = num(step, "y"),
                  let x2 = num(step, "x2"), let y2 = num(step, "y2") else { return Result(text: "Need x, y, x2, y2.") }
            Overlay.shared.add(.arrow(s.toScreen(x, y), s.toScreen(x2, y2)), color: Mark.color(named: str(step, "color"), default: .orange), label: label, lifetime: 40)
            return Result(text: "Drawn.")

        case "draw":
            guard let s = await currentSnap(), let raw = step["points"] as? [Any] else { return Result(text: "Need points [[x,y],…].") }
            let pts: [CGPoint] = raw.compactMap { p in
                guard let a = p as? [Any], a.count >= 2,
                      let x = (a[0] as? NSNumber)?.doubleValue, let y = (a[1] as? NSNumber)?.doubleValue else { return nil }
                return s.toScreen(x, y)
            }
            guard pts.count >= 2 else { return Result(text: "Need at least two points.") }
            Overlay.shared.add(.path(pts), color: Mark.color(named: str(step, "color"), default: .pink), label: label, lifetime: 40)
            return Result(text: "Drawn.")

        case "write":
            guard let s = await currentSnap(), let text = str(step, "text") else { return Result(text: "Need text (and x, y).") }
            let p = s.toScreen(num(step, "x") ?? Double(s.imageSize.width) / 2 - 100, num(step, "y") ?? 80)
            Overlay.shared.add(.text(p, text), color: Mark.color(named: str(step, "color"), default: .white), lifetime: 30)
            return Result(text: "Written on screen.")

        case "clear":
            Overlay.shared.clear()
            return Result(text: "Cleared the drawings.")

        case "ask":
            let q = str(step, "question") ?? str(step, "text") ?? "Can you tell me more?"
            let options = (step["options"] as? [String]) ?? []
            status = "Waiting for you…"
            note("questionmark.bubble", q)
            guard let answer = await Popups.ask(q, options: options) else {
                note("xmark.circle", "You dismissed the question")
                return Result(text: "The user dismissed the question without answering.")
            }
            messages.append(ChatMessage(role: .user, text: answer))
            return Result(text: "The user answered: \(answer)")

        case "wait":
            let secs = min(30, max(0.5, num(step, "seconds") ?? 2))
            status = "Waiting…"
            try? await Task.sleep(for: .seconds(secs))
            return await afterAction("Waited \(secs)s.")

        case "click", "type", "key", "scroll", "drag", "open_app", "open_url":
            return await act(tool, step)

        default:
            return Result(text: "Unknown tool \"\(tool)\".")
        }
    }

    private func rect(_ step: [String: Any], _ s: Snapshot) -> CGRect? {
        guard let x = num(step, "x"), let y = num(step, "y") else { return nil }
        let w = num(step, "w") ?? 60, h = num(step, "h") ?? 30
        return s.toScreen(x, y, max(4, w), max(4, h))
    }

    // MARK: Actions (always approved first)

    private func act(_ tool: String, _ step: [String: Any]) async -> Result {
        guard Hands.hasPermission else {
            return Result(text: "Halo doesn't have Accessibility permission, so it can't control the mouse or keyboard. Tell the user to turn it on in Halo's settings.")
        }
        guard let s = await currentSnap() else { return Result(text: "Couldn't see the screen.") }
        let say = (step["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Work out what it'll do and show it on screen before asking.
        var icon = "cursorarrow.click", title = "", preview: String?
        var marks: [UUID] = []
        var target: CGPoint?
        var target2: CGPoint?
        switch tool {
        case "click":
            guard let x = num(step, "x"), let y = num(step, "y") else { return Result(text: "click needs x and y.") }
            target = s.toScreen(x, y)
            let right = step["right"] as? Bool == true, double = step["double"] as? Bool == true
            title = double ? "Double-click here?" : right ? "Right-click here?" : "Click here?"
            icon = right ? "contextualmenu.and.cursorarrow" : "cursorarrow.click"
            marks.append(Overlay.shared.add(.target(target!), color: .pink, label: label(step) ?? "click", lifetime: nil))
        case "drag":
            guard let x = num(step, "x"), let y = num(step, "y"), let x2 = num(step, "x2"), let y2 = num(step, "y2") else { return Result(text: "drag needs x, y, x2, y2.") }
            target = s.toScreen(x, y); target2 = s.toScreen(x2, y2)
            title = "Drag from here to there?"
            icon = "hand.draw"
            marks.append(Overlay.shared.add(.arrow(target!, target2!), color: .pink, label: "drag", lifetime: nil))
        case "type":
            guard let text = step["text"] as? String, !text.isEmpty else { return Result(text: "type needs text.") }
            title = "Type this?"
            icon = "keyboard"
            preview = text
            if let x = num(step, "x"), let y = num(step, "y") {
                target = s.toScreen(x, y)
                title = "Click here, then type this?"
                marks.append(Overlay.shared.add(.target(target!), color: .pink, label: "type here", lifetime: nil))
            } else if let c = Focus.shared.caret {
                marks.append(Overlay.shared.add(.outline(c.insetBy(dx: -3, dy: -2)), color: .pink, label: "types here", lifetime: nil))
            }
        case "key":
            guard let keys = str(step, "keys") ?? str(step, "text") else { return Result(text: "key needs keys, like \"cmd+c\".") }
            title = "Press \(prettyKeys(keys))?"
            icon = "command"
        case "scroll":
            let amount = Int(num(step, "amount") ?? 5)
            target = s.toScreen(num(step, "x") ?? s.imageSize.width / 2, num(step, "y") ?? s.imageSize.height / 2)
            title = amount >= 0 ? "Scroll down here?" : "Scroll up here?"
            icon = amount >= 0 ? "arrow.down.circle" : "arrow.up.circle"
            marks.append(Overlay.shared.add(.target(target!), color: .pink, label: "scroll", lifetime: nil))
        case "open_app":
            guard let name = str(step, "text") else { return Result(text: "open_app needs text (the app's name).") }
            title = "Open \(name)?"
            icon = "app.badge"
        case "open_url":
            guard let url = str(step, "text") else { return Result(text: "open_url needs text (the address).") }
            title = "Open this link?"
            icon = "link"
            preview = url
        default: break
        }
        defer { marks.forEach { Overlay.shared.remove($0) } }

        status = "Waiting for your OK…"
        let verdict: Approval
        if allowRest {
            try? await Task.sleep(for: .milliseconds(700)) // still show where it's about to act
            verdict = .allow
        } else {
            verdict = await Popups.approve(icon: icon, title: title, detail: say, preview: preview)
        }
        if Task.isCancelled { return Result(text: "Stopped.") }

        switch verdict {
        case .deny(let note):
            self.note("hand.raised", "You said no to: \(title.replacingOccurrences(of: "?", with: ""))")
            if let note { messages.append(ChatMessage(role: .user, text: note)) }
            return Result(text: "The user did NOT allow this step." + (note.map { " They said: \($0)" } ?? " Ask what they'd like instead, or try another way."))
        case .allowRest:
            allowRest = true
        case .allow:
            break
        }

        // Let the dodger clear Halo's windows off the target before acting.
        try? await Task.sleep(for: .milliseconds(250))
        status = "Working…"
        let done: String
        switch tool {
        case "click":
            await Hands.click(at: target!, right: step["right"] as? Bool == true, double: step["double"] as? Bool == true)
            done = "Clicked"
        case "drag":
            await Hands.drag(from: target!, to: target2!)
            done = "Dragged"
        case "type":
            let text = step["text"] as! String
            if let t = target { await Hands.click(at: t) ; try? await Task.sleep(for: .milliseconds(200)) }
            ChatWindow.shared.giveFocusBack()
            await Hands.type(text)
            done = "Typed “\(text.prefix(40))\(text.count > 40 ? "…" : "")”"
        case "key":
            let keys = str(step, "keys") ?? str(step, "text") ?? ""
            ChatWindow.shared.giveFocusBack()
            let ok = await Hands.press(keys)
            if !ok { return Result(text: "I don't know the key \"\(keys)\". Use names like cmd+c, return, esc, tab, up, f5.") }
            done = "Pressed \(prettyKeys(keys))"
        case "scroll":
            await Hands.scroll(at: target!, lines: Int(num(step, "amount") ?? 5))
            done = "Scrolled"
        case "open_app":
            let ok = await Hands.openApp(str(step, "text")!)
            if !ok { return Result(text: "There's no app called \"\(str(step, "text")!)\".") }
            done = "Opened \(str(step, "text")!)"
        case "open_url":
            _ = Hands.openURL(str(step, "text")!)
            done = "Opened \(str(step, "text")!)"
        default:
            done = "Done"
        }
        note("checkmark.circle", done)
        try? await Task.sleep(for: .milliseconds(700)) // let the screen settle
        return await afterAction("\(done). It worked as far as I can tell.")
    }

    private func label(_ step: [String: Any]) -> String? { str(step, "label") }

    private func afterAction(_ text: String) async -> Result {
        if modelCanSee, let s = await look() {
            return Result(text: "\(text) New screenshot attached. \(contextLine())", snap: s)
        }
        return Result(text: "\(text) \(contextLine())")
    }

    private func note(_ symbol: String, _ text: String) {
        messages.append(ChatMessage(role: .step, text: text, symbol: symbol))
    }

    private func prettyKeys(_ k: String) -> String {
        k.lowercased().split(separator: "+").map { part -> String in
            switch part.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command": "⌘"
            case "shift": "⇧"
            case "opt", "option", "alt": "⌥"
            case "ctrl", "control": "⌃"
            case "return", "enter": "↩"
            case "esc", "escape": "esc"
            case "delete", "backspace": "⌫"
            case "tab": "⇥"
            case "space": "space"
            case let other: other.uppercased()
            }
        }.joined()
    }

    // MARK: Looking around on its own

    /// Every so often, if the screen has changed and nothing else is going on, Halo takes a
    /// look and decides whether there's anything worth saying or pointing at.
    private func maybeGlance() {
        guard watching, !busy, ollamaRunning, modelCanSee, Eyes.hasPermission,
              Date().timeIntervalSince(lastGlance) >= glanceEvery,
              Date().timeIntervalSince(lastUserActivity) > 8 else { return }
        lastGlance = Date()
        task = Task { await glance() }
    }

    private func glance() async {
        guard let s = try? await Eyes.look(grid: showGrid) else { return }
        // Nothing much changed since last time? Don't bother the model.
        if let prev = lastGlanceSnap, s.difference(from: prev) < 0.025 { return }
        lastGlanceSnap = s
        snap = s
        busy = true
        defer { busy = false; status = "" }

        history.append(["role": "user", "images": [s.jpegBase64],
                        "content": "[Glance — the user didn't ask anything. \(contextLine()). Screenshot attached: \(Int(s.imageSize.width))×\(Int(s.imageSize.height))]"])
        guard let step = await think(system: systemPrompt(glance: true), schema: Self.schema(glance: true), glance: true) else {
            if !history.isEmpty { history.removeLast() }
            return
        }
        let say = (step["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tool = step["tool"] as? String ?? "none"
        if ["highlight", "box", "outline", "arrow", "draw", "write"].contains(tool) {
            _ = await perform(tool, step)
        }
        if !say.isEmpty {
            messages.append(ChatMessage(role: .halo, text: say, noticed: true))
            onNotice?(say)
        } else {
            // Keep quiet glances out of the conversation.
            history.removeLast(min(2, history.count))
        }
    }

    // MARK: Prompt

    private func systemPrompt(glance: Bool) -> String {
        let size = snap.map { "\(Int($0.imageSize.width))×\(Int($0.imageSize.height))" } ?? "unknown"
        var p = """
        You are Halo, a helpful assistant that lives on the user's Mac. You chat with them, you can see their screen, \
        you can draw on it, and you can operate the mouse and keyboard for them — but only with their approval.

        Reply with ONE JSON object every turn: {"say": "...", "tool": "...", ...arguments}.
        "say" is what you tell the user (short and friendly, plain text). "tool" is what you do next.

        Screen coordinates are pixels in the latest screenshot (\(size)), origin top-left. The faint pink grid \
        with numbers marks every 100 pixels — use it to read positions accurately. Your own windows are hidden from screenshots.

        Tools:
        - none: just talk, or you've finished. Use this when there's nothing more to do.
        - look: take a fresh screenshot.
        - elements: list the buttons, fields and links in the front window with exact coordinates. Use it before clicking whenever you can — it's far more accurate than guessing from the picture.
        - highlight / box / outline {x, y, w, h, label?, color?}: mark an area on screen to show the user something.
        - arrow {x, y, x2, y2, label?}: point from one spot to another.
        - draw {points: [[x,y],...], color?}: draw a freehand line (e.g. circle or underline something).
        - write {x, y, text}: write text directly on the screen.
        - clear: remove your drawings.
        - ask {question, options?}: ask the user something in a popup. Use it whenever something is unclear or you need a choice.
        - click {x, y, double?, right?}: click a point.
        - type {text, x?, y?}: type text (if x,y given, clicks there first).
        - key {keys}: press a shortcut, e.g. "cmd+t", "return", "esc", "cmd+shift+4".
        - scroll {x, y, amount}: scroll; positive = down, negative = up.
        - drag {x, y, x2, y2}: drag from one point to another.
        - open_app {text}: open an app by name.  open_url {text}: open a web address.
        - wait {seconds}: wait for something to load.

        Rules:
        - click, type, key, scroll, drag, open_app and open_url are shown to the user as an approval popup first. \
        In "say", explain that step in a few words so they know what they're approving. If they say no, don't repeat it — ask or try another way.
        - For a task: first say your plan in one or two sentences. Ask (with the ask tool) if anything is unclear. Then do it one step at a time.
        - After each action you get a new screenshot. Check it worked before moving on.
        - When you point something out, draw on the screen (highlight, box, outline, arrow) rather than only describing it.
        - When you're finished, use tool "none" and say briefly what you did.
        """
        if !modelCanSee {
            p += "\n\nThis model cannot see images. You get no screenshots. Use `elements` to find out what's on screen and where."
        }
        if glance {
            p += """


            Right now you're just glancing at the screen — the user didn't ask you anything. Only speak up if you \
            can genuinely help: a mistake you can see, an error message you can explain, something they seem stuck on, \
            or a quicker way to do what they're doing. Most of the time stay quiet: reply {"say": "", "tool": "none"}. \
            If you do speak, keep it to one or two sentences, and you may use highlight, box, outline, arrow, draw or write to point at it.
            """
        }
        return p
    }

    /// The reply format, as a JSON schema. Written out by hand so "say" comes first —
    /// that way the user sees the words stream in before the model picks a tool.
    static func schema(glance: Bool) -> String {
        let tools = glance
            ? ["none", "highlight", "box", "outline", "arrow", "draw", "write"]
            : ["none", "look", "elements", "highlight", "box", "outline", "arrow", "draw", "write", "clear", "ask",
               "click", "type", "key", "scroll", "drag", "open_app", "open_url", "wait"]
        let toolList = tools.map { "\"\($0)\"" }.joined(separator: ",")
        let n = #"{"type":"number"}"#, s = #"{"type":"string"}"#, b = #"{"type":"boolean"}"#
        return """
        {"type":"object","properties":{"say":\(s),"tool":{"type":"string","enum":[\(toolList)]},\
        "x":\(n),"y":\(n),"w":\(n),"h":\(n),"x2":\(n),"y2":\(n),"text":\(s),"keys":\(s),"question":\(s),\
        "options":{"type":"array","items":\(s)},"points":{"type":"array","items":{"type":"array","items":\(n)}},\
        "amount":\(n),"seconds":\(n),"double":\(b),"right":\(b),"label":\(s),"color":\(s)},\
        "required":["say","tool"]}
        """
    }
}
