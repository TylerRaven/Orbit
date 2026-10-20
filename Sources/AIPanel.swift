import SwiftUI

/// Floating glass panel for Orbit AI, over the right side of the page.
struct AIPanel: View {
    let accent: Accent
    let tab: Tab?
    @FocusState private var focused: Bool
    private let inputState = State(initialValue: "")
    private var ai: Assistant { Assistant.shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !ai.isAvailable { AISetupCard(accent: accent) }
                        else if ai.messages.isEmpty { empty }
                        ForEach(ai.messages) { msg in
                            bubble(msg).id(msg.id)
                        }
                        if let status = ai.status {
                            Label(status, systemImage: "sparkles")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .symbolEffect(.pulse)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: ai.messages.last?.text) {
                    if let id = ai.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            if ai.isAvailable { input }
        }
        .frame(width: 360)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear {
            focused = true
            if !ai.isAvailable { Task { await Ollama.shared.refresh() } }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(accent.gradient)
                .font(.system(size: 14, weight: .semibold))
            Text("Orbit AI").font(.system(size: 14, weight: .semibold))
            Text(ai.modelLabel)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .help(ai.engineHelp)
            Spacer()
            NavButton(symbol: "square.and.pencil", help: "New chat", enabled: !ai.messages.isEmpty) { ai.reset() }
            NavButton(symbol: "xmark", help: "Close (⌘J)", enabled: true) { ai.isOpen = false }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 48)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about this page, or anything at all. It all runs on your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if tab?.isBlank == false {
                chip("Summarize this page", "text.badge.star") { ai.summarize(tab) }
                chip("Key takeaways", "list.bullet") { ai.ask("What are the most important takeaways from this page?", about: tab) }
                chip("Explain it simply", "lightbulb") { ai.ask("Explain this page like I'm 12.", about: tab) }
                if Browser.shared.spaceTabs.filter({ !$0.isBlank }).count > 1 {
                    chip("Compare my open tabs", "square.on.square") {
                        ai.askAboutTabs("Compare the pages I have open: what each is, how they differ, and which one is best for what.")
                    }
                }
            } else {
                chip("Give me a fun fact", "dice") { ai.ask("Tell me a surprising fun fact.", about: nil) }
                chip("Plan my day", "calendar") { ai.ask("Help me plan a productive day in 5 bullet points.", about: nil) }
            }
        }
        .padding(.top, 4)
    }

    private func chip(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 30)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    @ViewBuilder
    private func bubble(_ msg: AIMessage) -> some View {
        if msg.fromUser {
            Text(msg.text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(accent.gradient))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        } else if msg.text.isEmpty {
            TypingDots()
        } else {
            Text(Self.markdown(msg.text))
                .font(.system(size: 13))
                .foregroundStyle(msg.isError ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var input: some View {
        HStack(spacing: 8) {
            TextField(tab?.isBlank == false ? "Ask about this page" : "Ask anything", text: inputState.projectedValue, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: ai.isBusy ? "stop.fill" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(accent.gradient))
            }
            .buttonStyle(.plain)
            .disabled(!ai.isBusy && inputState.wrappedValue.isEmpty)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(10)
    }

    private func send() {
        if ai.isBusy { ai.reset(); return }
        let q = inputState.wrappedValue
        inputState.wrappedValue = ""
        ai.ask(q, about: tab)
    }

    /// Inline markdown, keeping line breaks so bullet lists stay readable.
    static func markdown(_ text: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        // Drop "---" divider lines and "#" heading marks, which inline markdown would show as-is.
        let cleaned = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces) != "---" }
            .map { line in line.hasPrefix("#") ? "**" + line.drop(while: { $0 == "#" || $0 == " " }) + "**" : String(line) }
            .joined(separator: "\n")
        let bulleted = cleaned.replacingOccurrences(of: "\n- ", with: "\n• ").replacingOccurrences(of: "\n* ", with: "\n• ")
        let fixed = bulleted.hasPrefix("- ") || bulleted.hasPrefix("* ") ? "• " + bulleted.dropFirst(2) : bulleted
        return (try? AttributedString(markdown: fixed, options: opts)) ?? AttributedString(text)
    }
}

/// Shown instead of the chat when this Mac has no AI yet: turn on Apple Intelligence if it can,
/// otherwise install Ollama and download a model sized to this Mac.
struct AISetupCard: View {
    let accent: Accent
    private var ollama: Ollama { .shared }
    private var ai: Assistant { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up Orbit AI").font(.system(size: 15, weight: .semibold))
            Text(ai.unavailableReason ?? "Orbit AI needs a model to run on.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)

            if ai.appleCouldWork {
                option(icon: "apple.intelligence", title: "Use Apple Intelligence",
                       detail: "Built into macOS. Turn it on in System Settings, then come back.") {
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                    }
                }
            }

            option(icon: "cpu", title: ai.appleCouldWork ? "Or use a free local model" : "Use a free local model",
                   detail: ollamaDetail) { ollamaAction }

            Label("Everything runs on your Mac. Pages you ask about are never sent anywhere.", systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var ollamaDetail: String {
        let pick = Ollama.recommended
        switch ollama.state {
        case .notInstalled:
            return "Orbit installs Ollama (free, about 200 MB), then downloads \(pick.label), picked for this Mac's \(Ollama.memoryDescription) of memory (\(pick.size))."
        case .noModel:
            return "Ollama is ready. Download \(pick.label), picked for this Mac's \(Ollama.memoryDescription) of memory (\(pick.size))."
        case .notRunning: return "Ollama is installed but not running."
        case .failed(let message): return message
        default: return "Ollama runs AI models right on this Mac."
        }
    }

    @ViewBuilder private var ollamaAction: some View {
        switch ollama.state {
        case .checking, .starting:
            ProgressView().controlSize(.small)
        case .notInstalled:
            Button("Install Ollama") { Task { await ollama.install() } }
        case .installing(let step):
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(step).font(.system(size: 11)) }
        case .notRunning:
            Button("Start Ollama") { Task { await ollama.start() } }
        case .noModel:
            Button("Download \(Ollama.recommended.size)") { Task { await ollama.downloadModel(Ollama.recommended) } }
        case .downloading(let f):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: f).tint(accent.color)
                Text("Downloading… \(Int(f * 100))%").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Button("Try Again") { Task { await ollama.refresh() } }
        }
    }

    private func option<A: View>(icon: String, title: String, detail: String, @ViewBuilder action: () -> A) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            action().controlSize(.small).buttonStyle(.borderedProminent).tint(accent.color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        }
    }
}
