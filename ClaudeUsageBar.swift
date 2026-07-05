// Claude Usage Bar — native macOS menu-bar widget showing Claude.ai session
// usage: used % + reset countdown. Swift rewrite of claude_usage_bar.py:
// single ~1 MB binary, ~20 MB RAM, no Python/venv needed.
//
// Auth model unchanged: paste your claude.ai sessionKey once; it lives in the
// macOS Keychain (service "claude-usage-bar", account "sessionKey" — same slot
// the old Python version used).
//
// The endpoint is UNOFFICIAL. If Anthropic changes it, the app keeps running
// but shows a warning — see the "CLAUDE API" section below; it's isolated on
// purpose so a fix is a small change.

import AppKit
import Security

// ─────────────────────────────── config ───────────────────────────────
let keychainService = "claude-usage-bar"
let keychainAccount = "sessionKey"
let refreshSeconds: TimeInterval = 300   // poll every 5 min
let tickSeconds: TimeInterval = 30       // countdown repaint (display is minute-granular)
let requestTimeout: TimeInterval = 15
let titlePrefix = "•"

// ══════════════════════════════ CLAUDE API ════════════════════════════
// The only unofficial part. If the widget suddenly shows "⚠ key" even though
// your key is fresh, or "⚠", the endpoint or field names below likely moved.
// Re-capture them: claude.ai → F12 → Network → visit claude.ai/settings/usage
// → the request ending in "/usage" → inspect URL + JSON response.
let orgsURL = URL(string: "https://claude.ai/api/organizations")!
func usageURL(orgId: String) -> URL {
    URL(string: "https://claude.ai/api/organizations/\(orgId)/usage")!
}

let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

struct UsageData: Sendable {
    var pct: Double?
    var resetEpoch: TimeInterval?
}

enum FetchError: Error {
    case auth          // sessionKey missing/expired/rejected — re-paste
    case api(String)   // endpoint moved / network trouble
}

let urlSession = URLSession(configuration: .ephemeral)

func getJSON(_ url: URL, key: String) async throws -> Any {
    var req = URLRequest(url: url, timeoutInterval: requestTimeout)
    req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
    req.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
    let (data, resp) = try await urlSession.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw FetchError.api("no response") }
    if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.auth }
    guard (200..<300).contains(http.statusCode) else {
        throw FetchError.api("http \(http.statusCode)")
    }
    return try JSONSerialization.jsonObject(with: data)
}

/// Claude returns utilization already as 0–100. Clamp; blanks/junk → nil.
func clampPct(_ value: Any?) -> Double? {
    let num: Double
    switch value {
    case let n as NSNumber: num = n.doubleValue
    case let s as String:
        guard let d = Double(s) else { return nil }
        num = d
    default: return nil
    }
    if num < 0 { return nil }
    return min(num, 100.0)
}

/// ISO 8601 (may have fractional seconds / 'Z') → epoch seconds, or nil.
func parseReset(_ value: Any?) -> TimeInterval? {
    guard let s = value as? String, !s.isEmpty else { return nil }
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = fmt.date(from: s) { return d.timeIntervalSince1970 }
    fmt.formatOptions = [.withInternetDateTime]
    return fmt.date(from: s)?.timeIntervalSince1970
}

/// Orgs → pick the one hosting the chat product; fall back to the first.
func selectOrg(_ payload: Any) -> [String: Any]? {
    let orgs: [[String: Any]]
    if let arr = payload as? [[String: Any]] {
        orgs = arr
    } else if let dict = payload as? [String: Any],
              let arr = dict["organizations"] as? [[String: Any]] {
        orgs = arr
    } else {
        return nil
    }
    for o in orgs where (o["capabilities"] as? [String])?.contains("chat") == true {
        return o
    }
    return orgs.first
}

