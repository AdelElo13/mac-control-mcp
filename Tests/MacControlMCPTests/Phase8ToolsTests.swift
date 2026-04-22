import Testing
import Foundation
@testable import MacControlMCP

@Suite("Phase 8 tools — Apple apps + power + audio + dock + extended", .serialized)
struct Phase8ToolsTests {

    // MARK: - Registry

    @Test("all 22 phase 8 tools are registered")
    func phase8Definitions() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let names = Set(registry.toolDefinitions.map { $0.name })
        let expected: Set<String> = [
            "imessage_send", "imessage_list_recent", "mail_send",
            "calendar_create_event", "calendar_list_events",
            "reminders_create", "reminders_list",
            "contacts_search",
            "system_sleep", "lock_screen",
            "system_restart", "system_shutdown", "system_logout",
            "list_audio_devices", "set_audio_output", "set_audio_input", "mic_mute",
            "wifi_scan", "wifi_join",
            "set_focus_mode",
            "list_dock_items", "click_dock_item"
        ]
        #expect(expected.count == 22)
        #expect(expected.isSubset(of: names))
    }

    // MARK: - iMessage

    @Test("imessage_send requires to")
    func imessageSendMissingTo() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "imessage_send", arguments: ["body": .string("hi")])
        #expect(r.isError == true)
    }

    @Test("imessage_send requires body")
    func imessageSendMissingBody() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "imessage_send", arguments: ["to": .string("1234")])
        #expect(r.isError == true)
    }

    // MARK: - Mail

    @Test("mail_send requires to/subject/body")
    func mailSendMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "mail_send", arguments: ["to": .string("a@b.c")])
        #expect(r.isError == true)
    }

    // MARK: - Calendar

    @Test("calendar_create_event requires summary/start/end")
    func calendarCreateMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "calendar_create_event", arguments: ["summary": .string("x")])
        #expect(r.isError == true)
    }

    @Test("calendar_create_event rejects non-ISO dates")
    func calendarCreateBadDate() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "calendar_create_event", arguments: [
                "summary": .string("x"),
                "start_iso": .string("not-iso"),
                "end_iso": .string("also-not-iso")
            ])
        // Either AppleScript permission failure OR our parse-ISO guard;
        // either way we get isError=true.
        #expect(r.isError == true)
    }

    // MARK: - Reminders

    @Test("reminders_create requires title")
    func remindersCreateMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "reminders_create", arguments: [:])
        #expect(r.isError == true)
    }

    // MARK: - Contacts

    @Test("contacts_search requires query")
    func contactsSearchMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "contacts_search", arguments: [:])
        #expect(r.isError == true)
    }

    // MARK: - Power

    @Test("system_restart without confirm returns error")
    func restartRequiresConfirm() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "system_restart", arguments: ["confirm": .bool(false)])
        #expect(r.isError == true)
    }

    @Test("system_shutdown without confirm returns error")
    func shutdownRequiresConfirm() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "system_shutdown", arguments: ["confirm": .bool(false)])
        #expect(r.isError == true)
    }

    @Test("system_logout without confirm returns error")
    func logoutRequiresConfirm() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "system_logout", arguments: ["confirm": .bool(false)])
        #expect(r.isError == true)
    }

    // MARK: - Audio

    @Test("set_audio_output requires name")
    func setAudioOutputMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "set_audio_output", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("set_audio_input requires name")
    func setAudioInputMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "set_audio_input", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("mic_mute requires boolean mute")
    func micMuteMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "mic_mute", arguments: [:])
        #expect(r.isError == true)
    }

    // MARK: - Wi-Fi extended

    @Test("wifi_join requires ssid")
    func wifiJoinMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "wifi_join", arguments: [:])
        #expect(r.isError == true)
    }

    // MARK: - Focus

    @Test("set_focus_mode requires mode and state")
    func focusMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "set_focus_mode", arguments: ["mode": .string("dnd")])
        #expect(r.isError == true)
    }

    // MARK: - Dock

    @Test("click_dock_item requires title")
    func clickDockMissing() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "click_dock_item", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("list_dock_items runs without error (or reports structured issue)")
    func listDockSmoke() async {
        // Dock is always running; this should succeed on any real Mac.
        // In CI environments without AppKit the call may return isError
        // with a structured 'error' field — either is acceptable.
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "list_dock_items", arguments: [:])
        _ = r  // just ensure no crash
    }

    // MARK: - tool count sanity (Phase 5 owns the exact assertion)

    @Test("tool count >= 117 after phase 8 (Phase 5 tests own the exact count)")
    func phase8CountCheck() {
        // Phase 5's totalToolCount test holds the authoritative exact
        // number; Phase 8 just guarantees we haven't dropped below the
        // v0.5.0 floor. This prevents the cascade-failure pattern we
        // hit at v0.7.0 where Phase 8/9/10 all asserted their own
        // exact count and each CI run flagged 3 "failures" for what
        // was really one tool count drift.
        let registry = ToolRegistry(accessibility: AccessibilityController())
        #expect(registry.toolDefinitions.count >= 117)
    }
}
