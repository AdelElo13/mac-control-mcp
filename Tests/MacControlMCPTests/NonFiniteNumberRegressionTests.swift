import Testing
import Foundation
@testable import MacControlMCP

/// Regression guard for the System Settings hang found by the real-app
/// suite during v0.9 verification (present since v0.8): a SwiftUI element
/// reported an AX frame with a non-finite coordinate, `JSONEncoder`
/// refused the whole `tools/call` response, and the server logged the
/// failure to stderr without ever answering — the client waited until its
/// own timeout. Two layers now guarantee an answer: non-finite numbers
/// encode as `null`, and an unencodable response degrades to a JSON-RPC
/// `internalError` for the same id instead of silence.
@Suite("Non-finite numbers never silence a response")
struct NonFiniteNumberRegressionTests {

    private func encode(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    @Test("NaN and infinities encode as null instead of throwing", arguments: [
        Double.nan, Double.infinity, -Double.infinity, Double.signalingNaN
    ])
    func nonFiniteEncodesAsNull(value: Double) throws {
        let object = JSONValue.object([
            "position": .object(["x": .number(value), "y": .number(12)]),
            "count": .number(390)
        ])
        let json = try encode(object)
        #expect(json.contains("\"x\":null"))
        #expect(json.contains("\"y\":12"))
        #expect(json.contains("\"count\":390"))
        // The output must be real JSON, not a `NaN` token.
        #expect(throws: Never.self) { try JSONSerialization.jsonObject(with: Data(json.utf8)) }
    }

    @Test("finite numbers are untouched")
    func finiteUnchanged() throws {
        #expect(try encode(.number(0)) == "0")
        #expect(try encode(.number(-1.5)) == "-1.5")
        #expect(try encode(.number(1e300)) == "1e+300")
    }

    @Test("a tools/call response with a NaN coordinate frames as one NDJSON line")
    func responseWithNaNFrames() throws {
        let response = JSONRPCResponse.success(
            id: .number(7),
            result: .object(["nodes": .array([
                .object(["role": .string("AXGroup"), "position": .object(["x": .number(.nan), "y": .number(.infinity)])])
            ])])
        )
        let data = try StdioMessageFramer.frame(response, encoder: JSONEncoder())
        let line = String(decoding: data, as: UTF8.self)
        #expect(line.hasSuffix("\n"))
        #expect(!line.dropLast().contains("\n"))
        #expect(line.contains("\"x\":null"))
        #expect(line.contains("\"y\":null"))
        #expect(line.contains("\"id\":7"))
    }

    /// An encoder that rejects the first payload it sees, then behaves
    /// normally — the shape of "the result is unencodable, the fallback
    /// error is not".
    private final class RejectFirstEncoder: JSONEncoder, @unchecked Sendable {
        var calls = 0
        override func encode<T: Encodable>(_ value: T) throws -> Data {
            calls += 1
            if calls == 1 {
                throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "rejected for the test"))
            }
            return try super.encode(value)
        }
    }

    @Test("an unencodable response degrades to internalError for the same id, never silence")
    func unencodableResponseBecomesInternalError() throws {
        let encoder = RejectFirstEncoder()
        let response = JSONRPCResponse.success(id: .number(42), result: .object(["ok": .bool(true)]))
        let framed = try #require(StdioMessageFramer.frameOrInternalError(response, encoder: encoder))
        #expect(framed.encodingFailure != nil)
        let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: framed.data)
        #expect(decoded.id == .number(42))
        #expect(decoded.result == nil)
        #expect(decoded.error?.code == JSONRPCErrorCode.internalError.rawValue)
        #expect(decoded.error?.data == .object(["reason": .string("encoding_failed")]))
    }

    @Test("an encodable response passes through frameOrInternalError untouched")
    func encodablePassesThrough() throws {
        let response = JSONRPCResponse.success(id: .string("a"), result: .object(["ok": .bool(true)]))
        let framed = try #require(StdioMessageFramer.frameOrInternalError(response, encoder: JSONEncoder()))
        #expect(framed.encodingFailure == nil)
        // Compare decoded, not bytes: JSONEncoder does not promise a key
        // order between two encodes of the same dictionary.
        let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: framed.data)
        #expect(decoded.id == .string("a"))
        #expect(decoded.result == .object(["ok": .bool(true)]))
        #expect(decoded.error == nil)
    }
}
