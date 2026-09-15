import Foundation
import AppKit

// MARK: - Tool definitions (v0.2.0 Phase 2)

extension ToolRegistry {
    static let definitionsV2Phase2: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "browser_list_tabs",
            description: "List all tabs of Safari or Chrome with window/tab index, title, URL, and active flag.",
            inputSchema: schema(
                properties: [
                    "browser": .object([
                        "type": .string("string"),
                        "description": .string("'safari' or 'chrome'. Default: safari.")
                    ])
                ]
            )
        ),
        MCPToolDefinition(
            name: "browser_get_active_tab",
            description: "Return metadata for the active tab of Safari or Chrome's frontmost window.",
            inputSchema: schema(
                properties: [
                    "browser": .object(["type": .string("string")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "browser_navigate",
            description: "Point a tab at a new URL. Defaults to active tab of the front window.",
            inputSchema: schema(
                properties: [
                    "browser": .object(["type": .string("string")]),
                    "url": .object(["type": .string("string")]),
                    "window_index": .object(["type": .array([.string("integer"), .string("string")])]),
                    "tab_index": .object(["type": .array([.string("integer"), .string("string")])])
                ],
                required: ["url"]
            )
        ),
        MCPToolDefinition(
            name: "browser_eval_js",
            description: "Evaluate JavaScript in a Safari/Chrome tab and return the result as a string. Requires 'Allow JavaScript from Apple Events' in the browser's Develop menu.",
            inputSchema: schema(
                properties: [
                    "browser": .object(["type": .string("string")]),
                    "code": .object(["type": .string("string")]),
                    "window_index": .object(["type": .array([.string("integer"), .string("string")])]),
                    "tab_index": .object(["type": .array([.string("integer"), .string("string")])])
                ],
                required: ["code"]
            )
        ),
        MCPToolDefinition(
            name: "capture_screen",
            description: "Capture the MAIN display, or a region of it (x, y, width, height in global screen points — all four or none), to an image file on disk and return path, width, height (pixels of the written image) plus format, scale, source_width/source_height and pixels_per_point. "
                + "The quickest general-purpose screenshot. Use capture_window for one app window (ScreenCaptureKit; works when the window is occluded or on another Space), "
                + "capture_display for a non-main display by list_displays index, and capture_screen_v2 when you need a content-addressed artifact (sha256, max_bytes cap, optional inline base64). "
                + "Pass max_width and/or format=jpeg to cut latency and image tokens.",
            inputSchema: schema(
                properties: withImageOutputProperties([
                    "x": .object(["type": .array([.string("integer"), .string("string")]), "description": .string("Region origin x. Omit for full screen.")]),
                    "y": .object(["type": .array([.string("integer"), .string("string")])]),
                    "width": .object(["type": .array([.string("integer"), .string("string")])]),
                    "height": .object(["type": .array([.string("integer"), .string("string")])]),
                    "output_path": .object(["type": .string("string"), "description": .string("Optional output path (encoded per `format`). Default: temp file.")])
                ])
            )
        ),
        MCPToolDefinition(
            name: "ocr_screen",
            description: "Capture the screen (or a region, or ONE window via window_id) and run OCR. Returns joined text plus per-block coordinates and confidence. Coordinates are in IMAGE PIXELS matching image_width/image_height (i.e. backing resolution — 2x point size on Retina), for annotating/cropping the returned image. For click-ready screen points, use the `ground` tool with strategy 'ocr' instead. "
                + "Speed/size knobs (default level=accurate; language correction defaults on for accurate and off for fast): level=fast (~10x faster than accurate, weaker on small or low-contrast text); language_correction=false (~2x faster at accurate level; raw glyphs, no dictionary fix-ups — good for code, IDs, URLs); include_blocks=false returns only `text` (much smaller response); max_blocks caps the blocks array. "
                + "window_id (from list_windows) OCRs THAT window through the same per-window ScreenCaptureKit capture `ground` uses, so a covered or off-Space window reads its OWN text instead of whatever is on top of it. window_id takes precedence: x/y/width/height are ignored when it is present. "
                + "Every response says what the block coordinates mean: coordinate_space is window_image_pixels (window_id), region_image_pixels (x/y/width/height) or screen_image_pixels (whole main display), and `origin` is that image's top-left in global screen points. "
                + "Map a block with screen_point = origin + block_px / pixels_per_point.",
            inputSchema: schema(
                properties: withWindowIDProperty([
                    "x": .object(["type": .array([.string("integer"), .string("string")])]),
                    "y": .object(["type": .array([.string("integer"), .string("string")])]),
                    "width": .object(["type": .array([.string("integer"), .string("string")])]),
                    "height": .object(["type": .array([.string("integer"), .string("string")])]),
                    "languages": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("ISO codes e.g. ['en-US', 'nl-NL']. Empty = auto.")
                    ]),
                    "keep_image": .object(["type": .string("boolean")]),
                    "level": .object([
                        "type": .string("string"),
                        "enum": .array([.string("accurate"), .string("fast")]),
                        "description": .string("Vision recognition level. accurate (default) or fast.")
                    ]),
                    "language_correction": .object([
                        "type": .string("boolean"),
                        "description": .string("Apply Vision language correction (default true for accurate, false for fast).")
                    ]),
                    "include_blocks": .object([
                        "type": .string("boolean"),
                        "description": .string("Include per-block coordinates (default true). false → only text/block_count.")
                    ]),
                    "max_blocks": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Return at most this many blocks (in Vision's reading order). block_count and text still cover all blocks; blocks_truncated=true when capped.")
                    ])
                ])
            )
        )
    ]
}

