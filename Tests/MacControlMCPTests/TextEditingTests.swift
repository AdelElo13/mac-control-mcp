import Testing
import Foundation
import ApplicationServices
import CoreGraphics
@testable import MacControlMCP

/// v0.9 workstream E (gap-audit C-7 + B-15) — text editing primitives.
///
/// These tests cover the parts that can be verified without driving a live
/// app: the AXValue ↔ Swift typing layer (the whole point of B-15 — callers
/// should never regex-parse `"range(2115,0)"` again) and argument validation
/// on the six new tools. The live round-trip against a TextEdit document is
/// run manually via the stdio probe (see the workstream report); it is not
/// part of `swift test` because it needs AX trust + a GUI session.
@Suite("Text editing primitives (C-7)")
struct TextEditingTests {

    // MARK: - AXValue range typing

    @Test("cfRange AXValue decodes to a typed TextRange")
    func decodesRange() {
        var range = CFRange(location: 2115, length: 7)
        let value = AXValueCreate(.cfRange, &range)
        #expect(value != nil)
        let decoded = TextEditingController.textRange(from: value!)
        #expect(decoded?.location == 2115)
        #expect(decoded?.length == 7)
    }

    @Test("a zero-length cfRange (collapsed caret) decodes as length 0")
    func decodesCollapsedRange() {
        var range = CFRange(location: 0, length: 0)
        let value = AXValueCreate(.cfRange, &range)!
        let decoded = TextEditingController.textRange(from: value)
        #expect(decoded?.location == 0)
        #expect(decoded?.length == 0)
    }

    @Test("a non-range AXValue does not decode as a range")
    func rejectsWrongAXValueType() {
        var point = CGPoint(x: 12, y: 34)
        let value = AXValueCreate(.cgPoint, &point)!
        #expect(TextEditingController.textRange(from: value) == nil)
    }

    @Test("cgRect AXValue decodes to typed bounds")
    func decodesRect() {
        var rect = CGRect(x: 10, y: 20, width: 3, height: 17)
        let value = AXValueCreate(.cgRect, &rect)!
        let decoded = TextEditingController.bounds(from: value)
        #expect(decoded?.x == 10)
        #expect(decoded?.y == 20)
        #expect(decoded?.width == 3)
        #expect(decoded?.height == 17)
    }

    @Test("a non-rect AXValue does not decode as bounds")
    func rejectsWrongRectType() {
        var range = CFRange(location: 1, length: 2)
        let value = AXValueCreate(.cfRange, &range)!
        #expect(TextEditingController.bounds(from: value) == nil)
    }

    @Test("makeRangeValue round-trips through AXValue")
    func rangeValueRoundTrip() {
        let value = TextEditingController.makeRangeValue(location: 42, length: 5)
        #expect(value != nil)
        #expect(AXValueGetType(value!) == .cfRange)
        let decoded = TextEditingController.textRange(from: value!)
        #expect(decoded?.location == 42)
        #expect(decoded?.length == 5)
    }

    // MARK: - Range validation

    @Test("a range inside the document validates")
    func validRange() {
        #expect(TextEditingController.validateRange(location: 2, length: 3, numberOfCharacters: 10) == nil)
        // Exactly at the end (append position) is legal.
        #expect(TextEditingController.validateRange(location: 10, length: 0, numberOfCharacters: 10) == nil)
    }

    @Test("negative location or length is rejected")
    func negativeRange() {
        #expect(TextEditingController.validateRange(location: -1, length: 0, numberOfCharacters: 10) != nil)
        #expect(TextEditingController.validateRange(location: 0, length: -2, numberOfCharacters: 10) != nil)
    }

    @Test("a range past the end of the document is rejected")
    func outOfBoundsRange() {
        #expect(TextEditingController.validateRange(location: 11, length: 0, numberOfCharacters: 10) != nil)
        #expect(TextEditingController.validateRange(location: 8, length: 5, numberOfCharacters: 10) != nil)
    }

    @Test("with an unknown character count the bounds check is skipped, not guessed")
    func unknownCharacterCount() {
        #expect(TextEditingController.validateRange(location: 9_000, length: 1, numberOfCharacters: nil) == nil)
        // Sign checks still apply.
        #expect(TextEditingController.validateRange(location: -1, length: 0, numberOfCharacters: nil) != nil)
    }

    // MARK: - Value truncation

    @Test("truncate reports the untruncated value when it fits")
    func truncateFits() {
        let r = TextEditingController.truncate("hello", maxChars: 10)
        #expect(r.text == "hello")
        #expect(r.truncated == false)
    }

    @Test("truncate cuts to maxChars and flags it")
    func truncateCuts() {
        let r = TextEditingController.truncate("hello world", maxChars: 5)
        #expect(r.text == "hello")
        #expect(r.truncated == true)
    }

