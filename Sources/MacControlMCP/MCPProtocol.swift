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

/// Stdio message framing per the MCP transport spec:
/// each JSON-RPC message is emitted as a single line terminated by `\n`
/// (newline-delimited JSON — NDJSON). Incoming messages follow the same
/// convention.
///
/// A previous version of this framer produced + consumed LSP-style
/// `Content-Length:` headers, which Claude Desktop (and most MCP
/// clients) reject outright — `SyntaxError: Unexpected token 'C',
/// "Content-Length: 93" is not valid JSON` on every initialize call.
/// See the 0.2.1 release notes for details.
///
/// For maximum tolerance we still ACCEPT Content-Length framing on
/// input (in case an older probe sends it), but we NEVER produce it on
/// output. Outgoing frames are always `<json>\n`.
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

    /// Pop one complete message off the buffer. Tries NDJSON first
    /// (`<json>\n`), falls back to `Content-Length:` framing when the
    /// buffer starts with a header-looking prefix.
    static func popMessage(from buffer: inout Data) -> ParseResult {
        // Skip any leading whitespace / blank lines between frames.
        while let first = buffer.first, first == UInt8(ascii: "\n") || first == UInt8(ascii: "\r") {
            buffer.removeFirst()
        }
        guard !buffer.isEmpty else { return .needMoreData }

        // Content-Length branch — only when the buffer clearly opens
        // with a header line, not a JSON `{`. Accept this path for
        // backward compatibility with probes written against the old
        // framing.
        if buffer.first == UInt8(ascii: "C") || buffer.first == UInt8(ascii: "c") {
            let prefix = buffer.prefix(16)
            if let prefixText = String(data: prefix, encoding: .utf8),
               prefixText.lowercased().hasPrefix("content-length") {
                return popContentLengthFramed(from: &buffer)
            }
        }

        // NDJSON branch: look for the next newline. Body is everything
        // before it, byte-for-byte.
        guard let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) else {
            return .needMoreData
        }
        let body = buffer.subdata(in: buffer.startIndex..<newlineIndex)
        buffer.removeSubrange(buffer.startIndex...newlineIndex)
        // Tolerate trailing \r that some clients emit as \r\n line endings.
        if let lastByte = body.last, lastByte == UInt8(ascii: "\r") {
            return .message(body.dropLast())
        }
        return .message(body)
    }

    private static func popContentLengthFramed(from buffer: inout Data) -> ParseResult {
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

    /// Encode a message as a single NDJSON line: JSON body followed by
    /// exactly one `\n`. Per MCP transport spec, the body itself must
    /// not contain embedded newlines — JSONEncoder produces minified
    /// output by default, so we just need to make sure no one has flipped
    /// `.prettyPrinted` on.
    static func frame<T: Encodable>(_ message: T, encoder: JSONEncoder) throws -> Data {
        // Defensive: clear pretty-printing if a caller accidentally set it,
        // because that would embed `\n` inside the body and break framing.
        if encoder.outputFormatting.contains(.prettyPrinted) {
            encoder.outputFormatting.remove(.prettyPrinted)
        }
        var body = try encoder.encode(message)
        body.append(UInt8(ascii: "\n"))
        return body
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
