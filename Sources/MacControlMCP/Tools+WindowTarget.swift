import Foundation
import CoreGraphics

// MARK: - v0.9 (C-2): `window_id` as a target on every window-scoped tool

extension ToolRegistry {

    /// The shared `window_id` schema property. Merged into every tool that
    /// can act on a single window.
    static let windowIDSchemaProperty: [String: JSONValue] = [
        "window_id": .object([
            "type": .array([.string("integer"), .string("string")]),
            "description": .string(
                "CGWindowID from list_windows — the PREFERRED way to target a window. "
                + "When present, pid / title_contains / index are IGNORED. "
                + "Unlike pid+index (only meaningful inside one list_windows response) or "
                + "pid+title_contains (ambiguous for same-titled or untitled windows), a "
                + "window_id names exactly one window for as long as it exists. "
                + "Unknown id → error_code no_such_window. The window server RECYCLES ids after a "
                + "window closes, so a cached id can come back pointing at a different window — pass "
                + "expect_pid / expect_title_contains to assert what it should be."
            )
        ]),
        "expect_pid": .object([
            "type": .array([.string("integer"), .string("string")]),
            "description": .string(
                "Guard for window_id: fail with error_code window_mismatch unless the resolved window "
                + "belongs to this pid. A cheap liveness check against a recycled id."
            )
        ]),
        "expect_title_contains": .object([
            "type": .string("string"),
            "description": .string(
                "Guard for window_id: fail with error_code window_mismatch unless the resolved window's "
                + "title contains this substring (case-insensitive)."
            )
        ])
    ]

    static func withWindowIDProperty(_ properties: [String: JSONValue]) -> [String: JSONValue] {
        properties.merging(windowIDSchemaProperty) { existing, _ in existing }
    }

    /// Sentence appended to the description of every tool that accepts
    /// `window_id`, so the precedence rule is documented where an agent
    /// reads it.
    static let windowIDPrecedenceNote =
        "Targeting: pass window_id (from list_windows) to name the window unambiguously — "
        + "it takes precedence and pid / index / title_contains are then ignored. "
        + "Window ids are recycled by the window server after a window closes, so a cached id can "
        + "resolve to a different window; add expect_pid / expect_title_contains to fail with "
        + "error_code window_mismatch instead. Responses echo window_id / owner_pid / owner_name / title."

    /// Resolve the optional `window_id` argument.
    ///
    /// - `.success(nil)`   — no `window_id` given; the caller keeps its
    ///   existing pid/index/title_contains path.
    /// - `.success(.some)` — resolved to a live window.
    /// - `.failure`        — malformed id (`invalid_argument`) or no live
    ///   window with that id (`no_such_window`).
    ///
    /// `requiresAXWindow` is for the tools that mutate a window through
    /// Accessibility (focus/move/resize/state): those need the AX window
    /// behind the id, which some apps (Chrome's browser windows) do not
    /// expose. Capture/OCR/grounding work without it.
    func resolveWindowTarget(
        _ arguments: [String: JSONValue],
        tool: String,
        requiresAXWindow: Bool = false
    ) async -> Result<WindowController.ResolvedWindow?, ToolCallResultBox> {
        guard let raw = arguments["window_id"], raw != .null else { return .success(nil) }
        guard let integer = raw.intValue, integer >= 0, integer <= Int(UInt32.max) else {
            return .failure(ToolCallResultBox(result: invalidArgument(
                "\(tool): window_id must be a CGWindowID (non-negative integer) from list_windows."
            )))
        }
        let id = CGWindowID(integer)
        guard let resolved = await windows.resolve(windowID: id) else {
            return .failure(ToolCallResultBox(result: errorResult(
                "\(tool): no window with window_id \(id).",
                [
                    "ok": .bool(false),
                    "window_id": .number(Double(id)),
                    "error_code": .string("no_such_window"),
                    "hint": .string(
                        "Call list_windows and use a window_id from its output — the window may have "
                        + "been closed, or the id may belong to a different session."
                    )
                ]
            )))
        }
        // Reuse guards: an id the caller cached can now name a different
        // window (the window server recycles ids), so let the caller
        // assert what it expects instead of acting on the wrong window.
        var expectPID: pid_t?
        if let raw = arguments["expect_pid"], raw != .null {
            guard let parsed = parsePID(raw) else {
                return .failure(ToolCallResultBox(result: invalidArgument(
                    "\(tool): expect_pid must be a positive integer."
                )))
            }
            expectPID = parsed
        }
        let expectTitle = arguments["expect_title_contains"]?.stringValue
        if let bad = resolved.mismatch(expectPID: expectPID, expectTitleContains: expectTitle) {
            var payload: [String: JSONValue] = [
                "ok": .bool(false),
                "error_code": .string("window_mismatch"),
                "field": .string(bad.field),
                "expected": .string(bad.expected),
                "actual": .string(bad.actual),
                "hint": .string(
                    "window_id \(id) resolved to a window that does not match \(bad.field). CGWindowIDs "
                    + "are recycled after a window closes — call list_windows for a current id."
                )
            ]
            payload.merge(resolved.payload) { existing, _ in existing }
            return .failure(ToolCallResultBox(result: errorResult(
                "\(tool): window_id \(id) does not match \(bad.field) (expected \(bad.expected), "
                + "got \(bad.actual)).",
                payload
            )))
        }
        if requiresAXWindow, resolved.index == nil {
            var payload: [String: JSONValue] = [
                "ok": .bool(false),
                "error_code": .string("no_ax_window"),
                "minimized_hint": .bool(!resolved.isOnscreen),
                "hint": .string(
                    "A MINIMIZED window is the usual cause: its Accessibility frame no longer matches "
                    + "its window-server bounds, so there is no AX window to act on — unminimize it "
                    + "(set_window_state state=normal by pid+index) and retry. Some apps (Chrome "
                    + "browser windows, parts of Electron) also publish windows to the window server "
                    + "but never to Accessibility. capture_window / ocr_screen / ground still work by "
                    + "window_id without AX."
                )
            ]
            payload.merge(resolved.payload) { existing, _ in existing }
            return .failure(ToolCallResultBox(result: errorResult(
                "\(tool): window \(id) (\(resolved.ownerName), pid \(resolved.pid)) has no Accessibility "
                + "window matching its frame, so it cannot be moved/resized/focused through AX.",
                payload
            )))
        }
        return .success(resolved)
    }

