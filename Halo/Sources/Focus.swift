import AppKit
import ApplicationServices

/// Works out where the user's attention is — the mouse, the text caret, the focused control
/// and the front window — so Halo's windows can stay clear of it.
@MainActor
final class Focus {
    static let shared = Focus()

    private let system = AXUIElementCreateSystemWide()
    private init() { AXUIElementSetMessagingTimeout(system, 0.08) }

    // All in Quartz coordinates.
    private(set) var caret: CGRect?
    private(set) var focusedControl: CGRect?
    private(set) var frontWindow: CGRect?
    private(set) var frontAppName = ""
    private(set) var mouseDown = false
    /// Extra places to keep clear, e.g. where the AI is pointing or about to click.
    var reserved: [CGRect] = []

    func update() {
        mouseDown = NSEvent.pressedMouseButtons != 0
        let me = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        frontAppName = front?.localizedName ?? ""
        caret = nil
        focusedControl = nil
        frontWindow = nil

        if let front, front.processIdentifier != me {
            frontWindow = Self.frontWindowBounds(pid: front.processIdentifier)
            if Hands.hasPermission, let el: AXUIElement = attr(system, kAXFocusedUIElementAttribute) {
                var pid: pid_t = 0
                AXUIElementGetPid(el, &pid)
                if pid != me {
                    focusedControl = frame(of: el)
                    caret = caretBounds(in: el)
                }
            }
        }
    }

    /// Rectangles (Cocoa coordinates) Halo's windows should stay out of, with how much each matters.
    /// `placing` is true when choosing a spot for a new window (never land under the cursor),
    /// false when deciding whether an existing window should move. A hovering mouse doesn't
    /// push windows around — otherwise you could never reach the chat — but clicking or
    /// dragging right next to one does.
    func hotZones(ignoring ours: [CGRect], placing: Bool = false) -> [(rect: CGRect, weight: CGFloat)] {
        var zones: [(CGRect, CGFloat)] = []
        let mouse = NSEvent.mouseLocation
        // If the mouse is on one of Halo's own windows, the user is using Halo — not in the way.
        if !ours.contains(where: { $0.insetBy(dx: -6, dy: -6).contains(mouse) }) && (placing || mouseDown) {
            let r: CGFloat = placing ? 120 : 70
            zones.append((CGRect(x: mouse.x - r, y: mouse.y - r, width: r * 2, height: r * 2), 2))
        }
        if let caret {
            zones.append((Geo.cocoa(caret).insetBy(dx: -140, dy: -70), 4))
        }
        if let f = focusedControl {
            let screenArea = Geo.screen(containing: Geo.cocoa(f).center).frame
            // A whole-window text view isn't useful to dodge; the caret covers that case.
            if f.width * f.height < screenArea.width * screenArea.height * 0.35 {
                zones.append((Geo.cocoa(f).insetBy(dx: -16, dy: -16), 3))
            }
        }
        for r in reserved { zones.append((Geo.cocoa(r).insetBy(dx: -50, dy: -50), 5)) }
        return zones
    }

    // MARK: Accessibility helpers

    private func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func frame(of el: AXUIElement) -> CGRect? {
        guard let posV: AXValue = attr(el, kAXPositionAttribute), let sizeV: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posV, .cgPoint, &p)
        AXValueGetValue(sizeV, .cgSize, &s)
        return s.width > 0 && s.height > 0 ? CGRect(origin: p, size: s) : nil
    }

    private func caretBounds(in el: AXUIElement) -> CGRect? {
        guard let range: AXValue = attr(el, kAXSelectedTextRangeAttribute) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &out) == .success,
              let v = out, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        AXValueGetValue(v as! AXValue, .cgRect, &r)
        guard r.width >= 0, r.height > 0, r.height < 400 else { return nil }
        return CGRect(x: r.minX, y: r.minY, width: max(r.width, 2), height: r.height)
    }

    static func frontWindowBounds(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b), r.width > 80, r.height > 80 {
                return r
            }
        }
        return nil
    }
}

/// Reads the clickable things in the front window through Accessibility, so the AI can
/// target buttons and fields precisely instead of guessing from pixels.
enum UIElements {
    struct Item { let role: String; let label: String; let frame: CGRect }

    private static let wanted: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXTab", "AXMenuItem", "AXCell", "AXSlider", "AXDisclosureTriangle",
        "AXMenuBarItem", "AXSegmentedControl", "AXIncrementor", "AXImage",
    ]

    static func scanFrontWindow(limit: Int = 70) async -> (app: String, items: [Item]) {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return ("", []) }
        let pid = front.processIdentifier
        let name = front.localizedName ?? ""
        let items = await Task.detached(priority: .userInitiated) { scan(pid: pid, limit: limit) }.value
        return (name, items)
    }

    nonisolated private static func scan(pid: pid_t, limit: Int) -> [Item] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        func get<T>(_ el: AXUIElement, _ a: String) -> T? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success ? v as? T : nil
        }
        func frame(_ el: AXUIElement) -> CGRect? {
            guard let p: AXValue = get(el, kAXPositionAttribute), let s: AXValue = get(el, kAXSizeAttribute) else { return nil }
            var pt = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(p, .cgPoint, &pt); AXValueGetValue(s, .cgSize, &sz)
            return CGRect(origin: pt, size: sz)
        }
        var roots: [AXUIElement] = []
        if let w: AXUIElement = get(app, kAXFocusedWindowAttribute) { roots.append(w) }
        if let bar: AXUIElement = get(app, kAXMenuBarAttribute) { roots.append(bar) }
        let windowFrame = roots.first.flatMap(frame)

        var out: [Item] = []
        var queue = roots.map { ($0, 0) }
        var visited = 0
        while !queue.isEmpty, visited < 2500, out.count < limit {
            let (el, depth) = queue.removeFirst()
            visited += 1
            let role: String = get(el, kAXRoleAttribute) ?? ""
            if wanted.contains(role), let f = frame(el), f.width > 3, f.height > 3,
               windowFrame.map({ $0.insetBy(dx: -2, dy: -2).intersects(f) }) ?? true || role == "AXMenuBarItem" {
                var label = ""
                for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute, kAXValueAttribute] {
                    if let s: String = get(el, key), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        label = String(s.prefix(60)).replacingOccurrences(of: "\n", with: " ")
                        break
                    }
                }
                if !label.isEmpty || role.contains("Text") || role.contains("Search") {
                    out.append(Item(role: role.replacingOccurrences(of: "AX", with: ""), label: label, frame: f))
                }
            }
            // Menus below the bar are only listed when open, so skip closed menu contents.
            if depth < 30, role != "AXMenu", let kids: [AXUIElement] = get(el, kAXChildrenAttribute) {
                queue.append(contentsOf: kids.prefix(200).map { ($0, depth + 1) })
            }
        }
        return out
    }
}
