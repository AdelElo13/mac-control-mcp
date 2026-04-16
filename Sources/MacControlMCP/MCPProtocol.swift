import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON payload."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let array) = self else { return nil }
        return array
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .string(let value):
            return Double(value)
        default:
            return nil
        }
    }

    var floatValue: Float? {
        guard let value = doubleValue else { return nil }
        return Float(value)
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            guard value.rounded() == value else { return nil }
            return Int(value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }
}

func encodeAsJSONValue<T: Encodable>(_ value: T) -> JSONValue {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    guard
        let data = try? encoder.encode(value),
        let jsonValue = try? decoder.decode(JSONValue.self, from: data)
    else {
        return .null
    }

    return jsonValue
}

struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String
    let id: JSONValue?
    let method: String
    let params: JSONValue?
}

struct JSONRPCErrorObject: Codable, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?
}

struct JSONRPCResponse: Codable, Sendable {
    let jsonrpc: String
    let id: JSONValue?
    let result: JSONValue?
    let error: JSONRPCErrorObject?

    static func success(id: JSONValue?, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }

    static func failure(id: JSONValue?, code: Int, message: String, data: JSONValue? = nil) -> JSONRPCResponse {
        JSONRPCResponse(
            jsonrpc: "2.0",
            id: id,
            result: nil,
            error: JSONRPCErrorObject(code: code, message: message, data: data)
        )
    }
}

enum JSONRPCErrorCode: Int {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
}

struct MCPToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
}

enum StdioMessageFramer {
    private static let crlfHeaderTerminator = Data("\r\n\r\n".utf8)
    private static let lfHeaderTerminator = Data("\n\n".utf8)

    struct HeaderParseError: Error, CustomStringConvertible {
        let description: String
    }

    enum ParseResult {
        case message(Data)
        case needMoreData
        case malformed(String)
    }

    static func popMessage(from buffer: inout Data) -> ParseResult {
        guard let headerBoundary = headerBoundary(in: buffer) else {
            return .needMoreData
        }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerBoundary.headerEnd)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            buffer.removeSubrange(buffer.startIndex..<headerBoundary.bodyStart)
            return .malformed("Message headers must be UTF-8.")
        }

        switch parseContentLength(headerText) {
        case .failure(let error):
            buffer.removeSubrange(buffer.startIndex..<headerBoundary.bodyStart)
            return .malformed(error.description)
        case .success(let contentLength):
            let bodyStart = headerBoundary.bodyStart
            let bodyEnd = bodyStart + contentLength
            guard buffer.count >= bodyEnd else { return .needMoreData }

            let body = buffer.subdata(in: bodyStart..<bodyEnd)
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            return .message(body)
        }
    }

    static func frame<T: Encodable>(_ message: T, encoder: JSONEncoder) throws -> Data {
        let body = try encoder.encode(message)
        var output = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        output.append(body)
        return output
    }

    private struct HeaderBoundary {
        let headerEnd: Int
        let bodyStart: Int
    }

    private static func headerBoundary(in buffer: Data) -> HeaderBoundary? {
        let crlfRange = buffer.range(of: crlfHeaderTerminator)
        let lfRange = buffer.range(of: lfHeaderTerminator)

        if let crlfRange, let lfRange {
            if crlfRange.lowerBound <= lfRange.lowerBound {
                return HeaderBoundary(headerEnd: crlfRange.lowerBound, bodyStart: crlfRange.upperBound)
            }
            return HeaderBoundary(headerEnd: lfRange.lowerBound, bodyStart: lfRange.upperBound)
        }

        if let crlfRange {
            return HeaderBoundary(headerEnd: crlfRange.lowerBound, bodyStart: crlfRange.upperBound)
        }

        if let lfRange {
            return HeaderBoundary(headerEnd: lfRange.lowerBound, bodyStart: lfRange.upperBound)
        }

        return nil
    }

    private static func parseContentLength(_ headerText: String) -> Result<Int, HeaderParseError> {
        var contentLength: Int?

        for rawLine in headerText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                return .failure(HeaderParseError(description: "Malformed header line: '\(line)'."))
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key == "content-length" else { continue }

            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let length = Int(value), length >= 0 else {
                return .failure(HeaderParseError(description: "Invalid Content-Length header value: '\(value)'."))
            }

            guard contentLength == nil else {
                return .failure(HeaderParseError(description: "Duplicate Content-Length headers are not allowed."))
            }

            contentLength = length
        }

        guard let contentLength else {
            return .failure(HeaderParseError(description: "Missing Content-Length header."))
        }

        return .success(contentLength)
    }
}
