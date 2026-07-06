import Testing
@testable import MacControlMCP

@Suite("AppleScriptString.escape")
struct AppleScriptStringTests {
    @Test("escapes backslash before quote (order matters)")
    func ordering() {
        // A lone backslash becomes two backslashes.
        #expect(AppleScriptString.escape(#"a\b"#) == #"a\\b"#)
        // A lone quote becomes escaped-quote.
        #expect(AppleScriptString.escape("a\"b") == "a\\\"b")
        // Backslash + quote: backslash doubles first, then the quote escapes —
        // the reversed order would have produced a broken \\" sequence.
        #expect(AppleScriptString.escape("\\\"") == "\\\\\\\"")
        // Plain text is unchanged.
        #expect(AppleScriptString.escape("hello world") == "hello world")
    }
}
