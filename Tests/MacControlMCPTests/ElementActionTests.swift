import Testing
import Foundation
import ApplicationServices
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

    @Test("invalid action parameters are rejected before target resolution")
    func invalidActionParameters() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let bad: [[String: JSONValue]] = [
            ["action": .string("key"), "key": .string("not-a-real-key")],
            ["action": .string("key"), "key": .string("return"), "modifiers": .array([.string("bogus")])],
            ["action": .string("set_value"), "value": .array([])],
            ["action": .string("type"), "text": .string("x"), "strategy": .string("bad")]
        ]
        for extra in bad {
            let args = extra.merging(["target": .string("el_missing"), "verify": .object(["condition": .string("appears")])]) { _, new in new }
            let result = await registry.callTool(name: "act", arguments: args)
            #expect(result.structuredContent.objectValue?["error_code"] == .string("invalid_argument"))
        }
    }

    @Test("act failures preserve the acted/verified contract")
    func failedActEnvelope() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: "act", arguments: [
            "target": .string("el_missing"), "action": .string("click"),
            "verify": .object(["condition": .string("appears")])
        ])
        #expect(result.structuredContent.objectValue?["acted"] == .bool(false))
        #expect(result.structuredContent.objectValue?["verified"] == .null)
        #expect(result.structuredContent.objectValue?["before"] == .null)
    }

    @Test("recycled process identities are refused before input", arguments: ["click", "double_click", "right_click", "scroll", "drag_and_drop", "type_text", "wait_for"])
    func staleIdentity(tool: String) async {
        let cache = ElementCache()
        let id = await cache.store(AXUIElementCreateApplication(getpid()), pid: getpid(),
            identity: ProcessIdentity(startTime: -1, bundleID: "never-this-process"))
        let registry = ToolRegistry(accessibility: AccessibilityController(), elementCache: cache)
        let result = await registry.callTool(name: tool, arguments: [
            "element_id": .string(id), "text": .string("never type"), "strategy": .string("keys"),
            "delta_y": .number(10), "x2": .number(10), "y2": .number(10), "condition": .string("appears")
        ])
        #expect(result.structuredContent.objectValue?["error_code"] == .string("stale_element"))
    }

    @Test("legacy wait wrappers retain response shapes")
    func legacyWrappers() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let gone = await registry.callTool(name: "wait_for_element", arguments: ["pid": .number(Double(Int32.max)), "role": .string("AXTextArea"), "expect_disappear": .bool(true)])
        #expect(gone.structuredContent.objectValue?["disappeared"] == .bool(true))
        #expect(gone.structuredContent.objectValue?["attempts"] == .number(1))
        let missingWindow = await registry.callTool(name: "wait_for_window", arguments: ["pid": .number(Double(Int32.max)), "timeout_seconds": .number(0.1)])
        #expect(missingWindow.structuredContent.objectValue?["timed_out"] == .bool(true))
        #expect(missingWindow.structuredContent.objectValue?["attempts"] == nil)
    }

    @Test("element targeting is advertised without requiring coordinates")
    func schemas() throws {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        for name in ["click", "double_click", "right_click", "scroll", "drag_and_drop", "type_text"] {
            let definition = try #require(registry.toolDefinitions.first { $0.name == name })
            let schema = try #require(definition.inputSchema.objectValue)
            #expect(schema["properties"]?.objectValue?["element_id"] != nil)
            let required = schema["required"]?.arrayValue ?? []
            #expect(required.contains(.string("x")) == false)
            #expect(required.contains(.string("x1")) == false)
        }
        #expect(registry.toolDefinitions.contains { $0.name == "wait_for" })
        #expect(registry.toolDefinitions.contains { $0.name == "act" })
    }
}
