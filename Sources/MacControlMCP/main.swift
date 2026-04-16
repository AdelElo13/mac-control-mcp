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
            while let message = StdioMessageFramer.popMessage(from: &readBuffer) {
                await handleRawMessage(message)
            }

            let chunk = input.readData(ofLength: 4096)
            if chunk.isEmpty {
                while let message = StdioMessageFramer.popMessage(from: &readBuffer) {
                    await handleRawMessage(message)
                }
                return
            }

            readBuffer.append(chunk)
        }
    }

    private func handleRawMessage(_ data: Data) async {
        do {
            let request = try decoder.decode(JSONRPCRequest.self, from: data)
            guard let response = await dispatch(request: request) else { return }
            write(response: response)
        } catch {
            let response = JSONRPCResponse.failure(
                id: nil,
                code: JSONRPCErrorCode.parseError.rawValue,
                message: "Failed to parse JSON-RPC request."
            )
            write(response: response)
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
                    "version": .string("0.1.0")
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
}

// Entry point
Task {
    await server.run()
}

RunLoop.main.run()
