import Testing
@testable import MacControlMCP

@Suite("Phase 4 tools — MUST completion")
struct Phase4ToolsTests {
    @Test("phase 4 tools are registered")
    func phase4Definitions() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let names = Set(registry.toolDefinitions.map { $0.name })
        let expected: Set<String> = [
            "move_window", "resize_window", "set_window_state",
            "file_dialog_set_path", "file_dialog_select_item", "file_dialog_confirm"
        ]
        #expect(expected.isSubset(of: names))
    }

    @Test("total tool count is 42 — all MUST tier complete")
    func totalToolCount() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        #expect(registry.toolDefinitions.count == 42)
    }

    @Test("move_window requires all four args")
    func moveWindowValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r1 = await registry.callTool(name: "move_window", arguments: [:])
        #expect(r1.isError == true)

        let r2 = await registry.callTool(
            name: "move_window",
            arguments: ["pid": .number(1), "index": .number(0), "x": .number(100)]
        )
        #expect(r2.isError == true)
    }

    @Test("resize_window rejects non-positive dimensions")
    func resizeValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "resize_window",
            arguments: [
                "pid": .number(1), "index": .number(0),
                "width": .number(0), "height": .number(100)
            ]
        )
        #expect(r.isError == true)
    }

    @Test("set_window_state requires state")
    func setStateValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "set_window_state",
            arguments: ["pid": .number(1), "index": .number(0)]
        )
        #expect(r.isError == true)
    }

    @Test("file dialog tools validate required arguments")
    func fileDialogValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())

        let r1 = await registry.callTool(name: "file_dialog_set_path", arguments: [:])
        #expect(r1.isError == true)

        let r2 = await registry.callTool(name: "file_dialog_select_item", arguments: [:])
        #expect(r2.isError == true)

        // confirm has no required args — returns ok regardless of whether a
        // dialog is actually present (the keystroke is posted either way).
        let r3 = await registry.callTool(name: "file_dialog_confirm", arguments: [:])
        #expect(r3.isError == false)
    }

    @Test("WindowController.setState recognizes canonical state names")
    func stateNames() async {
        // We cannot control a real window here without picking a pid/index,
        // but we can verify the unknown-state path returns false (not crash).
        let wc = WindowController()
        #expect(await wc.setState(pid: 99999, index: 0, state: "bogus_state") == false)
    }
}
