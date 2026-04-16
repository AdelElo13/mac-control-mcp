import Testing
import ApplicationServices
@testable import MacControlMCP

@Suite("ToolRegistry v0.2.0 tools")
struct ToolRegistryV2Tests {
    @Test("tool definitions include all v2 tools")
    func v2DefinitionsPresent() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let names = Set(registry.toolDefinitions.map { $0.name })
        let expected: Set<String> = [
            "get_ui_tree", "find_elements", "query_elements",
            "get_element_attributes", "set_element_attribute", "perform_element_action",
            "list_windows", "focus_window",
            "click_menu_path", "list_menu_titles",
            "clipboard_read", "clipboard_write",
            "permissions_status"
        ]
        #expect(expected.isSubset(of: names))
    }

    @Test("clipboard round-trip")
    func clipboardRoundTrip() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let marker = "mcp-test-\(UUID().uuidString)"

        let write = await registry.callTool(name: "clipboard_write", arguments: ["text": .string(marker)])
        #expect(write.isError == false)

        let read = await registry.callTool(name: "clipboard_read", arguments: [:])
        #expect(read.isError == false)
        guard case .object(let payload) = read.structuredContent,
              case .string(let text) = payload["text"] ?? .null else {
            Issue.record("clipboard_read returned no text")
            return
        }
        #expect(text == marker)
    }

    @Test("unknown element_id returns error")
    func unknownElementID() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(
            name: "get_element_attributes",
            arguments: ["element_id": .string("el_nope"), "names": .array([.string("AXTitle")])]
        )
        #expect(result.isError == true)
    }

    @Test("missing required arguments return isError=true")
    func missingArguments() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())

        let ui = await registry.callTool(name: "get_ui_tree", arguments: [:])
        #expect(ui.isError == true)

        let click = await registry.callTool(name: "click_menu_path", arguments: ["pid": .number(1)])
        #expect(click.isError == true)

        let setter = await registry.callTool(
            name: "set_element_attribute",
            arguments: ["element_id": .string("el_foo")]
        )
        #expect(setter.isError == true)
    }

    @Test("permissions_status returns ok=true regardless of permission")
    func permissionsStatusAlwaysOk() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: "permissions_status", arguments: [:])
        #expect(result.isError == false)
        guard case .object(let payload) = result.structuredContent else {
            Issue.record("no payload")
            return
        }
        #expect(payload["ok"] == .bool(true))
        #expect(payload["accessibility"] != nil)
    }

    @Test("unknown tool name returns error")
    func unknownTool() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: "nonexistent_tool", arguments: [:])
        #expect(result.isError == true)
    }
}
