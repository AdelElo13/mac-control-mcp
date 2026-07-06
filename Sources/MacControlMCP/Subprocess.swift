import Foundation

/// Shared, deadlock-safe subprocess runner used by `OsascriptRunner` and
/// `ProcessRunner`.
///
/// Two properties the naive `try run(); waitUntilExit(); readToEnd()` pattern
/// lacked and this guarantees:
///
///  1. **Concurrent drain.** stdout and stderr are read on background queues
///     *while* the child runs. The old code read only after `waitUntilExit`,
///     so a child writing more than the ~64 KB pipe buffer blocked on write
///     forever (its reader never ran) — an unkillable hang for `osascript`,
///     which had no timeout at all.
///  2. **Bounded wait.** A child that never exits is escalated SIGTERM →
///     (2 s grace) → SIGKILL, so one wedged subprocess can't pin a tool call
///     — and, because these run synchronously inside actors, the actor —
///     indefinitely.
enum Subprocess {
    struct Result: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let timedOut: Bool
        /// True only on a clean zero exit that did not time out.
        var ok: Bool { exitCode == 0 && !timedOut }
    }

    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes concurrently so the child never blocks on a full
        // pipe buffer. Results are guarded by `lock` because the two reads
        // and the caller touch the buffers from different threads.
        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        let ioGroup = DispatchGroup()
        let ioQueue = DispatchQueue(label: "mac-control-mcp.subprocess.io", attributes: .concurrent)

        func drain(_ handle: FileHandle, into store: @escaping (Data) -> Void) {
            ioGroup.enter()
            ioQueue.async {
                let data = handle.readDataToEndOfFile()
                lock.lock(); store(data); lock.unlock()
                ioGroup.leave()
            }
        }
        drain(outPipe.fileHandleForReading) { outData = $0 }
        drain(errPipe.fileHandleForReading) { errData = $0 }

        // Signal on exit rather than polling; lets us wait with a deadline.
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
        } catch {
            // Nothing was written to the pipes; cancel the drains.
            outPipe.fileHandleForReading.closeFile()
            errPipe.fileHandleForReading.closeFile()
            return Result(
                stdout: "",
                stderr: "Failed to launch \(executable): \(error)",
                exitCode: -1,
                timedOut: false
            )
        }

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate() // SIGTERM
            if done.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                done.wait() // reap
            }
        }

        // Both pipe writers are closed now (process exited), so the drains
        // hit EOF and finish; wait for the captured bytes.
        ioGroup.wait()

        lock.lock()
        let out = outData
        let err = errData
        lock.unlock()

        return Result(
            stdout: String(data: out, encoding: .utf8) ?? "",
            stderr: String(data: err, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus,
            timedOut: timedOut
        )
    }
}
