import Testing
import Foundation
@testable import MacControlMCP

/// Regression guards for the v0.8.x crash sweep. Each test drives an input
/// that used to abort the whole server process (SIGTRAP / arithmetic
/// overflow, exit 133) and asserts it is now rejected gracefully. Because a
/// Swift trap kills the test runner too, a regression here shows up as a
/// hard crash of the suite — exactly the signal we want.
@Suite("Crash regressions — untrusted numeric input")
struct CrashRegressionTests {

    // MARK: - JSONValue.intValue out-of-range (MCPProtocol.swift)

    private func decode(_ json: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test("intValue returns nil for out-of-Int-range JSON numbers instead of trapping")
    func intValueOutOfRange() {
        // Each of these parses as a large integral Double and used to trap
        // in Int(value). They must now yield nil.
        #expect(decode("99999999999999999999").intValue == nil)   // ~1e20
        #expect(decode("1e300").intValue == nil)
        #expect(decode("-1e300").intValue == nil)
        #expect(decode("1e19").intValue == nil)                    // > Int.max (9.22e18)
    }

    @Test("intValue still accepts in-range integers and rejects fractions")
    func intValueInRange() {
        #expect(decode("0").intValue == 0)
        #expect(decode("123").intValue == 123)
        #expect(decode("-4096").intValue == -4096)
        #expect(decode("9007199254740992").intValue == 9007199254740992) // 2^53, exact in Double
        #expect(decode("1.5").intValue == nil)
        #expect(decode("\"42\"").intValue == 42)                   // string form still parses
    }

    // MARK: - Content-Length framing overflow (MCPProtocol.swift)

    private func pop(_ raw: String) -> StdioMessageFramer.ParseResult {
        var buffer = Data(raw.utf8)
        return StdioMessageFramer.popMessage(from: &buffer)
    }

    @Test("a near-Int.max Content-Length is rejected, not overflow-trapped")
    func contentLengthOverflow() {
        // bodyStart + Int.max used to overflow-trap before the bounds guard.
        if case .malformed = pop("Content-Length: 9223372036854775807\r\n\r\n{}") {
            // expected
        } else {
            Issue.record("expected .malformed for Int.max Content-Length")
        }
    }

    @Test("an oversized-but-valid Content-Length is rejected by the cap")
    func contentLengthCap() {
        let tooBig = StdioMessageFramer.maxContentLength + 1
        if case .malformed = pop("Content-Length: \(tooBig)\r\n\r\n{}") {
            // expected
        } else {
            Issue.record("expected .malformed for Content-Length past the cap")
        }
    }

    @Test("a normal Content-Length frame still parses")
    func contentLengthHappyPath() {
        let body = "{\"jsonrpc\":\"2.0\"}"
        if case .message(let data) = pop("Content-Length: \(body.utf8.count)\r\n\r\n\(body)") {
            #expect(String(data: data, encoding: .utf8) == body)
        } else {
            Issue.record("expected .message for a well-formed frame")
        }
    }

    // MARK: - scroll delta narrowing to Int32 (MouseController.swift)

    @Test("scroll with out-of-Int32-range deltas does not trap")
    func scrollHugeDelta() async {
        // Int32(deltaY) used to trap on > 2.1e9. Int32(clamping:) saturates.
        // Success depends on a HID tap being available, so we only assert it
        // returns (Bool) without crashing the process.
        let mouse = MouseController()
        _ = await mouse.scroll(deltaX: 3_000_000_000, deltaY: 3_000_000_000, at: nil)
        _ = await mouse.scroll(deltaX: Int.min, deltaY: Int.max, at: nil)
    }

    // MARK: - redact_image_regions coordinate narrowing (Tools+V2Phase9.swift)

    @Test("redact_image_regions rejects out-of-range coords instead of trapping")
    func redactHugeCoords() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(
            name: "redact_image_regions",
            arguments: [
                "path": .string("/nonexistent/path.png"),
                "regions": .array([
                    .object(["x": .number(1e300), "y": .number(1e300),
                             "width": .number(1e300), "height": .number(1e300)])
                ])
            ]
        )
        // The out-of-range region is skipped, so we reach the "no valid
        // regions" argument error — not a crash.
        #expect(result.isError == true)
    }
}
