# Tool Reference

Auto-generated from `ToolRegistry.toolDefinitions` — the exact list the
running server returns from `tools/list`. **Do not hand-edit.** Regenerate with:

```bash
UPDATE_TOOL_DOCS=1 swift test --filter ToolDocsDriftTests
```

<!-- tool-count -->143<!-- /tool-count --> tools total.

| Tool | Description | Required params | Optional params |
|---|---|---|---|
| `activate_app` | Bring a running app to the front by PID or bundle ID. | — | `bundle_id`, `pid` |
| `agent_memory_recall` | Recall memory entries by substring + optional tag. Case-insensitive. Returns freshest first. | `query` | `limit`, `tag` |
| `agent_memory_store` | Store a key/value memory entry with optional tags (A-Mem pattern). Persisted to ~/.mac-control-mcp/memory.jsonl. Multiple entries with same key coexist; recall returns freshest first. | `key`, `value` | `tags` |
| `app_expose` | Show every window of the frontmost app (App Exposé). Equivalent of Ctrl+Down. | — | — |
| `artifact_gc` | Force a sweep of expired artifacts at ~/.mac-control-mcp/artifacts/ (normally auto-swept on every store). | — | — |
| `audio_record` | Record <seconds> of microphone audio to an M4A file. Triggers Microphone TCC prompt on first use. Default output ~/Desktop/mac-control-mcp-<ts>.m4a. | `seconds` | `output_path` |
| `audit_log_append` | Append a structured entry to the audit log at ~/.mac-control-mcp/audit.jsonl. Use for recording tool calls, grants, revocations, or custom events. | `event` | `bundle_id`, `metadata`, `result`, `tool` |
| `audit_log_read` | Read entries from the audit log with optional since/filter. Returns newest-first up to limit (default 500, max capped). | — | `filter_event`, `filter_tool`, `limit`, `since_iso` |
| `ax_snapshot_capture` | Capture the current AX tree of a process into a named snapshot for later diffing. Returns snapshot_id. LRU queue of 16. | `pid` | `max_depth` |
| `ax_snapshot_diff` | Diff two previously-captured AX snapshots. Returns added / removed / changed node lists. Lets agents observe UI change after an action without re-screenshoting. | `from`, `to` | — |
| `ax_tree_augmented` | AX tree walk augmented with OCR-derived labels for unlabeled elements. ONE OCR pass + geometric join (not per-node OCR). Useful for Electron/Chromium/Canvas apps where native AX is sparse. Trimmed to max_nodes (default 300, range 50-1000) with labelled elements preferred over unlabelled when truncating. | `pid` | `max_depth`, `max_nodes` |
| `battery_status` | Return battery percentage, charging state, plugged-in state, and time-remaining estimate (desktop Macs report nil fields). | — | — |
| `bluetooth_devices` | List paired Bluetooth devices — name, address, connected state. Slow (~1-2s) because it goes through system_profiler. | — | — |
| `bluetooth_set` | Turn Bluetooth on/off/toggle. Requires 'blueutil' (brew install blueutil) — returns a hint with install instructions when missing. | `state` | — |
| `browser_close_tab` | Close a tab by window/tab index, or the current tab when omitted. | — | `browser`, `tab_index`, `window_index` |
| `browser_dom_tree` | Walk the DOM of the active tab INCLUDING Shadow DOM and open shadow roots. Returns a tree of {tag, id, classes, text, role, isShadow, children}. Works in Safari + Chrome via browser_eval_js under the hood. | — | `browser` |
| `browser_eval_js` | Evaluate JavaScript in a Safari/Chrome tab and return the result as a string. Requires 'Allow JavaScript from Apple Events' in the browser's Develop menu. | `code` | `browser`, `tab_index`, `window_index` |
| `browser_get_active_tab` | Return metadata for the active tab of Safari or Chrome's frontmost window. | — | `browser` |
| `browser_iframes` | List every <iframe>, same-origin status, size, and (when same-origin) a text summary of its contentDocument. Cross-origin iframes fail-closed with sameOrigin=false. | — | `browser` |
| `browser_list_tabs` | List all tabs of Safari or Chrome with window/tab index, title, URL, and active flag. | — | `browser` |
| `browser_navigate` | Point a tab at a new URL. Defaults to active tab of the front window. | `url` | `browser`, `tab_index`, `window_index` |
| `browser_new_tab` | Open a new tab in Safari or Chrome's front window, optionally navigating to a URL. | — | `browser`, `url` |
| `browser_visible_text` | Return all currently-visible text (filters display:none and visibility:hidden). Faster than dom_tree when you just want 'what does the user see'. | — | `browser` |
| `calendar_create_event` | Create a Calendar event. start_iso + end_iso must be ISO-8601. Optional 'calendar' targets a specific calendar by name. | `end_iso`, `start_iso`, `summary` | `calendar` |
| `calendar_list_events` | List upcoming events across all calendars. horizon_days clamps to 1-90 (default 7). | — | `horizon_days` |
| `capture_display` | Screenshot a specific display by its index from list_displays. | `display_index` | `output_path` |
| `capture_screen` | Capture the main display (or a rectangular region) to a PNG file and return its path, width, and height. | — | `height`, `output_path`, `width`, `x`, `y` |
| `capture_screen_v2` | Capture the main display, store as a content-addressed artifact at ~/.mac-control-mcp/artifacts/<sha256>.png, and return {content_ref, bytes, sha256}. Default inline=false prevents context-size blowups (claude-code #13383, #45785). Optional max_dimension (default 4000px) and max_bytes (default 4MB) downscale before return. | — | `inline`, `max_bytes`, `max_dimension` |
| `capture_window` | Screenshot a specific window of an app by PID (and optional title filter). | `pid` | `output_path`, `title_contains` |
| `click` | Click an element by role/title or click absolute coordinates. | — | `pid`, `role`, `title`, `x`, `y` |
| `click_dock_item` | Click a Dock item by title (case-insensitive substring match). Triggers the app/folder/document exactly like a user click would. | `title` | — |
| `click_menu_path` | Click a menu item by title path, e.g. path=["File","Export","PDF..."]. | `path`, `pid` | — |
| `clipboard_clear` | Clear the clipboard. | — | — |
| `clipboard_read` | Read the current clipboard as text and list all available pasteboard types. | — | — |
| `clipboard_write` | Replace the clipboard with plain text. | `text` | — |
| `contacts_search` | Search Contacts by name substring. Returns phones + emails — perfect input for imessage_send / mail_send. | `query` | `limit` |
| `control_center_toggle` | Open/close Control Center (the top-right icon popover). Clicks the menu-bar item directly. | — | — |
| `convert_coordinates` | Convert coordinates between coordinate spaces: 'global' (default) or 'display:<index>'. | `from`, `to`, `x`, `y` | — |
| `deny_access` | Add bundle_id to the deny list. Overrides any existing grant; the check endpoint returns reason='denied' for this bundle. Deny entries self-heal after 30 days. | `bundle_id` | `reason` |
| `disk_usage` | Per-volume disk usage — mount point, total/used/available GB, used %. | — | — |
| `double_click` | Double-click at coordinates. Ergonomic wrapper around mouse_event with action='double_click'. | `x`, `y` | `button` |
| `drag_and_drop` | Click-and-drag from (x1,y1) to (x2,y2). Supports left/right/center button and step count for smoothness. | `x1`, `x2`, `y1`, `y2` | `button`, `steps` |
| `file_dialog_cancel` | Dismiss the frontmost Open/Save dialog via Escape. Equivalent to file_dialog_confirm with cancel=true. | — | — |
| `file_dialog_confirm` | Commit the frontmost Open/Save dialog (Return). Pass cancel=true to dismiss via Escape instead. | — | `cancel` |
| `file_dialog_select_item` | Select a file or folder by title in the frontmost Open/Save dialog. | `title` | — |
| `file_dialog_set_path` | Type a path into the frontmost Open/Save dialog via the 'Go to folder' shortcut (Cmd+Shift+G). | `path` | — |
| `find_element` | Find a matching accessibility element by role/title. | `pid` | `role`, `title` |
| `find_elements` | Find all matching accessibility elements (not just the first) by role/title/value. | `pid` | `limit`, `max_depth`, `role`, `title`, `value` |
| `focus_window` | Bring a window to the front by pid + window index (from list_windows). | `index`, `pid` | — |
| `focused_app` | Get metadata for NSWorkspace.shared.frontmostApplication. | — | — |
| `force_quit_app` | Force-terminate an app by PID or bundle ID. Equivalent to quit_app with force=true. | — | `bundle_id`, `pid` |
| `foundation_models_generate` | Generate text via Apple's Foundation Models framework (macOS Tahoe 26+, Apple Intelligence). On-device, free, offline. Gracefully reports 'not available' when framework missing. | `prompt` | `system` |
| `get_element_attributes` | Read one or more AX attributes for a cached element ID. Pass names=[] to list available attribute names. | `element_id` | `names` |
| `get_ui_tree` | Walk the full accessibility tree of a process and return every node (including containers) with stable element IDs for follow-up calls. | `pid` | `max_depth` |
| `ground` | Mixture-of-grounding: find screen coordinates for a target text. Strategy: 'ax' (fastest, structured), 'ocr' (works on any app including Electron/Canvas), 'auto' (AX first, OCR fallback). Returns (x,y) with confidence 0..1 + candidate list. | `pid`, `target` | `strategy` |
| `imessage_list_recent` | List recent iMessage threads by participant. Does not return message bodies (would require Full Disk Access). | — | `limit` |
| `imessage_send` | Send an iMessage to a phone number or email. Triggers the Messages automation permission prompt on first use. | `body`, `to` | — |
| `invoke_app_intent` | Invoke a named App Intent by routing through /usr/bin/shortcuts. User must have a Shortcut with the exact intent name. Returns stdout of the shortcut invocation. | `bundle_id`, `intent` | `input` |
| `key_down` | Post a key-down event without releasing. Pair with key_up. | `key` | `modifiers` |
| `key_up` | Post a key-up event to release a previously held key. | `key` | `modifiers` |
| `launch_app` | Launch an application by bundle ID, absolute path, or app name. Accepts `identifier` (canonical) or `bundle_id` (alias — same meaning, aligns with activate_app/quit_app/wait_for_app). | — | `bundle_id`, `identifier` |
| `launchpad` | Open Launchpad. Equivalent of F4. | — | — |
| `list_app_intents` | Enumerate installed apps that ship App Intents metadata (via Info.plist AppShortcuts / Intents keys). Returns {bundleId, appName, intentCount}. | — | — |
| `list_apps` | List running regular applications. | — | — |
| `list_audio_devices` | List every audio input + output device with current-selection flag. Requires 'switchaudio-osx' (brew install switchaudio-osx). | — | — |
| `list_displays` | List all connected displays with bounds, scale factor, and main-display flag. | — | — |
| `list_dock_items` | Enumerate the Dock's items via AX — app/folder/file names as they appear in the Dock. | — | — |
| `list_elements` | List actionable accessibility elements for a process ID. | `pid` | `max_depth` |
| `list_granted_applications` | List every live permission grant (expired grants are filtered out). Includes denied entries so callers can see the deny list too. | — | — |
| `list_menu_paths` | Enumerate every menu path in an app's menubar, up to max_depth. | `pid` | `max_depth` |
| `list_menu_titles` | List top-level menubar titles for an app — useful for discovery before click_menu_path. Omit pid to use the frontmost app. | — | `pid` |
| `list_shortcuts` | Enumerate every shortcut defined in Shortcuts.app. Returns names that can be passed to run_shortcut. | — | — |
| `list_windows` | List all windows of all running regular apps (or one app if pid is provided). | — | `pid` |
| `lock_screen` | Lock the screen (display sleep + FileVault lock). | — | — |
| `mail_send` | Compose + send an email via Mail.app. Supports TO/CC/BCC (comma-sep), subject, body. Set send_now=false to save as draft and open Mail. | `body`, `subject`, `to` | `bcc`, `cc`, `send_now` |
| `mcp_server_info` | Self-diagnostic: returns mac-control-mcp version, this process PID, binary path, uptime, and any OTHER mac-control-mcp processes running on this machine (Claude Desktop occasionally leaves zombie instances after extension reload — this surfaces them). | — | — |
| `mic_mute` | Mute or unmute the system input (microphone). mute=true sets input volume to 0; mute=false sets it to 100. | `mute` | — |
| `mission_control` | Toggle Mission Control (all windows across Spaces). Equivalent of F3 / Ctrl+Up. | — | — |
| `mouse_event` | Low-level mouse event: move, click, double_click, triple_click. Use for precise positional input when AX element-based click is not possible. | `action`, `x`, `y` | `button` |
| `move_window` | Move a window to an absolute (x,y) position in global coordinates. | `index`, `pid`, `x`, `y` | — |
| `move_window_to_display` | Move a window to the specified display (by display_index), preserving its size. | `display_index`, `index`, `pid` | — |
| `network_info` | Active Wi-Fi SSID + interface + every network interface's IP/MAC address. | — | — |
| `night_shift_set` | Turn Night Shift on/off/toggle. Requires 'nightlight' (brew install smudge/smudge/nightlight) — returns a hint when missing. | `state` | — |
| `notification_center_toggle` | Open/close Notification Center (right-edge panel). Uses Fn+F12 via System Events. | — | — |
| `ocr_screen` | Capture the screen (or a region) and run OCR. Returns joined text plus per-block coordinates and confidence. Coordinates are in IMAGE PIXELS matching image_width/image_height (i.e. backing resolution — 2x point size on Retina), for annotating/cropping the returned image. For click-ready screen points, use the `ground` tool with strategy 'ocr' instead. | — | `height`, `keep_image`, `languages`, `width`, `x`, `y` |
| `open_airplay_preferences` | Open the Displays preference pane so the user can start/stop AirPlay mirroring. macOS has no sanctioned AirPlay CLI. | — | — |
| `open_permission_pane` | Open a specific System Settings → Privacy & Security pane so the user can grant (or revoke) access for mac-control-mcp. Returns the URL opened and the current authorization status if known. | `pane` | — |
| `open_url_scheme` | Open any macOS URL scheme (x-apple.systempreferences://, shortcuts://, obsidian://, mailto:, ...). Wraps /usr/bin/open. | `url` | — |
| `perform_element_action` | Invoke an AX action on a cached element ID (AXPress, AXShowMenu, AXIncrement, AXDecrement, AXCancel, AXRaise, etc). Omit action to list available actions. | `element_id` | `action` |
| `permissions_status` | Report the accessibility permission state for this process. | — | — |
| `press_key` | Send a keyboard key with optional modifiers. | `key` | `modifiers` |
| `press_key_sequence` | Press multiple keys in order. Each step is {key, modifiers?}. | `steps` | `delay_ms` |
| `probe_ax_tree` | Check whether an app exposes an AX tree. Returns has_ax_tree=false + an actionable hint for apps that don't implement NSAccessibility (e.g. native Telegram) so callers can skip fruitless find/query loops. | `pid` | — |
| `query_elements` | Regex search over role/title/value. Invalid regex falls back to case-insensitive substring. | `pid` | `limit`, `max_depth`, `role_regex`, `title_regex`, `value_regex` |
| `quick_look` | Open a QuickLook preview window for the given file. 'timeout_seconds' (default 10, max 120) keeps the preview on screen; after that it auto-closes. | `path` | `timeout_seconds` |
| `quit_app` | Quit an app by PID or bundle ID. Pass force=true for forceTerminate. | — | `bundle_id`, `force`, `pid` |
| `read_value` | Read kAXValueAttribute from a matching element. | `pid`, `role`, `title` | — |
| `record_screen` | Record <seconds> of main-display video via /usr/sbin/screencapture (sanctioned macOS binary; auto-handles TCC). MP4 output. | `seconds` | `include_audio`, `output_path` |
| `redact_image_regions` | Blur or black-out rectangular regions in an image. regions: list of {x, y, width, height} in CG coordinates (top-left). mode: 'blur' (pixelate) or 'black' (solid fill). Output written to source-redacted.png next to source, or explicit output_path. | `path`, `regions` | `mode`, `output_path` |
| `redact_pii_text` | Replace PII patterns with [REDACTED:<category>]. Categories: email, phone, ssn, creditCard (Luhn-validated), apiKey (AWS/Stripe/GitHub/Anthropic/OpenAI/JWT). | `text` | `categories` |
| `reminders_create` | Create a reminder in Reminders.app. Optional due_iso (ISO-8601) and list (default: 'default list'). | `title` | `due_iso`, `list` |
| `reminders_list` | List reminders across all lists. include_completed=false (default) hides completed items. | — | `include_completed`, `limit` |
| `request_access` | Grant a per-app permission tier (view \| click \| full) to the given bundle id for a bounded TTL. Writes to ~/.mac-control-mcp/permissions.json. | `bundle_id`, `tier` | `reason`, `ttl_seconds` |
| `request_permissions` | Prompt the user for Accessibility permission (shows system dialog). | — | — |
| `resize_window` | Resize a window to the given width and height. | `height`, `index`, `pid`, `width` | — |
| `reveal_in_finder` | Open Finder and select the file at the given path (reveal ≠ open). | `path` | — |
| `revoke_access` | Remove a grant (or deny entry) for bundle_id. Idempotent — missing entries are a no-op. | `bundle_id` | — |
| `right_click` | Right-click (secondary button) at coordinates. Ergonomic wrapper around mouse_event. | `x`, `y` | — |
| `run_shortcut` | Invoke a Shortcut by its exact name. Optional 'input' is piped as the shortcut's 'Shortcut Input' magic variable. | `name` | `input` |
| `scroll` | Scroll wheel event. Positive delta_y scrolls up, negative scrolls down. Optional x/y targets the cursor position. | — | `delta_x`, `delta_y`, `x`, `y` |
| `scroll_to_element` | Scroll until an AX element matching role/title is visible. Returns its element_id. | `pid` | `max_scrolls`, `role`, `title` |
| `set_audio_input` | Switch system input device (microphone) by exact name. | `name` | — |
| `set_audio_output` | Switch system output device by exact name from list_audio_devices. | `name` | — |
| `set_brightness` | Set display brightness. Pass 'level' (0.0-1.0) for absolute control (requires 'brightness' CLI) OR 'direction' (up\|down) for relative 4-step nudges via F14/F15. | — | `direction`, `level` |
| `set_dark_mode` | Enable or disable macOS Dark Mode (System Events automation permission required). | `enabled` | — |
| `set_element_attribute` | Write an AX attribute on a cached element ID. Accepts string, number, or boolean. | `element_id`, `name`, `value` | — |
| `set_focus_mode` | Turn a Focus mode on/off via a named Shortcut. macOS has no sanctioned CLI; this requires a user-seeded shortcut named 'Turn <mode> Focus On/Off' (or 'Turn Do Not Disturb On/Off' for dnd). | `mode`, `state` | — |
| `set_volume` | Set system output volume 0-100. Optional 'muted' toggles the output mute flag. | `volume` | `muted` |
| `set_window_state` | Apply a window state: minimize, unminimize, fullscreen, exit_fullscreen, or main. | `index`, `pid`, `state` | — |
| `show_desktop` | Reveal the desktop (F11 / Fn+F11). | — | — |
| `speech_to_text` | Transcribe an audio file via Apple's Speech framework. On-device when supported. Triggers Speech Recognition TCC prompt on first use. | `audio_path` | `language` |
| `spotlight_open_result` | Confirm an active Spotlight query; pass index to pick the nth result. | — | `index` |
| `spotlight_search` | Open Spotlight (Cmd+Space) and type a query, leaving the popover ready for follow-up. | `query` | — |
| `switch_to_space` | Switch to macOS Space by index 1-9 via Ctrl+<N>. The Ctrl+N shortcut must be enabled in System Settings → Keyboard → Shortcuts → Mission Control; the tool returns hint='shortcut_disabled' if macOS swallows the event. | `index` | — |
| `system_load` | Snapshot CPU user/sys/idle %, 1/5/15-minute load average, and physical memory used/free in MB. | — | — |
| `system_logout` | Log out the current user. REQUIRES confirm:true. | `confirm` | — |
| `system_restart` | Restart the Mac. REQUIRES confirm:true. Apps still show their own save-changes prompts. | `confirm` | — |
| `system_shutdown` | Shut down the Mac. REQUIRES confirm:true. | `confirm` | — |
| `system_sleep` | Put the Mac to sleep immediately (reversible). | — | — |
| `text_to_speech` | Speak text aloud via AVSpeechSynthesizer (default) or write to an AIFF/WAV file via /usr/bin/say (when output_path is set). | `text` | `output_path`, `voice` |
| `trash_file` | Move a file to the Trash (reversible). Restricted to paths under the user's home dir — refuses to trash system files. | `path` | — |
| `type_text` | Type text into the currently focused field. Strategies: auto (clipboard → keys → ax, default; best for React/Angular SPAs), clipboard (paste events), keys (CGEvent unicode), ax (AX set_value last-resort). | `text` | `strategy` |
| `undo_last_action` | Undo the most recent destructive tool call(s) using pre-image snapshots. Pops from the LRU queue (depth 20). Returns {undone: [...], failed: [...], remaining}. Best-effort: not cross-crash persistent, not transactional across external app activity. | — | `steps` |
| `undo_peek` | Return the current undo queue without popping. Read-only introspection. | — | — |
| `wait_for_app` | Poll until an app matching bundle_id or name is running, or timeout. | — | `bundle_id`, `name`, `poll_interval_ms`, `timeout_seconds` |
| `wait_for_ax_notification` | Block until an AX notification fires on the app root (or a cached element_id), or timeout. Uses AXObserver so reaction latency is ~1 frame instead of the 250ms poll interval used by wait_for_window / wait_for_app. | `notification` | `element_id`, `pid`, `timeout_seconds` |
| `wait_for_element` | Poll for an AX element matching role/title to appear (or disappear). Returns the element ID once found. | `pid` | `expect_disappear`, `poll_interval_ms`, `role`, `timeout_seconds`, `title` |
| `wait_for_file_dialog` | Poll until an Open/Save dialog is visible in the focused app, or timeout. | — | `poll_interval_ms`, `timeout_seconds` |
| `wait_for_window` | Poll until a window (matching optional title_contains) exists for an app, or timeout. | `pid` | `poll_interval_ms`, `timeout_seconds`, `title_contains` |
| `wait_for_window_state_change` | Block until a window-related AX notification fires for the app (AXWindowCreated, AXWindowMoved, AXWindowResized, AXFocusedWindowChanged). | `pid` | `change`, `timeout_seconds` |
| `wifi_join` | Join a Wi-Fi network by SSID + optional password. macOS stores the password in Keychain on success. | `ssid` | `password` |
| `wifi_scan` | Scan for visible Wi-Fi networks. Uses Apple's private airport utility; returns a structured hint if it's been removed in this macOS version. | — | — |
| `wifi_set` | Turn Wi-Fi on, off, or toggle. Uses networksetup so no third-party CLI needed. | `state` | — |
