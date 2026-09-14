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
        /// Structured classification of `error`, when it came from a
        /// failed osascript invocation / AppleScript `on error`. Nil for
        /// success and for JS-level exceptions that aren't
        /// permission/automation related.
        let errorCode: String?
        let hint: String?
        let pane: String?
    }

    /// Result of a tab-listing attempt. Distinguishes "the script failed"
    /// (`classification != nil`, `tabs` empty) from "the browser genuinely
    /// has zero tabs right now" (`classification == nil`, `tabs` empty).
    struct TabsFetchResult: Sendable {
        let tabs: [TabInfo]
        let classification: BrowserErrorClassifier.Classification?
    }

    /// Result of an active-tab lookup. Same success/failure distinction
    /// as `TabsFetchResult`: `tab == nil && classification == nil` means
    /// the script ran fine but there is genuinely no active tab (e.g. no
    /// window open).
    struct ActiveTabFetchResult: Sendable {
        let tab: TabInfo?
        let classification: BrowserErrorClassifier.Classification?
    }

    // Field/record separators for AppleScript output. Tab (`\t`) and
    // linefeed were used previously, but page titles routinely contain
    // literal tab characters and newlines, which silently corrupted
    // parsing (fields shifted, tabs dropped). ASCII 30 (record separator)
    // and 31 (unit separator) are control characters that never appear in
    // real page titles/URLs.
    private static let recordSeparator = String(UnicodeScalar(30))
    private static let unitSeparator = String(UnicodeScalar(31))

    // MARK: - Tabs

    /// Fetch all tabs. Returns `.classification` (never both tabs and a
    /// classification) when the underlying osascript call failed — e.g.
    /// Apple Events permission not granted (-1743). Previously this
    /// swallowed such failures into a bare `[]`, which `browser_list_tabs`
    /// then reported as a misleading "0 tabs, maybe multi-process" success.
    func listTabs(browser: Browser) -> TabsFetchResult {
        let us = Self.unitSeparator
        let rs = Self.recordSeparator
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
                        set output to output & (w as string) & "\(us)" & (t as string) & "\(us)" & (name of theTab) & "\(us)" & (URL of theTab) & "\(us)" & ((w = 1 and t = activeTabIndex) as string) & "\(rs)"
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
                        set output to output & (w as string) & "\(us)" & (t as string) & "\(us)" & (title of theTab) & "\(us)" & (URL of theTab) & "\(us)" & ((w = 1 and t = activeIndex) as string) & "\(rs)"
                    end repeat
                end repeat
                return output
            end tell
            """
        }

        guard let raw = runOsascript(script: script) else {
            return TabsFetchResult(tabs: [], classification: classifiedError(browser: browser))
        }
        return TabsFetchResult(tabs: parseTabs(browser: browser.rawValue, raw: raw), classification: nil)
    }

    /// Fetch the active tab by querying `active tab of front window`
    /// (Chrome) / `current tab of front window` (Safari) directly, rather
    /// than filtering `listTabs()`'s output. BUG-FIX: filtering the full
    /// tab list inherited every failure mode of `listTabs` (permission
    /// errors -> [] -> "no active tab") and could also mis-rank ordering
    /// across windows. Querying the front window's active tab directly is
    /// both cheaper and correct regardless of window ordering.
    func activeTab(browser: Browser) -> ActiveTabFetchResult {
        let us = Self.unitSeparator
        let script: String
        switch browser {
        case .safari:
            script = """
            tell application "Safari"
                set win to front window
                set idx to index of current tab of win
                set theTab to current tab of win
                return "1\(us)" & (idx as string) & "\(us)" & (name of theTab) & "\(us)" & (URL of theTab)
            end tell
            """
        case .chrome:
            script = """
            tell application "Google Chrome"
                set win to front window
                set idx to active tab index of win
                set theTab to active tab of win
                return "1\(us)" & (idx as string) & "\(us)" & (title of theTab) & "\(us)" & (URL of theTab)
            end tell
            """
        }

        guard let raw = runOsascript(script: script) else {
            return ActiveTabFetchResult(tab: nil, classification: classifiedError(browser: browser))
        }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: us)
        guard parts.count >= 4, let w = Int(parts[0]), let t = Int(parts[1]) else {
            return ActiveTabFetchResult(
                tab: nil,
                classification: BrowserErrorClassifier.Classification(
                    errorCode: "failed",
                    error: "Unexpected response from \(browser.rawValue): \(raw)",
                    hint: nil,
                    pane: nil
                )
            )
        }
        let tab = TabInfo(
            browser: browser.rawValue,
            windowIndex: w,
            tabIndex: t,
            title: parts[2],
            url: parts[3],
            active: true
        )
        return ActiveTabFetchResult(tab: tab, classification: nil)
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
    /// browser's Develop menu. Any osascript/AppleScript-level failure
    /// (Automation permission missing, that developer setting disabled,
    /// browser not running, timeout) is run through
    /// `BrowserErrorClassifier` so the caller gets a structured
    /// error_code/hint/pane instead of a generic message.
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
            // Real stderr (e.g. -1743 Automation denial) lives in
            // `lastError` — previously this branch discarded it in favor
            // of a generic "osascript invocation failed" string, which is
            // exactly the silent-swallow bug being fixed here.
            return evalFailure(lastError ?? "osascript invocation failed", browser: browser)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ERR\t") {
            // AppleScript's own `on error errMsg` catches OS-level errors
            // (Automation denial, "isn't running", timeouts) as well as
            // browser-side policy errors (JS from Apple Events disabled)
            // — classify uniformly.
            return evalFailure(String(trimmed.dropFirst(4)), browser: browser)
        }
        guard trimmed.hasPrefix("OK\t") else {
            return evalFailure("Unexpected response: \(trimmed)", browser: browser)
        }
        // The wrapper ALWAYS returns a JSON envelope — parse it.
        let envelope = String(trimmed.dropFirst(3))
        guard let data = envelope.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Old-format compatibility: treat raw string as value.
            return EvalResult(success: true, value: envelope, error: nil, errorCode: nil, hint: nil, pane: nil)
        }
        if let ok = json["ok"] as? Bool, ok {
            return EvalResult(success: true, value: (json["v"] as? String) ?? "", error: nil, errorCode: nil, hint: nil, pane: nil)
        }
        // Genuine JS-level exception — not an Automation/policy failure,
        // so no classification (errorCode nil), just the raw JS message.
        return EvalResult(
            success: false, value: nil,
            error: (json["err"] as? String) ?? "unknown JS error",
            errorCode: nil, hint: nil, pane: nil
        )
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

    /// Classify `lastError` (if any) for the given browser. Exposed so
    /// callers that drive `navigate`/`newTab`/`closeTab` (which return a
    /// plain `Bool`) can turn a failure into a structured error_code/hint
    /// without duplicating the classification logic.
    func classifiedError(browser: Browser) -> BrowserErrorClassifier.Classification? {
        guard let err = lastError else { return nil }
        return BrowserErrorClassifier.classify(stderr: err, browser: browser)
    }

    private func evalFailure(_ message: String, browser: Browser) -> EvalResult {
        let c = BrowserErrorClassifier.classify(stderr: message, browser: browser)
        return EvalResult(success: false, value: nil, error: c.error, errorCode: c.errorCode, hint: c.hint, pane: c.pane)
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

    /// Parses AppleScript tab output. Records are separated by ASCII 30
    /// (record separator), fields within a record by ASCII 31 (unit
    /// separator) — control characters that never occur in real page
    /// titles/URLs, unlike the previous tab/linefeed delimiters which a
    /// title containing a literal tab character or newline would corrupt
    /// (fields shift, or a title gets split into two bogus records).
    /// Internal (not private) so it is directly unit-testable.
    func parseTabs(browser: String, raw: String) -> [TabInfo] {
        var out: [TabInfo] = []
        for record in raw.components(separatedBy: Self.recordSeparator) {
            guard !record.isEmpty else { continue }
            let parts = record.components(separatedBy: Self.unitSeparator)
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