/// Fetch {pct, resetEpoch} for the current 5-hour session window.
/// Prefer the `limits` array (entries {kind: "session", percent, resets_at});
/// fall back to the legacy flat `five_hour` bucket ({utilization, resets_at}).
func fetchSessionUsage(key: String) async throws -> UsageData {
    guard let org = selectOrg(try await getJSON(orgsURL, key: key)) else {
        throw FetchError.api("no organization on this account")
    }
    guard let orgId = (org["uuid"] ?? org["organization_uuid"] ?? org["id"]) as? String else {
        throw FetchError.api("could not resolve organization id")
    }
    let usage = try await getJSON(usageURL(orgId: orgId), key: key) as? [String: Any] ?? [:]
    if let limits = usage["limits"] as? [[String: Any]],
       let lim = limits.first(where: { ($0["kind"] as? String) == "session" }) {
        return UsageData(pct: clampPct(lim["percent"]),
                         resetEpoch: parseReset(lim["resets_at"]))
    }
    let flat = usage["five_hour"] as? [String: Any] ?? [:]
    return UsageData(pct: clampPct(flat["utilization"]),
                     resetEpoch: parseReset(flat["resets_at"]))
}
// ════════════════════════════ end CLAUDE API ══════════════════════════

// ─────────────────────────────── keychain ─────────────────────────────
func keychainGet() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

func keychainSet(_ value: String) {
    let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
    ]
    let data = Data(value.utf8)
    let status = SecItemUpdate(base as CFDictionary,
                               [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}

// ─────────────────────────────── formatting ───────────────────────────
func fmtCountdown(_ resetEpoch: TimeInterval?) -> String? {
    guard let resetEpoch else { return nil }
    let secs = Int(resetEpoch - Date().timeIntervalSince1970)
    if secs <= 0 { return "resetting" }
    let h = secs / 3600
    let m = (secs % 3600) / 60
    return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
}

func fmtClock(_ resetEpoch: TimeInterval?) -> String {
    guard let resetEpoch else { return "—" }
    let fmt = DateFormatter()
    fmt.dateFormat = "h:mm a"
    return fmt.string(from: Date(timeIntervalSince1970: resetEpoch))
}

/// Orange from 80%, red from 90%; below that nil → native monochrome.
func usageColor(_ used: Double) -> NSColor? {
    used >= 90 ? .systemRed : used >= 80 ? .systemOrange : nil
}

/// Ring gauge drawn with Core Graphics: a faint full-circle track plus an arc
/// that fills clockwise from 12 o'clock as usage grows. With no color it's a
/// template image, so macOS tints it to match the menu bar (light/dark).
func ringImage(_ used: Double, color: NSColor?) -> NSImage {
    let side: CGFloat = 16
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        let lineWidth: CGFloat = 2
        let radius = (min(rect.width, rect.height) - lineWidth) / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let tint = color ?? .black

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        tint.withAlphaComponent(0.25).setStroke()
        track.stroke()

        let frac = min(max(used / 100, 0), 1)
        if frac > 0 {
            let arc = NSBezierPath()
            if frac >= 0.999 {
                arc.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            } else {
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: 90, endAngle: 90 - frac * 360, clockwise: true)
            }
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            tint.setStroke()
            arc.stroke()
        }
        return true
    }
    image.isTemplate = (color == nil)
    return image
}

