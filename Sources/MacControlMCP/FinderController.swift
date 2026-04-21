import Foundation

/// Finder-scoped file actions: reveal, QuickLook, trash. These replace the
/// common "show me where file X is" and "let me peek at this without
/// opening its full app" interactions.
///
/// Security posture: reveal + QuickLook are READ-ONLY — they don't write
/// anything to disk, so the output-path allowlist in `PathValidator` would
/// be unnecessarily strict (would reject `/Applications/Safari.app` or
/// `~/Library/...`). We instead verify the path exists and is absolute, and
/// expand `~` and `$HOME`. `trash` IS destructive, so we refuse paths
/// outside the user's home directory to prevent a tool call from
/// auto-trashing system files.
actor FinderController {

    public struct RevealResult: Codable, Sendable {
        public let ok: Bool
        public let path: String
        public let error: String?
    }

    /// `open -R <path>` asks Finder to select the file inside its containing
    /// folder — the exact UX of the "Reveal in Finder" menu item.
    func reveal(path: String) -> RevealResult {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return RevealResult(ok: false, path: path, error: "path does not exist")
        }
        let r = ProcessRunner.run("/usr/bin/open", ["-R", expanded])
        return RevealResult(
            ok: r.ok,
            path: expanded,
            error: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public struct QuickLookResult: Codable, Sendable {
        public let ok: Bool
        public let path: String
        public let method: String
        public let error: String?
    }

    /// Trigger QuickLook preview. `/usr/bin/qlmanage -p <path>` spawns a
    /// preview window that dismisses when the tool call ends, which is NOT
    /// what a user would expect. We run `qlmanage` detached and arm a
    /// watchdog that terminates it after `timeoutSeconds`, so the preview
    /// stays on screen long enough to be useful but never orphans.
    func quickLook(path: String, timeoutSeconds: TimeInterval) -> QuickLookResult {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return QuickLookResult(ok: false, path: path, method: "qlmanage",
                                   error: "path does not exist")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", expanded]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return QuickLookResult(
                ok: false, path: expanded, method: "qlmanage",
                error: "Failed to launch qlmanage: \(error)"
            )
        }
        // Arm the watchdog on a global queue; it fires even if the caller
        // returns early.
        let t = max(0.5, min(timeoutSeconds, 120.0))
        DispatchQueue.global().asyncAfter(deadline: .now() + t) {
            if process.isRunning { process.terminate() }
        }
        return QuickLookResult(
            ok: true, path: expanded, method: "qlmanage", error: nil
        )
    }

    public struct TrashResult: Codable, Sendable {
        public let ok: Bool
        public let path: String
        public let method: String
        public let error: String?
    }

    /// Directories inside `$HOME` that agents should NEVER be able to trash
    /// via a simple path call. Even a "path is under $HOME" check leaves
    /// these exposed (a malicious LLM could ask `trash_file` on
    /// `~/.ssh/id_ed25519`). The denylist is matched AFTER symlink
    /// resolution so `~/safe/link -> ~/.ssh` doesn't sneak through.
    ///
    /// Order matters — more specific before less specific. Matching is
    /// prefix-based so the whole subtree is protected.
    private static let trashDenylist: [String] = [
        ".ssh",
        "Library/Keychains",
        "Library/Application Support/Google/Chrome",
        "Library/Application Support/Firefox",
        "Library/Application Support/com.apple.TCC",
        "Library/Preferences/com.apple.security",
        "Library/Cookies",
        "Library/IdentityServices",
        "Library/Mail",
        "Library/Messages",
        "Library/Calendars",
        ".config/mcp-publisher",
        ".mac-control-mcp",
        ".gnupg",
        ".aws",
        ".kube"
    ]

    /// Move a file to the Trash (reversible). We deliberately DON'T expose
    /// a permanent `rm` — that's the kind of destructive capability that
    /// should stay behind a named shell command the user owns, not an
    /// agent-callable primitive.
    ///
    /// Codex v0.5.0 hardening (P0 #2): previous version checked
    /// `expanded.hasPrefix("$HOME/")` which is bypassable via `..` and
    /// symlinks. Now we:
    ///   1. Expand tilde + environment
    ///   2. `resolvingSymlinksInPath().standardizedFileURL` → canonical path
    ///   3. Re-check prefix AGAINST the resolved path
    ///   4. Check canonical path against the denylist (~/.ssh, Keychains,
    ///      Mail, Messages, browser profiles with saved passwords, …)
    ///   5. Invoke Finder's `delete` which moves to Trash (reversible)
    func trash(path: String) -> TrashResult {
        let expanded = (path as NSString).expandingTildeInPath

        // Canonicalize — resolves symlinks AND normalizes `..`.
        let canonical = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        let home = URL(fileURLWithPath: NSHomeDirectory())
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        // Reconfirm the canonical path sits under home — NOT the raw
        // user-supplied string. This kills the `~/..` escape.
        guard canonical == home || canonical.hasPrefix(home + "/") else {
            return TrashResult(
                ok: false, path: path, method: "finder_tell",
                error: "trash is restricted to paths under \(home) — resolved path '\(canonical)' is outside this root"
            )
        }

        // Denylist check — matched against the tail under $HOME so
        // `~/.ssh/anything` matches `.ssh`.
        let relative = canonical == home ? "" :
            String(canonical.dropFirst(home.count + 1))
        for blocked in Self.trashDenylist {
            if relative == blocked || relative.hasPrefix(blocked + "/") {
                return TrashResult(
                    ok: false, path: path, method: "finder_tell",
                    error: "trash refused: '\(relative)' is under protected directory '\(blocked)'"
                )
            }
        }

        guard FileManager.default.fileExists(atPath: canonical) else {
            return TrashResult(ok: false, path: path, method: "finder_tell",
                               error: "path does not exist")
        }

        // AppleScript's `tell application "Finder" to delete` moves to Trash.
        // It's the only sanctioned way; `mv ~/.Trash/` breaks Finder's
        // "Put Back" feature.
        let escaped = canonical.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Finder" to delete POSIX file "\(escaped)"
        """
        let r = OsascriptRunner.run(script)
        return TrashResult(
            ok: r.ok,
            path: canonical,
            method: "finder_tell",
            error: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
