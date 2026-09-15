import Testing
import Foundation
@testable import MacControlMCP

// v0.10 C1/C3/C4/C8: bad targets must be rejected before synthetic input.
@Suite("Element actions", .serialized)
struct ElementActionTests {
    @Test("element mouse tools resolve unknown IDs before posting input", arguments: [
        "click", "double_click", "right_click", "scroll", "drag_and_drop", "type_text"
    ])
    func unknownTarget(tool: String) async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: tool, arguments: [
            "element_id": .string("el_missing"), "text": .string("must not type"),
            "expected_app": .string("dev.mac-control-mcp.never-focused"), "delta_y": .number(10), "x2": .number(20), "y2": .number(30)
        ])
        #expect(result.isError)
        #expect(result.structuredContent.objectValue?["error_code"] == .string("unknown_element_id"))
    }

    @Test("drag resolves target-only IDs before posting input")
    func unknownDragDestination() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: "drag_and_drop", arguments: [
            "target_element_id": .string("el_missing"), "x1": .number(10), "y1": .number(10)
        ])
        #expect(result.structuredContent.objectValue?["error_code"] == .string("unknown_element_id"))
    }

    @Test("wait_for validates conditions and resolves IDs")
    func waitValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let invalid = await registry.callTool(name: "wait_for", arguments: [
            "element_id": .string("el_missing"), "condition": .string("anything")
        ])
        #expect(invalid.structuredContent.objectValue?["error_code"] == .string("invalid_argument"))
        let unknown = await registry.callTool(name: "wait_for", arguments: [
            "element_id": .string("el_missing"), "condition": .string("appears")
        ])
        #expect(unknown.structuredContent.objectValue?["error_code"] == .string("unknown_element_id"))
    }

    @Test("act validates verification before it can act")
    func actValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: "act", arguments: [
            "target": .string("el_missing"), "action": .string("click"),
            "verify": .object(["condition": .string("typo")])
        ])
        #expect(result.structuredContent.objectValue?["error_code"] == .string("invalid_argument"))
    }

    @Test("act resolves an element once before any action")
    func actUnknown() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: "act", arguments: [
            "target": .string("el_missing"), "action": .string("set_value"), "value": .string("never write"),
            "verify": .object(["condition": .string("value_equals"), "value": .string("never write")])
        ])
        #expect(result.structuredContent.objectValue?["error_code"] == .string("unknown_element_id"))
    }

    @Test("element targeting is advertised without requiring coordinates")
    func schemas() throws {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        for name in ["click", "double_click", "right_click", "scroll", "drag_and_drop", "type_text"] {
            let definition = try #require(registry.toolDefinitions.first { $0.name == name })
            let schema = try #require(definition.inputSchema.objectValue)
            #expect(schema["properties"]?.objectValue?["element_id"] != nil)
            #expect(!(schema["required"]?.arrayValue ?? []).contains(.string("x")))
            #expect(!(schema["required"]?.arrayValue ?? []).contains(.string("x1")))
        }
        #expect(registry.toolDefinitions.contains { $0.name == "wait_for" })
        #expect(registry.toolDefinitions.contains { $0.name == "act" })
    }
}
