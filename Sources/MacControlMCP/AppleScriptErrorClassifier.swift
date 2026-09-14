import Foundation

/// Classifies a failed osascript invocation's stderr into a structured
/// error code for AppleScript-driven tools that talk to a single named
/// app (Reminders, Calendar's write path, etc.) — the app-agnostic
/// sibling of `BrowserErrorClassifier`.
///
/// v0.9 review fix (A-7 follow-up): `reminders_list`/`reminders_create`
/// initially pre-blocked on the EventKit `kTCCServiceReminders`
/// authorization status before ever running the AppleScript. That's the
/// wrong gate — sending Apple Events to Reminders.app is governed by the
/// **Automation** TCC bucket, not the EventKit Reminders one. A user with
/// Automation granted but EventKit reminders still `not_determined` (or
/// even `denied` — EventKit and Automation are independently toggled)
/// would get blocked by the pre-check even though the AppleScript call
/// itself would have worked. The fix: never pre-block: run the script,
/// and classify its actual failure the same way `BrowserErrorClassifier`
/// does for browser AppleScript calls.
enum AppleScriptErrorClassifier {
    struct Classification: Sendable, Equatable {
        /// One of: "permission_missing", "not_running", "timeout", "failed".
        let errorCode: String
        /// Human-readable message — the original stderr/AppleScript error text.
        let error: String
        /// What the caller should do to resolve it, when known.
        let hint: String?
        /// A valid `open_permission_pane` pane name, when the fix is a
        /// System Settings toggle.
        let pane: String?
    }

    static func classify(stderr: String, appName: String) -> Classification {
        let lower = stderr.lowercased()

        // -1743 — "Not authorized to send Apple events to <App>." The
        // Automation permission for the MCP host (Claude Desktop, etc.)
        // has not been granted for this app.
        if lower.contains("-1743") || (lower.contains("not authorized") && lower.contains("apple event")) {
            return Classification(
                errorCode: "permission_missing",
                error: stderr,
                hint: "Grant System Settings → Privacy & Security → Automation → allow the MCP host app "
                    + "(e.g. Claude Desktop) to control \(appName).",
                pane: "automation"
            )
        }

        // -600 — the target application isn't running.
        if lower.contains("-600") || lower.contains("isn't running") || lower.contains("is not running") {
            return Classification(
                errorCode: "not_running",
                error: stderr,
                hint: "\(appName) isn't running — launch it first.",
                pane: nil
            )
        }

        // -1712 — the Apple Event timed out (app busy, modal dialog, etc.).
        // Also covers OsascriptRunner's own subprocess-level timeout message.
        if lower.contains("-1712") || lower.contains("timed out") || lower.contains("timeout") {
            return Classification(
                errorCode: "timeout",
                error: stderr,
                hint: "osascript timed out talking to \(appName) — it may be busy, "
                    + "showing a dialog, or unresponsive.",
                pane: nil
            )
        }

        return Classification(errorCode: "failed", error: stderr, hint: nil, pane: nil)
    }
}
