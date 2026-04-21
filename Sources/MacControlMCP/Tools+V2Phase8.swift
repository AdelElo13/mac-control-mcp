import Foundation

// MARK: - Tool definitions (v0.5.0 Phase 8: Apple apps + power + audio + dock + wifi-extended + focus)
//
// v0.5.0 closes the top-5 "no-gap" capability gaps Codex flagged in its
// review of v0.4.0:
//
//   • Native Apple-app automation   (Messages, Mail, Calendar, Reminders, Contacts)
//   • System power                  (sleep, lock, restart, shutdown, logout — all with confirm gate)
//   • Audio device selection        (output/input + mic mute)
//   • Wi-Fi extended                (scan, join-by-SSID)
//   • Dock + Focus                  (list/click dock items, DND/Focus toggle)
//
// 20 tools over 4 new controllers + 1 extension. Every destructive tool
// is wired into the Phase 6 tiered-permission gate via `enforceIfEnabled`
// so the `MAC_CONTROL_MCP_ENFORCE_TIERS=1` flag now covers this surface
// too. System-info tools retain opt-in semantics at `.view` since they
// only READ state.

extension ToolRegistry {
    static let definitionsV2Phase8: [MCPToolDefinition] = [

        // MARK: iMessage + Mail

        MCPToolDefinition(
            name: "imessage_send",
            description: "Send an iMessage to a phone number or email. Triggers the Messages automation permission prompt on first use.",
            inputSchema: schema(
                properties: [
                    "to": .object(["type": .string("string"), "description": .string("Phone (E.164) or Apple ID email.")]),
                    "body": .object(["type": .string("string")])
                ],
                required: ["to", "body"]
            )
        ),
        MCPToolDefinition(
            name: "imessage_list_recent",
            description: "List recent iMessage threads by participant. Does not return message bodies (would require Full Disk Access).",
            inputSchema: schema(
                properties: [
                    "limit": .object(["type": .array([.string("integer"), .string("string")]), "description": .string("Max threads 1-50. Default 10.")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "mail_send",
            description: "Compose + send an email via Mail.app. Supports TO/CC/BCC (comma-sep), subject, body. Set send_now=false to save as draft and open Mail.",
            inputSchema: schema(
                properties: [
                    "to": .object(["type": .string("string")]),
                    "subject": .object(["type": .string("string")]),
                    "body": .object(["type": .string("string")]),
                    "cc": .object(["type": .string("string")]),
                    "bcc": .object(["type": .string("string")]),
                    "send_now": .object(["type": .string("boolean"), "description": .string("Default true. false = open in Mail for review.")])
                ],
                required: ["to", "subject", "body"]
            )
        ),

        // MARK: Calendar + Reminders + Contacts

        MCPToolDefinition(
            name: "calendar_create_event",
            description: "Create a Calendar event. start_iso + end_iso must be ISO-8601. Optional 'calendar' targets a specific calendar by name.",
            inputSchema: schema(
                properties: [
                    "summary": .object(["type": .string("string")]),
                    "start_iso": .object(["type": .string("string")]),
                    "end_iso": .object(["type": .string("string")]),
                    "calendar": .object(["type": .string("string")])
                ],
                required: ["summary", "start_iso", "end_iso"]
            )
        ),
        MCPToolDefinition(
            name: "calendar_list_events",
            description: "List upcoming events across all calendars. horizon_days clamps to 1-90 (default 7).",
            inputSchema: schema(
                properties: [
                    "horizon_days": .object(["type": .array([.string("integer"), .string("string")])])
                ]
            )
        ),
        MCPToolDefinition(
            name: "reminders_create",
            description: "Create a reminder in Reminders.app. Optional due_iso (ISO-8601) and list (default: 'default list').",
            inputSchema: schema(
                properties: [
                    "title": .object(["type": .string("string")]),
                    "due_iso": .object(["type": .string("string")]),
                    "list": .object(["type": .string("string")])
                ],
                required: ["title"]
            )
        ),
        MCPToolDefinition(
            name: "reminders_list",
            description: "List reminders across all lists. include_completed=false (default) hides completed items.",
            inputSchema: schema(
                properties: [
                    "include_completed": .object(["type": .string("boolean")]),
                    "limit": .object(["type": .array([.string("integer"), .string("string")])])
                ]
            )
        ),
        MCPToolDefinition(
            name: "contacts_search",
            description: "Search Contacts by name substring. Returns phones + emails — perfect input for imessage_send / mail_send.",
            inputSchema: schema(
                properties: [
                    "query": .object(["type": .string("string")]),
                    "limit": .object(["type": .array([.string("integer"), .string("string")])])
                ],
                required: ["query"]
            )
        ),

        // MARK: Power

        MCPToolDefinition(
            name: "system_sleep",
            description: "Put the Mac to sleep immediately (reversible).",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "lock_screen",
            description: "Lock the screen (display sleep + FileVault lock).",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "system_restart",
            description: "Restart the Mac. REQUIRES confirm:true. Apps still show their own save-changes prompts.",
            inputSchema: schema(
                properties: [
                    "confirm": .object(["type": .string("boolean")])
                ],
                required: ["confirm"]
            )
        ),
        MCPToolDefinition(
            name: "system_shutdown",
            description: "Shut down the Mac. REQUIRES confirm:true.",
            inputSchema: schema(
                properties: [
                    "confirm": .object(["type": .string("boolean")])
                ],
                required: ["confirm"]
            )
        ),
        MCPToolDefinition(
            name: "system_logout",
            description: "Log out the current user. REQUIRES confirm:true.",
            inputSchema: schema(
                properties: [
                    "confirm": .object(["type": .string("boolean")])
                ],
                required: ["confirm"]
            )
        ),

        // MARK: Audio

        MCPToolDefinition(
            name: "list_audio_devices",
            description: "List every audio input + output device with current-selection flag. Requires 'switchaudio-osx' (brew install switchaudio-osx).",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "set_audio_output",
            description: "Switch system output device by exact name from list_audio_devices.",
            inputSchema: schema(
                properties: ["name": .object(["type": .string("string")])],
                required: ["name"]
            )
        ),
        MCPToolDefinition(
            name: "set_audio_input",
            description: "Switch system input device (microphone) by exact name.",
            inputSchema: schema(
                properties: ["name": .object(["type": .string("string")])],
                required: ["name"]
            )
        ),
        MCPToolDefinition(
            name: "mic_mute",
            description: "Mute or unmute the system input (microphone). mute=true sets input volume to 0; mute=false sets it to 100.",
            inputSchema: schema(
                properties: ["mute": .object(["type": .string("boolean")])],
                required: ["mute"]
            )
        ),

        // MARK: Wi-Fi extended

        MCPToolDefinition(
            name: "wifi_scan",
            description: "Scan for visible Wi-Fi networks. Uses Apple's private airport utility; returns a structured hint if it's been removed in this macOS version.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "wifi_join",
            description: "Join a Wi-Fi network by SSID + optional password. macOS stores the password in Keychain on success.",
            inputSchema: schema(
                properties: [
                    "ssid": .object(["type": .string("string")]),
                    "password": .object(["type": .string("string")])
                ],
                required: ["ssid"]
            )
        ),

        // MARK: Focus

        MCPToolDefinition(
            name: "set_focus_mode",
            description: "Turn a Focus mode on/off via a named Shortcut. macOS has no sanctioned CLI; this requires a user-seeded shortcut named 'Turn <mode> Focus On/Off' (or 'Turn Do Not Disturb On/Off' for dnd).",
            inputSchema: schema(
                properties: [
                    "mode": .object(["type": .string("string"), "description": .string("dnd | work | personal | sleep | <custom>")]),
                    "state": .object(["type": .string("string"), "description": .string("on | off")])
                ],
                required: ["mode", "state"]
            )
        ),

        // MARK: Dock

        MCPToolDefinition(
            name: "list_dock_items",
            description: "Enumerate the Dock's items via AX — app/folder/file names as they appear in the Dock.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "click_dock_item",
            description: "Click a Dock item by title (case-insensitive substring match). Triggers the app/folder/document exactly like a user click would.",
            inputSchema: schema(
                properties: ["title": .object(["type": .string("string")])],
                required: ["title"]
            )
        )
    ]

    // MARK: - Handlers

    // MARK: iMessage + Mail

    func callIMessageSend(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let to = arguments["to"]?.stringValue, !to.isEmpty else {
            return invalidArgument("imessage_send requires 'to'.")
        }
        guard let body = arguments["body"]?.stringValue, !body.isEmpty else {
            return invalidArgument("imessage_send requires 'body'.")
        }
        if let gate = await enforceIfEnabled(bundleId: "com.apple.MobileSMS", required: .full) {
            return gate
        }
        let r = await appleApps.sendMessage(to: to, body: body)
        return r.ok
            ? successResult("iMessage sent to \(to)", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "imessage_send failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callIMessageListRecent(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let limit = arguments["limit"]?.intValue ?? 10
        if let gate = await enforceIfEnabled(bundleId: "com.apple.MobileSMS", required: .view) {
            return gate
        }
        let r = await appleApps.listRecentMessageThreads(limit: limit)
        return r.ok
            ? successResult("found \(r.data?.count ?? 0) thread(s)",
                            ["ok": .bool(true), "threads": encodeAsJSONValue(r.data ?? [])])
            : errorResult(r.error ?? "imessage_list_recent failed",
                          ["ok": .bool(false), "error": .string(r.error ?? "")])
    }

    func callMailSend(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let to = arguments["to"]?.stringValue, !to.isEmpty,
              let subject = arguments["subject"]?.stringValue,
              let body = arguments["body"]?.stringValue else {
            return invalidArgument("mail_send requires to/subject/body.")
        }
        if let gate = await enforceIfEnabled(bundleId: "com.apple.mail", required: .full) {
            return gate
        }
        let cc = arguments["cc"]?.stringValue
        let bcc = arguments["bcc"]?.stringValue
        let sendNow = arguments["send_now"]?.boolValue ?? true
        let r = await appleApps.sendMail(to: to, subject: subject, body: body, cc: cc, bcc: bcc, sendNow: sendNow)
        return r.ok
            ? successResult(sendNow ? "email sent to \(to)" : "draft opened",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "mail_send failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    // MARK: Calendar + Reminders + Contacts

    func callCalendarCreateEvent(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let summary = arguments["summary"]?.stringValue,
              let start = arguments["start_iso"]?.stringValue,
              let end = arguments["end_iso"]?.stringValue else {
            return invalidArgument("calendar_create_event requires summary + start_iso + end_iso.")
        }
        if let gate = await enforceIfEnabled(bundleId: "com.apple.iCal", required: .full) {
            return gate
        }
        let cal = arguments["calendar"]?.stringValue
        let r = await appleApps.createCalendarEvent(summary: summary, startISO: start, endISO: end, calendar: cal)
        return r.ok
            ? successResult("event created", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "calendar_create_event failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callCalendarListEvents(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let horizon = arguments["horizon_days"]?.intValue ?? 7
        if let gate = await enforceIfEnabled(bundleId: "com.apple.iCal", required: .view) {
            return gate
        }
        let r = await appleApps.listCalendarEvents(horizonDays: horizon)
        return r.ok
            ? successResult("found \(r.data?.count ?? 0) event(s)",
                            ["ok": .bool(true), "events": encodeAsJSONValue(r.data ?? [])])
            : errorResult(r.error ?? "calendar_list_events failed",
                          ["ok": .bool(false), "error": .string(r.error ?? "")])
    }

    func callRemindersCreate(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
            return invalidArgument("reminders_create requires 'title'.")
        }
        if let gate = await enforceIfEnabled(bundleId: "com.apple.reminders", required: .full) {
            return gate
        }
        let dueISO = arguments["due_iso"]?.stringValue
        let list = arguments["list"]?.stringValue
        let r = await appleApps.createReminder(title: title, dueISO: dueISO, list: list)
        return r.ok
            ? successResult("reminder created", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "reminders_create failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callRemindersList(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        if let gate = await enforceIfEnabled(bundleId: "com.apple.reminders", required: .view) {
            return gate
        }
        let includeCompleted = arguments["include_completed"]?.boolValue ?? false
        let limit = arguments["limit"]?.intValue ?? 50
        let r = await appleApps.listReminders(includeCompleted: includeCompleted, limit: limit)
        return r.ok
            ? successResult("found \(r.data?.count ?? 0) reminder(s)",
                            ["ok": .bool(true), "reminders": encodeAsJSONValue(r.data ?? [])])
            : errorResult(r.error ?? "reminders_list failed",
                          ["ok": .bool(false), "error": .string(r.error ?? "")])
    }

    func callContactsSearch(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            return invalidArgument("contacts_search requires 'query'.")
        }
        if let gate = await enforceIfEnabled(bundleId: "com.apple.AddressBook", required: .view) {
            return gate
        }
        let limit = arguments["limit"]?.intValue ?? 10
        let r = await appleApps.searchContacts(query: query, limit: limit)
        return r.ok
            ? successResult("found \(r.data?.count ?? 0) contact(s)",
                            ["ok": .bool(true), "contacts": encodeAsJSONValue(r.data ?? [])])
            : errorResult(r.error ?? "contacts_search failed",
                          ["ok": .bool(false), "error": .string(r.error ?? "")])
    }

    // MARK: Power

    func callSystemSleep() async -> ToolCallResult {
        if let gate = await enforceIfEnabled(bundleId: "system:power", required: .full) {
            return gate
        }
        let r = await power.sleep()
        return r.ok
            ? successResult("sleep triggered", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "system_sleep failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callLockScreen() async -> ToolCallResult {
        if let gate = await enforceIfEnabled(bundleId: "system:power", required: .click) {
            return gate
        }
        let r = await power.lockScreen()
        return r.ok
            ? successResult("screen locked", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "lock_screen failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callSystemRestart(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let confirm = arguments["confirm"]?.boolValue ?? false
        if let gate = await enforceIfEnabled(bundleId: "system:power", required: .full) {
            return gate
        }
        let r = await power.restart(confirm: confirm)
        return r.ok
            ? successResult("restart initiated", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "system_restart failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callSystemShutdown(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let confirm = arguments["confirm"]?.boolValue ?? false
        if let gate = await enforceIfEnabled(bundleId: "system:power", required: .full) {
            return gate
        }
        let r = await power.shutdown(confirm: confirm)
        return r.ok
            ? successResult("shutdown initiated", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "system_shutdown failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callSystemLogout(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let confirm = arguments["confirm"]?.boolValue ?? false
        if let gate = await enforceIfEnabled(bundleId: "system:power", required: .full) {
            return gate
        }
        let r = await power.logout(confirm: confirm)
        return r.ok
            ? successResult("logout initiated", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "system_logout failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    // MARK: Audio

    func callListAudioDevices() async -> ToolCallResult {
        let r = await audio.listDevices()
        return r.ok
            ? successResult("found \(r.devices.count) device(s)",
                            ["ok": .bool(true), "devices": encodeAsJSONValue(r.devices)])
            : errorResult(r.hint ?? "list_audio_devices failed",
                          ["ok": .bool(false), "hint": .string(r.hint ?? "")])
    }

    func callSetAudioOutput(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
            return invalidArgument("set_audio_output requires 'name'.")
        }
        if let gate = await enforceIfEnabled(bundleId: "system:audio", required: .full) {
            return gate
        }
        let r = await audio.setOutputDevice(name: name)
        return r.ok
            ? successResult("audio output → \(name)", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.hint ?? "set_audio_output failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callSetAudioInput(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
            return invalidArgument("set_audio_input requires 'name'.")
        }
        if let gate = await enforceIfEnabled(bundleId: "system:audio", required: .full) {
            return gate
        }
        let r = await audio.setInputDevice(name: name)
        return r.ok
            ? successResult("audio input → \(name)", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.hint ?? "set_audio_input failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callMicMute(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let mute = arguments["mute"]?.boolValue else {
            return invalidArgument("mic_mute requires boolean 'mute'.")
        }
        if let gate = await enforceIfEnabled(bundleId: "system:audio", required: .full) {
            return gate
        }
        let r = await audio.setMicMute(mute: mute)
        return r.ok
            ? successResult(mute ? "mic muted" : "mic unmuted", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "mic_mute failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    // MARK: Wi-Fi extended

    func callWifiScan() async -> ToolCallResult {
        let r = await hardware.wifiScan()
        return r.ok
            ? successResult("found \(r.networks.count) network(s)",
                            ["ok": .bool(true), "networks": encodeAsJSONValue(r.networks)])
            : errorResult(r.hint ?? "wifi_scan failed",
                          ["ok": .bool(false), "hint": .string(r.hint ?? "")])
    }

    func callWifiJoin(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let ssid = arguments["ssid"]?.stringValue, !ssid.isEmpty else {
            return invalidArgument("wifi_join requires 'ssid'.")
        }
        if let gate = await enforceIfEnabled(bundleId: "system:wifi", required: .full) {
            return gate
        }
        let password = arguments["password"]?.stringValue
        let r = await hardware.wifiJoin(ssid: ssid, password: password)
        return r.ok
            ? successResult("joined \(ssid)", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.hint ?? "wifi_join failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    // MARK: Focus

    func callSetFocusMode(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let mode = arguments["mode"]?.stringValue, !mode.isEmpty,
              let state = arguments["state"]?.stringValue, !state.isEmpty else {
            return invalidArgument("set_focus_mode requires 'mode' and 'state'.")
        }
        if let gate = await enforceIfEnabled(bundleId: "system:focus", required: .click) {
            return gate
        }
        let r = await hardware.setFocusMode(mode: mode, state: state)
        return r.ok
            ? successResult("focus \(mode) → \(state)", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.hint ?? "set_focus_mode failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    // MARK: Dock

    func callListDockItems() async -> ToolCallResult {
        let r = await dock.listItems()
        return r.ok
            ? successResult("found \(r.items.count) dock item(s)",
                            ["ok": .bool(true), "items": encodeAsJSONValue(r.items)])
            : errorResult(r.error ?? "list_dock_items failed",
                          ["ok": .bool(false), "error": .string(r.error ?? "")])
    }

    func callClickDockItem(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
            return invalidArgument("click_dock_item requires 'title'.")
        }
        if let gate = await enforceIfEnabled(bundleId: "system:dock", required: .click) {
            return gate
        }
        let r = await dock.clickItem(title: title)
        return r.ok
            ? successResult("clicked dock item \(r.title)", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "click_dock_item failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }
}