    /// What `ocr_screen`'s block coordinates are relative to, and where
    /// that image's top-left sits in global screen points.
    ///
    /// Callers map a block back with
    /// `screen_point = origin + block_px / pixels_per_point`; before v0.9
    /// the response named neither the space nor the origin, so a caller
    /// had to infer from its own arguments which of the three it got.
    static func ocrCoordinateSpace(
        region: ScreenController.CaptureRegion?,
        windowBounds: CGRect?,
        displayBounds: CGRect
    ) -> (space: String, origin: CGPoint) {
        if let windowBounds {
            return ("window_image_pixels", windowBounds.origin)
        }
        if let region {
            return ("region_image_pixels", CGPoint(x: Double(region.x), y: Double(region.y)))
        }
        return ("screen_image_pixels", displayBounds.origin)
    }

    /// Bridge a resolved `window_id` into the capture layer's window
    /// descriptor, so capture/OCR skip the pid + title_contains
    /// selection heuristic entirely and act on exactly this window.
    static func selectedWindow(_ resolved: WindowController.ResolvedWindow) -> ScreenController.SelectedWindowInfo {
        ScreenController.SelectedWindowInfo(
            windowID: resolved.windowID,
            title: resolved.title,
            bounds: resolved.bounds,
            isOnscreen: resolved.isOnscreen
        )
    }

    /// Same as `resolveWindowTarget`, in the shape the grounding layer
    /// takes (`ground` / `ax_tree_augmented`).
    func windowScope(
        _ arguments: [String: JSONValue],
        tool: String
    ) async -> Result<GroundingController.WindowScope?, ToolCallResultBox> {
        switch await resolveWindowTarget(arguments, tool: tool) {
        case .failure(let box):
            return .failure(box)
        case .success(let resolved):
            guard let resolved else { return .success(nil) }
            return .success(GroundingController.WindowScope(
                windowID: resolved.windowID,
                pid: resolved.pid,
                ownerName: resolved.ownerName,
                title: resolved.title,
                bounds: resolved.bounds,
                isOnscreen: resolved.isOnscreen
            ))
        }
    }

    /// The `(pid, index)` pair the AX window tools take, resolved from
    /// either `window_id` (preferred) or the legacy `pid` + `index`.
    struct WindowHandle: Sendable {
        let pid: pid_t
        let index: Int
        let resolved: WindowController.ResolvedWindow?

        var windowID: CGWindowID? { resolved?.windowID }

        /// Echo for the response payload: pid/index always, plus the full
        /// identity (window_id, owner_pid, owner_name, title) when the
        /// caller targeted a window_id — so it can see WHICH window the id
        /// resolved to and catch a recycled id after the fact.
        var payload: [String: JSONValue] {
            var out: [String: JSONValue] = [
                "pid": .number(Double(pid)),
                "index": .number(Double(index))
            ]
            if let resolved {
                out.merge(resolved.payload) { existing, _ in existing }
            }
            return out
        }
    }

    func windowHandle(
        _ arguments: [String: JSONValue],
        tool: String
    ) async -> Result<WindowHandle, ToolCallResultBox> {
        switch await resolveWindowTarget(arguments, tool: tool, requiresAXWindow: true) {
        case .failure(let box):
            return .failure(box)
        case .success(let resolved):
            if let resolved, let index = resolved.index {
                return .success(WindowHandle(pid: resolved.pid, index: index, resolved: resolved))
            }
        }
        guard let pid = parsePID(arguments["pid"]) else {
            return .failure(ToolCallResultBox(result: invalidArgument(
                "\(tool) requires a positive integer pid (or a window_id from list_windows)."
            )))
        }
        guard let index = arguments["index"]?.intValue, index >= 0 else {
            return .failure(ToolCallResultBox(result: invalidArgument(
                "\(tool) requires a non-negative index (or a window_id from list_windows)."
            )))
        }
        return .success(WindowHandle(pid: pid, index: index, resolved: nil))
    }
}
