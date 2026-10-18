import AppKit
import LocalAuthentication
import Observation
import Security
import WebKit

struct Login: Identifiable, Hashable {
    let host: String
    let username: String
    var id: String { host + "\u{1}" + username }
}

/// Saved logins live in the macOS login Keychain as internet passwords.
enum PasswordStore {
    private static let label = "Orbit"

    static func all() -> [Login] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let host = item[kSecAttrServer as String] as? String else { return nil }
            return Login(host: host, username: item[kSecAttrAccount as String] as? String ?? "")
        }
        .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    static func logins(for host: String) -> [Login] {
        all().filter { $0.host == host }
    }

    static func password(for login: Login) -> String? {
        var query = baseQuery(login)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ login: Login, password: String) {
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(baseQuery(login) as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = baseQuery(login)
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ login: Login) {
        SecItemDelete(baseQuery(login) as CFDictionary)
    }

    private static func baseQuery(_ login: Login) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
            kSecAttrServer as String: login.host,
            kSecAttrAccount as String: login.username,
        ]
    }

    /// Asks for Touch ID / the Mac password before revealing a saved password.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// Offer shown after a login form is submitted.
struct PasswordOffer: Equatable {
    let login: Login
    let password: String
    let isUpdate: Bool
}

/// Watches login forms and fills saved logins. Runs in its own JS world so pages can't see or spoof it.
@MainActor
final class PasswordAgent: NSObject, WKScriptMessageHandler {
    static let shared = PasswordAgent()
    static let world = WKContentWorld.world(name: "OrbitPasswords")
    private static let handlerName = "orbitPasswords"

    /// Usernames typed on a "step 1" page, for sites that ask for the password on a second page.
    private var pendingUsername: [String: String] = [:]

    func install(in controller: WKUserContentController) {
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: Self.world))
    }

    func fill(_ login: Login, in webView: WKWebView) {
        guard let password = PasswordStore.password(for: login) else { return }
        webView.callAsyncJavaScript("window.__orbitFill(u, p)", arguments: ["u": login.username, "p": password],
                                    in: nil, in: Self.world)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Trust only what WebKit tells us about the origin, never what the page claims.
        guard message.frameInfo.isMainFrame,
              let host = message.frameInfo.request.url?.host() ?? message.webView?.url?.host(),
              message.frameInfo.securityOrigin.protocol == "https" || host == "localhost",
              let body = message.body as? [String: Any],
              let kind = body["type"] as? String else { return }

        let username = (body["username"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if kind == "username" {
            if !username.isEmpty { pendingUsername[host] = username }
            return
        }
        let fromPrivateTab = Browser.shared.tabs.first { $0.webView === message.webView }?.isPrivate ?? true
        guard kind == "submit", !fromPrivateTab,
              UserDefaults.standard.bool(forKey: Pref.offerPasswords),
              let password = body["password"] as? String, !password.isEmpty,
              !Self.neverSave.contains(host) else { return }

        let user = username.isEmpty ? (pendingUsername[host] ?? "") : username
        let login = Login(host: host, username: user)
        let existing = PasswordStore.logins(for: host).first { $0.username == user }
        if let existing, PasswordStore.password(for: existing) == password { return }

        let offer = PasswordOffer(login: login, password: password, isUpdate: existing != nil)
        if Browser.shared.passwordOffer != offer { Browser.shared.passwordOffer = offer }
    }

    static var neverSave: [String] {
        get { UserDefaults.standard.stringArray(forKey: "neverSavePasswords") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "neverSavePasswords") }
    }

    private static let script = #"""
    (() => {
      const post = (msg) => { try { window.webkit.messageHandlers.orbitPasswords.postMessage(msg); } catch (_) {} };
      const visible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
      const isUserField = (el) => el.tagName === 'INPUT' &&
        ['text', 'email', 'tel', ''].includes((el.getAttribute('type') || '').toLowerCase()) && visible(el);

      function findUser(scope, pw) {
        const inputs = [...scope.querySelectorAll('input')];
        const i = pw ? inputs.indexOf(pw) : inputs.length;
        for (let j = i - 1; j >= 0; j--) if (isUserField(inputs[j]) && inputs[j].value) return inputs[j];
        return scope.querySelector('input[autocomplete~="username"], input[type="email"]');
      }

      function grab(scope) {
        scope = scope || document;
        const pw = [...scope.querySelectorAll('input[type="password"]')].find(i => i.value);
        if (pw) {
          const user = findUser(pw.form || document, pw);
          post({ type: 'submit', username: user ? user.value : '', password: pw.value });
        } else {
          const user = findUser(scope, null);
          if (user && user.value) post({ type: 'username', username: user.value });
        }
      }

      let last = 0;
      const once = (scope) => { const now = Date.now(); if (now - last > 800) { last = now; grab(scope); } };
      document.addEventListener('submit', (e) => once(e.target), true);
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && e.target && e.target.tagName === 'INPUT') once(e.target.form);
      }, true);
      document.addEventListener('click', (e) => {
        const b = e.target.closest && e.target.closest('button, input[type="submit"], [role="button"]');
        if (b) once(b.form);
      }, true);

      const setValue = (el, value) => {
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        el.focus();
        setter.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      };

      window.__orbitFill = (username, password) => {
        const pw = [...document.querySelectorAll('input[type="password"]')].find(visible);
        const user = pw ? findUser(pw.form || document, pw) || [...(pw.form || document).querySelectorAll('input')].find(isUserField)
                        : [...document.querySelectorAll('input')].find(isUserField);
        if (user && username) setValue(user, username);
        if (pw) setValue(pw, password);
      };
    })();
    """#
}
