import Testing
@testable import MacControlMCP

// v0.10 C4: fake AX transport verifies refusal and ordering without CGEvents.
@Suite("Verified element input", .serialized)
struct ElementInputTests {
    actor Field {
        var value = "before"
        var events: [String] = []
        let acceptsFocus: Bool?
        init(_ acceptsFocus: Bool?) { self.acceptsFocus = acceptsFocus }
        func focus() -> ToolCallResult { events.append("set AXFocused"); return ToolCallResult(text: "set", structuredContent: .object(["ok": .bool(true)]), isError: false) }
        func read() -> Bool? { events.append("read AXFocused"); return acceptsFocus }
        func type() -> ToolCallResult { events.append("type"); value = "after"; return ToolCallResult(text: "typed", structuredContent: .object(["ok": .bool(true)]), isError: false) }
    }

    @Test("secure fields receive neither focus nor text")
    func secure() async {
        let field = Field(true)
        let result = await ElementInput.focusAndRun(secure: true, focus: { await field.focus() }, isFocused: { await field.read() }, input: { await field.type() })
        #expect(result.isError)
        #expect(result.structuredContent.objectValue?["reason"] == .string("secure_field"))
        #expect(await field.events.isEmpty)
        #expect(await field.value == "before")
    }

    @Test("unknown or false focus never types", arguments: [false, nil] as [Bool?])
    func unverified(focus: Bool?) async {
        let field = Field(focus)
        let result = await ElementInput.focusAndRun(secure: false, focus: { await field.focus() }, isFocused: { await field.read() }, input: { await field.type() })
        #expect(result.isError)
        #expect(await field.value == "before")
        #expect(await field.events == ["set AXFocused", "read AXFocused"])
    }

    @Test("typing happens only after successful focus readback")
    func verified() async {
        let field = Field(true)
        let result = await ElementInput.focusAndRun(secure: false, focus: { await field.focus() }, isFocused: { await field.read() }, input: { await field.type() })
        #expect(!result.isError)
        #expect(await field.value == "after")
        #expect(await field.events == ["set AXFocused", "read AXFocused", "type"])
    }
}
