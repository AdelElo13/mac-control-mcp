import Testing
@testable import MacControlMCP

@Suite("Phase 5 tools — SHOULD + NICE", .serialized)
struct Phase5ToolsTests {
    @Test("all phase 5 tools are registered")
    func phase5Definitions() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let names = Set(registry.toolDefinitions.map { $0.name })
        let expected: Set<String> = [
            "browser_new_tab", "browser_close_tab",
            "capture_window", "capture_display",
            "list_menu_paths",
            "spotlight_search", "spotlight_open_result",
            "set_volume", "set_dark_mode",
            "key_down", "key_up", "press_key_sequence",
            "wait_for_window", "wait_for_app", "wait_for_file_dialog",
            "move_window_to_display",
            "request_permissions",
            "scroll_to_element",
            "force_quit_app", "file_dialog_cancel", "clipboard_clear"
        ]
        #expect(expected.isSubset(of: names))
    }

    @Test("total tool count is 127 after v0.6.0 (+10 Phase 9 tools)")
    func totalToolCount() {
        // v0.2.6 baseline:     64
        // v0.3.0 Phase 6 adds:  6 (tiered perms + AX observer waits) → 70
        // v0.4.0 Phase 7 adds: 25 (no-gap Mac control surface)        → 95
        // v0.5.0 Phase 8 adds: 22 (Apple apps + power + audio + dock) → 117
        // v0.6.0 Phase 9 adds: 10 (reliability substrate — grounding,
        //                         ax augmentation/snapshot/diff, audit
        //                         log, agent memory, PII redaction)   → 127
        let registry = ToolRegistry(accessibility: AccessibilityController())
        #expect(registry.toolDefinitions.count == 127)
    }

    @Test("set_volume requires volume argument")
    func setVolumeValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "set_volume", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("set_dark_mode requires enabled boolean")
    func setDarkModeValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "set_dark_mode", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("key_down + key_up reject unknown key")
    func keyDownUnknown() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "key_down",
            arguments: ["key": .string("not_a_real_key")]
        )
        #expect(r.isError == true)
    }

    @Test("press_key_sequence rejects empty steps")
    func sequenceEmpty() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "press_key_sequence",
            arguments: ["steps": .array([])]
        )
        #expect(r.isError == true)
    }

    @Test("clipboard_clear is registered (tool wiring only)")
    func clipboardClearRegistered() {
        // NOTE: we intentionally do NOT invoke clipboard_clear here —
        // NSPasteboard is a process-global and Swift Testing runs test
        // suites in parallel, so calling clipboard_clear would race with
        // ToolRegistryV2Tests.clipboardRoundTrip and sporadically wipe
        // that test's marker between write and read. Round-trip coverage
        // lives in ToolRegistryV2Tests; here we only assert the name is
        // registered.
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let names = Set(registry.toolDefinitions.map { $0.name })
        #expect(names.contains("clipboard_clear"))
    }

    @Test("move_window_to_display validates display_index")
    func moveToDisplayValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "move_window_to_display",
            arguments: [
                "pid": .number(1),
                "index": .number(0),
                "display_index": .number(999)
            ]
        )
        #expect(r.isError == true)
    }

    @Test("wait_for_window times out cleanly on fake pid")
    func waitForWindowTimeout() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "wait_for_window",
            arguments: [
                "pid": .number(999999),
                "title_contains": .string("nothing"),
                "timeout_seconds": .number(0.2),
                "poll_interval_ms": .number(100)
            ]
        )
        #expect(r.isError == true)
    }

    @Test("ModifierMap recognizes standard names")
    func modifierMap() {
        #expect(ModifierMap.flag(for: "cmd") != nil)
        #expect(ModifierMap.flag(for: "Command") != nil)
        #expect(ModifierMap.flag(for: "Shift") != nil)
        #expect(ModifierMap.flag(for: "alt") != nil)
        #expect(ModifierMap.flag(for: "ctrl") != nil)
        #expect(ModifierMap.flag(for: "fn") != nil)
        #expect(ModifierMap.flag(for: "banana") == nil)
    }
}
