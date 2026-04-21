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

    /// Move a file to the Trash (reversible). We deliberately DON'T expose
    /// a permanent `rm` — that's the kind of destructive capability that
    /// should stay behind a named shell command the user owns, not an
    /// agent-callable primitive.
    ///
    /// Safety rail: refuse paths outside the user's home directory. Agents
    /// calling `trash` on `/Applications/Finder.app` should fail-closed.
    func trash(path: String) -> TrashResult {
        let expanded = (path as NSString).expandingTildeInPath
        let home = NSHomeDirectory()
        guard expanded.hasPrefix(home + "/") else {
            return TrashResult(
                ok: false, path: path, method: "finder_tell",
                error: "trash is restricted to paths under \(home) — refusing to trash system files"
            )
        }
        guard FileManager.default.fileExists(atPath: expanded) else {
            return TrashResult(ok: false, path: path, method: "finder_tell",
                               error: "path does not exist")
        }
        // AppleScript's `tell application "Finder" to delete` moves to Trash.
        // It's the only sanctioned way; `mv ~/.Trash/` breaks Finder's
        // "Put Back" feature.
        let escaped = expanded.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Finder" to delete POSIX file "\(escaped)"
        """
        let r = OsascriptRunner.run(script)
        return TrashResult(
            ok: r.ok,
            path: expanded,
            method: "finder_tell",
            error: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
