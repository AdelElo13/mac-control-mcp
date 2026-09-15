import Foundation
import CoreGraphics

struct ToolCallResult: Sendable {
    let text: String
    let structuredContent: JSONValue
    let isError: Bool

    func asMCPResult() -> JSONValue {
        var result: [String: JSONValue] = [
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text)
                ])
            ]),
            "structuredContent": structuredContent
        ]

        if isError {
            result["isError"] = .bool(true)
        }

        return .object(result)
    }
}

// ToolRegistry holds actor references and a few stateless JSON helpers.
// All mutable state lives inside the referenced actors, so the registry
// itself is effectively a Sendable dispatch table. @unchecked Sendable
// is used here because the Swift 6 compiler cannot yet see through this
// "bag of actors" pattern automatically.
final class ToolRegistry: @unchecked Sendable {
    let accessibility: AccessibilityController
    let elementCache: ElementCache
    let windows: WindowController
    let menus: MenuController
    let clipboard: ClipboardController
    let browser: BrowserController
    let screen: ScreenController
    let mouse: MouseController
    let appLifecycle: AppLifecycleController
    let displays: DisplayController
    let fileDialog: FileDialogController
    let system: SystemController
    let spotlight: SpotlightController
    // v0.4.0 Phase 7 — no-gap Mac control surface
    let systemInfo: SystemInfoController
    let missionControl: MissionControlController
    let hardware: HardwareController
    let shortcuts: ShortcutsController
    let finder: FinderController
    let notificationCenter: NotificationCenterController
    // v0.5.0 Phase 8 — Apple apps + power + audio + dock
    let appleApps: AppleAppsController
    let power: PowerController
    let audio: AudioController
    let dock: DockController
    // v0.6.0 Phase 9 — reliability + observability substrate
    let audit: AuditLogController
    let redaction: RedactionController
    let memory: AgentMemoryController
    let axSnapshot: AXSnapshotController
    let grounding: GroundingController
    // v0.7.0 Phase 10 — complete Mac surface
    let voice: VoiceController
    let browserDOM: BrowserDOMController
    let appleNative: AppleNativeController
    let undo: UndoController
    let artifactStore: ArtifactStore
    // v0.9 workstream E — text editing primitives (gap-audit C-7 / B-15)
    let textEditing: TextEditingController

    init(
        accessibility: AccessibilityController,
        elementCache: ElementCache = ElementCache(),
        windows: WindowController = WindowController(),
        menus: MenuController = MenuController(),
        clipboard: ClipboardController = ClipboardController(),
        browser: BrowserController = BrowserController(),
        screen: ScreenController = ScreenController(),
        mouse: MouseController = MouseController(),
        appLifecycle: AppLifecycleController = AppLifecycleController(),
        displays: DisplayController = DisplayController(),
        fileDialog: FileDialogController = FileDialogController(),
        system: SystemController = SystemController(),
        spotlight: SpotlightController = SpotlightController(),
        systemInfo: SystemInfoController = SystemInfoController(),
        missionControl: MissionControlController = MissionControlController(),
        hardware: HardwareController = HardwareController(),
        shortcuts: ShortcutsController = ShortcutsController(),
        finder: FinderController = FinderController(),
        notificationCenter: NotificationCenterController = NotificationCenterController(),
        appleApps: AppleAppsController = AppleAppsController(),
        power: PowerController = PowerController(),
        audio: AudioController = AudioController(),
        dock: DockController = DockController(),
        audit: AuditLogController = AuditLogController(),
        redaction: RedactionController = RedactionController(),
        memory: AgentMemoryController = AgentMemoryController(),
        axSnapshot: AXSnapshotController = AXSnapshotController(),
        grounding: GroundingController? = nil,
        voice: VoiceController = VoiceController(),
        browserDOM: BrowserDOMController? = nil,
        appleNative: AppleNativeController = AppleNativeController(),
        undoCtrl: UndoController = UndoController(),
        artifactStore: ArtifactStore = ArtifactStore(),
        textEditing: TextEditingController = TextEditingController()
    ) {
        self.accessibility = accessibility
        self.elementCache = elementCache
        self.windows = windows
        self.menus = menus
        self.clipboard = clipboard
        self.browser = browser
        self.screen = screen
        self.mouse = mouse
        self.appLifecycle = appLifecycle
        self.displays = displays
        self.fileDialog = fileDialog
        self.system = system
        self.spotlight = spotlight
        self.systemInfo = systemInfo
        self.missionControl = missionControl
        self.hardware = hardware
        self.shortcuts = shortcuts
        self.finder = finder
        self.notificationCenter = notificationCenter
        self.appleApps = appleApps
        self.power = power
        self.audio = audio
        self.dock = dock
        self.audit = audit
        self.redaction = redaction
        self.memory = memory
        self.axSnapshot = axSnapshot
        // Grounding needs the existing AccessibilityController + ScreenController
        // — if the caller didn't pass one, construct with the defaults so the
        // registry is self-consistent.
        self.grounding = grounding ?? GroundingController(
            accessibility: accessibility, screen: screen, elementCache: elementCache
        )
        self.voice = voice
        self.browserDOM = browserDOM ?? BrowserDOMController(browser: browser)
        self.appleNative = appleNative
        self.undo = undoCtrl
        self.artifactStore = artifactStore
        self.textEditing = textEditing
    }

