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

    /// Open a url-scheme (`x-apple.systempreferences://…`, `shortcuts://`,
    /// `mailto:`, `obsidian://`, app-specific schemes, …). Equivalent of
    /// `open "url"` but with a structured ok/error envelope.
    func openURL(_ url: String) -> RunResult {
        guard URL(string: url) != nil else {
            return RunResult(ok: false, name: url, stdout: nil,
                             stderr: "invalid URL")
        }
        let r = ProcessRunner.run("/usr/bin/open", [url], timeout: 5)
        return RunResult(
            ok: r.ok, name: url,
            stdout: r.stdout.isEmpty ? nil : r.stdout,
            stderr: r.stderr.isEmpty ? nil : r.stderr
        )
    }
}
