import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif

// MCPServer is an actor so its mutable `readBuffer` and in-flight counter
// are safely isolated.
//
// v0.8.3 request model (see ServerLifecycle.swift for the measured v0.8.2
// failures this replaces):
//   - stdin is read on a dedicated thread (StdinPump) and delivered in order
//     through an AsyncStream; the blocking read never occupies the actor.
//   - every complete request is handled in its own Task, so a slow tool
//     (unanswered TCC prompt, hung AppleScript) no longer blocks reading
//     stdin or answering other requests. JSON-RPC responses carry their id,
//     so out-of-order replies are valid.
//   - each tools/call is bounded by ToolTimeouts.
//   - stdin EOF → wait up to `shutdownGrace` for in-flight requests, exit.
actor MCPServer {
    static let shutdownGrace: TimeInterval = 2

    private let toolRegistry: ToolRegistry
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let errorOutput = FileHandle.standardError
    private var readBuffer = Data()
    private var inFlight = 0

    init(toolRegistry: ToolRegistry) {
        self.toolRegistry = toolRegistry
    }

    func run(chunks: AsyncStream<Data>) async {
        for await chunk in chunks {
            readBuffer.append(chunk)
            drainReadBuffer()
        }

        drainReadBuffer()
        if !readBuffer.isEmpty {
            write(response: parseErrorResponse("Unexpected EOF while reading MCP frame."))
            log("EOF reached with \(readBuffer.count) unparsed bytes in stdin buffer.")
            readBuffer.removeAll(keepingCapacity: false)
        }
        await waitForInFlightRequests(grace: Self.shutdownGrace)
    }

    private func drainReadBuffer() {
        while true {
            switch StdioMessageFramer.popMessage(from: &readBuffer) {
            case .message(let message):
                inFlight += 1
                Task {
                    await self.handleRawMessage(message)
                    self.requestFinished()
                }
            case .malformed(let reason):
                log("Discarded malformed MCP frame header: \(reason)")
                write(response: parseErrorResponse("Malformed MCP frame header: \(reason)"))
            case .needMoreData:
                return
            }
        }
    }

    private func requestFinished() {
        inFlight -= 1
    }

    private func waitForInFlightRequests(grace: TimeInterval) async {
        let deadline = Date().addingTimeInterval(grace)
        while inFlight > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if inFlight > 0 {
            log("stdin closed; exiting with \(inFlight) request(s) still running.")
        }
    }

    private func handleRawMessage(_ data: Data) async {
        do {
            let request = try decoder.decode(JSONRPCRequest.self, from: data)
            guard let response = await dispatch(request: request) else { return }
            write(response: response)
        } catch {
            write(response: parseErrorResponse("Failed to parse JSON-RPC request."))
            log("Request decode failure: \(error.localizedDescription)")
        }
    }

    private func dispatch(request: JSONRPCRequest) async -> JSONRPCResponse? {
        if request.id == nil && request.method != "notifications/initialized" {
            return nil
        }

        guard request.jsonrpc == "2.0" else {
            return JSONRPCResponse.failure(
                id: request.id,
                code: JSONRPCErrorCode.invalidRequest.rawValue,
                message: "Only JSON-RPC 2.0 is supported."
            )
        }

        switch request.method {
        case "initialize":
            let permission = await toolRegistry.accessibility.checkPermission()
            let result: JSONValue = .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([
                    "tools": .object([:])
                ]),
                "serverInfo": .object([
                    "name": .string("mac-control-mcp"),
                    "version": .string("0.8.2")
                ]),
                "accessibilityPermission": .bool(permission)
            ])
            return JSONRPCResponse.success(id: request.id, result: result)

        case "tools/list":
            let tools = toolRegistry.toolDefinitions
            let result: JSONValue = .object([
                "tools": encodeAsJSONValue(tools)
            ])
            return JSONRPCResponse.success(id: request.id, result: result)

        case "tools/call":
            guard let params = request.params?.objectValue else {
                return JSONRPCResponse.failure(
                    id: request.id,
                    code: JSONRPCErrorCode.invalidParams.rawValue,
                    message: "tools/call requires params."
                )
            }

            guard let name = params["name"]?.stringValue, !name.isEmpty else {
                return JSONRPCResponse.failure(
                    id: request.id,
                    code: JSONRPCErrorCode.invalidParams.rawValue,
                    message: "tools/call requires a non-empty name."
                )
            }

            let arguments = params["arguments"]?.objectValue ?? [:]
            let limit = ToolTimeouts.limit(for: name, arguments: arguments)
            let registry = toolRegistry
            let finished = await AsyncTimeout.run(timeout: limit) {
                await registry.callTool(name: name, arguments: arguments)
            }
            if finished == nil {
                log("tools/call \(name) exceeded \(Int(limit))s; answered with a timeout error.")
            }
            let toolResult = (finished ?? ToolTimeouts.timeoutResult(name: name, limit: limit))
                .withPermissionContext()
            return JSONRPCResponse.success(id: request.id, result: toolResult.asMCPResult())

        case "notifications/initialized":
            return nil

        case "ping":
            return JSONRPCResponse.success(id: request.id, result: .object([:]))

        default:
            return JSONRPCResponse.failure(
                id: request.id,
                code: JSONRPCErrorCode.methodNotFound.rawValue,
                message: "Method not found: \(request.method)"
            )
        }
    }

    // Writes are actor-isolated, so concurrent request Tasks never interleave
    // frames. A blocking Darwin.write can still head-of-line stall other
    // responses if the client stops draining stdout; an MCP client that does
    // that has stalled itself, so this is acceptable.
    private func write(response: JSONRPCResponse) {
        do {
            let message = try StdioMessageFramer.frame(response, encoder: encoder)
            // Bypass FileHandle and write via the raw POSIX descriptor so the
            // response arrives immediately even when the client keeps stdin
            // open between requests.
            try message.withUnsafeBytes { buffer -> Void in
                guard let base = buffer.baseAddress else {
                    throw NSError(domain: "mac-control-mcp", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "empty buffer"])
                }
                var remaining = buffer.count
                var ptr = base
                while remaining > 0 {
                    let written = Darwin.write(1, ptr, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        if errno == EPIPE {
                            // The client closed its read end: nobody can
                            // receive responses any more.
                            log("stdout closed by client (EPIPE); exiting.")
                            exit(EXIT_SUCCESS)
                        }
                        throw NSError(domain: "mac-control-mcp", code: Int(errno),
                                      userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
                    }
                    if written == 0 {
                        throw NSError(domain: "mac-control-mcp", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "write(2) returned 0; refusing to loop"])
                    }
                    remaining -= written
                    ptr = ptr.advanced(by: Int(written))
                }
            }
            fflush(stdout)
        } catch {
            log("Failed to write response: \(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        try? errorOutput.write(contentsOf: data)
    }

    private func parseErrorResponse(_ message: String) -> JSONRPCResponse {
        JSONRPCResponse.failure(
            id: nil,
            code: JSONRPCErrorCode.parseError.rawValue,
            message: message
        )
    }
}

