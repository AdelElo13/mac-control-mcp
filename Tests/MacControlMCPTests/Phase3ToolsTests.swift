import Testing
@testable import MacControlMCP

@Suite("Phase 3 tools — input + lifecycle + displays")
struct Phase3ToolsTests {
    @Test("all phase 3 tools are registered")
    func phase3Definitions() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let names = Set(registry.toolDefinitions.map { $0.name })
        let expected: Set<String> = [
            "mouse_event", "drag_and_drop", "scroll",
            "launch_app", "activate_app", "quit_app",
            "wait_for_element", "list_displays", "convert_coordinates"
        ]
        #expect(expected.isSubset(of: names))
    }

    @Test("phase 3 includes 9 input/lifecycle/display tools")
    func phase3Count() {
        #expect(ToolRegistry.definitionsV2Phase3.count == 9)
    }

    @Test("mouse_event requires action, x, y")
    func mouseEventValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r1 = await registry.callTool(name: "mouse_event", arguments: [:])
        #expect(r1.isError == true)

        let r2 = await registry.callTool(name: "mouse_event", arguments: ["action": .string("click")])
        #expect(r2.isError == true)

        let r3 = await registry.callTool(name: "mouse_event", arguments: [
            "action": .string("unknown_action"),
            "x": .number(100),
            "y": .number(100)
        ])
        #expect(r3.isError == true)
    }

    @Test("drag_and_drop requires all four coordinates")
    func dragValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "drag_and_drop",
            arguments: ["x1": .number(0), "y1": .number(0), "x2": .number(100)]
        )
        #expect(r.isError == true)
    }

    @Test("scroll rejects zero deltas")
    func scrollValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "scroll",
            arguments: ["delta_x": .number(0), "delta_y": .number(0)]
        )
        #expect(r.isError == true)
    }

    @Test("activate_app without pid or bundle_id fails")
    func activateValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "activate_app", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("list_displays returns at least one display on a real mac")
    func listDisplays() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: "list_displays", arguments: [:])
        #expect(result.isError == false)
        guard case .object(let payload) = result.structuredContent,
              case .number(let count) = payload["count"] ?? .null else {
            Issue.record("list_displays missing count")
            return
        }
        #expect(count >= 1)
    }

    @Test("convert_coordinates global→global is identity")
    func convertIdentity() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(
            name: "convert_coordinates",
            arguments: [
                "x": .number(123.5),
                "y": .number(456.0),
                "from": .string("global"),
                "to": .string("global")
            ]
        )
        #expect(result.isError == false)
        guard case .object(let payload) = result.structuredContent,
              case .number(let x) = payload["x"] ?? .null,
              case .number(let y) = payload["y"] ?? .null else {
            Issue.record("convert missing coords")
            return
        }
        #expect(x == 123.5)
        #expect(y == 456.0)
    }

    @Test("convert_coordinates unknown space returns error")
    func convertUnknownSpace() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(
            name: "convert_coordinates",
            arguments: [
                "x": .number(0),
                "y": .number(0),
                "from": .string("banana"),
                "to": .string("global")
            ]
        )
        #expect(result.isError == true)
    }

    @Test("wait_for_element respects timeout when element never appears")
    func waitTimeout() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        // pid 1 = launchd; won't have a unique AX element named "ZZZ_DOES_NOT_EXIST_9999"
        let result = await registry.callTool(
            name: "wait_for_element",
            arguments: [
                "pid": .number(1),
                "role": .string("AXUnlikelyRole"),
                "title": .string("ZZZ_DOES_NOT_EXIST_9999"),
                "timeout_seconds": .number(0.3),
                "poll_interval_ms": .number(100)
            ]
        )
        #expect(result.isError == true)
        guard case .object(let payload) = result.structuredContent else {
            Issue.record("no payload"); return
        }
        #expect(payload["timed_out"] == .bool(true))
    }
}
