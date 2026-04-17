import Foundation

/// Safari and Chrome automation via AppleScript.
///
/// We invoke `osascript` as a subprocess to avoid the main-thread
/// restrictions of NSAppleScript and keep the actor cleanly isolated.
/// Both Safari and Chrome require the user to enable "Allow JavaScript
/// from Apple Events" in their respective Develop/Developer menu the
/// first time any JS-eval tool is used.
actor BrowserController {
    enum Browser: String, Sendable {
        case safari = "Safari"
        case chrome = "Google Chrome"

        static func detect(_ raw: String?) -> Browser {
            switch raw?.lowercased() {
            case "chrome", "google chrome": return .chrome
            default: return .safari
            }
        }
    }

    struct TabInfo: Codable, Sendable {
        let browser: String
        let windowIndex: Int
        let tabIndex: Int
        let title: String
        let url: String
        let active: Bool
    }

    struct EvalResult: Codable, Sendable {
        let success: Bool
        let value: String?
        let error: String?
    }

    // MARK: - Tabs

    func listTabs(browser: Browser) -> [TabInfo] {
        let script: String
        switch browser {
        case .safari:
            script = """
            tell application "Safari"
                set output to ""
                set activeTabIndex to 0
                try
                    set activeTabIndex to index of current tab of front window
                end try
                repeat with w from 1 to (count of windows)
                    repeat with t from 1 to (count of tabs of window w)
                        set theTab to tab t of window w
                        set output to output & (w as string) & "\\t" & (t as string) & "\\t" & (name of theTab) & "\\t" & (URL of theTab) & "\\t" & ((w = 1 and t = activeTabIndex) as string) & "\\n"
                    end repeat
                end repeat
                return output
            end tell
            """
        case .chrome:
            script = """
            tell application "Google Chrome"
                set output to ""
                set activeIndex to 0
                try
                    set activeIndex to active tab index of front window
                end try
                repeat with w from 1 to (count of windows)
                    repeat with t from 1 to (count of tabs of window w)
                        set theTab to tab t of window w
                        set output to output & (w as string) & tab & (t as string) & tab & (title of theTab) & tab & (URL of theTab) & tab & ((w = 1 and t = activeIndex) as string) & linefeed
                    end repeat
                end repeat
                return output
            end tell
            """
        }

        guard let raw = runOsascript(script: script) else { return [] }
        return parseTabs(browser: browser.rawValue, raw: raw)
    }

    func activeTab(browser: Browser) -> TabInfo? {
        let tabs = listTabs(browser: browser)
        return tabs.first { $0.active }
    }

    /// Set a tab's URL. Creates a window if none exists (same reasoning
    /// as newTab — was failing on windowless browsers).
    func navigate(browser: Browser, url: String, windowIndex: Int = 1, tabIndex: Int? = nil) -> Bool {
        let tabRef: String
        let ensureWindow: String
        switch browser {
        case .safari:
            tabRef = tabIndex.map { "tab \($0) of window \(windowIndex)" } ?? "current tab of window \(windowIndex)"
            ensureWindow = "if (count of windows) = 0 then make new document"
        case .chrome:
            tabRef = tabIndex.map { "tab \($0) of window \(windowIndex)" } ?? "active tab of window \(windowIndex)"
            ensureWindow = "if (count of windows) = 0 then make new window"
        }

        let script = """
        tell application "\(browser.rawValue)"
            activate
            \(ensureWindow)
            set URL of \(tabRef) to "\(escape(url))"
            return "ok"
        end tell
        """
        return runOsascript(script: script) != nil
    }

    /// Evaluate JavaScript in a tab. The result is always returned as a
    /// JavaScript-formatted string (numbers via `String(n)`, objects via
    /// `JSON.stringify`), so the caller never sees AppleScript's locale-
    /// dependent number coercion — `1+1` returns `"2"` regardless of
    /// system locale, not `"2,0"` on nl-NL.
    ///
    /// Requires "Allow JavaScript from Apple Events" enabled in the
    /// browser's Develop menu.
    func evalJS(browser: Browser, code: String, windowIndex: Int = 1, tabIndex: Int? = nil) -> EvalResult {
        // Wrap user code so the result is always a well-formed JS string
        // before AppleScript ever touches it.
        //
        // Indirect eval `(0, eval)(code)` gives us REPL-like semantics:
        //   - `1+1`              → 2
        //   - `'hi'.toUpperCase()` → "HI"
        //   - `const x=1; x`     → 1       (block with trailing expression)
        //   - `document.title`   → "..."
        // whereas a naive `return (CODE)` wrapper would syntax-fail on
        // any statement-style script. `(0, eval)` also runs in global
        // scope so `const`/`let` from prior calls don't leak.
        //
        // Coercion of the returned value:
        //   string         → as-is
        //   null/undefined → "null" / "undefined"
        //   object         → JSON.stringify
        //   number/bool/…  → String(x)   (period decimal, no locale)
        //
        // Success/error are now distinguished by a structured JSON
        // envelope (not a sentinel string prefix), so a page result
        // that happens to look like an error sentinel can't be
        // misclassified (Codex v10 #MEDIUM).
        let wrappedJS = """
        (function(){
            function __mcp_coerce(v){
                if (v === null) return "null";
                if (v === undefined) return "undefined";
                if (typeof v === "string") return v;
                if (typeof v === "object") { try { return JSON.stringify(v); } catch(e) { return String(v); } }
                return String(v);
            }
            try {
                var __r = (0, eval)(\(jsStringLiteral(code)));
                return JSON.stringify({ ok: true, v: __mcp_coerce(__r) });
            } catch(e) {
                return JSON.stringify({ ok: false, err: (e && e.message ? e.message : String(e)) });
            }
        })()
        """

        let command: String
        switch browser {
        case .safari:
            let tabRef = tabIndex.map { "tab \($0) of window \(windowIndex)" } ?? "current tab of window \(windowIndex)"
            command = """
            tell application "Safari"
                try
                    set result to (do JavaScript "\(escape(wrappedJS))" in \(tabRef))
                    return "OK\\t" & (result as string)
                on error errMsg
                    return "ERR\\t" & errMsg
                end try
            end tell
            """
        case .chrome:
            let tabRef = tabIndex.map { "tab \($0) of window \(windowIndex)" } ?? "active tab of window \(windowIndex)"
            command = """
            tell application "Google Chrome"
                try
                    set result to (execute \(tabRef) javascript "\(escape(wrappedJS))")
                    return "OK\\t" & (result as string)
                on error errMsg
                    return "ERR\\t" & errMsg
                end try
            end tell
            """
        }

        guard let raw = runOsascript(script: command) else {
            return EvalResult(success: false, value: nil, error: "osascript invocation failed")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ERR\t") {
            return EvalResult(success: false, value: nil, error: String(trimmed.dropFirst(4)))
        }
        guard trimmed.hasPrefix("OK\t") else {
            return EvalResult(success: false, value: nil, error: "Unexpected response: \(trimmed)")
        }
        // The wrapper ALWAYS returns a JSON envelope — parse it.
        let envelope = String(trimmed.dropFirst(3))
        guard let data = envelope.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Old-format compatibility: treat raw string as value.
            return EvalResult(success: true, value: envelope, error: nil)
        }
        if let ok = json["ok"] as? Bool, ok {
            return EvalResult(success: true, value: (json["v"] as? String) ?? "", error: nil)
        }
        return EvalResult(success: false, value: nil, error: (json["err"] as? String) ?? "unknown JS error")
    }

    /// Open a new tab. If the browser has no window, creates one first
    /// so new_tab works from a fresh launch state (was failing with
    /// 'Can't get window 1' when Safari was running but windowless).
    func newTab(browser: Browser, url: String?) -> Bool {
        let script: String
        switch browser {
        case .safari:
            let nav = url.map { "\n    set URL of current tab of front window to \"\(escape($0))\"" } ?? ""
            script = """
            tell application "Safari"
                activate
                if (count of windows) = 0 then
                    make new document
                else
                    tell front window to set current tab to (make new tab)
                end if\(nav)
                return "ok"
            end tell
            """
        case .chrome:
            let nav = url.map { "\n    set URL of active tab of front window to \"\(escape($0))\"" } ?? ""
            script = """
            tell application "Google Chrome"
                activate
                if (count of windows) = 0 then
                    make new window
                else
                    tell front window to make new tab
                end if\(nav)
                return "ok"
            end tell
            """
        }
        return runOsascript(script: script) != nil
    }

    /// Close a tab by window/tab index, or the current tab when indices are nil.
    func closeTab(browser: Browser, windowIndex: Int = 1, tabIndex: Int? = nil) -> Bool {
        let tabRef: String
        switch browser {
        case .safari:
            tabRef = tabIndex.map { "tab \($0) of window \(windowIndex)" } ?? "current tab of window \(windowIndex)"
        case .chrome:
            tabRef = tabIndex.map { "tab \($0) of window \(windowIndex)" } ?? "active tab of window \(windowIndex)"
        }
        let script = """
        tell application "\(browser.rawValue)"
            close \(tabRef)
            return "ok"
        end tell
        """
        return runOsascript(script: script) != nil
    }

    // MARK: - Helpers

    /// Last AppleScript error from a failed `runOsascript` call on this
    /// actor. Cleared whenever a subsequent call succeeds so stale errors
    /// don't leak into later tool invocations.
    private(set) var lastError: String?

    /// Returns stdout on success. On non-zero exit, returns nil and
    /// populates `lastError` with the captured stderr so the caller can
    /// surface the AppleScript error instead of silently failing.
    private func runOsascript(script: String) -> String? {
        let result = OsascriptRunner.run(script)
        if result.ok {
            lastError = nil
            return result.stdout
        }
        lastError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return nil
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// JSON-encode a Swift string into a JS string literal. Used so the
    /// user's raw JS code can be safely embedded inside a larger JS
    /// wrapper as a string argument to `(0, eval)()`. JSONEncoder handles
    /// every edge case (quotes, newlines, unicode) that naive string
    /// escaping misses.
    private func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s),
              let literal = String(data: data, encoding: .utf8) else {
            // Fallback — JSONEncoder never fails on a plain String, but
            // handle it defensively.
            return "\"\(escape(s))\""
        }
        return literal
    }

    private func parseTabs(browser: String, raw: String) -> [TabInfo] {
        var out: [TabInfo] = []
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5,
                  let w = Int(parts[0]),
                  let t = Int(parts[1]) else { continue }
            out.append(
                TabInfo(
                    browser: browser,
                    windowIndex: w,
                    tabIndex: t,
                    title: parts[2],
                    url: parts[3],
                    active: parts[4].lowercased() == "true"
                )
            )
        }
        return out
    }
}