// ─────────────────────────────── app ──────────────────────────────────
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum ErrorState { case none, nokey, auth, api }

    var statusItem: NSStatusItem!
    var itemUsed = NSMenuItem(title: "Session: —", action: nil, keyEquivalent: "")
    var itemRemaining = NSMenuItem(title: "Remaining: —", action: nil, keyEquivalent: "")
    var itemReset = NSMenuItem(title: "Resets: —", action: nil, keyEquivalent: "")

    var pct: Double?
    var resetEpoch: TimeInterval?
    var errorState: ErrorState = .nokey
    var haveData = false            // a successful fetch has completed at least once
    var lastFetch: TimeInterval = 0
    var fetching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "\(titlePrefix) …"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(itemUsed)
        menu.addItem(itemRemaining)
        menu.addItem(itemReset)
        menu.addItem(.separator())
        menu.addItem(makeItem("Refresh now", #selector(onRefresh)))
        menu.addItem(makeItem("Set session key…", #selector(onSetKey)))
        menu.addItem(makeItem("Open usage page", #selector(onOpenPage)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit", #selector(onQuit)))
        statusItem.menu = menu

        // One main-thread timer drives everything: it repaints the countdown
        // and schedules background fetches when due.
        let timer = Timer.scheduledTimer(timeInterval: tickSeconds, target: self,
                                         selector: #selector(tick), userInfo: nil,
                                         repeats: true)
        timer.tolerance = 5  // let macOS coalesce wakeups
        tick()               // fetch + paint immediately
    }

    func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // ---- scheduling ---------------------------------------------------
    @objc func tick() {
        if !fetching && Date().timeIntervalSince1970 - lastFetch >= refreshSeconds {
            startFetch()
        }
        render()
    }

    func menuWillOpen(_ menu: NSMenu) {
        render()  // fresh countdown the moment the menu opens
    }

    func startFetch() {
        guard let key = keychainGet() else {
            errorState = .nokey
            lastFetch = Date().timeIntervalSince1970
            return
        }
        fetching = true
        Task {
            do {
                let data = try await fetchSessionUsage(key: key)
                self.pct = data.pct
                self.resetEpoch = data.resetEpoch
                self.errorState = .none
                self.haveData = true
            } catch FetchError.auth {
                self.errorState = .auth
            } catch {
                self.errorState = .api
            }
            self.lastFetch = Date().timeIntervalSince1970
            self.fetching = false
            self.render()
        }
    }

    // ---- rendering ------------------------------------------------------
    func render() {
        guard let button = statusItem.button else { return }

        if errorState == .nokey {
            button.image = nil
            button.title = "\(titlePrefix) set key"
            itemUsed.title = "Session: no session key"
            itemRemaining.title = "Remaining: —"
            itemReset.title = "Use \"Set session key…\" below"
            return
        }
        if errorState == .auth {
            button.image = nil
            button.title = "\(titlePrefix) ⚠ key"
            itemUsed.title = "Session key expired or rejected"
            itemRemaining.title = "Re-paste from claude.ai cookies"
            itemReset.title = "→ Set session key…"
            return
        }

        // For display, a null session bucket means "not used yet" → 0%.
        let used: Double? = pct ?? (haveData ? 0.0 : nil)
        let cd = fmtCountdown(resetEpoch)

        if let used {
            let warn = errorState == .api ? " ⚠" : ""
            var title = " \(Int(used.rounded()))%"
            if let cd { title += " · \(cd)" }
            let color = usageColor(used)
            button.image = ringImage(used, color: color)
            button.imagePosition = .imageLeft
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.systemFontSize, weight: .regular),
                .baselineOffset: 1,
            ]
            if let color { attrs[.foregroundColor] = color }
            button.attributedTitle = NSAttributedString(string: title + warn,
                                                        attributes: attrs)
            itemUsed.title = "Session: \(Int(used.rounded()))% used"
            itemRemaining.title = "Remaining: \(Int(max(0, 100 - used).rounded()))%"
            if resetEpoch != nil, let cd {
                itemReset.title = "Resets in \(cd)  (\(fmtClock(resetEpoch)))"
            } else {
                itemReset.title = "Resets: not active yet"
            }
        } else {
            // first fetch not back yet
            button.image = nil
            button.title = "\(titlePrefix) …"
            itemUsed.title = "Session: loading…"
            itemRemaining.title = "Remaining: —"
            itemReset.title = "Resets: —"
        }

        if errorState == .api {
            itemReset.title += "  · stale (API changed?)"
        }
    }

    // ---- menu callbacks -------------------------------------------------
    @objc func onRefresh() {
        lastFetch = 0
        tick()
    }

    @objc func onSetKey() {
        let alert = NSAlert()
        alert.messageText = "Claude session key"
        alert.informativeText = "Paste your claude.ai sessionKey (starts with sk-ant-sid01-…).\n"
            + "Get it: claude.ai → F12 → Application → Cookies → "
            + "https://claude.ai → sessionKey → copy the value."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix("sessionkey=") {   // tolerate a full-cookie paste
            key = String(key.dropFirst("sessionkey=".count))
                .trimmingCharacters(in: .whitespaces)
        }
        if !key.isEmpty {
            keychainSet(key)
            errorState = .none
            lastFetch = 0  // refresh immediately
            tick()
        }
    }

    @objc func onOpenPage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc func onQuit() {
        NSApp.terminate(nil)
    }
}

@main
@MainActor
struct ClaudeUsageBarApp {
    static func main() {
        // Single-instance guard: double-clicking the .app while the login
        // agent already runs it must not spawn a second menu-bar icon.
        if let bundleId = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).count > 1 {
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
        app.run()
    }
}
