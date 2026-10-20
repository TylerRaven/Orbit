import AppKit

/// Keeps Halo's chat window and popups out of the user's way.
///
/// Several times a second it checks where the user is working (mouse, text caret, focused
/// control, whatever the AI is pointing at). If a Halo window covers any of that, it glides to
/// the nearest clear spot, and returns to where the user put it once that spot is clear again.
/// New popups use the same scoring to appear somewhere natural: clear of the work, near the chat.
@MainActor
final class Dodger {
    static let shared = Dodger()

    enum Kind { case chat, popup }

    final class Item {
        weak var window: NSWindow?
        let kind: Kind
        var home: CGPoint?          // where the user wants it (Cocoa origin)
        var target: CGRect          // where it is or is animating to
        var movedByUsAt = Date.distantPast
        var homeClearSince: Date?
        var lastDodge = Date.distantPast
        init(window: NSWindow, kind: Kind) {
            self.window = window
            self.kind = kind
            self.target = window.frame
        }
    }

    private(set) var items: [Item] = []
    var paused = false   // the "pin" toggle in the chat

    private init() {}

    func start() {
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { Dodger.shared.tick() }
        }
    }

    func manage(_ window: NSWindow, kind: Kind) {
        let item = Item(window: window, kind: kind)
        item.home = kind == .chat ? window.frame.origin : nil
        items.append(item)
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak item] _ in
            MainActor.assumeIsolated {
                guard let item, let w = item.window else { return }
                // A move we didn't make is the user dragging it: that's its new home.
                if Date().timeIntervalSince(item.movedByUsAt) > 0.6 {
                    item.target = w.frame
                    if item.kind == .chat { item.home = w.frame.origin }
                    item.lastDodge = Date() // give them a moment before dodging again
                }
            }
        }
    }

    func unmanage(_ window: NSWindow) {
        items.removeAll { $0.window == nil || $0.window === window }
    }

    var chatFrame: CGRect? { items.first { $0.kind == .chat && $0.window?.isVisible == true }?.target }

    // MARK: Choosing a spot

    /// The best origin (Cocoa) for a new popup of this size.
    func placeNewPopup(size: CGSize) -> CGPoint {
        Focus.shared.update()
        let screen = Geo.screen(containing: chatFrame?.center ?? NSEvent.mouseLocation)
        return bestSpot(size: size, on: screen, for: nil, kind: .popup).origin
    }

    private func ourFrames(except item: Item?) -> [CGRect] {
        items.compactMap { $0 === item || $0.window?.isVisible != true ? nil : $0.target }
    }

    /// Lower is better.
    private func cost(_ f: CGRect, kind: Kind, item: Item?, zones: [(rect: CGRect, weight: CGFloat)], others: [CGRect], front: CGRect?) -> CGFloat {
        let area = f.width * f.height
        var c: CGFloat = 0
        for z in zones { c += f.overlapArea(z.rect) / area * 1000 * z.weight }
        for o in others { c += f.insetBy(dx: -8, dy: -8).overlapArea(o) / area * 700 }
        if let front { c += f.overlapArea(front) / area * 30 }   // prefer empty desktop, mildly

        switch kind {
        case .chat:
            // Move as little as possible.
            if let cur = item?.target { c += hypot(f.midX - cur.midX, f.midY - cur.midY) / 18 }
        case .popup:
            // Sit near the chat, so questions feel like they come from it.
            if let chat = chatFrame { c += f.distance(to: chat) / 14 }
            else { c += hypot(f.midX - NSEvent.mouseLocation.x, f.midY - NSEvent.mouseLocation.y) / 60 }
        }
        return c
    }

    private func bestSpot(size: CGSize, on screen: NSScreen, for item: Item?, kind: Kind) -> CGRect {
        let zones = Focus.shared.hotZones(ignoring: ourFrames(except: nil), placing: true)
        let others = ourFrames(except: item)
        let front = Focus.shared.frontWindow.map(Geo.cocoa)
        let area = screen.visibleFrame.insetBy(dx: 14, dy: 14)
        var best = CGRect(origin: CGPoint(x: area.maxX - size.width, y: area.maxY - size.height), size: size)
        var bestCost = CGFloat.infinity
        let step: CGFloat = 24
        var y = area.minY
        while y + size.height <= area.maxY + 0.5 {
            var x = area.minX
            while x + size.width <= area.maxX + 0.5 {
                let f = CGRect(x: x, y: y, width: size.width, height: size.height)
                let c = cost(f, kind: kind, item: item, zones: zones, others: others, front: front)
                if c < bestCost { bestCost = c; best = f }
                x += step
            }
            y += step
        }
        // Also try hugging each edge exactly.
        for f in [CGRect(x: area.maxX - size.width, y: best.minY, width: size.width, height: size.height),
                  CGRect(x: area.minX, y: best.minY, width: size.width, height: size.height),
                  CGRect(x: best.minX, y: area.maxY - size.height, width: size.width, height: size.height),
                  CGRect(x: best.minX, y: area.minY, width: size.width, height: size.height)] {
            let c = cost(f, kind: kind, item: item, zones: zones, others: others, front: front)
            if c < bestCost { bestCost = c; best = f }
        }
        return best
    }

    // MARK: The loop

    private func tick() {
        items.removeAll { $0.window == nil }
        Focus.shared.update()
        guard !paused else { return }

        let all = ourFrames(except: nil)
        let zones = Focus.shared.hotZones(ignoring: all)
        let mouse = NSEvent.mouseLocation

        for (index, item) in items.enumerated() {
            guard let w = item.window, w.isVisible else { continue }
            // Each window only makes way for ones that were there before it, so they never chase each other.
            let earlier = items.prefix(index).compactMap { $0.window?.isVisible == true ? $0.target : nil }
            // Never yank a window out from under the user's hand.
            if NSEvent.pressedMouseButtons != 0 && w.frame.insetBy(dx: -4, dy: -4).contains(mouse) { continue }
            if Date().timeIntervalSince(item.lastDodge) < 0.5 { continue }

            let others = ourFrames(except: item)
            let blocked = zones.contains { $0.rect.intersects(item.target) } || earlier.contains { $0.insetBy(dx: 4, dy: 4).intersects(item.target) }

            if blocked {
                let screen = Geo.screen(containing: item.target.center)
                let spot = bestSpot(size: item.target.size, on: screen, for: item, kind: item.kind)
                if spot.origin.distance(to: item.target.origin) > 4 {
                    move(item, to: spot)
                }
                item.homeClearSince = nil
            } else if item.kind == .chat, let home = item.home, home.distance(to: item.target.origin) > 4 {
                // Displaced: go back home once it's been clear for a bit.
                let homeFrame = CGRect(origin: home, size: item.target.size)
                let clear = !zones.contains { $0.rect.intersects(homeFrame) } && !others.contains { $0.intersects(homeFrame) }
                if clear {
                    if let since = item.homeClearSince {
                        if Date().timeIntervalSince(since) > 2.5 { move(item, to: homeFrame); item.homeClearSince = nil }
                    } else {
                        item.homeClearSince = Date()
                    }
                } else {
                    item.homeClearSince = nil
                }
            }
        }
    }

    private func move(_ item: Item, to frame: CGRect) {
        guard let w = item.window else { return }
        item.target = frame
        item.movedByUsAt = Date()
        item.lastDodge = Date()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            w.animator().setFrame(frame, display: true)
        }
    }
}

private extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
}
