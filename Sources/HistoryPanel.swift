import SwiftUI

/// ⌘Y: everywhere you've been, newest first, grouped by day, with search.
struct HistoryPanel: View {
    let accent: Accent
    @FocusState private var focused: Bool
    private let searchState = State(initialValue: "")
    private var history: History { History.shared }

    var body: some View {
        let query = searchState.wrappedValue.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = history.entries.filter {
            query.isEmpty || $0.title.lowercased().contains(query) || $0.url.lowercased().contains(query)
        }
        let days = Dictionary(grouping: matches.prefix(800)) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent.color)
                TextField("Search history", text: searchState.projectedValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onExitCommand { Browser.shared.showHistory = false }
                Menu {
                    Button("Clear All History", role: .destructive) { history.clear() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                NavButton(symbol: "xmark", help: "Close (esc)", enabled: true) { Browser.shared.showHistory = false }
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(height: 54)

            Divider().opacity(0.5)

            if days.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No history yet" : "No matches",
                                       systemImage: "clock",
                                       description: Text(query.isEmpty ? "Sites you visit show up here." : "Try another word."))
                    .frame(height: 320)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(days, id: \.key) { day, entries in
                            Section {
                                ForEach(entries) { row($0) }
                            } header: {
                                Text(label(for: day))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.ultraThinMaterial)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(height: 460)
            }
        }
        .frame(width: 640)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .onAppear { focused = true }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        let url = URL(string: entry.url)
        return HStack(spacing: 10) {
            SiteIcon(host: url?.host() ?? "", title: entry.title.isEmpty ? entry.url : entry.title)
                .font(.system(size: 10))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? entry.url : entry.title).lineLimit(1)
                Text(url?.host() ?? entry.url).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .contentShape(Rectangle())
        .modifier(RowHover())
        .onTapGesture { open(entry, newTab: NSEvent.modifierFlags.contains(.command)) }
        .contextMenu {
            Button("Open") { open(entry, newTab: false) }
            Button("Open in New Tab") { open(entry, newTab: true) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url, forType: .string)
            }
            Divider()
            Button("Remove from History", role: .destructive) { History.shared.remove(entry) }
        }
    }

    private func open(_ entry: HistoryEntry, newTab: Bool) {
        guard let url = URL(string: entry.url) else { return }
        Browser.shared.showHistory = false
        if newTab || Browser.shared.selected == nil { Browser.shared.newTab(url: url) }
        else { Browser.shared.selected?.load(url) }
    }

    private func label(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

private struct RowHover: ViewModifier {
    private let hover = State(initialValue: false)
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hover.wrappedValue ? 0.07 : 0)))
            .onHover { hover.wrappedValue = $0 }
    }
}
