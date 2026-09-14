import Foundation
#if canImport(Darwin)
import Darwin
#endif

// v0.8.3 — server lifecycle and request isolation.
//
// Measured on v0.8.2: `mcp_server_info` found 4 leftover MacControlMCP
// processes after Claude Desktop restarts, and one hanging tool froze every
// other tool. Root cause: requests were handled strictly one at a time inside
// the stdin loop, so a hung call (unanswered TCC prompt, stuck AppleScript)
// stopped the server from reading stdin — it never saw EOF when the client
// went away and never answered anything else.

/// Reads stdin on a dedicated thread and delivers chunks, in order, through an
/// AsyncStream. The blocking read never occupies an actor or a cooperative
/// thread, and EOF (client closed the pipe) finishes the stream.
enum StdinPump {
    static func start(fileDescriptor: Int32 = STDIN_FILENO) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in
                    Darwin.read(fileDescriptor, raw.baseAddress, raw.count)
                }
                if count > 0 {
                    continuation.yield(Data(buffer[0..<count]))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break  // 0 = EOF; <0 = unrecoverable read error
                }
            }
            continuation.finish()
        }
        thread.name = "mac-control-mcp.stdin"
        thread.start()
        return stream
    }
}

/// Exits the server when the process that launched it dies, even if stdin
/// is still held open by something else (e.g. a helper that outlives the
/// client). kqueue NOTE_EXIT via DispatchSource is the primary signal; a
/// periodic liveness poll catches a parent that died before registration.
final class ParentWatchdog: @unchecked Sendable {
    private let processSource: DispatchSourceProcess
    private let pollTimer: DispatchSourceTimer

    /// nil when there is no meaningful parent to watch (pid ≤ 1: already
    /// orphaned or started by launchd).
    static func start(
        parentPID: pid_t,
        pollInterval: TimeInterval = 2,
        isParentAlive: (@Sendable () -> Bool)? = nil,
        onParentExit: @escaping @Sendable () -> Void = ParentWatchdog.exitProcess
    ) -> ParentWatchdog? {
        guard parentPID > 1 else { return nil }
        let alive = isParentAlive ?? { getppid() == parentPID }
        return ParentWatchdog(parentPID: parentPID, pollInterval: pollInterval,
                              isParentAlive: alive, onParentExit: onParentExit)
    }

    private init(
        parentPID: pid_t,
        pollInterval: TimeInterval,
        isParentAlive: @escaping @Sendable () -> Bool,
        onParentExit: @escaping @Sendable () -> Void
    ) {
        let queue = DispatchQueue(label: "mac-control-mcp.parent-watchdog")
        let once = OnceFlag()
        let fire: @Sendable () -> Void = {
            if once.claim() { onParentExit() }
        }
        processSource = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: queue)
        processSource.setEventHandler(handler: fire)
        processSource.resume()

        pollTimer = DispatchSource.makeTimerSource(queue: queue)
        pollTimer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        pollTimer.setEventHandler {
            if !isParentAlive() { fire() }
        }
        pollTimer.resume()
    }

    func cancel() {
        processSource.cancel()
        pollTimer.cancel()
    }

    static let exitProcess: @Sendable () -> Void = {
        FileHandle.standardError.write(Data("[mac-control-mcp] parent process exited; shutting down.\n".utf8))
        exit(EXIT_SUCCESS)
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// true exactly once.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Upper bound for one tools/call. On expiry the client gets a structured
/// `timeout` error; the tool's work may still finish in the background (a
/// blocking framework call cannot be cancelled), but the server keeps serving.
enum ToolTimeouts {
    static let defaultLimit: TimeInterval = 90
    /// Extra time on top of a caller-requested duration (`seconds`,
    /// `timeout_seconds`) so the tool can report its own result first.
    static let slack: TimeInterval = 15
    static let environmentKey = "MAC_CONTROL_MCP_TOOL_TIMEOUT"
    /// Tools whose normal runtime can exceed the default.
    static let perToolLimit: [String: TimeInterval] = [
        "speech_to_text": 180
    ]

    /// v0.9 (`batch` tool, C-1): a batch's own `tools/call` timeout — the
    /// one `main.swift` wraps `callTool(name: "batch", ...)` in — must
    /// cover however long its sequential sub-calls will actually take,
    /// or the outer wrapper fires a generic timeout while the batch
    /// handler keeps running underneath it (per `AsyncTimeout.run`'s
    /// "late result discarded" semantics). Sum each sub-call's own limit
    /// (computed the same way a standalone `tools/call` would) plus the
    /// inter-call `delay_ms` overhead, capped at `batchCap`.
    static let batchCap: TimeInterval = 300

    static func limit(
        for name: String,
        arguments: [String: JSONValue],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        if name == "batch" {
            return batchLimit(arguments: arguments, environment: environment)
        }
        var base = perToolLimit[name] ?? defaultLimit
        if let raw = environment[environmentKey], let value = Double(raw), value > 0 {
            base = value
        }
        let requested = ["seconds", "timeout_seconds"]
            .compactMap { arguments[$0]?.doubleValue }
            .filter { $0.isFinite && $0 > 0 }
            .max()
        guard let requested else { return base }
        return max(base, requested + slack)
    }

    private static func batchLimit(
        arguments: [String: JSONValue],
        environment: [String: String]
    ) -> TimeInterval {
        guard let calls = arguments["calls"]?.arrayValue, !calls.isEmpty else {
            return defaultLimit
        }

        let rawDelay = arguments["delay_ms"]?.doubleValue ?? 0
        let delayMs = rawDelay.isFinite ? min(max(rawDelay, 0), 5000) : 0
        let delayOverhead = (delayMs / 1000) * Double(max(0, calls.count - 1))

        let sum = calls.reduce(TimeInterval(0)) { total, call in
            guard let object = call.objectValue, let subName = object["name"]?.stringValue else {
                return total
            }
            // A nested "batch" entry is rejected outright by the handler
            // before it ever runs — don't recurse into it, just budget the
            // default so a deeply/self-nested payload can't blow the stack.
            guard subName != "batch" else { return total + defaultLimit }
            let subArguments = object["arguments"]?.objectValue ?? [:]
            return total + limit(for: subName, arguments: subArguments, environment: environment)
        }

        return min(batchCap, sum + delayOverhead)
    }

    static func timeoutResult(name: String, limit: TimeInterval) -> ToolCallResult {
        let message = "\(name) did not finish within \(Int(limit))s. It may still complete in the background (e.g. waiting on a permission prompt or a slow AppleScript) — check the resulting state before retrying."
        return ToolCallResult(
            text: message,
            structuredContent: .object([
                "ok": .bool(false),
                "error_code": .string("timeout"),
                "error": .string(message),
                "tool": .string(name),
                "timeout_seconds": .number(limit)
            ]),
            isError: true
        )
    }
}

enum AsyncTimeout {
    /// Runs `operation` in its own task and returns nil if it hasn't finished
    /// within `timeout`. The operation is not cancelled (blocking framework
    /// calls can't be); its late result is discarded.
    static func run<T: Sendable>(
        timeout: TimeInterval,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await PermissionContext.awaitCallback(timeout: timeout) { done in
            Task { done(await operation()) }
        }
    }
}
