import Foundation

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
            description: "Capture the main display (or a rectangular region) to a PNG file and return its path, width, and height.",
            inputSchema: schema(
                properties: [
                    "x": .object(["type": .array([.string("integer"), .string("string")]), "description": .string("Region origin x. Omit for full screen.")]),
                    "y": .object(["type": .array([.string("integer"), .string("string")])]),
                    "width": .object(["type": .array([.string("integer"), .string("string")])]),
                    "height": .object(["type": .array([.string("integer"), .string("string")])]),
                    "output_path": .object(["type": .string("string"), "description": .string("Optional PNG output path. Default: temp file.")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "ocr_screen",
            description: "Capture the screen (or a region) and run OCR. Returns joined text plus per-block coordinates and confidence.",
            inputSchema: schema(
                properties: [
                    "x": .object(["type": .array([.string("integer"), .string("string")])]),
                    "y": .object(["type": .array([.string("integer"), .string("string")])]),
                    "width": .object(["type": .array([.string("integer"), .string("string")])]),
                    "height": .object(["type": .array([.string("integer"), .string("string")])]),
                    "languages": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("ISO codes e.g. ['en-US', 'nl-NL']. Empty = auto.")
                    ]),
                    "keep_image": .object(["type": .string("boolean")])
                ]
            )
        )
    ]
}

// MARK: - Tool implementations (Phase 2)

extension ToolRegistry {
    func callBrowserListTabs(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let browserKind = BrowserController.Browser.detect(arguments["browser"]?.stringValue)
        let tabs = await browser.listTabs(browser: browserKind)
        return successResult(
            "Listed \(tabs.count) \(browserKind.rawValue) tab(s).",
            [
                "ok": .bool(true),
                "browser": .string(browserKind.rawValue),
                "count": .number(Double(tabs.count)),
                "tabs": encodeAsJSONValue(tabs)
            ]
        )
    }

    func callBrowserActiveTab(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let browserKind = BrowserController.Browser.detect(arguments["browser"]?.stringValue)
        guard let tab = await browser.activeTab(browser: browserKind) else {
            return errorResult(
                "No active tab found (is \(browserKind.rawValue) running with a window open?)",
                ["ok": .bool(false), "browser": .string(browserKind.rawValue)]
            )
        }
        return successResult(
            "Active \(browserKind.rawValue) tab retrieved.",
            [
                "ok": .bool(true),
                "browser": .string(browserKind.rawValue),
                "tab": encodeAsJSONValue(tab)
            ]
        )
    }

    func callBrowserNavigate(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let url = arguments["url"]?.stringValue, !url.isEmpty else {
            return invalidArgument("browser_navigate requires url.")
        }
        let browserKind = BrowserController.Browser.detect(arguments["browser"]?.stringValue)
        let windowIndex = arguments["window_index"]?.intValue ?? 1
        let tabIndex = arguments["tab_index"]?.intValue

        let ok = await browser.navigate(browser: browserKind, url: url, windowIndex: windowIndex, tabIndex: tabIndex)
        let err = await browser.lastError
        let payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "browser": .string(browserKind.rawValue),
            "url": .string(url),
            "window_index": .number(Double(windowIndex)),
            "tab_index": tabIndex.map { .number(Double($0)) } ?? .null,
            "error": err.map(JSONValue.string) ?? .null
        ]
        return ok
            ? successResult("Navigation issued.", payload)
            : errorResult("browser_navigate failed: \(err ?? "is the browser running?")", payload)
    }

    func callBrowserEvalJS(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let code = arguments["code"]?.stringValue, !code.isEmpty else {
            return invalidArgument("browser_eval_js requires code.")
        }
        let browserKind = BrowserController.Browser.detect(arguments["browser"]?.stringValue)
        let windowIndex = arguments["window_index"]?.intValue ?? 1
        let tabIndex = arguments["tab_index"]?.intValue

        let result = await browser.evalJS(browser: browserKind, code: code, windowIndex: windowIndex, tabIndex: tabIndex)
        let payload: [String: JSONValue] = [
            "ok": .bool(result.success),
            "browser": .string(browserKind.rawValue),
            "value": result.value.map(JSONValue.string) ?? .null,
            "error": result.error.map(JSONValue.string) ?? .null
        ]
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

        do {
            let capture: ScreenController.CaptureResult
            if let x = arguments["x"]?.intValue,
               let y = arguments["y"]?.intValue,
               let w = arguments["width"]?.intValue,
               let h = arguments["height"]?.intValue {
                capture = try await screen.captureRegion(x: x, y: y, width: w, height: h, outputPath: outputPath)
            } else {
                capture = try await screen.captureDisplay(outputPath: outputPath)
            }

            return successResult(
                "Captured \(capture.width)x\(capture.height) to \(capture.path).",
                [
                    "ok": .bool(true),
                    "path": .string(capture.path),
                    "width": .number(Double(capture.width)),
                    "height": .number(Double(capture.height))
                ]
            )
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

        do {
            // Optional region
            let capture: ScreenController.CaptureResult
            if let x = arguments["x"]?.intValue,
               let y = arguments["y"]?.intValue,
               let w = arguments["width"]?.intValue,
               let h = arguments["height"]?.intValue {
                capture = try await screen.captureRegion(x: x, y: y, width: w, height: h)
            } else {
                capture = try await screen.captureDisplay()
            }

            let ocrResult: ScreenController.OCRResult
            do {
                ocrResult = try await screen.ocr(imagePath: capture.path, languages: languages)
            } catch {
                if !keepImage {
                    try? FileManager.default.removeItem(atPath: capture.path)
                }
                throw error
            }

            if !keepImage {
                try? FileManager.default.removeItem(atPath: capture.path)
            }

            return successResult(
                "OCR extracted \(ocrResult.blocks.count) block(s).",
                [
                    "ok": .bool(true),
                    "text": .string(ocrResult.joinedText),
                    "block_count": .number(Double(ocrResult.blocks.count)),
                    "blocks": encodeAsJSONValue(ocrResult.blocks),
                    "image_path": keepImage ? .string(capture.path) : .null,
                    "image_width": .number(Double(capture.width)),
                    "image_height": .number(Double(capture.height))
                ]
            )
        } catch {
            return errorResult(
                "OCR failed: \(error).",
                ["ok": .bool(false), "error": .string(String(describing: error))]
            )
        }
    }
}
