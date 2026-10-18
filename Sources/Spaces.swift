import AppKit
import SwiftUI

/// A Space is a separate set of tabs (Work, School, Gaming…) with its own icon and glow color.
struct Space: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var icon: String
    /// Accent for this space; nil follows the accent chosen in Settings.
    var accent: String?

    static let icons = [
        "house.fill", "briefcase.fill", "graduationcap.fill", "gamecontroller.fill", "music.note",
        "paintbrush.fill", "hammer.fill", "cart.fill", "heart.fill", "star.fill", "book.fill",
        "camera.fill", "airplane", "leaf.fill", "flame.fill", "moon.stars.fill",
    ]
}

@MainActor
@Observable
final class SpaceStore {
    static let shared = SpaceStore()
    private static let key = "spaces"

    private(set) var spaces: [Space]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Space].self, from: data), !saved.isEmpty {
            spaces = saved
        } else {
            spaces = [Space(name: "Home", icon: "house.fill")]
        }
    }

    func space(_ id: UUID?) -> Space? { spaces.first { $0.id == id } }

    @discardableResult
    func add(name: String = "New Space") -> Space {
        let used = Set(spaces.compactMap(\.accent))
        let accent = Accent.allCases.first { !used.contains($0.rawValue) && $0 != .graphite }?.rawValue
        let icon = Space.icons.first { icon in !spaces.contains { $0.icon == icon } } ?? "star.fill"
        let space = Space(name: name, icon: icon, accent: accent)
        spaces.append(space)
        save()
        return space
    }

    func update(_ space: Space) {
        guard let i = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        spaces[i] = space
        save()
    }

    func remove(_ space: Space) {
        guard spaces.count > 1 else { return }
        spaces.removeAll { $0.id == space.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(spaces) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Space switcher: a glass pill with the current space's icon; click for the list.
struct SpaceSwitcher: View {
    var compact = true
    private var store: SpaceStore { SpaceStore.shared }
    private var browser: Browser { Browser.shared }

    var body: some View {
        let current = store.space(browser.currentSpaceID) ?? store.spaces[0]
        Menu {
            ForEach(store.spaces) { space in
                Button {
                    browser.switchSpace(to: space.id)
                } label: {
                    Label(space.name, systemImage: space.id == current.id ? "checkmark" : space.icon)
                }
            }
            Divider()
            Button("New Space…") {
                let space = store.add()
                browser.switchSpace(to: space.id)
                browser.editingSpace = space
            }
            Button("Edit “\(current.name)”…") { browser.editingSpace = current }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(spaceAccent(current).color)
                if !compact || store.spaces.count > 1 {
                    Text(current.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: Capsule())
        .help("Spaces (⌃1–9 to switch)")
    }

    private func spaceAccent(_ space: Space) -> Accent {
        Accent(rawValue: space.accent ?? UserDefaults.standard.string(forKey: Pref.accent) ?? "") ?? .blue
    }
}

/// Editing a space: name, icon, color, delete.
struct SpaceEditor: View {
    let original: Space
    private let draft: State<Space>

    init(space: Space) {
        original = space
        draft = State(initialValue: space)
    }

    var body: some View {
        let space = draft.wrappedValue
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: space.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill((Accent(rawValue: space.accent ?? "") ?? .blue).gradient))
                TextField("Name", text: draft.projectedValue.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))
            }

            Text("Icon").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 8), spacing: 8) {
                ForEach(Space.icons, id: \.self) { icon in
                    Image(systemName: icon)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(icon == space.icon ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06)))
                        .onTapGesture { draft.wrappedValue.icon = icon }
                }
            }

            Text("Color").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(Accent.allCases) { a in
                    Circle()
                        .fill(a.gradient)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white, lineWidth: space.accent == a.rawValue ? 2.5 : 0))
                        .onTapGesture { draft.wrappedValue.accent = a.rawValue }
                }
            }

            HStack {
                if SpaceStore.shared.spaces.count > 1 {
                    Button("Delete Space", role: .destructive) {
                        Browser.shared.deleteSpace(original)
                        Browser.shared.editingSpace = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { Browser.shared.editingSpace = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    var s = draft.wrappedValue
                    if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = original.name }
                    SpaceStore.shared.update(s)
                    Browser.shared.editingSpace = nil
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 380)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
    }
}