// MARK: - Tool implementations (Phase 2)

extension ToolRegistry {
    func callBrowserListTabs(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let browserKind = BrowserController.Browser.detect(arguments["browser"]?.stringValue)
        let fetch = await browser.listTabs(browser: browserKind)

        // BUG-FIX (fix/browser-errors): a failed osascript call (Automation
        // permission missing, browser not running, timeout, ...) previously
        // came back as an empty tab list indistinguishable from "genuinely
        // zero tabs" — the tool then reported success with a misleading
        // multi_process_hint. Surface the classified failure instead.
        if let c = fetch.classification {
            var payload: [String: JSONValue] = [
                "ok": .bool(false),
                "browser": .string(browserKind.rawValue),
                "error_code": .string(c.errorCode),
                "error": .string(c.error)
            ]
            if let hint = c.hint { payload["hint"] = .string(hint) }
            if let pane = c.pane { payload["pane"] = .string(pane) }
            return errorResult("browser_list_tabs failed: \(c.error)", payload)
        }

        let tabs = fetch.tabs
        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "browser": .string(browserKind.rawValue),
            "count": .number(Double(tabs.count)),
            "tabs": encodeAsJSONValue(tabs)
        ]
        // BUG-FIX v0.2.6 #1: AppleScript `tell application "Google Chrome"`
        // targets a single Chrome scripting instance. When multiple Chrome
        // processes share the bundle (main Chrome + detached Claude-in-
        // Chrome window, or a hijacked AppleEvent path), the script can
        // return zero tabs even with windows clearly on screen. Check the
        // running-app table as a sanity signal and surface a concrete
        // fallback pointer so callers don't conclude the browser is empty.
        //
        // This hint is now ONLY reachable when the script actually
        // succeeded and returned zero tabs (classification == nil above) —
        // it no longer masks permission/automation failures.
        if tabs.isEmpty {
            let bundleId = browserKind == .chrome ? "com.google.Chrome" : "com.apple.Safari"
            let procCount = NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == bundleId }
                .count
            if procCount > 1 {
                payload["multi_process_hint"] = .string(
                    "AppleScript returned 0 tabs but \(procCount) process(es) with bundle \(bundleId) are running. "
                    + "This is a known limitation: `tell application` only scripts the primary instance. "
                    + "Fall back to `list_windows` (filter by app name) + AX-based tab detection, or close the detached process."
                )
            }
        }
        return successResult("Listed \(tabs.count) \(browserKind.rawValue) tab(s).", payload)
    }

    func callBrowserActiveTab(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let browserKind = BrowserController.Browser.detect(arguments["browser"]?.stringValue)
        let outcome = await browser.activeTab(browser: browserKind)

        // `ActiveTabOutcome` is exhaustive (found/failed) — there is no
        // third "no active tab, no error" case to guard against here.
        switch outcome {
        case .failed(let c):
            var payload: [String: JSONValue] = [
                "ok": .bool(false),
                "browser": .string(browserKind.rawValue),
                "error_code": .string(c.errorCode),
                "error": .string(c.error)
            ]
            if let hint = c.hint { payload["hint"] = .string(hint) }
            if let pane = c.pane { payload["pane"] = .string(pane) }
            return errorResult("browser_get_active_tab failed: \(c.error)", payload)

        case .found(let tab):
            return successResult(
                "Active \(browserKind.rawValue) tab retrieved.",
                [
                    "ok": .bool(true),
                    "browser": .string(browserKind.rawValue),
                    "tab": encodeAsJSONValue(tab)
                ]
            )
        }
    }

    func callBrowserNavigate(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let url = arguments["url"]?.stringValue, !url.isEmpty else {
            return invalidArgument("browser_navigate requires url.")
        }
        let browserKind = BrowserController.Browser.detect(arguments["browser"]?.stringValue)
        let windowIndex = arguments["window_index"]?.intValue ?? 1
        let tabIndex = arguments["tab_index"]?.intValue

        // Single actor call returns ok + classification together — no
        // separate follow-up read of actor state, which under concurrent
        // tool calls could race with another request overwriting it.
        let outcome = await browser.navigate(browser: browserKind, url: url, windowIndex: windowIndex, tabIndex: tabIndex)
        let ok = outcome.ok
        let classification = outcome.classification
        var payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "browser": .string(browserKind.rawValue),
            "url": .string(url),
            "window_index": .number(Double(windowIndex)),
            "tab_index": tabIndex.map { .number(Double($0)) } ?? .null,
            "error": classification.map { JSONValue.string($0.error) } ?? .null
        ]
        if let c = classification {
            payload["error_code"] = .string(c.errorCode)
            if let hint = c.hint { payload["hint"] = .string(hint) }
            if let pane = c.pane { payload["pane"] = .string(pane) }
        }
        return ok
            ? successResult("Navigation issued.", payload)
            : errorResult("browser_navigate failed: \(classification?.error ?? "is the browser running?")", payload)
    }

    func callBrowserEvalJS(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let code = arguments["code"]?.stringValue, !code.isEmpty else {
            return invalidArgument("browser_eval_js requires code.")
        }
        let browserKind = BrowserController.Browser.detect(arguments["browser"]?.stringValue)
        let windowIndex = arguments["window_index"]?.intValue ?? 1
        let tabIndex = arguments["tab_index"]?.intValue

        let result = await browser.evalJS(browser: browserKind, code: code, windowIndex: windowIndex, tabIndex: tabIndex)
        var payload: [String: JSONValue] = [
            "ok": .bool(result.success),
            "browser": .string(browserKind.rawValue),
            "value": result.value.map(JSONValue.string) ?? .null,
            "error": result.error.map(JSONValue.string) ?? .null
        ]
        if let errorCode = result.errorCode { payload["error_code"] = .string(errorCode) }
        if let hint = result.hint { payload["hint"] = .string(hint) }
        if let pane = result.pane { payload["pane"] = .string(pane) }
        return result.success
            ? successResult("JavaScript evaluated.", payload)
            : errorResult(result.error ?? "Evaluation failed", payload)
    }

    func callCaptureScreen(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let rawPath = arguments["output_path"]?.stringValue
        let outputPath: String?
        do {
            outputPath = try rawPath.map(PathValidator.validate)
        } catch {
            return invalidArgument(String(describing: error))
        }

        // Region is all-or-nothing. A partial/malformed spec (e.g. x+y+width
        // but no height) previously fell through to a full-display capture and
        // still reported success — silently ignoring the caller's intent.
        let regionKeys = ["x", "y", "width", "height"]
        let present = regionKeys.filter { arguments[$0] != nil }
        if !present.isEmpty && present.count < regionKeys.count {
            return invalidArgument("capture_screen region requires all of x, y, width, height together (or omit all for the full display). Got: \(present.joined(separator: ", ")).")
        }

        let options: ImageOutputOptions
        switch parseImageOutputOptions(arguments, tool: "capture_screen") {
        case .success(let parsed): options = parsed
        case .failure(let box): return box.result
        }

        do {
            let capture: ScreenController.CaptureResult
            if let x = arguments["x"]?.intValue,
               let y = arguments["y"]?.intValue,
               let w = arguments["width"]?.intValue,
               let h = arguments["height"]?.intValue {
                capture = try await screen.captureRegion(x: x, y: y, width: w, height: h, outputPath: outputPath, options: options)
            } else if present.isEmpty {
                capture = try await screen.captureDisplay(outputPath: outputPath, options: options)
            } else {
                return invalidArgument("capture_screen region values (x, y, width, height) must be integers.")
            }

            var payload: [String: JSONValue] = [
                "ok": .bool(true),
                "path": .string(capture.path),
                "width": .number(Double(capture.width)),
                "height": .number(Double(capture.height))
            ]
            payload.merge(Self.captureMetadata(capture)) { existing, _ in existing }
            return successResult("Captured \(capture.width)x\(capture.height) to \(capture.path).", payload)
        } catch {
            return errorResult(
                "Screen capture failed: \(error).",
                ["ok": .bool(false), "error": .string(String(describing: error))]
            )
        }
    }

    func callOCRScreen(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let languages = arguments["languages"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        let keepImage: Bool = {
            if case .bool(let b) = arguments["keep_image"] ?? .null { return b }
            return false
        }()

        var ocrOptions = ScreenController.OCRRequestOptions(languages: languages)
        if let raw = arguments["level"], raw != .null {
            switch raw.stringValue?.lowercased() {
            case "accurate": ocrOptions.fast = false
            case "fast": ocrOptions.fast = true; ocrOptions.languageCorrection = false
            default: return invalidArgument("ocr_screen: level must be \"accurate\" or \"fast\".")
            }
        }
        if let raw = arguments["language_correction"], raw != .null {
            guard let b = raw.boolValue else {
                return invalidArgument("ocr_screen: language_correction must be a boolean.")
            }
            ocrOptions.languageCorrection = b
        }
        var includeBlocks = true
        if let raw = arguments["include_blocks"], raw != .null {
            guard let b = raw.boolValue else {
                return invalidArgument("ocr_screen: include_blocks must be a boolean.")
            }
            includeBlocks = b
        }
        var maxBlocks: Int?
        if let raw = arguments["max_blocks"], raw != .null {
            guard let n = raw.intValue, n >= 0 else {
                return invalidArgument("ocr_screen: max_blocks must be a non-negative integer.")
            }
            maxBlocks = n
        }

        // v0.9 (C-3): window_id OCRs that ONE window (per-window SCK
        // capture), so an occluded window reads its own text. It takes
        // precedence over the x/y/width/height region.
        let resolved: WindowController.ResolvedWindow?
        switch await resolveWindowTarget(arguments, tool: "ocr_screen") {
        case .success(let target): resolved = target
        case .failure(let box): return box.result
        }

        do {
            // Optional region. Captured and OCR'd in memory; a PNG is only
            // written when keep_image is set (ScreenController.ocrScreen).
            var region: ScreenController.CaptureRegion?
            if resolved == nil,
               let x = arguments["x"]?.intValue,
               let y = arguments["y"]?.intValue,
               let w = arguments["width"]?.intValue,
               let h = arguments["height"]?.intValue {
                region = ScreenController.CaptureRegion(x: x, y: y, width: w, height: h)
            }

            let capture: ScreenController.CaptureResult
            let ocrResult: ScreenController.OCRResult
            if let resolved {
                (capture, ocrResult) = try await screen.ocrWindow(
                    selected: Self.selectedWindow(resolved), keepImage: keepImage, options: ocrOptions
                )
            } else {
                (capture, ocrResult) = try await screen.ocrScreen(
                    region: region, keepImage: keepImage, options: ocrOptions
                )
            }

            var payload: [String: JSONValue] = [
                "ok": .bool(true),
                "text": .string(ocrResult.joinedText),
                "block_count": .number(Double(ocrResult.blocks.count)),
                "image_path": keepImage ? .string(capture.path) : .null,
                "image_width": .number(Double(capture.width)),
                "image_height": .number(Double(capture.height)),
                "level": .string(ocrOptions.fast ? "fast" : "accurate"),
                "language_correction": .bool(ocrOptions.languageCorrection)
            ]
            // What the block coordinates are relative to, and where that
            // image's top-left is in global points:
            //   screen_point = origin + block_px / pixels_per_point
            let space = Self.ocrCoordinateSpace(
                region: region,
                windowBounds: resolved?.bounds,
                displayBounds: CGDisplayBounds(CGMainDisplayID())
            )
            payload["coordinate_space"] = .string(space.space)
            payload["origin"] = .object([
                "x": .number(Double(space.origin.x)),
                "y": .number(Double(space.origin.y))
            ])
            payload.merge(Self.captureMetadata(capture)) { existing, _ in existing }
            if let resolved {
                payload.merge(resolved.payload) { existing, _ in existing }
            }
            if includeBlocks {
                let shown = maxBlocks.map { Array(ocrResult.blocks.prefix($0)) } ?? ocrResult.blocks
                payload["blocks"] = Self.encodeOCRBlocks(shown)
                if shown.count < ocrResult.blocks.count {
                    payload["blocks_truncated"] = .bool(true)
                }
            }

            return successResult("OCR extracted \(ocrResult.blocks.count) block(s).", payload)
        } catch {
            var payload: [String: JSONValue] = [
                "ok": .bool(false),
                "error": .string(String(describing: error))
            ]
            if let resolved {
                payload["window_id"] = .number(Double(resolved.windowID))
                payload["error_code"] = .string(GroundingController.errorCode(for: error))
                payload["hint"] = .string(
                    "Per-window OCR needs Screen Recording permission for mac-control-mcp; "
                    + "if the window was just closed, call list_windows for a fresh window_id."
                )
            }
            return errorResult("OCR failed: \(error).", payload)
        }
    }
}
