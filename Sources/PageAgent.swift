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
        case "page":
            tab.readerAvailable = body["article"] as? Bool ?? false
            tab.pageLanguage = Translator.detectLanguage(sample: body["sample"] as? String ?? "",
                                                         declared: body["lang"] as? String ?? "")
            tab.isTranslated = false
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

      // What kind of page is this? (article worth reading mode, and its language)
      const describe = () => {
        const paras = [...document.querySelectorAll('article p, main p, p')].filter(p => p.innerText.length > 80);
        const text = paras.map(p => p.innerText).join(' ');
        post({ type: 'page', article: paras.length >= 4 && text.length > 1800,
               lang: document.documentElement.lang || '',
               sample: (text || document.body.innerText || '').slice(0, 1200) });
      };
      setTimeout(describe, 600);

      // Reading mode: the main article, cleaned up.
      window.__orbitReader = () => {
        // Score containers by the paragraph text they hold (parents fully, grandparents half),
        // so the whole article wins over any single section of it.
        const scores = new Map();
        document.querySelectorAll('p').forEach(p => {
          const len = p.innerText.trim().length;
          if (len < 40) return;
          const parent = p.parentElement, grand = parent && parent.parentElement;
          if (parent) scores.set(parent, (scores.get(parent) || 0) + len);
          if (grand) scores.set(grand, (scores.get(grand) || 0) + len / 2);
        });
        let best = null, top = 0;
        scores.forEach((s, el) => { if (s > top) { top = s; best = el; } });
        const article = document.querySelector('article');
        if (article && (!best || article.contains(best))) best = article;
        if (!best) return null;
        // Climb until the container holds most of the page's paragraph text (sections → whole article).
        const textIn = (el) => [...el.querySelectorAll('p')]
          .reduce((s, p) => s + (p.innerText.trim().length >= 40 ? p.innerText.length : 0), 0);
        const total = textIn(document.body);
        while (best.parentElement && best.parentElement !== document.body && textIn(best) < total * 0.75) {
          best = best.parentElement;
        }
        const clone = best.cloneNode(true);
        clone.querySelectorAll('script, style, noscript, nav, aside, footer, form, button, input, iframe, svg, video, ' +
          '[role="navigation"], [aria-hidden="true"], .ad, .ads, .advert, .share, .social, .newsletter, ' +
          '.mw-editsection, sup.reference, .reference, .noprint, .navbox, .metadata, .hatnote, [role="note"], ' +
          '.bandeau-container, .mw-indicators, .infobox, .infobox_v2, .infobox_v3, .sidebar, .toc, #toc')
          .forEach(e => e.remove());
        clone.querySelectorAll('*').forEach(e => {
          [...e.attributes].forEach(a => { if (!['href', 'src', 'alt', 'srcset'].includes(a.name)) e.removeAttribute(a.name); });
        });
        clone.querySelectorAll('img').forEach(img => { if (img.src) img.setAttribute('src', img.src); });
        clone.querySelectorAll('a').forEach(a => { if (a.href) a.setAttribute('href', a.href); });
        const meta = (n) => (document.querySelector(`meta[name="${n}"], meta[property="${n}"]`) || {}).content || '';
        const headline = (document.querySelector('h1') || {}).innerText || '';
        return { title: headline.trim() || meta('og:title') || document.title, byline: meta('author'),
                 site: meta('og:site_name') || location.hostname, html: clone.innerHTML };
      };

      // Translation: collect visible text, swap in translations, and put the original back.
      window.__orbitCollect = () => {
        const skip = 'script, style, noscript, code, pre, textarea, kbd, samp';
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, { acceptNode: n =>
          (n.nodeValue.trim().length > 1 && n.parentElement && !n.parentElement.closest(skip))
            ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT });
        const nodes = [];
        while (walker.nextNode() && nodes.length < 4000) nodes.push(walker.currentNode);
        window.__orbitNodes = nodes;
        window.__orbitOriginal = nodes.map(n => n.nodeValue);
        // Order: what's on screen first, then below it, then above it.
        const range = document.createRange();
        const rank = nodes.map((n, i) => {
          range.selectNodeContents(n);
          const r = range.getBoundingClientRect();
          const onScreen = r.bottom > 0 && r.top < innerHeight && r.width > 0;
          const score = onScreen ? r.top : (r.top >= innerHeight ? 1e5 + r.top : 2e5 - r.top);
          return [i, score];
        });
        rank.sort((a, b) => a[1] - b[1]);
        return rank.map(([i]) => [i, window.__orbitOriginal[i]]);
      };
      window.__orbitApply = (pairs) => {
        for (const [i, t] of pairs) {
          const n = (window.__orbitNodes || [])[i];
          if (n) { const lead = n.nodeValue.match(/^\s*/)[0], tail = n.nodeValue.match(/\s*$/)[0]; n.nodeValue = lead + t + tail; }
        }
      };
      window.__orbitRestore = () => {
        (window.__orbitNodes || []).forEach((n, i) => { n.nodeValue = window.__orbitOriginal[i]; });
      };

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
