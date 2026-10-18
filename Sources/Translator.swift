import NaturalLanguage
import SwiftUI
import Translation
import WebKit

/// Page translation with Apple's on-device Translation framework: private, free, works offline
/// once the language is downloaded (macOS offers the download the first time).
@MainActor
enum Translator {
    /// Your language (what pages get translated into).
    static var target: Locale.Language { Locale.current.language }

    /// The page's language, if it's confidently different from yours.
    static func detectLanguage(sample: String, declared: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        var code = recognizer.dominantLanguage?.rawValue
        if let lang = recognizer.dominantLanguage,
           (recognizer.languageHypotheses(withMaximum: 1)[lang] ?? 0) < 0.6 || sample.count < 60 {
            code = declared.isEmpty ? nil : declared // not sure from the text; trust the page's own tag
        }
        guard let code, !code.isEmpty else { return nil }
        let language = Locale.Language(identifier: code)
        guard language.languageCode != nil, language.languageCode != target.languageCode else { return nil }
        return language
    }

    static func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forLanguageCode: language.languageCode?.identifier ?? "")?.capitalized ?? "this language"
    }

    /// Runs inside `.translationTask`, which supplies a ready session.
    static func translate(_ tab: Tab, with session: TranslationSession) async {
        let webView = tab.webView
        // [[index, text]], already ordered with on-screen text first.
        guard let raw = (try? await webView.callAsyncJavaScript("return window.__orbitCollect()", arguments: [:],
                                                                in: nil, contentWorld: PageAgent.world)) as? [[Any]],
              !raw.isEmpty else { return }
        tab.isTranslating = true
        defer { tab.isTranslating = false }

        // Translate in batches so the page fills in progressively, starting with what you can see.
        let indexed: [(Int, String)] = raw.compactMap { pair in
            guard pair.count == 2, let i = (pair[0] as? NSNumber)?.intValue, let text = pair[1] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (i, trimmed)
        }
        // A tiny first batch so something changes within seconds, then big batches.
        var starts = [0]
        var next = 20
        while next < indexed.count { starts.append(next); next += 150 }
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1] : indexed.count
            let batch = indexed[start..<end]
            let requests = batch.map { TranslationSession.Request(sourceText: $0.1, clientIdentifier: String($0.0)) }
            guard let responses = try? await session.translations(from: requests) else { return }
            let pairs: [[Any]] = responses.compactMap { r in
                guard let id = r.clientIdentifier.flatMap(Int.init) else { return nil }
                return [id, r.targetText]
            }
            _ = try? await webView.callAsyncJavaScript("window.__orbitApply(pairs)", arguments: ["pairs": pairs],
                                                       in: nil, contentWorld: PageAgent.world)
            tab.isTranslated = true
        }
    }

    static func showOriginal(_ tab: Tab) {
        tab.webView.callAsyncJavaScript("window.__orbitRestore()", arguments: [:], in: nil, in: PageAgent.world) { _ in }
        tab.isTranslated = false
    }
}

/// Invisible view that hands a translation session to whichever tab asked for one.
struct TranslationHost: View {
    private let configState = State<TranslationSession.Configuration?>(initialValue: nil)
    private var browser: Browser { Browser.shared }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configState.wrappedValue) { session in
                guard let tab = browser.translating else { return }
                await Translator.translate(tab, with: session)
                browser.translating = nil
            }
            .onChange(of: browser.translating?.id) {
                guard let tab = browser.translating, let source = tab.pageLanguage else {
                    configState.wrappedValue = nil
                    return
                }
                configState.wrappedValue = TranslationSession.Configuration(source: source, target: Translator.target)
            }
    }
}
