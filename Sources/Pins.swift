import AppKit
import SwiftUI

/// Your pinned sites. Starts empty; stored as JSON in UserDefaults.
enum Pins {
    static func load() -> [QuickLink] {
        guard let raw = UserDefaults.standard.string(forKey: Pref.pins),
              let data = raw.data(using: .utf8),
              let pins = try? JSONDecoder().decode([QuickLink].self, from: data) else { return [] }
        return pins
    }

    static func save(_ pins: [QuickLink]) {
        UserDefaults.standard.set(QuickLink.encode(pins), forKey: Pref.pins)
    }

    /// Pins the current page (or unpins it if it's already there).
    @MainActor
    static func toggleCurrentPage() {
        guard let tab = Browser.shared.selected, let url = tab.url else { return }
        var pins = load()
        if let i = pins.firstIndex(where: { $0.url == url.absoluteString }) {
            pins.remove(at: i)
        } else {
            pins.append(QuickLink(title: shortTitle(tab.displayTitle, host: url.host() ?? ""), url: url.absoluteString))
            WallpaperMood.shared.pulse(0.6)
        }
        save(pins)
    }

    @MainActor
    static func isPinned(_ url: URL?) -> Bool {
        guard let url else { return false }
        return load().contains { $0.url == url.absoluteString }
    }

    /// "Inbox (1,209) - you@gmail.com - Gmail" → "Gmail"-ish: keep it short for the bar.
    private static func shortTitle(_ title: String, host: String) -> String {
        let parts = title.components(separatedBy: CharacterSet(charactersIn: "-–|·:"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let candidate = parts.count > 1 ? parts.last! : (parts.first ?? host)
        return candidate.count > 22 ? String(candidate.prefix(22)) + "…" : candidate
    }
}

struct PinsBar: View {
    var vertical = false
    @AppStorage(Pref.pins) private var raw = ""

    var body: some View {
        let pins = Pins.load()
        let current = Browser.shared.selected?.url
        let canPin = current != nil && !Pins.isPinned(current)

        Group {
            if vertical {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(pins.enumerated()), id: \.element.id) { i, pin in
                        PinChip(pin: pin, index: i, count: pins.count, vertical: true)
                    }
                    if canPin { addButton(vertical: true) }
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(Array(pins.enumerated()), id: \.element.id) { i, pin in
                            PinChip(pin: pin, index: i, count: pins.count, vertical: false)
                        }
                        if canPin || pins.isEmpty { addButton(vertical: false) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .id(raw) // redraw when pins change
    }

    private func addButton(vertical: Bool) -> some View {
        let empty = Pins.load().isEmpty
        return Button { Pins.toggleCurrentPage() } label: {
            Label(empty ? "Pin this page  ⌘D" : "Pin", systemImage: "plus")
                .font(.system(size: 11, weight: .medium))
                .labelStyle(empty || vertical ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .frame(maxWidth: vertical ? .infinity : nil, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverStyle(radius: 8))
        .foregroundStyle(.secondary)
        .disabled(Browser.shared.selected?.url == nil)
        .help("Pin this page (⌘D)")
    }
}

struct PinChip: View {
    let pin: QuickLink
    let index: Int
    let count: Int
    let vertical: Bool
    private let hoverState = State(initialValue: false)

    var body: some View {
        let active = Browser.shared.selected?.url?.absoluteString == pin.url
        HStack(spacing: 6) {
            SiteIcon(host: pin.host, title: pin.title)
                .font(.system(size: 9))
                .frame(width: 14, height: 14)
            Text(pin.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            if vertical { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 9)
        .frame(height: vertical ? 28 : 24)
        .frame(maxWidth: vertical ? .infinity : 180, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hoverState.wrappedValue ? Color.primary.opacity(0.07) : .clear)
        )
        .glassEffect(active ? .regular.interactive() : .identity,
                     in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { open(newTab: NSEvent.modifierFlags.contains(.command)) }
        .onHover { inside in
            hoverState.wrappedValue = inside
            WallpaperMood.shared.hover(host: inside ? pin.host : nil)
        }
        .help(pin.url)
        .contextMenu {
            Button("Open") { open(newTab: false) }
            Button("Open in New Tab") { open(newTab: true) }
            Button("Open in Private Tab") {
                if let url = URL(string: pin.url) { Browser.shared.newTab(url: url, isPrivate: true) }
            }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pin.url, forType: .string)
            }
            Divider()
            Button("Rename…", action: rename)
            Button("Move Left") { move(by: -1) }.disabled(index == 0)
            Button("Move Right") { move(by: 1) }.disabled(index == count - 1)
            Divider()
            Button("Unpin", role: .destructive) {
                Pins.save(Pins.load().filter { $0.url != pin.url })
            }
        }
    }

    private func open(newTab: Bool) {
        guard let url = URL(string: pin.url) else { return }
        if newTab || Browser.shared.selected == nil {
            Browser.shared.newTab(url: url, select: !newTab)
        } else {
            Browser.shared.selected?.load(url)
        }
    }

    private func move(by step: Int) {
        var pins = Pins.load()
        guard let i = pins.firstIndex(of: pin), pins.indices.contains(i + step) else { return }
        pins.swapAt(i, i + step)
        Pins.save(pins)
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename pin"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = pin.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var pins = Pins.load()
        if let i = pins.firstIndex(of: pin) { pins[i].title = name }
        Pins.save(pins)
    }
}

/// Lets one call site pick a label style at runtime.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
