import Foundation

/// Classifies a failed osascript invocation's stderr (or an AppleScript
/// `on error` message caught inside a script) into a structured error
/// code so browser tools can distinguish "the script failed" from "the
/// browser genuinely has zero tabs" — and tell the user exactly what to
/// fix instead of a vague/misleading hint.
///
/// BUG (measured on macOS 26 / Claude Desktop v0.8.2): `browser_list_tabs`
/// returned `tabs: []` + a `multi_process_hint` ("tell application only
/// scripts the primary instance…") while both Safari and Chrome were open
/// with tabs. Root cause: Apple Events (Automation) permission was not
/// granted, osascript failed with -1743, and `runOsascript` swallowed the
/// error into `nil` -> `listTabs` -> `[]`. This classifier is the fix's
/// core: pure, stateless, and unit-testable without ever touching
/// AppleScript or the OS.
enum BrowserErrorClassifier {
    struct Classification: Sendable, Equatable {
        /// One of: "permission_missing", "permission_policy_denied",
        /// "not_running", "timeout", "failed".
        let errorCode: String
        /// Human-readable message — the original stderr/AppleScript error text.
        let error: String
        /// What the caller should do to resolve it, when known.
        let hint: String?
        /// A valid `open_permission_pane` pane name, when the fix is a
        /// System Settings toggle.
        let pane: String?
    }

    static func classify(stderr: String, browser: BrowserController.Browser) -> Classification {
        let lower = stderr.lowercased()

        // -1743 — "Not authorized to send Apple events to <App>." The
        // Automation permission for the MCP host (Claude Desktop, etc.)
        // has not been granted for this browser.
        if lower.contains("-1743") || (lower.contains("not authorized") && lower.contains("apple event")) {
            return Classification(
                errorCode: "permission_missing",
                error: stderr,
                hint: "Grant System Settings → Privacy & Security → Automation → allow the MCP host app "
                    + "(e.g. Claude Desktop) to control \(browser.rawValue).",
                pane: "automation"
            )
        }

        // Browser-side developer setting: "Allow JavaScript from Apple
        // Events" is off. Distinct from -1743 — Automation is granted,
        // but the browser itself refuses the `do JavaScript` / `execute
        // javascript` command. Checked before the generic -600/"isn't
        // running" branch since the wording can otherwise overlap.
        if lower.contains("javascript")
            && (lower.contains("apple event") || lower.contains("applescript"))
            && (lower.contains("turned off") || lower.contains("disabled")
                || lower.contains("not enabled") || lower.contains("is not enabled")
                || lower.contains("not allowed") || lower.contains("must enable")) {
            let hint: String
            switch browser {
            case .chrome:
                hint = "In Chrome: View → Developer → Allow JavaScript from Apple Events."
            case .safari:
                hint = "In Safari: Settings → Advanced → Show features for web developers, "
                    + "then Develop → Allow JavaScript from Apple Events."
            }
            return Classification(errorCode: "permission_policy_denied", error: stderr, hint: hint, pane: nil)
        }

        // v0.10 A7: a missing active tab is not an unclassified script failure.
        if (lower.contains("can't get") || lower.contains("cannot get"))
            && (lower.contains("tab") || lower.contains("window")) {
            return Classification(errorCode: "no_active_tab", error: stderr,
                hint: "Open a window and an active tab in \(browser.rawValue), then retry.", pane: nil)
        }

        // -600 — the target application isn't running.
        if lower.contains("-600") || lower.contains("isn't running") || lower.contains("is not running") {
            return Classification(
                errorCode: "not_running",
                error: stderr,
                hint: "\(browser.rawValue) isn't running — launch it first.",
                pane: nil
            )
        }

        // -1712 — the Apple Event timed out (browser busy, modal dialog, etc.).
        // Also covers OsascriptRunner's own subprocess-level timeout message
        // ("osascript exceeded the 30s timeout and was terminated."), which
        // says "timeout" rather than "timed out" and carries no -1712 code.
        if lower.contains("-1712") || lower.contains("timed out") || lower.contains("timeout") {
            return Classification(
                errorCode: "timeout",
                error: stderr,
                hint: "osascript timed out talking to \(browser.rawValue) — it may be busy, "
                    + "showing a dialog, or unresponsive.",
                pane: nil
            )
        }

        return Classification(errorCode: "failed", error: stderr, hint: nil, pane: nil)
    }
}
