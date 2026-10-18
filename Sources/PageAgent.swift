import AppKit
import WebKit

/// Watches each page for things the browser chrome reacts to: the link under the mouse
/// (status pill and ⌥-hover peek) and whether a video is playing (picture-in-picture).
/// Runs in its own JS world so pages can't see it or fake its messages.
@MainActor
final class PageAgent: NSObject, WKScriptMessageHandler {
    static let shared = PageAgent()
    static let world = WKContentWorld.world(name: "OrbitPage")
    private static let handlerName = "orbitPage"

    func install(in controller: WKUserContentController) {
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: Self.world))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let kind = body["type"] as? String,
              let tab = Browser.shared.tabs.first(where: { $0.webView === message.webView })
                ?? (Browser.shared.peek?.webView === message.webView ? Browser.shared.peek : nil)
        else { return }

        switch kind {
        case "hover":
            let href = body["href"] as? String ?? ""
            tab.hoveredLink = href.isEmpty ? nil : URL(string: href)
        case "peek":
            if let href = body["href"] as? String, let url = URL(string: href),
               ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               tab.id == Browser.shared.selectedID {
                Browser.shared.openPeek(url, from: tab)
            }
        case "media":
            tab.isPlayingVideo = body["playing"] as? Bool ?? false
        default:
            break
        }
    }

    /// Pops the page's main video out into a floating window.
    func pictureInPicture(_ tab: Tab) {
        tab.webView.callAsyncJavaScript("return window.__orbitPiP()", arguments: [:], in: nil, in: Self.world) { _ in }
    }

    private static let script = #"""
    (() => {
      const post = (m) => { try { window.webkit.messageHandlers.orbitPage.postMessage(m); } catch (_) {} };

      // Link under the mouse → status pill. Holding ⌥ over it for a moment → peek.
      let hovered = '', peekTimer = null, altDown = false;
      const linkAt = (el) => { const a = el && el.closest && el.closest('a[href]'); return a ? a.href : ''; };
      const schedulePeek = () => {
        clearTimeout(peekTimer);
        if (altDown && hovered) peekTimer = setTimeout(() => { if (altDown && hovered) post({ type: 'peek', href: hovered }); }, 380);
      };
      document.addEventListener('mouseover', (e) => {
        const href = linkAt(e.target);
        if (href !== hovered) { hovered = href; post({ type: 'hover', href }); }
        altDown = e.altKey; schedulePeek();
      }, true);
      document.addEventListener('mouseout', (e) => {
        if (!e.relatedTarget) { hovered = ''; post({ type: 'hover', href: '' }); clearTimeout(peekTimer); }
      }, true);
      document.addEventListener('keydown', (e) => { if (e.key === 'Alt') { altDown = true; schedulePeek(); } }, true);
      document.addEventListener('keyup', (e) => { if (e.key === 'Alt') { altDown = false; clearTimeout(peekTimer); } }, true);
      window.addEventListener('blur', () => { altDown = false; clearTimeout(peekTimer); });

      // Is a real video playing? (ignore tiny/muted autoplay previews)
      const realVideo = (v) => !v.paused && !v.ended && v.readyState > 2 && !v.muted && v.offsetWidth > 200;
      let playing = false;
      const report = () => {
        const now = [...document.querySelectorAll('video')].some(realVideo);
        if (now !== playing) { playing = now; post({ type: 'media', playing }); }
      };
      ['play', 'pause', 'ended', 'volumechange', 'emptied'].forEach(ev => document.addEventListener(ev, report, true));
      setInterval(report, 2000);

      window.__orbitPiP = () => {
        const vids = [...document.querySelectorAll('video')].filter(v => v.readyState > 0);
        const v = vids.sort((a, b) => (b.offsetWidth * b.offsetHeight) - (a.offsetWidth * a.offsetHeight))[0];
        if (!v) return false;
        try {
          if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) {
            v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
            return true;
          }
          if (document.pictureInPictureElement) { document.exitPictureInPicture(); return true; }
          v.requestPictureInPicture();
          return true;
        } catch (_) { return false; }
      };
    })();
    """#
}
