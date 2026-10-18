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
