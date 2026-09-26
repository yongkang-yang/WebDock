import AppKit
import Foundation
import LocalAuthentication
import OSLog
import Security
import WebKit

/// Saved logins, in the login keychain as internet passwords marked as WebDock's. Each belongs to
/// one of the user's sites as well as a host, so two sites on one host (two journals on the same
/// submission system, say) keep their own logins; the site's ID goes in the item's path.
enum LoginKeychain {
    struct Login: Identifiable, Hashable {
        var siteID: UUID
        var host: String
        var account: String
        var id: String { "\(siteID)\n\(host)\n\(account)" }
    }

    /// 'WbDk': tells WebDock's items apart from other apps' passwords for the same host.
    private static let creator = NSNumber(value: 0x5762_446B as UInt32)

    private static func query(siteID: UUID? = nil, host: String? = nil, account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrCreator as String: creator,
        ]
        if let siteID { query[kSecAttrPath as String] = path(siteID) }
        if let host { query[kSecAttrServer as String] = host }
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private static func path(_ siteID: UUID) -> String { "/" + siteID.uuidString }

    static func logins(siteID: UUID? = nil, host: String? = nil) -> [Login] {
        var query = query(siteID: siteID, host: host)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let server = item[kSecAttrServer as String] as? String,
                  let path = item[kSecAttrPath as String] as? String,
                  let siteID = UUID(uuidString: String(path.dropFirst())) else { return nil }
            return Login(siteID: siteID, host: server, account: item[kSecAttrAccount as String] as? String ?? "")
        }
        .sorted { ($0.host, $0.account) < ($1.host, $1.account) }
    }

    static func password(for login: Login) -> String? {
        var query = query(siteID: login.siteID, host: login.host, account: login.account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ login: Login, password: String) {
        let data = Data(password.utf8)
        let existing = query(siteID: login.siteID, host: login.host, account: login.account)
        if SecItemUpdate(existing as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = existing
            item[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS
            item[kSecAttrLabel as String] = "\(login.host) (WebDock)"
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete(_ login: Login) {
        SecItemDelete(query(siteID: login.siteID, host: login.host, account: login.account) as CFDictionary)
    }

    /// Drops the logins of sites that no longer exist, and ones saved before logins belonged to a
    /// site (those were shared by every site on their host).
    static func removeAll(except siteIDs: Set<UUID>) {
        var query = query()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        query[kSecReturnPersistentRef as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        for item in items {
            let path = item[kSecAttrPath as String] as? String ?? ""
            if let siteID = UUID(uuidString: String(path.dropFirst())), siteIDs.contains(siteID) { continue }
            // By reference: a query by attributes would also match the site's own login when a
            // pathless one has the same host and account.
            guard let ref = item[kSecValuePersistentRef as String] else { continue }
            SecItemDelete([kSecClass as String: kSecClassInternetPassword, kSecValuePersistentRef as String: ref] as CFDictionary)
        }
    }
}

/// Touch ID, or the Mac's login password, before a saved password is used or deleted, so someone
/// at an unlocked Mac can't sign in with it. One success covers the next few minutes, until the
/// screen locks or the Mac sleeps.
enum PasswordGate {
    private static let grace: TimeInterval = 5 * 60
    private static var lastSuccess: Date?
    /// While the system's dialog is up, a click on it mustn't close the panel.
    private(set) static var isAuthenticating = false

    static func startObserving() {
        let lock: (Notification) -> Void = { _ in lastSuccess = nil }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"),
                                                            object: nil, queue: .main, using: lock)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lock)
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: lock)
    }

    /// `reason` finishes the system's sentence "WebDock is trying to …".
    static func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        if let lastSuccess, Date().timeIntervalSince(lastSuccess) < grace {
            completion(true)
            return
        }
        guard !isAuthenticating else { return }
        isAuthenticating = true
        LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                isAuthenticating = false
                if success { lastSuccess = Date() }
                completion(success)
            }
        }
    }
}

/// Offers saved logins the way Safari does: focusing a sign-in field shows the site's saved accounts
/// in a menu under it, and choosing one fills it in. Until then the page gets account names only;
/// the password leaves the keychain when the user picks its account and passes PasswordGate. The script runs in its own
/// content world and draws the menu in a closed shadow root, so the page's scripts can neither ask
/// for a password nor reach the menu. It never submits the form: the user still presses Return.
/// It also notices logins typed in by hand, so the app can offer to save them.
enum Autofill {
    /// Message types and hosts only; never usernames or passwords.
    static let log = Logger(subsystem: "com.johanyang.WebDock", category: "Autofill")
    static let messageName = "webdockAutofill"
    static let world = WKContentWorld.world(name: "WebDockAutofill")