    var toolDefinitions: [MCPToolDefinition] {
        Self.definitions + Self.definitionsV2 + Self.definitionsV2Phase2 +
            Self.definitionsV2Phase3 + Self.definitionsV2Phase4 + Self.definitionsV2Phase5 +
            Self.definitionsV2Phase6 + Self.definitionsV2Phase7 + Self.definitionsV2Phase8 +
            Self.definitionsV2Phase9 + Self.definitionsV2Phase10 + Self.definitionsV2Phase11 +
            Self.definitionsBatch + Self.definitionsV0_9AXCore + Self.definitionsAnnotate +
            Self.definitionsTextEditing
    }

    // MARK: - Tool dispatch
    //
    // MAINTAINABILITY NOTE (Codex v1 LOW):
    // This single switch statement now dispatches every tool in
    // `toolDefinitions` (see docs/TOOLS.md for the current count — this
    // comment intentionally doesn't hardcode a number that would drift).
    // Splitting it
    // into a `[String: @Sendable (Arguments) -> ToolCallResult]` table per
    // phase file would reduce surface area and make tool registration
    // self-contained. The split is intentionally deferred until we add
    // more tools OR the switch exceeds ~100 cases — doing it now would
    // churn 63 case arms for little immediate benefit and complicate the
    // actor-hop story for tools that need async access to specific
    // controllers.
    func callTool(name: String, arguments: [String: JSONValue]) async -> ToolCallResult {
        switch name {
        case "list_elements":
            return await callListElements(arguments)
        case "find_element":
            return await callFindElement(arguments)
        case "click":
            return await callClick(arguments)
        case "type_text":
            return await callTypeText(arguments)
        case "read_value":
            return await callReadValue(arguments)
        case "press_key":
            return await callPressKey(arguments)
        case "focused_app":
            return await callFocusedApp()
        case "list_apps":
            return await callListApps()
        case "get_ui_tree":
            return await callGetUITree(arguments)
        case "find_elements":
            return await callFindElements(arguments)
        case "query_elements":
            return await callQueryElements(arguments)
        case "get_element_attributes":
            return await callGetElementAttributes(arguments)
        case "set_element_attribute":
            return await callSetElementAttribute(arguments)
        case "perform_element_action":
            return await callPerformElementAction(arguments)
        case "list_windows":
            return await callListWindows(arguments)
        case "focus_window":
            return await callFocusWindow(arguments)
        case "click_menu_path":
            return await callClickMenuPath(arguments)
        case "list_menu_titles":
            return await callListMenuTitles(arguments)
        case "clipboard_read":
            return await callClipboardRead(arguments)
        case "clipboard_write":
            return await callClipboardWrite(arguments)
        case "permissions_status":
            return await callPermissionsStatus()
        case "open_permission_pane":
            return await callOpenPermissionPane(arguments)
        case "mcp_server_info":
            return await callMcpServerInfo()
        case "probe_ax_tree":
            return await callProbeAXTree(arguments)
        case "element_at_point":
            return await callElementAtPoint(arguments)
        case "browser_list_tabs":
            return await callBrowserListTabs(arguments)
        case "browser_get_active_tab":
            return await callBrowserActiveTab(arguments)
        case "browser_navigate":
            return await callBrowserNavigate(arguments)
        case "browser_eval_js":
            return await callBrowserEvalJS(arguments)
        case "capture_screen":
            return await callCaptureScreen(arguments)
        case "ocr_screen":
            return await callOCRScreen(arguments)
        case "mouse_event":
            return await callMouseEvent(arguments)
        case "drag_and_drop":
            return await callDragAndDrop(arguments)
        case "scroll":
            return await callScroll(arguments)
        case "launch_app":
            return await callLaunchApp(arguments)
        case "activate_app":
            return await callActivateApp(arguments)
        case "quit_app":
            return await callQuitApp(arguments)
        case "wait_for_element":
            return await callWaitForElement(arguments)
        case "list_displays":
            return await callListDisplays()
        case "convert_coordinates":
            return await callConvertCoordinates(arguments)
        case "move_window":
            return await callMoveWindow(arguments)
        case "resize_window":
            return await callResizeWindow(arguments)
        case "set_window_state":
            return await callSetWindowState(arguments)
        case "file_dialog_set_path":
            return await callFileDialogSetPath(arguments)
        case "file_dialog_select_item":
            return await callFileDialogSelectItem(arguments)
        case "file_dialog_confirm":
            return await callFileDialogConfirm(arguments)
        case "browser_new_tab":
            return await callBrowserNewTab(arguments)
        case "browser_close_tab":
            return await callBrowserCloseTab(arguments)
        case "capture_window":
            return await callCaptureWindow(arguments)
        case "capture_display":
            return await callCaptureDisplay(arguments)
        case "list_menu_paths":
            return await callListMenuPaths(arguments)
        case "spotlight_search":
            return await callSpotlightSearch(arguments)
        case "spotlight_open_result":
            return await callSpotlightOpenResult(arguments)
        case "set_volume":
            return await callSetVolume(arguments)
        case "set_dark_mode":
            return await callSetDarkMode(arguments)
        case "key_down":
            return await callKeyDown(arguments)
        case "key_up":
            return await callKeyUp(arguments)
        case "press_key_sequence":
            return await callPressKeySequence(arguments)
        case "wait_for_window":
            return await callWaitForWindow(arguments)
        case "wait_for_app":
            return await callWaitForApp(arguments)
        case "wait_for_file_dialog":
            return await callWaitForFileDialog(arguments)
        case "move_window_to_display":
            return await callMoveWindowToDisplay(arguments)
        case "request_permissions":
            return await callRequestPermissions(arguments)
        case "scroll_to_element":
            return await callScrollToElement(arguments)
        case "force_quit_app":
            // Alias: force_quit_app → quit_app with force=true
            var forced = arguments
            forced["force"] = .bool(true)
            return await callQuitApp(forced)
        case "file_dialog_cancel":
            // Alias: file_dialog_cancel → file_dialog_confirm with cancel=true
            return await callFileDialogConfirm(["cancel": .bool(true)])
        case "clipboard_clear":
            await clipboard.clear()
            return successResult("Clipboard cleared.", ["ok": .bool(true)])
        // MARK: - v0.3.0 Phase 6 — tiered permissions + event waits
        case "request_access":
            return await callRequestAccess(arguments)
        case "list_granted_applications":
            return await callListGrantedApplications()
        case "revoke_access":
            return await callRevokeAccess(arguments)
        case "deny_access":
            return await callDenyAccess(arguments)
        case "wait_for_ax_notification":
            return await callWaitForAXNotification(arguments)
        case "wait_for_window_state_change":
            return await callWaitForWindowStateChange(arguments)
        // MARK: - v0.4.0 Phase 7 — no-gap surface (25 tools)
        // System info
        case "battery_status":
            return await callBatteryStatus()
        case "system_load":
            return await callSystemLoad()
        case "network_info":
            return await callNetworkInfo()
        case "bluetooth_devices":
            return await callBluetoothDevices()
        case "disk_usage":
            return await callDiskUsage()
        // Mission Control + Spaces
        case "mission_control":
            return await callMissionControl()
        case "app_expose":
            return await callAppExpose()
        case "launchpad":
            return await callLaunchpad()
        case "show_desktop":
            return await callShowDesktop()
        case "switch_to_space":
            return await callSwitchToSpace(arguments)
        // Hardware
        case "wifi_set":
            return await callWifiSet(arguments)
        case "bluetooth_set":
            return await callBluetoothSet(arguments)
        case "set_brightness":
            return await callSetBrightness(arguments)
        case "night_shift_set":
            return await callNightShiftSet(arguments)
        case "open_airplay_preferences":
            return await callOpenAirPlayPreferences()
        // Shortcuts + URL schemes
        case "list_shortcuts":
            return await callListShortcuts()
        case "run_shortcut":
            return await callRunShortcut(arguments)
        case "open_url_scheme":
            return await callOpenURLScheme(arguments)
        // Finder
        case "reveal_in_finder":
            return await callRevealInFinder(arguments)
        case "quick_look":
            return await callQuickLook(arguments)
        case "trash_file":
            return await callTrashFile(arguments)
        // Notification / Control Center
        case "notification_center_toggle":
            return await callNotificationCenterToggle()
        case "control_center_toggle":
            return await callControlCenterToggle()
        // Ergonomic input wrappers
        case "right_click":
            return await callRightClick(arguments)
        case "double_click":
            return await callDoubleClick(arguments)
        // MARK: - v0.5.0 Phase 8 — Apple apps + power + audio + dock + extended (20 tools)
        case "imessage_send":
            return await callIMessageSend(arguments)
        case "imessage_list_recent":
            return await callIMessageListRecent(arguments)
        case "mail_send":
            return await callMailSend(arguments)
        case "calendar_create_event":
            return await callCalendarCreateEvent(arguments)
        case "calendar_list_events":
            return await callCalendarListEvents(arguments)
        case "reminders_create":
            return await callRemindersCreate(arguments)
        case "reminders_list":
            return await callRemindersList(arguments)
        case "contacts_search":
            return await callContactsSearch(arguments)
        case "system_sleep":
            return await callSystemSleep()
        case "lock_screen":
            return await callLockScreen()
        case "system_restart":
            return await callSystemRestart(arguments)
        case "system_shutdown":
            return await callSystemShutdown(arguments)
        case "system_logout":
            return await callSystemLogout(arguments)
        case "list_audio_devices":
            return await callListAudioDevices()
        case "set_audio_output":
            return await callSetAudioOutput(arguments)
        case "set_audio_input":
            return await callSetAudioInput(arguments)
        case "mic_mute":
            return await callMicMute(arguments)
        case "wifi_scan":
            return await callWifiScan()
        case "wifi_join":
            return await callWifiJoin(arguments)
        case "set_focus_mode":
            return await callSetFocusMode(arguments)
        case "list_dock_items":
            return await callListDockItems()
        case "click_dock_item":
            return await callClickDockItem(arguments)
        // MARK: - v0.6.0 Phase 9 — reliability + observability substrate (10 tools)
        case "ground":
            return await callGround(arguments)
        case "ax_tree_augmented":
            return await callAXTreeAugmented(arguments)
        case "ax_snapshot_capture":
            return await callAXSnapshotCapture(arguments)
        case "ax_snapshot_diff":
            return await callAXSnapshotDiff(arguments)
        case "audit_log_append":
            return await callAuditLogAppend(arguments)
        case "audit_log_read":
            return await callAuditLogRead(arguments)
        case "agent_memory_store":
            return await callAgentMemoryStore(arguments)
        case "agent_memory_recall":
            return await callAgentMemoryRecall(arguments)
        case "redact_pii_text":
            return await callRedactPIIText(arguments)
        case "redact_image_regions":
            return await callRedactImageRegions(arguments)
        // MARK: - v0.7.0 Phase 10 — complete surface (13 tools)
        case "capture_screen_v2":
            return await callCaptureScreenV2(arguments)
        case "artifact_gc":
            return await callArtifactGC()
        case "undo_last_action":
            return await callUndoLastAction(arguments)
        case "undo_peek":
            return await callUndoPeek()
        case "speech_to_text":
            return await callSpeechToText(arguments)
        case "text_to_speech":
            return await callTextToSpeech(arguments)
        case "audio_record":
            return await callAudioRecord(arguments)
        case "record_screen":
            return await callRecordScreen(arguments)
        case "browser_dom_tree":
            return await callBrowserDOMTree(arguments)
        case "browser_visible_text":
            return await callBrowserVisibleText(arguments)
        case "browser_iframes":
            return await callBrowserIframes(arguments)
        case "list_app_intents":
            return await callListAppIntents()
        case "invoke_app_intent":
            return await callInvokeAppIntent(arguments)
        // MARK: - v0.9 workstream C — batch / composite call (C-1)
        case "batch":
            return await callBatch(arguments)
        // MARK: - v0.9 workstream F — annotated screenshot (C-13)
        case "capture_annotated":
            return await callCaptureAnnotated(arguments)
        // v0.9 workstream E — text editing primitives
        case "text_get_selection":
            return await callTextGetSelection(arguments)
        case "text_get_caret":
            return await callTextGetCaret(arguments)
        case "text_set_selection":
            return await callTextSetSelection(arguments)
        case "text_insert_at_caret":
            return await callTextInsertAtCaret(arguments)
        case "text_replace_range":
            return await callTextReplaceRange(arguments)
        case "text_get_value":
            return await callTextGetValue(arguments)
        default:
            return errorResult("Unknown tool '\(name)'.")
        }
    }

