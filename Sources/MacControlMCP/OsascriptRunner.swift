import Foundation

/// Shared osascript subprocess runner. Captures stdout AND stderr so
/// AppleScript errors become visible instead of silently returning nil.
/// Uses Process with argv (not shell), so there is no command-injection
/// surface — user-supplied strings go through `-e <script>` as a single
/// argv entry, and AppleScript string literals escape quotes internally.
enum OsascriptRunner {
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        var ok: Bool { exitCode == 0 }
    }

    /// Run an AppleScript via `osascript -e`. Delegates to `Subprocess`,
    /// which drains stdout/stderr concurrently (so a script producing a large
    /// result — e.g. a full DOM/AX dump — cannot deadlock on a full pipe
    /// buffer) and enforces `timeout` so a hung script cannot wedge the tool
    /// call, and with it the calling actor, forever. On timeout the runner
    /// returns a non-zero exit with an explanatory stderr.
    static func run(_ script: String, timeout: TimeInterval = 30) -> Result {
        let r = Subprocess.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: timeout
        )
        let stderr = r.timedOut
            ? "osascript exceeded the \(Int(timeout))s timeout and was terminated."
            : r.stderr
        return Result(stdout: r.stdout, stderr: stderr, exitCode: r.exitCode)
    }
}
