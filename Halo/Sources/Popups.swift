import AppKit
import SwiftUI

/// A borderless floating panel that can take typing without pulling focus away from the
/// user's app until they actually click into it.
final class FloatingPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum Approval: Equatable {
    case allow
    case allowRest        // allow everything else in this task
    case deny(String?)    // optional note: "do X instead"
}

@MainActor
enum Popups {
    private static var open: [NSPanel] = []

    // MARK: Public API

    /// Asks the user a question. Returns their answer, or nil if they dismissed it.
    static func ask(_ question: String, options: [String] = []) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            var panel: NSPanel?
            var done = false
            let finish: (String?) -> Void = { answer in
                guard !done else { return }
                done = true
                if let panel { dismiss(panel) }
                cont.resume(returning: answer)
            }
            panel = show(QuestionCard(question: question, options: options, finish: finish), width: 340)
        }
    }

    /// Asks permission for one step. `preview` is shown in a box (e.g. text that will be typed).
    static func approve(icon: String, title: String, detail: String, preview: String? = nil) async -> Approval {
        await withCheckedContinuation { (cont: CheckedContinuation<Approval, Never>) in
            var panel: NSPanel?
            var done = false
            let finish: (Approval) -> Void = { result in
                guard !done else { return }
                done = true
                if let panel { dismiss(panel) }
                cont.resume(returning: result)
            }
            panel = show(ApprovalCard(icon: icon, title: title, detail: detail, preview: preview, finish: finish), width: 340)
            approvalCancel = { finish(.deny("Stopped by the user.")) }
        }
    }

    /// A small note that fades away by itself (used when Halo notices something on its own).
    static func toast(_ text: String, seconds: Double = 9, onOpen: @escaping () -> Void) {
        var panel: NSPanel?
        panel = show(ToastCard(text: text, open: {
            if let panel { dismiss(panel) }
            onOpen()
        }, close: { if let panel { dismiss(panel) } }), width: 300)
        let p = panel
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            // Leave it while the mouse is over it.
            while let p, p.isVisible, p.frame.contains(NSEvent.mouseLocation) { try? await Task.sleep(for: .seconds(1)) }
            if let p, p.isVisible { dismiss(p) }
        }
    }

    /// Stop button / hotkey: answer any waiting approval with "no".
    static var approvalCancel: (() -> Void)?
    static func cancelPending() {
        approvalCancel?()
        approvalCancel = nil
    }

    // MARK: Showing and hiding

    private static func show<V: View>(_ view: V, width: CGFloat) -> NSPanel {
        let host = NSHostingView(rootView: view.frame(width: width))
        let size = host.fittingSize
        let panel = FloatingPanel(size: size)
        panel.contentView = host

        let origin = Dodger.shared.placeNewPopup(size: size)
        let final = CGRect(origin: origin, size: size)
        // Slide in gently from the chat's direction.
        let from = Dodger.shared.chatFrame?.center ?? NSEvent.mouseLocation
        let dx = from.x < final.midX ? -14.0 : 14.0
        panel.setFrame(final.offsetBy(dx: dx, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
        open.append(panel)
        Dodger.shared.manage(panel, kind: .popup)
        NSSound(named: "Pop")?.play()
        return panel
    }

    private static func dismiss(_ panel: NSPanel) {
        Dodger.shared.unmanage(panel)
        open.removeAll { $0 === panel }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

// MARK: - Cards

struct HaloCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(6)
    }
}

extension View {
    func haloCard() -> some View { modifier(HaloCard()) }
}

struct HaloBadge: View {
    var symbol = "circle.circle"
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(LinearGradient(colors: [Color(red: 0.45, green: 0.55, blue: 1), Color(red: 0.7, green: 0.4, blue: 1)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
    }
}

private struct QuestionCard: View {
    let question: String
    let options: [String]
    let finish: (String?) -> Void
    private let answerState = State(initialValue: "")
    private var answer: String { answerState.wrappedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                HaloBadge(symbol: "questionmark")
                Text(question).font(.system(size: 13.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { finish(nil) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if !options.isEmpty {
                FlowButtons(options: options) { finish($0) }
            }
            HStack {
                TextField(options.isEmpty ? "Type your answer…" : "Or type something else…", text: answerState.projectedValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !answer.isEmpty { finish(answer) } }
                Button("Send") { finish(answer) }.disabled(answer.isEmpty)
            }
        }
        .haloCard()
    }
}

private struct FlowButtons: View {
    let options: [String]
    let pick: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { o in
                Button { pick(o) } label: {
                    Text(o).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }
}

private struct ApprovalCard: View {
    let icon: String
    let title: String
    let detail: String
    let preview: String?
    let finish: (Approval) -> Void
    private let noteState = State(initialValue: "")
    private var note: String { noteState.wrappedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                HaloBadge(symbol: icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let preview, !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(6)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                Button { finish(.allow) } label: { Text("Allow").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent).controlSize(.large)
                Button { finish(.deny(note.isEmpty ? nil : note)) } label: { Text("Don't").frame(maxWidth: .infinity) }
                    .buttonStyle(.glass).controlSize(.large)
            }
            Button { finish(.allowRest) } label: {
                Text("Allow the rest of this task").font(.system(size: 11.5)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            TextField("…or tell Halo what to do instead", text: noteState.projectedValue)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
                .onSubmit { if !note.isEmpty { finish(.deny(note)) } }
        }
        .haloCard()
    }
}

private struct ToastCard: View {
    let text: String
    let open: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HaloBadge(symbol: "eye")
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .haloCard()
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}
