import AppKit
import Combine
import SwiftUI

/// The floating chat. It never takes focus from your app unless you click into it,
/// and the Dodger slides it out of the way when you're working underneath it.
@MainActor
final class ChatWindow {
    static let shared = ChatWindow()
    private(set) var panel: FloatingPanel!
    private var appBeforeTyping: NSRunningApplication?

    private init() {}

    func build() {
        let size = CGSize(width: 372, height: 520)
        panel = FloatingPanel(size: size)
        panel.contentView = NSHostingView(rootView: ChatView())
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrame(CGRect(x: vf.maxX - size.width - 16, y: vf.minY + 16, width: size.width, height: size.height), display: false)
        Dodger.shared.manage(panel, kind: .chat)
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                let front = NSWorkspace.shared.frontmostApplication
                if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    ChatWindow.shared.appBeforeTyping = front
                }
            }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        panel.makeKey()
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { ChatWindow.shared.panel.orderOut(nil) } })
    }

    func toggle() { isVisible ? hide() : show() }

    /// Hands the keyboard back to the app the user was in, so typed keys go there — not into Halo.
    func giveFocusBack() {
        guard panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        panel.resignKey()
        (appBeforeTyping ?? NSWorkspace.shared.frontmostApplication)?.activate()
    }
}

// MARK: - Views

