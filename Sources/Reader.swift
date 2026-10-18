import SwiftUI
import WebKit

/// Reading mode: the page's article in a clean, distraction-free view.
/// The cleaned HTML is shown in a separate web view with JavaScript turned off.
@MainActor
@Observable
final class Reader {
    static let shared = Reader()

    enum Theme: String, CaseIterable { case light, sepia, dark }

    var article: Article?
    var fontSize: Double = UserDefaults.standard.object(forKey: "reader.fontSize") as? Double ?? 19 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "reader.fontSize"); render() }
    }
    var theme: Theme = Theme(rawValue: UserDefaults.standard.string(forKey: "reader.theme") ?? "") ?? .dark {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "reader.theme"); render() }
    }

    struct Article { let title: String; let byline: String; let site: String; let html: String; let base: URL? }

    @ObservationIgnored let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.underPageBackgroundColor = .clear
        return wv
    }()

    func open(_ tab: Tab) {
        tab.webView.callAsyncJavaScript("return window.__orbitReader()", arguments: [:], in: nil, in: PageAgent.world) { result in
            MainActor.assumeIsolated {
                guard case .success(let value) = result, let d = value as? [String: Any],
                      let html = d["html"] as? String else { return }
                self.article = Article(title: d["title"] as? String ?? tab.displayTitle,
                                       byline: d["byline"] as? String ?? "",
                                       site: d["site"] as? String ?? (tab.url?.host() ?? ""),
                                       html: html, base: tab.url)
                self.render()
            }
        }
    }

    func close() { article = nil }

    private func render() {
        guard let a = article else { return }
        let (bg, fg, muted, link) = switch theme {
        case .light: ("#fbfbfa", "#1d1d1f", "#6e6e73", "#0a66d8")
        case .sepia: ("#f5ecd9", "#3b2f22", "#80705d", "#9a4d16")
        case .dark: ("#17171a", "#e8e6e3", "#9a9aa0", "#7ab4ff")
        }
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data:; style-src 'unsafe-inline';">
        <style>
          html { background: \(bg); }
          body { margin: 0 auto; max-width: 680px; padding: 64px 32px 120px; color: \(fg);
                 font: \(Int(fontSize))px/1.65 "New York", ui-serif, Georgia, serif; -webkit-font-smoothing: antialiased; }
          .site { font: 600 12px -apple-system, system-ui; letter-spacing: .06em; text-transform: uppercase; color: \(muted); }
          h1.title { font: 700 \(Int(fontSize * 1.75))px/1.2 -apple-system, system-ui; margin: 10px 0 8px; letter-spacing: -.02em; }
          .byline { font: 14px -apple-system, system-ui; color: \(muted); margin-bottom: 36px; }
          h1, h2, h3, h4 { font-family: -apple-system, system-ui; line-height: 1.25; }
          img, figure, video { max-width: 100%; height: auto; border-radius: 14px; }
          figure { margin: 28px 0; } figcaption { font: 13px -apple-system, system-ui; color: \(muted); margin-top: 8px; }
          a { color: \(link); text-decoration: none; } a:hover { text-decoration: underline; }
          blockquote { margin: 24px 0; padding-left: 18px; border-left: 3px solid \(muted); color: \(muted); }
          table { border-collapse: collapse; margin: 24px 0; font: 14px/1.4 -apple-system, system-ui; width: 100%; }
          th, td { padding: 8px 10px; border-bottom: 1px solid rgba(127,127,127,.25); text-align: left; vertical-align: top; }
          th { color: \(muted); font-weight: 600; }
          pre, code { font: 14px ui-monospace, Menlo, monospace; } pre { overflow-x: auto; padding: 14px; border-radius: 12px; background: rgba(127,127,127,.12); }
          ::selection { background: \(link)44; }
        </style></head><body>
        <div class="site">\(esc(a.site))</div>
        <h1 class="title">\(esc(a.title))</h1>
        \(a.byline.isEmpty ? "" : "<div class=\"byline\">\(esc(a.byline))</div>")
        \(a.html)
        </body></html>
        """
        webView.loadHTMLString(page, baseURL: a.base)
    }
}

/// Reading mode over the page, with a small glass toolbar.
struct ReaderPanel: View {
    let accent: Accent
    private var reader: Reader { Reader.shared }

    var body: some View {
        ZStack(alignment: .top) {
            WebViewHost(webView: reader.webView)
            HStack(spacing: 4) {
                NavButton(symbol: "textformat.size.smaller", help: "Smaller text", enabled: reader.fontSize > 14) {
                    reader.fontSize -= 1
                }
                NavButton(symbol: "textformat.size.larger", help: "Larger text", enabled: reader.fontSize < 28) {
                    reader.fontSize += 1
                }
                Divider().frame(height: 16).padding(.horizontal, 4)
                ForEach(Reader.Theme.allCases, id: \.self) { theme in
                    Circle()
                        .fill(theme == .light ? Color(white: 0.98) : theme == .sepia ? Color(red: 0.96, green: 0.92, blue: 0.85) : Color(white: 0.1))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(reader.theme == theme ? accent.color : Color.primary.opacity(0.2),
                                                       lineWidth: reader.theme == theme ? 2 : 1))
                        .onTapGesture { reader.theme = theme }
                        .padding(.horizontal, 2)
                }
                Divider().frame(height: 16).padding(.horizontal, 4)
                NavButton(symbol: "xmark", help: "Close reading mode (esc)", enabled: true) { reader.close() }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, 12)
        }
        .onExitCommand { reader.close() }
    }
}
