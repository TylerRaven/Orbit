import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct HaloMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // lives in the menu bar, no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        Overlay.shared.start()
        ChatWindow.shared.build()
        Dodger.shared.start()
        Agent.shared.start()
        Updater.shared.start()
        let last = UserDefaults.standard.string(forKey: "lastVersion")
        if let last, last != Updater.currentVersion {
            Agent.shared.noteUpdate("Halo updated itself to \(Updater.currentVersion).")
        }
        UserDefaults.standard.set(Updater.currentVersion, forKey: "lastVersion")
        Agent.shared.onNotice = { text in
            // Speak up quietly when the chat is tucked away.
            if !ChatWindow.shared.isVisible {
                Popups.toast(text) { ChatWindow.shared.show() }
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Halo")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        Hotkeys.register(key: kVK_Space, modifiers: optionKey) { ChatWindow.shared.toggle() }
        Hotkeys.register(key: kVK_Escape, modifiers: optionKey) {
            Agent.shared.stop()
            Overlay.shared.clear()
        }

        ChatWindow.shared.show()
        if !Eyes.hasPermission { CGRequestScreenCaptureAccess() }

        // A quick self-test mode for development: `open Halo.app --args --demo`
        if CommandLine.arguments.contains("--demo") { Demo.run() }
        // ...and `--ask "something"` sends a message as if typed.
        if let i = CommandLine.arguments.firstIndex(of: "--ask"), i + 1 < CommandLine.arguments.count {
            let text = CommandLine.arguments[i + 1]
            Task { try? await Task.sleep(for: .seconds(1)); Agent.shared.send(text) }
        }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Show Halo  ⌥Space", action: #selector(showChat), keyEquivalent: "")
            menu.addItem(withTitle: "Stop  ⌥Esc", action: #selector(stopAgent), keyEquivalent: "")
            menu.addItem(withTitle: "Clear drawings", action: #selector(clearDrawings), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Halo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            ChatWindow.shared.toggle()
        }
    }

    @objc private func showChat() { ChatWindow.shared.show() }
    @objc private func stopAgent() { Agent.shared.stop() }
    @objc private func clearDrawings() { Overlay.shared.clear() }
}

enum Permissions {
    static func requestScreen() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}

/// System-wide shortcuts (Carbon hot keys need no extra permission).
@MainActor
enum Hotkeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    static func register(key: Int, modifiers: Int, action: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                let n = id.id
                DispatchQueue.main.async { MainActor.assumeIsolated { Hotkeys.handlers[n]?() } }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let n = UInt32(handlers.count + 1)
        handlers[n] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: OSType(0x48414C4F), id: n),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

/// Shows off the drawing, dodging and popups without needing a model. Launch with --demo.
@MainActor
enum Demo {
    static func run() {
        Task {
            let screen = CGDisplayBounds(CGMainDisplayID())
            let c = CGPoint(x: screen.midX, y: screen.midY)
            try? await Task.sleep(for: .seconds(1))
            Overlay.shared.add(.highlight(CGRect(x: c.x - 300, y: c.y - 160, width: 220, height: 28)), color: .yellow, label: "highlight", lifetime: 20)
            try? await Task.sleep(for: .milliseconds(400))
            Overlay.shared.add(.box(CGRect(x: c.x - 40, y: c.y - 180, width: 200, height: 70)), color: .red, label: "box", lifetime: 20)
            try? await Task.sleep(for: .milliseconds(400))
            Overlay.shared.add(.outline(CGRect(x: c.x + 220, y: c.y - 170, width: 140, height: 50)), color: .cyan, label: "outline", lifetime: 20)
            try? await Task.sleep(for: .milliseconds(400))
            let pts = (0...40).map { i -> CGPoint in
                let a = Double(i) / 40 * 2 * .pi
                return CGPoint(x: c.x - 200 + cos(a) * 80, y: c.y + 60 + sin(a) * 45)
            }
            Overlay.shared.add(.path(pts), color: .pink, label: "draw", lifetime: 20)
            Overlay.shared.add(.arrow(CGPoint(x: c.x, y: c.y + 140), CGPoint(x: c.x + 160, y: c.y + 60)), color: .orange, label: "arrow", lifetime: 20)
            Overlay.shared.add(.text(CGPoint(x: c.x + 60, y: c.y + 160), "Halo can write on your screen ✨"), color: .white, lifetime: 20)
            Overlay.shared.add(.target(CGPoint(x: c.x + 260, y: c.y + 40)), color: .pink, label: "click", lifetime: 20)
            try? await Task.sleep(for: .seconds(1))
            _ = await Popups.approve(icon: "cursorarrow.click", title: "Click here?", detail: "Click the Export button to save the file.")
            _ = await Popups.ask("Which format do you want?", options: ["PDF", "PNG", "Keep as it is"])
        }
    }
}
