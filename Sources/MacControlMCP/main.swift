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

// MCPServer is an actor so its mutable `readBuffer` is safely isolated,
// which lets us hold the global server reference without resorting to
// `nonisolated(unsafe)`. The stdio loop still runs in a single Task; the
// actor just gives the compiler a correct concurrency story.
actor MCPServer {
    private let toolRegistry: ToolRegistry
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let input = FileHandle.standardInput
    private let output = FileHandle.standardOutput
    private let errorOutput = FileHandle.standardError
    private var readBuffer = Data()

    init(toolRegistry: ToolRegistry) {
        self.toolRegistry = toolRegistry
    }

    func run() async {
        while true {
            let handledBufferedMessage = await drainReadBuffer()
            if handledBufferedMessage {
                continue
            }

            // `availableData` returns whatever bytes are ready right now
            // (one read(2) syscall). Previously `readData(ofLength: 4096)`
            // blocked the task until either 4096 bytes were buffered OR
            // stdin closed — which froze interactive MCP clients who send
            // small JSON-RPC frames (~100 bytes) and expect a reply before
            // sending the next request. Functional test against a Python
            // MCP driver pinpointed this: the server processed the frame
            // in memory but readData blocked while waiting for 3.5 KB
            // more bytes that the client was never going to send.
            let chunk = input.availableData
            if chunk.isEmpty {
                _ = await drainReadBuffer()
                if !readBuffer.isEmpty {
                    write(response: parseErrorResponse("Unexpected EOF while reading MCP frame."))
                    log("EOF reached with \(readBuffer.count) unparsed bytes in stdin buffer.")
                    readBuffer.removeAll(keepingCapacity: false)
                }
                return
            }

            readBuffer.append(chunk)
        }
    }

    private func drainReadBuffer() async -> Bool {
        var handled = false

        while true {
            switch StdioMessageFramer.popMessage(from: &readBuffer) {
            case .message(let message):
                handled = true
                await handleRawMessage(message)
            case .malformed(let reason):
                handled = true
                log("Discarded malformed MCP frame header: \(reason)")
                write(response: parseErrorResponse("Malformed MCP frame header: \(reason)"))
            case .needMoreData:
                return handled
            }
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
                    "version": .string("0.4.0")
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
            let toolResult = await toolRegistry.callTool(name: name, arguments: arguments)
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

    // ARCHITECTURAL NOTE (Codex v5/v6 MEDIUM, deferred):
    // `write` performs a blocking Darwin.write inside actor-isolated code,
    // which means a slow or stalled stdout consumer head-of-line stalls
    // the protocol handler — we cannot process the next incoming request
    // until the previous response has been fully flushed to the pipe.
    //
    // This is acceptable for the MCP stdio use case: an MCP client drives
    // the server over its own stdio, drains promptly, and tears down when
    // done. A misbehaving client freezing us simply stalls the client it
    // owns. A more concurrency-correct design would offload writes to a
    // dedicated writer Task with a bounded queue, but that's added
    // complexity for a scenario that doesn't materialise in practice.
    private func write(response: JSONRPCResponse) {
        do {
            let message = try StdioMessageFramer.frame(response, encoder: encoder)
            // Bypass FileHandle and write via the raw POSIX descriptor so the
            // response arrives immediately even when the client keeps stdin
            // open between requests. Functional testing against a Python MCP
            // driver showed FileHandle-backed writes appearing to the other
            // side only after stdin close or EOF — a subtle buffering gap
            // that breaks live MCP clients which stream requests and expect
            // streamed responses. Direct write(2) + fflush(nil) makes the
            // write atomic and visible at once.
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
                        // Retry transparently on EINTR. Any other errno is a
                        // real write failure and we surface it.
                        if errno == EINTR { continue }
                        throw NSError(domain: "mac-control-mcp", code: Int(errno),
                                      userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
                    }
                    if written == 0 {
                        // POSIX write(2) returning 0 with positive `remaining`
                        // is not supposed to happen on a pipe, but defend
                        // against it explicitly so we never spin here.
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

// Ignore SIGPIPE. This is an MCP stdio server — when the client closes
// its end of stdout, any pending Darwin.write call would otherwise take
// down the process with SIGPIPE before we can handle EPIPE in Swift
// and exit cleanly. Seen on CI: one stdio test closed its subprocess
// pipe mid-write, the binary died with signal 13, and `swift test`
// flagged the whole run as failed even though every test assertion
// had actually passed. Ignoring the signal converts the write failure
// into a plain EPIPE return, which our existing write loop handles.
#if canImport(Darwin)
signal(SIGPIPE, SIG_IGN)
#endif

Task {
    let accessibility = AccessibilityController()
    let toolRegistry = ToolRegistry(accessibility: accessibility)
    let server = MCPServer(toolRegistry: toolRegistry)
    await server.run()
    exit(EXIT_SUCCESS)
}

RunLoop.main.run()