struct ChatView: View {
    private let agent = Agent.shared
    // Plain State storage: the @State macro plugin only ships with full Xcode.
    private let draftState = State(initialValue: "")
    private let settingsState = State(initialValue: false)
    private let pinnedState = State(initialValue: false)
    private var draft: String { get { draftState.wrappedValue } nonmutating set { draftState.wrappedValue = newValue } }
    private var showSettings: Bool { get { settingsState.wrappedValue } nonmutating set { settingsState.wrappedValue = newValue } }
    private var pinned: Bool { get { pinnedState.wrappedValue } nonmutating set { pinnedState.wrappedValue = newValue } }
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if showSettings {
                SettingsView().transition(.move(edge: .top).combined(with: .opacity))
            } else {
                PermissionBanner()
                messagesList
            }
            Divider().opacity(0.4)
            input
        }
        // A soft backing under the glass keeps text readable over busy windows.
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(6)
        .animation(.smooth(duration: 0.25), value: showSettings)
    }

    private var header: some View {
        HStack(spacing: 9) {
            HaloBadge(symbol: agent.busy ? "sparkle" : "circle.circle")
                .symbolEffect(.pulse, isActive: agent.busy)
            VStack(alignment: .leading, spacing: 0) {
                Text("Halo").font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            iconButton(agent.watching ? "eye.fill" : "eye.slash", help: agent.watching ? "Halo glances at your screen and speaks up when it can help. Click to stop." : "Let Halo glance at your screen on its own", active: agent.watching) {
                agent.watching.toggle()
            }
            iconButton(pinned ? "pin.fill" : "pin", help: pinned ? "Windows stay put. Click to let them dodge again." : "Stop windows moving out of your way", active: pinned) {
                pinned.toggle()
                Dodger.shared.paused = pinned
            }
            iconButton("trash", help: "Clear the chat and drawings") { agent.clearChat() }
            iconButton(showSettings ? "xmark.circle.fill" : "gearshape", help: "Settings", active: showSettings) { showSettings.toggle() }
            iconButton("minus", help: "Hide (⌥Space to bring back)") { ChatWindow.shared.hide() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var subtitle: String {
        if !agent.status.isEmpty { return agent.status }
        if !agent.ollamaRunning { return "Ollama isn't running" }
        if agent.model.isEmpty { return "No model yet" }
        return agent.model + (agent.modelCanSee ? "" : " · can't see")
    }

    private func iconButton(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if agent.messages.isEmpty { emptyState }
                    ForEach(agent.messages) { m in
                        MessageRow(message: m).id(m.id)
                    }
                    if agent.busy, agent.messages.last?.role != .halo || agent.messages.last?.text.isEmpty == true {
                        TypingDots().id("typing")
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.never)
            .onChange(of: agent.messages) { _, _ in
                withAnimation(.smooth) { proxy.scrollTo(agent.messages.last?.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hi! I can see your screen, point things out, and do tasks for you — I'll ask before every step.")
                .font(.system(size: 13))
            ForEach(["What am I looking at?", "Circle the thing I should click to export this", "Rename these files for me"], id: \.self) { s in
                Button { draft = s; inputFocused = true } label: {
                    Text(s).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.glass)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Halo, or tell it what to do…", text: draftState.projectedValue, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit(send)
                .padding(.vertical, 8)
            if agent.busy {
                Button { agent.stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28)
                }
                .buttonStyle(.glass).clipShape(Circle()).help("Stop (⌥Esc)")
            }
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28)
            }
            .buttonStyle(.glassProminent).clipShape(Circle())
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func send() {
        let text = draft
        draft = ""
        agent.send(text)
        // Give the keyboard back to whatever the user was doing.
        ChatWindow.shared.giveFocusBack()
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
            }
        case .halo:
            VStack(alignment: .leading, spacing: 4) {
                if message.noticed {
                    Label("Noticed", systemImage: "eye").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(LocalizedStringKey(message.text))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .step, .note:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: message.symbol ?? "circle").font(.system(size: 11))
                Text(message.text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(message.role == .note ? Color.orange : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
    }
}

private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { tl in
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    let t = tl.date.timeIntervalSinceReferenceDate * 3 - Double(i) * 0.5
                    Circle().frame(width: 6, height: 6).opacity(0.3 + 0.5 * (sin(t) + 1) / 2)
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct PermissionBanner: View {
    private let tickState = State(initialValue: 0)
    private var tick: Int { get { tickState.wrappedValue } nonmutating set { tickState.wrappedValue = newValue } }
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let screen = Eyes.hasPermission, access = Hands.hasPermission
        let _ = tick
        if !screen || !access {
            VStack(alignment: .leading, spacing: 8) {
                Text("Halo needs two permissions").font(.system(size: 12, weight: .semibold))
                if !screen {
                    row("Screen Recording", "so it can see your screen") { Permissions.requestScreen() }
                }
                if !access {
                    row("Accessibility", "so it can click and type (only when you approve)") { Permissions.requestAccessibility() }
                }
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .padding([.horizontal, .top], 12)
            .onReceive(timer) { _ in tick += 1 }
        }
    }

    private func row(_ title: String, _ why: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(why).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Turn on", action: action).buttonStyle(.glass).controlSize(.small)
        }
    }
}

private struct SettingsView: View {
    private let agent = Agent.shared
    private func bind<T>(_ kp: ReferenceWritableKeyPath<Agent, T>) -> Binding<T> {
        Binding(get: { agent[keyPath: kp] }, set: { agent[keyPath: kp] = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Model") {
                    if agent.installed.isEmpty {
                        Text(agent.ollamaRunning ? "No models installed in Ollama yet." : "Ollama isn't running.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: bind(\.model)) {
                            ForEach(agent.installed, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                    Text(agent.modelCanSee ? "This model can see your screen." :
                         "This model can't see images. It can still read buttons and fields, but a vision model works much better.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Refresh") { Task { await agent.checkModel() } }.buttonStyle(.glass).controlSize(.small)
                }
                section("Watching") {
                    Toggle("Glance at my screen and speak up when it can help", isOn: bind(\.watching))
                        .font(.system(size: 12))
                    HStack {
                        Text("Every").font(.system(size: 12))
                        Slider(value: bind(\.glanceEvery), in: 15...300, step: 15)
                        Text("\(Int(agent.glanceEvery))s").font(.system(size: 12).monospacedDigit()).frame(width: 40)
                    }
                    Toggle("Show a coordinate grid to the model (more accurate clicks)", isOn: bind(\.showGrid))
                        .font(.system(size: 12))
                }
                section("Shortcuts") {
                    Text("⌥Space  show or hide Halo\n⌥Esc  stop whatever Halo is doing")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
                section("Permissions") {
                    HStack {
                        Label("Screen Recording", systemImage: Eyes.hasPermission ? "checkmark.circle.fill" : "xmark.circle")
                        Spacer()
                        Button("Open") { Permissions.requestScreen() }.controlSize(.small)
                    }.font(.system(size: 12))
                    HStack {
                        Label("Accessibility", systemImage: Hands.hasPermission ? "checkmark.circle.fill" : "xmark.circle")
                        Spacer()
                        Button("Open") { Permissions.requestAccessibility() }.controlSize(.small)
                    }.font(.system(size: 12))
                }
            }
            .padding(16)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
