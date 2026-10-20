import AppKit
import ApplicationServices

/// Mouse and keyboard control. Nothing in here asks permission — the Agent only calls
/// these after the user has approved the step in a popup.
enum Hands {
    static var hasPermission: Bool { AXIsProcessTrusted() }

    private static let source = CGEventSource(stateID: .hidSystemState)

    static func click(at p: CGPoint, right: Bool = false, double: Bool = false) async {
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: button)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(60))
        for n in 1...(double ? 2 : 1) {
            let d = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: p, mouseButton: button)
            let u = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: p, mouseButton: button)
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            d?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(40))
            u?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    static func drag(from a: CGPoint, to b: CGPoint) async {
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left)?.post(tap: .cghidEventTap)
        for i in 1...20 {
            let t = CGFloat(i) / 20
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(15))
        }
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Types text as if from the keyboard (works with any layout, emoji included).
    static func type(_ text: String) async {
        for ch in text {
            if ch == "\n" { await press("return"); continue }
            if ch == "\t" { await press("tab"); continue }
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                e?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(12))
        }
    }

    static func scroll(at p: CGPoint, lines: Int) async {
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(50))
        // Positive = down, the way people describe it.
        let step = lines > 0 ? -1 : 1
        for _ in 0..<abs(lines) {
            CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: Int32(step * 3), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Presses a shortcut like "cmd+shift+t", "return" or "esc".
    @discardableResult
    static func press(_ combo: String) async -> Bool {
        var flags: CGEventFlags = []
        var keyCode: CGKeyCode?
        for raw in combo.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            switch part {
            case "cmd", "command", "⌘", "meta", "super", "win": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: keyCode = keyCodes[part]
            }
        }
        guard let code = keyCode else { return false }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(30))
        }
        return true
    }

    static func openApp(_ name: String) async -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", name]
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func openURL(_ s: String) -> Bool {
        guard let url = URL(string: s.contains("://") ? s : "https://" + s) else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "esc": 53, "escape": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let f: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, c) in f.enumerated() { m["f\(i + 1)"] = c }
        return m
    }()
}
