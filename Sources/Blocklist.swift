import Foundation

/// A small built-in ad and tracker blocker (WebKit content rules, runs natively, costs ~nothing).
enum Blocklist {
    static let domains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
        "google-analytics.com", "googletagservices.com", "pagead2.googlesyndication.com",
        "adnxs.com", "adsrvr.org", "advertising.com", "amazon-adsystem.com", "criteo.com", "criteo.net",
        "taboola.com", "outbrain.com", "scorecardresearch.com", "quantserve.com", "moatads.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com", "smartadserver.com",
        "adform.net", "bidswitch.net", "sharethrough.com", "media.net", "zedo.com", "yieldmo.com",
        "hotjar.com", "mouseflow.com", "crazyegg.com", "fullstory.com", "mixpanel.com",
        "connect.facebook.net", "ads-twitter.com", "ads.linkedin.com", "analytics.tiktok.com",
        "bat.bing.com", "clarity.ms", "adcolony.com", "applovin.com", "popads.net", "propellerads.com",
        "exoclick.com", "trafficjunky.net", "revcontent.com", "mgid.com", "33across.com", "teads.tv",
    ]

    static var json: String {
        let rules = domains.map { domain -> [String: Any] in
            let escaped = NSRegularExpression.escapedPattern(for: domain)
            return [
                "trigger": [
                    "url-filter": "^[a-z]+://([^/]+\\.)?\(escaped)[:/]",
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Removes tracking parameters from links.
enum Tracking {
    private static let exact: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "igshid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id",
        "vero_id", "wickedid", "rb_clickid", "s_cid", "ref_src", "ref_url",
    ]

    /// The URL without tracking parameters, or nil when there was nothing to remove.
    static func clean(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems, !items.isEmpty else { return nil }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !exact.contains(name) && !name.hasPrefix("utm_")
        }
        guard kept.count != items.count else { return nil }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.url
    }
}
