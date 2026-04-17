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

    static func run(_ script: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return Result(stdout: "", stderr: "Failed to launch osascript: \(error)", exitCode: -1)
        }

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(stdout: out, stderr: err, exitCode: process.terminationStatus)
    }
}
