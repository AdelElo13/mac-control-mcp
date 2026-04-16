import Foundation

let accessibility = AccessibilityController()
let toolRegistry = ToolRegistry(accessibility: accessibility)
nonisolated(unsafe) let server = MCPServer(toolRegistry: toolRegistry)

final class MCPServer {
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

            let chunk = input.readData(ofLength: 4096)
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
                    "version": .string("0.2.0")
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

    private func write(response: JSONRPCResponse) {
        do {
            let message = try StdioMessageFramer.frame(response, encoder: encoder)
            try output.write(contentsOf: message)
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

Task {
    await server.run()
    exit(EXIT_SUCCESS)
}

RunLoop.main.run()
