import SwiftUI

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() { Pref.register() }

    var body: some Scene {
        Window("Orbit", id: "main") {
            ContentView()
                .frame(minWidth: 720, minHeight: 460)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1360, height: 860)
        .commands { BrowserCommands() }

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Browser.shared.loadBlocker()
            MusicListener.shared.sync()
            // Start/stop listening as soon as the wallpaper or music setting changes.
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                   queue: .main) { _ in MusicListener.shared.sync() }
            if Browser.shared.tabs.isEmpty { Browser.shared.restoreSession() }
            DefaultBrowser.considerAsking()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { Browser.shared.newTab(url: url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Browser.shared.saveSession() }
        MusicListener.shared.stopSoon()
    }
}

struct BrowserCommands: Commands {
    private var browser: Browser { Browser.shared }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { browser.newTab() }
                .keyboardShortcut("t")
            Button("New Private Tab") { browser.newTab(isPrivate: true) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Reopen Closed Tab") { browser.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Open Location…") { browser.focusAddressRequest += 1 }
                .keyboardShortcut("l")
            Button("Pin / Unpin This Page") { Pins.toggleCurrentPage() }
                .keyboardShortcut("d")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { browser.closeSelected() }
                .keyboardShortcut("w")
        }
        CommandGroup(after: .toolbar) {
            Button("Reload Page") {
                guard let tab = browser.selected else { return }
                if tab.loadError != nil || tab.url == nil { tab.retry() } else { tab.webView.reload() }
            }
                .keyboardShortcut("r")
            Button("Back") { browser.selected?.webView.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { browser.selected?.webView.goForward() }
                .keyboardShortcut("]")
            Divider()
            Button("Zoom In") { zoom(by: 0.1) }
                .keyboardShortcut("+")
            Button("Zoom In") { zoom(by: 0.1) }
                .keyboardShortcut("=")
            Button("Zoom Out") { zoom(by: -0.1) }
                .keyboardShortcut("-")
            Button("Actual Size") { browser.selected?.webView.pageZoom = 1 }
                .keyboardShortcut("0")
            Divider()
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Page…") { browser.showFind = true }
                .keyboardShortcut("f")
        }
        CommandMenu("Go") {
            Button("Command Palette…") { browser.showPalette.toggle() }
                .keyboardShortcut("k")
            Button("Show History") { browser.showPalette = false; browser.showHistory.toggle() }
                .keyboardShortcut("y")
            Button("Downloads") { Downloads.shared.showPanel.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Split View") { browser.toggleSplitView() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            Button("Reading Mode") {
                if Reader.shared.article != nil { Reader.shared.close() }
                else if let tab = browser.selected, tab.readerAvailable { Reader.shared.open(tab) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Translate Page") {
                guard let tab = browser.selected, tab.pageLanguage != nil else { return }
                if tab.isTranslated { Translator.showOriginal(tab) } else { browser.translating = tab }
            }
            .keyboardShortcut("t", modifiers: [.command, .control])
            Button("Ask AI About All Tabs") {
                Assistant.shared.isOpen = true
                Assistant.shared.askAboutTabs("Compare the pages I have open: what each is, how they differ, and which one is best for what.")
            }
            Button("Orbit AI") { Assistant.shared.toggle() }
                .keyboardShortcut("j")
            Button("Summarize Page") { Assistant.shared.summarize(browser.selected) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Fill Password") {
                if let tab = browser.selected, let login = tab.logins.first {
                    PasswordAgent.shared.fill(login, in: tab.webView)
                }
            }
            .keyboardShortcut("\\")
        }
        CommandMenu("Spaces") {
            ForEach(Array(SpaceStore.shared.spaces.prefix(9).enumerated()), id: \.element.id) { i, space in
                Button(space.name) { browser.switchSpace(to: space.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .control)
            }
            Divider()
            Button("New Space…") {
                let space = SpaceStore.shared.add()
                browser.switchSpace(to: space.id)
                browser.editingSpace = space
            }
            Button("Edit Space…") { browser.editingSpace = browser.currentSpace }
        }
        CommandMenu("Tabs") {
            Button("Pin / Unpin Tab") { if let tab = browser.selected { browser.togglePin(tab) } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Next Tab") { browser.cycle(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { browser.cycle(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<9) { n in
                Button("Tab \(n)") { browser.select(index: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
            Button("Last Tab") { browser.selectLast() }
                .keyboardShortcut("9")
        }
    }

    private func zoom(by delta: CGFloat) {
        guard let wv = browser.selected?.webView else { return }
        wv.pageZoom = min(3, max(0.3, wv.pageZoom + delta))
    }
}