    private func callListElements(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("list_elements requires a positive integer pid.")
        }
        if let dead = noSuchProcessResult(pid: pid, tool: "list_elements") { return dead }

        let maxDepth = AXDepth.resolve(arguments["max_depth"]?.intValue)
        let elements = await accessibility.listElements(pid: pid, maxDepth: maxDepth)
        let budget = PayloadOptions(arguments, known: AXPayload.elementFields)

        // list_elements is already role-filtered to actionable controls,
        // so `interactive_only` is a no-op here; `viewport_only`,
        // `fields` and `max_bytes` still apply (v0.9 C-9).
        let windows = budget.viewportOnly ? await accessibility.windowFrames(pid: pid) : []
        let visible = budget.viewportOnly
            ? elements.filter {
                AXPayload.isInViewport(
                    frame: ToolRegistry.frame(position: $0.position, size: $0.size),
                    windows: windows
                )
            }
            : elements
        let encoded = visible.map { encodeElement(info: $0, id: nil, fields: budget.fields) }
        let budgeted = AXPayload.applyByteBudget(encoded, maxBytes: budget.maxBytes)

        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "pid": .number(Double(pid)),
            "max_depth": .number(Double(maxDepth)),
            "count": .number(Double(budgeted.items.count)),
            "elements": .array(budgeted.items)
        ]
        budget.annotate(
            &payload,
            maxDepthUsed: maxDepth,
            nodesVisited: elements.count,
            truncated: budgeted.truncated
        )
        if let hint = await axEmptyHint(pid: pid, whenEmpty: elements.isEmpty) {
            payload["ax_tree_hint"] = .string(hint)
        }
        return successResult("Found \(elements.count) actionable elements.", payload)
    }

    private func callFindElement(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("find_element requires a positive integer pid.")
        }
        if let dead = noSuchProcessResult(pid: pid, tool: "find_element") { return dead }

        if let error = validateSemantic(arguments) { return error }
        let role = arguments["role"]?.stringValue
        let title = arguments["title"]?.stringValue
        // v0.9 (A-9): opt-in equality matching. Default stays substring.
        let exact = AXPayload.flag(arguments["exact"])
        let maxDepth = AXDepth.resolve(arguments["max_depth"]?.intValue)

        let search = await accessibility.findElementsWithStats(
            pid: pid, role: role, title: title, value: arguments["value"]?.stringValue, exact: exact, maxDepth: maxDepth,
            limit: 1, semantic: arguments["semantic"]?.stringValue
        )
        guard let hit = search.matches.first else {
            var payload: [String: JSONValue] = [
                "ok": .bool(false),
                "pid": .number(Double(pid)),
                "role": role.map(JSONValue.string) ?? .null,
                "title": title.map(JSONValue.string) ?? .null,
                "exact": .bool(exact),
                "nodes_visited": .number(Double(search.nodesVisited)),
                "search_stopped_early": .bool(search.stoppedEarly),
                "truncated": .bool(search.truncated),
                "max_depth_used": .number(Double(maxDepth))
            ]
            if let hint = await axEmptyHint(pid: pid, whenEmpty: true) {
                payload["ax_tree_hint"] = .string(hint)
            }
            return errorResult("No matching element found.", payload)
        }

        let info = hit.info
        // v0.9 (C-5 / A-9): find_element now returns an element_id too,
        // so the cheapest entry-point tool no longer forces a second
        // find_elements call just to get a handle.
        let id = await elementCache.store(hit.element, pid: pid, path: hit.path)
        return successResult(
            "Element found.",
            [
                "ok": .bool(true),
                "pid": .number(Double(pid)),
                "element_id": .string(id),
                "exact": .bool(exact),
                "nodes_visited": .number(Double(search.nodesVisited)),
                "search_stopped_early": .bool(search.stoppedEarly),
                "truncated": .bool(search.truncated),
                "max_depth_used": .number(Double(maxDepth)),
                "matched_field": .string(hit.matchedField),
                "match": .string(hit.match),
                "rank_reason": .string(hit.rankReason),
                "element": encodeElement(info: info, id: id)
            ]
        )
    }

    /// BUG-FIX v0.2.6 #8: when a find/query/list returned empty we used
    /// to leave the caller guessing whether their filter was wrong or
    /// the app itself is AX-headless. We now probe the root of the app
    /// and surface a specific hint for Telegram-like apps (empty AX
    /// tree entirely) so agents stop spinning on queries that cannot
    /// succeed for the target bundle. Package-visible so `Tools+V2`
    /// can reuse it for findElements / queryElements.
    func axEmptyHint(pid: pid_t, whenEmpty: Bool) async -> String? {
        guard whenEmpty else { return nil }
        let health = await accessibility.probeAXTree(pid: pid)
        guard !health.hasAXTree else { return nil }
        return health.hint
    }

    /// Standalone probe tool — callers that want to check AX health
    /// *before* firing queries can call `probe_ax_tree` to know up front
    /// whether the app even has an accessibility surface.
    private func callProbeAXTree(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("probe_ax_tree requires a positive integer pid.")
        }
        let health = await accessibility.probeAXTree(pid: pid)
        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "pid": .number(Double(pid)),
            "has_ax_tree": .bool(health.hasAXTree),
            "child_count": .number(Double(health.childCount)),
            "window_count": .number(Double(health.windowCount))
        ]
        if let hint = health.hint { payload["hint"] = .string(hint) }
        let msg = health.hasAXTree
            ? "AX tree present (\(health.childCount) children, \(health.windowCount) windows)."
            : "App exposes no AX tree — see hint."
        return successResult(msg, payload)
    }

    private func callClick(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let pid = parsePID(arguments["pid"])

        if let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue {
            // Coordinate clicks are ALWAYS a synthetic CGEvent delivered to
            // whatever app is frontmost — guard right before injecting.
            if let mismatch = await checkFocusGuard(arguments) {
                return mismatch
            }

            let success = await accessibility.click(at: CGPoint(x: CGFloat(x), y: CGFloat(y)))
            var payload: [String: JSONValue] = [
                "x": .number(x),
                "y": .number(y)
            ]
            if let pid {
                payload["pid"] = .number(Double(pid))
            }
            if success {
                return successResult(
                    "Clicked at (\(x), \(y)).",
                    payload.merging(["ok": .bool(true)]) { _, new in new }
                )
            }

            return errorResult(
                "Failed to click at (\(x), \(y)).",
                payload.merging(["ok": .bool(false)]) { _, new in new }
            )
        }

        guard arguments["x"] == nil, arguments["y"] == nil else {
            return invalidArgument("click requires both x and y when using coordinates.")
        }

        guard let pid else {
            return invalidArgument("click requires a positive integer pid when clicking by role/title.")
        }

        let role = arguments["role"]?.stringValue
        let title = arguments["title"]?.stringValue

        guard role != nil || title != nil else {
            return invalidArgument("click requires role/title or x/y.")
        }

        guard let element = await accessibility.findElement(pid: pid, role: role, title: title) else {
            return errorResult(
                "No matching element to click.",
                [
                    "ok": .bool(false),
                    "pid": .number(Double(pid)),
                    "role": role.map(JSONValue.string) ?? .null,
                    "title": title.map(JSONValue.string) ?? .null
                ]
            )
        }

        // AXPress acts on the element handle directly — it does not depend
        // on which app is frontmost, so it needs no focus guard. Only the
        // coordinate-click fallback (bug #5, when AXPress is unsupported)
        // is a synthetic CGEvent that depends on focus; the guard is
        // applied right before that fallback fires, not before AXPress.
        let axOutcome = await accessibility.pressElementViaAX(element: element)
        let success: Bool
        switch axOutcome {
        case .succeeded:
            success = true
        case .disabled:
            success = false
        case .unsupported:
            if let mismatch = await checkFocusGuard(arguments) {
                return mismatch
            }
            success = await accessibility.clickElementCoordinateFallback(element: element)
        }

        if success {
            return successResult(
                "Element clicked.",
                [
                    "ok": .bool(true),
                    "pid": .number(Double(pid)),
                    "role": role.map(JSONValue.string) ?? .null,
                    "title": title.map(JSONValue.string) ?? .null
                ]
            )
        }

        return errorResult(
            "Failed to click matching element.",
            [
                "ok": .bool(false),
                "pid": .number(Double(pid)),
                "role": role.map(JSONValue.string) ?? .null,
                "title": title.map(JSONValue.string) ?? .null
            ]
        )
    }

    private func callTypeText(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let text = arguments["text"]?.stringValue else {
            return invalidArgument("type_text requires text.")
        }

        // BUG-FIX v0.2.6 #6: let callers pick the typing strategy.
        // `auto` (default) now tries clipboard → keys → ax for event
        // fidelity on React/Angular SPAs. See TypeStrategy docs in
        // AccessibilityController.swift.
        let strategyArg = arguments["strategy"]?.stringValue
        guard let strategy = AccessibilityController.TypeStrategy.resolve(argument: strategyArg) else {
            return invalidArgument(
                "type_text strategy must be one of: auto, clipboard, keys, ax (got '\(strategyArg ?? "")')."
            )
        }

        // `.ax` (explicit AX set_value) acts on the currently-focused
        // element's attribute directly and posts no CGEvent, so it does
        // not depend on which app is frontmost — skip the guard for it,
        // same reasoning as AXPress in `callClick`. `.auto` / `.clipboard`
        // / `.keys` all attempt a synthetic event first (clipboard paste
        // or CGEvent unicode) even though `.auto` may itself fall back to
        // `.ax` internally, so they're guarded conservatively.
        if strategy != .ax, let mismatch = await checkFocusGuard(arguments) {
            return mismatch
        }

        let result = await accessibility.typeText(text: text, strategy: strategy)
        if result.success {
            return successResult(
                "Text typed using \(result.strategy).",
                [
                    "ok": .bool(true),
                    "strategy": .string(result.strategy),
                    "requested_strategy": .string(strategy.rawValue),
                    "text_length": .number(Double(text.count))
                ]
            )
        }

        return errorResult(
            "Failed to type text (requested strategy=\(strategy.rawValue)).",
            [
                "ok": .bool(false),
                "strategy": .string(result.strategy),
                "requested_strategy": .string(strategy.rawValue),
                "text_length": .number(Double(text.count))
            ]
        )
    }

    private func callReadValue(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("read_value requires a positive integer pid.")
        }

        guard let role = arguments["role"]?.stringValue, !role.isEmpty else {
            return invalidArgument("read_value requires role.")
        }

        guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
            return invalidArgument("read_value requires title.")
        }

        guard let element = await accessibility.findElement(pid: pid, role: role, title: title) else {
            return errorResult(
                "No matching element found.",
                [
                    "ok": .bool(false),
                    "pid": .number(Double(pid)),
                    "role": .string(role),
                    "title": .string(title)
                ]
            )
        }

        guard let value = await accessibility.readValue(element: element) else {
            return errorResult(
                "Element has no readable value.",
                [
                    "ok": .bool(false),
                    "pid": .number(Double(pid)),
                    "role": .string(role),
                    "title": .string(title)
                ]
            )
        }

        return successResult(
            "Read element value.",
            [
                "ok": .bool(true),
                "pid": .number(Double(pid)),
                "role": .string(role),
                "title": .string(title),
                "value": .string(value)
            ]
        )
    }

    private func callPressKey(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let key = arguments["key"]?.stringValue, !key.isEmpty else {
            return invalidArgument("press_key requires key.")
        }

        guard let keyCode = KeyCodeMap.keyCode(for: key) else {
            return invalidArgument("Unsupported key '\(key)'.")
        }

        let modifierParse = parseModifiers(arguments["modifiers"])
        switch modifierParse {
        case .failure(let error):
            return invalidArgument(error.description)
        case .success(let modifiers):
            if let mismatch = await checkFocusGuard(arguments) {
                return mismatch
            }

            let pressed = await accessibility.pressKey(keyCode: keyCode, modifiers: modifiers)
            if pressed {
                return successResult(
                    "Key press sent.",
                    [
                        "ok": .bool(true),
                        "key": .string(key),
                        "key_code": .number(Double(keyCode)),
                        "modifiers": .array((arguments["modifiers"]?.arrayValue ?? []).compactMap { value in
                            value.stringValue.map(JSONValue.string)
                        })
                    ]
                )
            }

            return errorResult(
                "Failed to send key press.",
                [
                    "ok": .bool(false),
                    "key": .string(key),
                    "key_code": .number(Double(keyCode))
                ]
            )
        }
    }

    private func callFocusedApp() async -> ToolCallResult {
        guard let app = await accessibility.getFocusedApp() else {
            return errorResult("No focused app detected.", ["ok": .bool(false)])
        }

        return successResult(
            "Focused app retrieved.",
            [
                "ok": .bool(true),
                "app": encodeAsJSONValue(app)
            ]
        )
    }

    private func callListApps() async -> ToolCallResult {
        let apps = await accessibility.listApps()
        return successResult(
            "Listed \(apps.count) running apps.",
            [
                "ok": .bool(true),
                "count": .number(Double(apps.count)),
                "apps": encodeAsJSONValue(apps)
            ]
        )
    }

    func parsePID(_ value: JSONValue?) -> pid_t? {
        guard let integer = value?.intValue, integer > 0, integer <= Int(Int32.max) else {
            return nil
        }
        return pid_t(integer)
    }

    /// v0.9 (A-8): `find_element`/`find_elements`/`get_ui_tree`/
    /// `list_elements` used to send a pid that belongs to no running
    /// process straight into the AX walk, which came back with the same
    /// "app exposes no AX children or windows" hint a genuinely
    /// AX-headless *running* app gets — indistinguishable from a plain
    /// typo/stale pid. `kill(pid, 0)` sends no signal, just probes
    /// whether the process exists (ESRCH => it doesn't); it works for
    /// any process, not only ones NSRunningApplication tracks (GUI apps
    /// registered with the WindowServer).
    func isRunningProcess(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// Structured `error_code: no_such_process` payload for the AX-tool
    /// family above. `nil` when the pid is alive — callers proceed as
    /// before.
    func noSuchProcessResult(pid: pid_t, tool: String) -> ToolCallResult? {
        guard !isRunningProcess(pid) else { return nil }
        return errorResult(
            "\(tool): no running process with pid \(pid).",
            [
                "ok": .bool(false),
                "pid": .number(Double(pid)),
                "error_code": .string("no_such_process")
            ]
        )
    }

    struct ToolInputError: Error, CustomStringConvertible {
        let description: String
    }

    /// Parse a JSON modifiers array. Delegates name→flag mapping to the
    /// shared `ModifierMap` (see Tools+V2Phase5.swift) so key_down/key_up/
    /// press_key_sequence and press_key all use the exact same parsing.
    private func parseModifiers(_ rawValue: JSONValue?) -> Result<[CGEventFlags], ToolInputError> {
        guard let rawValue else { return .success([]) }
        guard let values = rawValue.arrayValue else {
            return .failure(ToolInputError(description: "modifiers must be an array of strings."))
        }

        var flags: [CGEventFlags] = []
        var unknown: [String] = []

        for value in values {
            guard let modifier = value.stringValue else {
                return .failure(ToolInputError(description: "modifiers must be an array of strings."))
            }

            if let flag = ModifierMap.flag(for: modifier) {
                flags.append(flag)
            } else {
                unknown.append(modifier)
            }
        }

        if !unknown.isEmpty {
            return .failure(ToolInputError(description: "Unknown modifiers: \(unknown.joined(separator: ", "))."))
        }

        return .success(flags)
    }

    func invalidArgument(_ message: String) -> ToolCallResult {
        errorResult(message, ["ok": .bool(false), "error": .string(message)])
    }

    func errorResult(_ message: String, _ payload: [String: JSONValue] = [:]) -> ToolCallResult {
        ToolCallResult(text: message, structuredContent: .object(payload), isError: true)
    }

    func successResult(_ message: String, _ payload: [String: JSONValue]) -> ToolCallResult {
        ToolCallResult(text: message, structuredContent: .object(payload), isError: false)
    }

    /// Input-focus guard for tools that inject synthetic CGEvent
    /// keyboard/mouse input. Synthetic input always goes to whatever app
    /// is frontmost *at delivery time* — not whatever the caller last
    /// observed — so when another app steals focus between a caller's
    /// check and its keystroke, the input lands in the wrong window.
    /// (Measured: two concurrent MCP clients both driving this server —
    /// a `press_key` cmd+a/cmd+v landed in the wrong app.)
    ///
    /// Call this immediately before injecting synthetic input. Returns
    /// `nil` when the caller omitted both `expected_app` and
    /// `expected_window` (the guard is opt-in and existing behaviour is
    /// unchanged), or when the actual focus matches. Returns a
    /// `focus_mismatch` error result — inject nothing — on mismatch.
    func checkFocusGuard(_ arguments: [String: JSONValue]) async -> ToolCallResult? {
        let expectedApp = arguments["expected_app"]?.stringValue
        let expectedWindow = arguments["expected_window"]?.stringValue

        let actual = await FocusGuard.currentFocus()
        let outcome = FocusGuard.evaluate(
            expectedApp: expectedApp,
            expectedWindow: expectedWindow,
            actualAppName: actual.appName,
            actualBundleIdentifier: actual.bundleIdentifier,
            actualWindowTitle: actual.windowTitle
        )

        guard case .mismatch(let reason) = outcome else {
            return nil
        }

        var actualAppDescription = actual.appName ?? "unknown"
        if let bundle = actual.bundleIdentifier {
            actualAppDescription += " (\(bundle))"
        }
        if let pid = actual.pid {
            actualAppDescription += " pid \(pid)"
        }

        var payload: [String: JSONValue] = [
            "ok": .bool(false),
            "error_code": .string("focus_mismatch"),
            "error": .string(reason),
            "actual_app": .string(actualAppDescription),
            "actual_window": actual.windowTitle.map(JSONValue.string) ?? .null,
            "hint": .string(
                "Frontmost app/window changed since your last check. Call activate_app / "
                    + "focus_window to bring the expected target back to front and retry, or — "
                    + "when you already have an AX element handle — prefer perform_element_action "
                    + "(AXPress) / set_element_attribute (AXValue), which act on that element "
                    + "directly and do not depend on what is frontmost."
            )
        ]
        if let expectedApp {
            payload["expected_app"] = .string(expectedApp)
        }
        if let expectedWindow {
            payload["expected_window"] = .string(expectedWindow)
        }

        return errorResult(reason, payload)
    }

    static func schema(properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false)
        ]

        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }

        return .object(schema)
    }

    private static let definitions: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "list_elements",
            description: "Survey the ACTIONABLE controls of an app (fixed role whitelist: buttons, links, text fields/areas, checkboxes, radio buttons, pop-up/menu buttons, sliders, switches, steppers… — no containers, rows or static text) down to max_depth (default 24). "
                + "No filters and no element ids. Use it to answer \"what can I interact with here?\"; use find_elements / query_elements to target specific elements and get ids for follow-up calls, and get_ui_tree for the full structure including containers. " + axPayloadBudgetDoc,
            inputSchema: schema(
                properties: [
                    "pid": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Target process ID.")
                    ]),
                    "max_depth": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Traversal depth limit. Default 24 (project-wide AX default), max 64.")
                    ]),
                    "fields": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Payload budget (v0.9): only emit these per-node keys. Default: all of id, role, title, value, position, size, depth.")
                    ]),
                    "interactive_only": .object([
                        "type": .string("boolean"),
                        "description": .string("Payload budget: keep only actionable roles (buttons, links, fields, checkboxes, …). Default false.")
                    ]),
                    "viewport_only": .object([
                        "type": .string("boolean"),
                        "description": .string("Payload budget: drop nodes whose frame lies outside the app's on-screen window bounds. Default false.")
                    ]),
                    "max_bytes": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Payload budget: soft cap on the encoded element/node bytes. Emission stops when the next item would exceed it and truncated=true is returned. Default: no cap.")
                    ])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "find_element",
            description: "Find one element with a stable element_id (max_depth default 24). Without semantic, return the first exact hit outside menus; otherwise rank the bounded traversal. " + axSearchDoc + axSemanticDoc,
            inputSchema: schema(
                properties: [
                    "pid": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Target process ID.")
                    ]),
                    "semantic": .object(["type": .string("string"), "description": .string(axSemanticDoc)]),
                    "value": .object(["type": .string("string"), "description": .string("Case-insensitive value filter.")]),
                    "role": .object([
                        "type": .string("string"),
                        "description": .string("Exact case-insensitive role name; Button is normalized to AXButton.")
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Case-insensitive title filter (substring unless exact=true).")
                    ]),
                    "exact": .object([
                        "type": .string("boolean"),
                        "description": .string("Match title/value by case-insensitive equality; roles always use exact normalized names.")
                    ]),
                    "max_depth": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Traversal depth limit. Default 24 (project-wide AX default), max 64.")
                    ])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "click",
            description: "Click an element by role/title or click absolute coordinates. "
                + "Coordinate clicks post a synthetic CGEvent that always lands on the "
                + "frontmost app — pass expected_app/expected_window to abort instead of "
                + "clicking the wrong window if focus changed. Role/title clicks try AXPress "
                + "first (focus-independent) and only fall back to a coordinate CGEvent click "
                + "when AXPress is unsupported on that element — expected_app/expected_window "
                + "is checked only if/when that fallback fires. Prefer perform_element_action "
                + "(AXPress) directly when you already have an element handle.",
            inputSchema: schema(
                properties: [
                    "pid": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Target process ID when clicking by selector.")
                    ]),
                    "role": .object([
                        "type": .string("string")
                    ]),
                    "title": .object([
                        "type": .string("string")
                    ]),
                    "x": .object([
                        "type": .string("number")
                    ]),
                    "y": .object([
                        "type": .string("number")
                    ]),
                    "expected_app": .object([
                        "type": .string("string"),
                        "description": .string("Bundle id or localized app name expected to be frontmost. On mismatch, nothing is clicked.")
                    ]),
                    "expected_window": .object([
                        "type": .string("string"),
                        "description": .string("Case-insensitive substring expected in the focused window title. On mismatch, nothing is clicked.")
                    ])
                ]
            )
        ),
        MCPToolDefinition(
            name: "type_text",
            description: "Type text into the currently focused field. "
                + "Strategies: auto (clipboard → keys → ax, default; best for React/Angular SPAs), "
                + "clipboard (paste events), keys (CGEvent unicode), ax (AX set_value last-resort). "
                + "auto/clipboard/keys post synthetic events and are checked against "
                + "expected_app/expected_window before typing; strategy=ax sets the value "
                + "directly and is not checked, since it does not depend on focus. Prefer "
                + "set_element_attribute (AXValue) directly when you already have an element handle.",
            inputSchema: schema(
                properties: [
                    "text": .object([
                        "type": .string("string")
                    ]),
                    "strategy": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("auto"),
                            .string("clipboard"),
                            .string("keys"),
                            .string("ax")
                        ]),
                        "default": .string("auto")
                    ]),
                    "expected_app": .object([
                        "type": .string("string"),
                        "description": .string("Bundle id or localized app name expected to be frontmost. On mismatch, nothing is typed.")
                    ]),
                    "expected_window": .object([
                        "type": .string("string"),
                        "description": .string("Case-insensitive substring expected in the focused window title. On mismatch, nothing is typed.")
                    ])
                ],
                required: ["text"]
            )
        ),
        MCPToolDefinition(
            name: "read_value",
            description: "Read kAXValueAttribute from a matching element.",
            inputSchema: schema(
                properties: [
                    "pid": .object([
                        "type": .array([.string("integer"), .string("string")])
                    ]),
                    "role": .object([
                        "type": .string("string")
                    ]),
                    "title": .object([
                        "type": .string("string")
                    ])
                ],
                required: ["pid", "role", "title"]
            )
        ),
        MCPToolDefinition(
            name: "press_key",
            description: "Send a keyboard key with optional modifiers. Posts a synthetic CGEvent "
                + "that always lands on the frontmost app — pass expected_app/expected_window to "
                + "abort instead of sending a key (e.g. cmd+a/cmd+v) to the wrong window if focus "
                + "changed since your last check. Prefer perform_element_action when the effect "
                + "you want is available as an AX action on a known element.",
            inputSchema: schema(
                properties: [
                    "key": .object([
                        "type": .string("string")
                    ]),
                    "modifiers": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string")
                        ])
                    ]),
                    "expected_app": .object([
                        "type": .string("string"),
                        "description": .string("Bundle id or localized app name expected to be frontmost. On mismatch, no key is sent.")
                    ]),
                    "expected_window": .object([
                        "type": .string("string"),
                        "description": .string("Case-insensitive substring expected in the focused window title. On mismatch, no key is sent.")
                    ])
                ],
                required: ["key"]
            )
        ),
        MCPToolDefinition(
            name: "focused_app",
            description: "Get metadata for NSWorkspace.shared.frontmostApplication.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "list_apps",
            description: "List running regular applications.",
            inputSchema: schema(properties: [:])
        )
    ]
}

enum KeyCodeMap {
    static let values: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50,
        "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "forward_delete": 117,
        "home": 115, "end": 119, "page_up": 116, "page_down": 121,
        "left": 123, "left_arrow": 123, "right": 124, "right_arrow": 124,
        "down": 125, "down_arrow": 125, "up": 126, "up_arrow": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        // Physical modifier keys — for key_down/key_up to hold/release
        // shift/control/etc. Separate from ModifierMap (which maps names
        // to CGEventFlags for combining with other keys).
        "shift": 56, "left_shift": 56, "right_shift": 60,
        "control": 59, "left_control": 59, "right_control": 62, "ctrl": 59,
        "option": 58, "left_option": 58, "right_option": 61, "alt": 58,
        "command": 55, "left_command": 55, "right_command": 54, "cmd": 55,
        "fn": 63, "function": 63,
        "caps_lock": 57, "caps": 57
    ]

    static func keyCode(for key: String) -> CGKeyCode? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return values[normalized]
    }
}