    static let script = WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                     forMainFrameOnly: false, in: world)

    /// The accounts saved for the frame's site and host, most likely first; empty when none.
    static func offer(accounts: [String], siteName: String, to frame: WKFrameInfo, in webView: WKWebView) {
        webView.callAsyncJavaScript("window.__webdockSetAccounts(accounts, site)",
                                    arguments: ["accounts": accounts, "site": siteName],
                                    in: frame, in: world, completionHandler: nil)
    }

    /// The account the user chose from the menu, with its password.
    static func fill(username: String, password: String, in frame: WKFrameInfo, of webView: WKWebView) {
        webView.callAsyncJavaScript("window.__webdockFill(username, password)",
                                    arguments: ["username": username, "password": password],
                                    in: frame, in: world, completionHandler: nil)
    }

    private static let source = """
    (() => {
      if (window.__webdockSetAccounts) return;
      const post = (message) => { try { webkit.messageHandlers.\(messageName).postMessage(message); } catch (e) {} };
      const textTypes = ['text', 'email', 'tel'];
      const visible = (el) => {
        const rect = el.getBoundingClientRect();
        const style = getComputedStyle(el);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && !el.disabled && !el.readOnly;
      };
      const passwordFields = () => [...document.querySelectorAll('input[type=password]')].filter(visible);
      // The last text field before the password in its form: where the username goes.
      const userFieldBefore = (password) => {
        let found = null;
        for (const input of (password.form || document).querySelectorAll('input')) {
          if (input === password) break;
          if (textTypes.includes(input.type) && visible(input)) found = input;
        }
        return found;
      };
      // A username asked for on its own, before a separate password step.
      const loneUserField = () => [...document.querySelectorAll('input')].find((input) =>
        textTypes.includes(input.type) && visible(input) &&
        (/username|email/.test(input.autocomplete) || input.type === 'email' ||
         /user|email|login|account|mail/i.test(input.name + ' ' + input.id)));
      const fields = () => {
        const passwords = passwordFields();
        if (passwords.length === 1) return { user: userFieldBefore(passwords[0]), password: passwords[0] };
        if (passwords.length === 0) {
          const user = loneUserField();
          if (user) return { user, password: null };
        }
        return null;  // none, or a new-password form with a confirmation field
      };

      // Sets a value the way typing does, so frameworks like React notice it.
      let filling = false;
      const setValue = (input, value) => {
        filling = true;
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, value);
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        filling = false;
      };

      // MARK: The saved accounts

      let accounts;  // undefined until the app answers; empty when nothing is saved here
      let siteName = '';
      let asked = false;
      const ask = () => {
        if (!asked && fields()) { asked = true; post({ type: 'fields' }); }
      };
      window.__webdockSetAccounts = (list, site) => {
        accounts = list;
        siteName = site;
        if (document.activeElement instanceof HTMLInputElement) show(document.activeElement);
      };
      window.__webdockFill = (username, password) => {
        const found = fields();
        if (!found) return;
        if (found.user && username) setValue(found.user, username);
        if (found.password && password) setValue(found.password, password);
        hide();
      };

      // MARK: The menu

      let host = null, menu = null, anchor = null, shown = [], active = -1;
      const build = () => {
        host = document.createElement('webdock-autofill');
        host.style.cssText = 'all: initial; position: absolute; z-index: 2147483647; display: none;';
        const root = host.attachShadow({ mode: 'closed' });
        root.innerHTML = `<style>
          .menu { box-sizing: border-box; min-width: 240px; max-width: 380px; padding: 5px;
            font: 13px -apple-system, system-ui, sans-serif; color: #1d1d1f;
            background: rgba(246, 246, 248, 0.94); -webkit-backdrop-filter: blur(24px); backdrop-filter: blur(24px);
            border: 0.5px solid rgba(0, 0, 0, 0.16); border-radius: 11px;
            box-shadow: 0 12px 32px rgba(0, 0, 0, 0.22), 0 1px 3px rgba(0, 0, 0, 0.12); }
          .row { display: flex; align-items: center; gap: 10px; padding: 6px 9px; border-radius: 7px; cursor: default; }
          .row.active { background: #0a64d8; background: AccentColor; color: #fff; }
          .icon { flex: none; width: 26px; height: 26px; border-radius: 50%; display: grid; place-items: center;
            background: linear-gradient(#8e8e93, #6e6e73); color: #fff; }
          .row.active .icon { background: rgba(255, 255, 255, 0.25); }
          .text { min-width: 0; }
          .name { font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
          .sub { font-size: 11px; color: #6e6e73; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
          .row.active .sub { color: rgba(255, 255, 255, 0.82); }
          @media (prefers-color-scheme: dark) {
            .menu { color: #f5f5f7; background: rgba(44, 44, 46, 0.94); border-color: rgba(255, 255, 255, 0.14); }
            .sub { color: #a1a1a6; }
          }
        </style><div class="menu" role="listbox"></div>`;
        menu = root.querySelector('.menu');
        // Clicking the menu mustn't take focus from the field.
        menu.addEventListener('mousedown', (event) => event.preventDefault());
        document.documentElement.appendChild(host);
      };
      const keyIcon = '<svg width="13" height="13" viewBox="0 0 16 16" fill="currentColor"><path d="M10.5 1a4.5 4.5 0 0 0-4.36 5.63L1.3 11.46a1 1 0 0 0-.3.71V14a1 1 0 0 0 1 1h1.5a.5.5 0 0 0 .5-.5V13h1.5a.5.5 0 0 0 .5-.5V11h1.5a.5.5 0 0 0 .35-.15l.8-.8A4.5 4.5 0 1 0 10.5 1Zm1 2.5a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3Z"/></svg>';
      const isOpen = () => host && host.isConnected && host.style.display !== 'none';
      const hide = () => {
        if (host) host.style.display = 'none';
        anchor = null;
        active = -1;
      };
      const setActive = (index) => {
        active = index;
        [...menu.children].forEach((row, i) => row.classList.toggle('active', i === index));
      };
      const choose = (name) => {
        hide();
        post({ type: 'choose', username: name });
      };
      const position = () => {
        if (!isOpen() || !anchor || !anchor.isConnected) return hide();
        const rect = anchor.getBoundingClientRect();
        const height = menu.offsetHeight;
        const below = rect.bottom + 4 + height <= innerHeight || rect.top - 4 - height < 0;
        // Page coordinates: a filter on the page (forced dark mode) breaks fixed positioning.
        host.style.left = (rect.left + scrollX) + 'px';
        host.style.top = ((below ? rect.bottom + 4 : rect.top - 4 - height) + scrollY) + 'px';
        menu.style.minWidth = Math.max(rect.width, 240) + 'px';
      };
      const show = (field) => {
        const found = fields();
        if (!accounts || !accounts.length || !found || (field !== found.user && field !== found.password)) return hide();
        let matches = accounts;
        const typed = found.user ? found.user.value.trim().toLowerCase() : '';
        if (field === found.user) {
          if (typed) matches = accounts.filter((name) => name.toLowerCase().startsWith(typed));
        } else {
          if (found.password.value) return hide();
          const exact = accounts.filter((name) => name.toLowerCase() === typed);
          if (exact.length) matches = exact;
        }
        if (!matches.length) return hide();
        if (!host || !host.isConnected) build();
        menu.textContent = '';
        matches.forEach((name, index) => {
          const row = document.createElement('div');
          row.className = 'row';
          row.setAttribute('role', 'option');
          row.innerHTML = '<span class="icon">' + keyIcon + '</span><span class="text"><div class="name"></div><div class="sub"></div></span>';
          row.querySelector('.name').textContent = name || 'Saved password';
          row.querySelector('.sub').textContent = 'Saved password · ' + siteName;
          row.addEventListener('mousemove', () => { if (active !== index) setActive(index); });
          row.addEventListener('click', () => choose(name));
          menu.appendChild(row);
        });
        shown = matches;
        anchor = field;
        active = -1;
        host.style.display = 'block';
        position();
      };

      // Registered before the capture listeners below, so choosing with Return stops there.
      document.addEventListener('keydown', (event) => {
        if (!isOpen()) return;
        const stop = () => { event.preventDefault(); event.stopImmediatePropagation(); };
        if (event.key === 'ArrowDown') { stop(); setActive((active + 1) % shown.length); }
        else if (event.key === 'ArrowUp') { stop(); setActive((active - 1 + shown.length) % shown.length); }
        else if (event.key === 'Enter' && active >= 0) { stop(); choose(shown[active]); }
        else if (event.key === 'Escape') { stop(); hide(); }
      }, true);
      document.addEventListener('focusin', (event) => {
        if (event.target instanceof HTMLInputElement) show(event.target); else hide();
      }, true);
      document.addEventListener('focusout', (event) => { if (event.target === anchor) hide(); }, true);
      document.addEventListener('input', (event) => {
        if (!filling && event.target instanceof HTMLInputElement && (isOpen() || event.target === document.activeElement)) show(event.target);
      }, true);
      document.addEventListener('mousedown', (event) => {
        // A click back into the field brings the menu back after Esc.
        if (event.target instanceof HTMLInputElement && event.target === document.activeElement && !isOpen()) {
          setTimeout(() => show(event.target), 0);
        }
      }, true);
      window.addEventListener('scroll', position, true);
      window.addEventListener('resize', position);

      // MARK: Logins typed in by hand

      let lastSent = '';
      const capture = () => {
        const found = fields();
        if (!found) return;
        const username = found.user ? found.user.value.trim() : '';
        const password = found.password ? found.password.value : '';
        if (!password && !username) return;
        const key = username + '\\n' + password;
        if (key === lastSent) return;
        lastSent = key;
        post(password ? { type: 'submit', username, password } : { type: 'username', username });
      };
      document.addEventListener('submit', capture, true);
      document.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' && event.target instanceof HTMLInputElement) capture();
      }, true);
      // Any click, not just buttons: older sites sign in from a link whose script calls
      // form.submit(), which fires no submit event. Leaving the page catches the rest.
      document.addEventListener('click', (event) => {
        if (!(host && host.contains(event.target))) capture();
      }, true);
      window.addEventListener('pagehide', capture, true);

      let pending;
      new MutationObserver(() => {
        clearTimeout(pending);
        pending = setTimeout(ask, 300);
      }).observe(document.documentElement, { childList: true, subtree: true });
      ask();
    })();
    """
}
