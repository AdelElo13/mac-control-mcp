import Foundation

/// System-power actions: sleep, lock, restart, shutdown, logout.
///
/// Three of the five are "destructive" in the sense that they evict user
/// work — the caller MUST pass `confirm:true` for restart/shutdown/logout
/// or the tool refuses. Sleep and lock are cheap and reversible so they
/// don't need the extra gate.
///
/// We use osascript for restart/shutdown/logout because those go through
/// the `loginwindow` which already shows the "save changes?" prompts for
/// any app with unsaved state — behaviour users expect. `pmset sleepnow`
/// handles sleep; `pmset displaysleepnow` handles lock (display sleep +
/// FileVault lock screen).
actor PowerController {

    public struct Result: Codable, Sendable {
        public let ok: Bool
        public let action: String
        public let method: String
        public let confirmed: Bool?
        public let error: String?
    }

    /// Put the Mac to sleep immediately. Reversible (just move the mouse).
    func sleep() -> Result {
        let r = ProcessRunner.run("/usr/bin/pmset", ["sleepnow"], timeout: 3)
        return Result(
            ok: r.ok, action: "sleep", method: "pmset_sleepnow",
            confirmed: nil,
            error: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Lock the screen immediately (FileVault lock).  Uses pmset
    /// `displaysleepnow` which triggers the lock if "require password
    /// after sleep" is enabled in Security preferences (default on).
    func lockScreen() -> Result {
        let r = ProcessRunner.run("/usr/bin/pmset", ["displaysleepnow"], timeout: 3)
        return Result(
            ok: r.ok, action: "lock_screen", method: "pmset_displaysleepnow",
            confirmed: nil,
            error: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Restart the Mac. Requires `confirm=true`. macOS still shows the
    /// "Are you sure?" dialog from loginwindow for any unsaved work.
    func restart(confirm: Bool) -> Result {
        guard confirm else {
            return Result(
                ok: false, action: "restart", method: "osascript",
                confirmed: false,
                error: "restart requires confirm:true — this will close all apps and the user may lose unsaved work"
            )
        }
        let r = OsascriptRunner.run(#"tell application "System Events" to restart"#)
        return Result(
            ok: r.ok, action: "restart", method: "osascript",
            confirmed: true,
            error: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Shut down the Mac. Requires `confirm=true`. Same save-prompt behaviour
    /// as `restart`.
    func shutdown(confirm: Bool) -> Result {
        guard confirm else {
            return Result(
                ok: false, action: "shutdown", method: "osascript",
                confirmed: false,
                error: "shutdown requires confirm:true — this will close all apps and the user may lose unsaved work"
            )
        }
        let r = OsascriptRunner.run(#"tell application "System Events" to shut down"#)
        return Result(
            ok: r.ok, action: "shutdown", method: "osascript",
            confirmed: true,
            error: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Log out the current user. Requires `confirm=true`. Saves loginwindow
    /// prompts for any apps that ask.
    func logout(confirm: Bool) -> Result {
        guard confirm else {
            return Result(
                ok: false, action: "logout", method: "osascript",
                confirmed: false,
                error: "logout requires confirm:true — this will end the current session"
            )
        }
        let r = OsascriptRunner.run(#"tell application "System Events" to log out"#)
        return Result(
            ok: r.ok, action: "logout", method: "osascript",
            confirmed: true,
            error: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
