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
            if Browser.shared.tabs.isEmpty { Browser.shared.restoreSession() }
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
    }
}

struct BrowserCommands: Commands {
    private var browser: Browser { Browser.shared }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { browser.newTab() }
                .keyboardShortcut("t")
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
            Button("Reload Page") { browser.selected?.webView.reload() }
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
