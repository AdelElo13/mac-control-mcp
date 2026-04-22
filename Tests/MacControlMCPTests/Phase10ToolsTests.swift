import Testing
import Foundation
@testable import MacControlMCP

@Suite("Phase 10 tools — complete Mac surface", .serialized)
struct Phase10ToolsTests {

    @Test("all 13 phase 10 tools are registered")
    func phase10Definitions() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let names = Set(registry.toolDefinitions.map { $0.name })
        let expected: Set<String> = [
            // A1 image discipline
            "capture_screen_v2", "artifact_gc",
            // F2 undo
            "undo_last_action", "undo_peek",
            // Voice
            "speech_to_text", "text_to_speech",
            "audio_record", "record_screen",
            // Browser DOM
            "browser_dom_tree", "browser_visible_text", "browser_iframes",
            // Apple native
            "foundation_models_generate",
            "list_app_intents", "invoke_app_intent"
        ]
        #expect(expected.count == 14)
        #expect(expected.isSubset(of: names))
    }

    // MARK: - Undo

    @Test("undo_peek returns empty queue on fresh registry")
    func undoPeekEmpty() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "undo_peek", arguments: [:])
        #expect(r.isError == false)
    }

    @Test("undo_last_action on empty queue returns not-ok")
    func undoEmptyQueue() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "undo_last_action", arguments: [:])
        #expect(r.isError == true)
    }

    // MARK: - Voice

    @Test("speech_to_text requires audio_path")
    func speechMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "speech_to_text", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("speech_to_text rejects missing file")
    func speechMissingFile() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(
                name: "speech_to_text",
                arguments: ["audio_path": .string("/tmp/no-file-\(UUID().uuidString).wav")]
            )
        #expect(r.isError == true)
    }

    @Test("text_to_speech requires text")
    func ttsMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "text_to_speech", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("audio_record requires seconds")
    func audioRecordMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "audio_record", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("record_screen requires seconds")
    func recordScreenMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "record_screen", arguments: [:])
        #expect(r.isError == true)
    }

    // MARK: - Apple native

    @Test("foundation_models_generate requires prompt")
    func fmMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "foundation_models_generate", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("list_app_intents runs without error (returns whatever apps expose Intents)")
    func listAppIntentsSmoke() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "list_app_intents", arguments: [:])
        // Should succeed — may return zero apps on a stripped Mac, which is
        // still ok:true per the controller's contract.
        #expect(r.isError == false)
    }

    @Test("invoke_app_intent requires bundle_id + intent")
    func invokeMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "invoke_app_intent", arguments: ["bundle_id": .string("x")])
        #expect(r.isError == true)
    }

    // MARK: - tool count sanity

    @Test("tool count >= 141 after phase 10 (Phase 5 owns the exact count after future phases)")
    func phase10CountCheck() {
        // v0.8.0 (+2 Phase 11) would otherwise drift this; keep as lower
        // bound. The authoritative exact count lives in Phase5ToolsTests.
        let registry = ToolRegistry(accessibility: AccessibilityController())
        #expect(registry.toolDefinitions.count >= 141)
    }
}
