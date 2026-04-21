import Foundation

/// Thin wrapper around `Process` for running CLI tools (`pmset`, `networksetup`,
/// `blueutil`, `shortcuts`, `brightness`, `pgrep`, …) from tool handlers.
///
/// Uses argv directly — **no shell interpolation**, so user-supplied strings
/// become argv entries and can't inject extra commands. Any tool that takes
/// user input should still validate/whitelist the value before passing it.
enum ProcessRunner {
    struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public var ok: Bool { exitCode == 0 }
    }

    /// Run `path arg1 arg2 ...` and capture stdout+stderr. Never throws —
    /// `Result.exitCode == -1` means the binary wasn't found / couldn't launch.
    /// Callers switch on `ok` and report `stderr` as the human-readable reason.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10.0) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return Result(stdout: "", stderr: "Failed to launch \(path): \(error)", exitCode: -1)
        }

        // `waitUntilExit` has no timeout variant, so we attach a watchdog that
        // terminates runaway children. 10s default is generous for CLI tools
        // but short enough that a hanging `pmset` can't wedge a tool call.
        let deadline = Date().addingTimeInterval(timeout)
        let checkQueue = DispatchQueue.global(qos: .utility)
        let watchdog = DispatchWorkItem {
            while process.isRunning {
                if Date() >= deadline {
                    process.terminate()
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        checkQueue.async(execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(stdout: out, stderr: err, exitCode: process.terminationStatus)
    }

    /// Check whether an absolute path exists and is executable. Used by
    /// optional-dependency tools (e.g. blueutil) to degrade gracefully with
    /// an install hint instead of a cryptic "No such file" error.
    static func exists(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// Resolve a binary name through PATH (like `which`). Returns the first
    /// match on the standard Homebrew-aware search path. nil when absent.
    static func which(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",     // Apple silicon brew
            "/usr/local/bin/\(name)",        // Intel brew
            "/usr/bin/\(name)",              // system
            "/bin/\(name)",
            "/usr/sbin/\(name)",
            "/sbin/\(name)"
        ]
        return candidates.first(where: exists)
    }
}
