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
                + "Unknown id → error_code no_such_window."
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
        + "it takes precedence and pid / index / title_contains are then ignored."

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
        if requiresAXWindow, resolved.index == nil {
            return .failure(ToolCallResultBox(result: errorResult(
                "\(tool): window \(id) (pid \(resolved.pid)) has no Accessibility window matching its "
                + "frame, so it cannot be moved/resized/focused through AX.",
                [
                    "ok": .bool(false),
                    "window_id": .number(Double(id)),
                    "pid": .number(Double(resolved.pid)),
                    "error_code": .string("no_ax_window"),
                    "hint": .string(
                        "Some apps (Chrome browser windows, parts of Electron) publish windows to the "
                        + "window server but not to Accessibility. Activate the app and retry, or use "
                        + "capture_window / ocr_screen / ground, which work by window_id without AX."
                    )
                ]
            )))
        }
        return .success(resolved)
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
        let windowID: CGWindowID?

        /// `window_id` / `pid` / `index` echo for the response payload.
        var payload: [String: JSONValue] {
            var out: [String: JSONValue] = [
                "pid": .number(Double(pid)),
                "index": .number(Double(index))
            ]
            if let windowID { out["window_id"] = .number(Double(windowID)) }
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
                return .success(WindowHandle(pid: resolved.pid, index: index, windowID: resolved.windowID))
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
        return .success(WindowHandle(pid: pid, index: index, windowID: nil))
    }
}