    @Test("truncate with no limit returns everything")
    func truncateNoLimit() {
        let r = TextEditingController.truncate("hello world", maxChars: nil)
        #expect(r.text == "hello world")
        #expect(r.truncated == false)
    }

    @Test("truncate counts characters, not UTF-8 bytes")
    func truncateUnicode() {
        let r = TextEditingController.truncate("héllo→wörld", maxChars: 6)
        #expect(r.text == "héllo→")
        #expect(r.truncated == true)
    }

    // MARK: - Registration

    @Test("all text editing tools are registered")
    func toolsRegistered() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let names = Set(registry.toolDefinitions.map { $0.name })
        let expected: Set<String> = [
            "text_get_selection", "text_get_caret", "text_set_selection",
            "text_insert_at_caret", "text_replace_range", "text_get_value"
        ]
        #expect(expected.count == 6)
        #expect(expected.isSubset(of: names))
    }

    @Test("every text tool dispatches (no unknown-tool fallthrough)")
    func toolsDispatch() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        for name in ["text_get_selection", "text_get_caret", "text_set_selection",
                     "text_insert_at_caret", "text_replace_range", "text_get_value"] {
            let r = await registry.callTool(name: name, arguments: [:])
            #expect(!r.text.contains("Unknown tool"), "\(name) fell through to the default case")
        }
    }

    // MARK: - Argument validation

    /// Every tool needs a target: an element_id or a pid. Neither → invalid.
    @Test("tools require element_id or pid", arguments: [
        "text_get_selection", "text_get_caret", "text_get_value"
    ])
    func requiresTarget(name: String) async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: name, arguments: [:])
        #expect(r.isError == true)
        #expect(r.structuredContent.objectValue?["error_code"]?.stringValue == "invalid_argument")
    }

    @Test("text_set_selection requires location and length")
    func setSelectionRequiresRange() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let missing = await registry.callTool(
            name: "text_set_selection", arguments: ["element_id": .string("el_nope")]
        )
        #expect(missing.isError == true)
        #expect(missing.structuredContent.objectValue?["error_code"]?.stringValue == "invalid_argument")

        let negative = await registry.callTool(
            name: "text_set_selection",
            arguments: ["element_id": .string("el_nope"), "location": .number(-1), "length": .number(0)]
        )
        #expect(negative.isError == true)
        #expect(negative.structuredContent.objectValue?["error_code"]?.stringValue == "invalid_argument")
    }

    @Test("text_insert_at_caret requires text")
    func insertRequiresText() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "text_insert_at_caret", arguments: ["element_id": .string("el_nope")]
        )
        #expect(r.isError == true)
        #expect(r.structuredContent.objectValue?["error_code"]?.stringValue == "invalid_argument")
    }

    @Test("text_replace_range requires location, length and text")
    func replaceRequiresAll() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let noText = await registry.callTool(
            name: "text_replace_range",
            arguments: ["element_id": .string("el_nope"), "location": .number(0), "length": .number(1)]
        )
        #expect(noText.isError == true)
        #expect(noText.structuredContent.objectValue?["error_code"]?.stringValue == "invalid_argument")

        let noRange = await registry.callTool(
            name: "text_replace_range",
            arguments: ["element_id": .string("el_nope"), "text": .string("x")]
        )
        #expect(noRange.isError == true)
        #expect(noRange.structuredContent.objectValue?["error_code"]?.stringValue == "invalid_argument")
    }

    @Test("text_get_value rejects a non-positive max_chars")
    func getValueRejectsBadMax() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "text_get_value",
            arguments: ["element_id": .string("el_nope"), "max_chars": .number(0)]
        )
        #expect(r.isError == true)
        #expect(r.structuredContent.objectValue?["error_code"]?.stringValue == "invalid_argument")
    }

    @Test("an unknown element_id reports not_found, not a crash")
    func unknownElementID() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "text_get_selection", arguments: ["element_id": .string("el_does_not_exist")]
        )
        #expect(r.isError == true)
        #expect(r.structuredContent.objectValue?["error_code"]?.stringValue == "not_found")
    }

    @Test("a pid that belongs to no process reports not_found")
    func deadPID() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        // 0x7FFFFFFE is far above any live pid on macOS (pid_max is 99999).
        let r = await registry.callTool(
            name: "text_get_selection", arguments: ["pid": .number(2_147_483_646)]
        )
        #expect(r.isError == true)
        #expect(r.structuredContent.objectValue?["error_code"]?.stringValue == "not_found")
    }

    @Test("an invalid pid is an argument error, not a not_found")
    func invalidPID() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "text_get_selection", arguments: ["pid": .string("not-a-pid")]
        )
        #expect(r.isError == true)
        #expect(r.structuredContent.objectValue?["error_code"]?.stringValue == "invalid_argument")
    }
}