private func handleScreenRecordingCommand(arguments: [String]) -> Int32? {
    #if canImport(CoreGraphics)
    if arguments.contains("--check-screen-recording") {
        let granted = CGPreflightScreenCaptureAccess()
        print(granted ? "granted" : "denied")
        return granted ? EXIT_SUCCESS : EXIT_FAILURE
    }

    if arguments.contains("--request-screen-recording") {
        if CGPreflightScreenCaptureAccess() {
            print("granted")
            return EXIT_SUCCESS
        }

        _ = CGRequestScreenCaptureAccess()
        let granted = CGPreflightScreenCaptureAccess()
        if !granted {
            #if canImport(AppKit)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                _ = NSWorkspace.shared.open(url)
            }
            #endif
            print("denied")
            return EXIT_FAILURE
        }

        print("granted")
        return EXIT_SUCCESS
    }
    #endif

    return nil
}

if let exitCode = handleScreenRecordingCommand(arguments: CommandLine.arguments) {
    exit(exitCode)
}

// Ignore SIGPIPE: when the client closes stdout, a pending write returns
// EPIPE (handled in `write`) instead of killing the process mid-response.
#if canImport(Darwin)
signal(SIGPIPE, SIG_IGN)

// Claude Desktop restarts the MCP extension by sending SIGTERM to the old
// child. Flush stdout and exit immediately so no instance lingers.
signal(SIGTERM) { _ in
    _ = fflush(stdout)
    _exit(0)
}
signal(SIGINT) { _ in
    _ = fflush(stdout)
    _exit(0)
}
#endif

// v0.8.3: exit when the launching client dies, even if stdin stays open.
let parentWatchdog = ParentWatchdog.start(parentPID: getppid())

let stdinChunks = StdinPump.start()

Task {
    let accessibility = AccessibilityController()
    let toolRegistry = ToolRegistry(accessibility: accessibility)
    let server = MCPServer(toolRegistry: toolRegistry)
    await server.run(chunks: stdinChunks)
    exit(EXIT_SUCCESS)
}

RunLoop.main.run()
