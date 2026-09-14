import Foundation
import CoreGraphics

// v0.9 workstream F (gap C-13) — annotated screenshot.
//
// `capture_*` returns pixels, `find_elements` returns geometry, and joining
// the two has been the agent's job: an extra round trip plus coordinate
// arithmetic on every grounding attempt, which is where grounding errors
// come from. `capture_annotated` does the join server-side and returns one
// image with numbered boxes plus the matching `elements` array, so the model
// can reason in indices ("click [3]") and still has a real `element_id` for
// perform_element_action / click.
extension ToolRegistry {

    /// Defaults, in one place so the description and the handler cannot drift.
    enum AnnotateDefaults {
        static let maxDepth = 24
        static let maxElements = 200
        /// Hard ceiling: past a couple of hundred boxes the image stops
        /// being readable, and every box costs AX geometry we already paid
        /// for.
        static let maxElementsCeiling = 500
    }

    static let definitionsAnnotate: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "capture_annotated",
            description: """
                Screenshot + numbered interactive elements in ONE call. \
                Captures an app window (pid, optional title_contains — same \
                window selection as capture_window) or the main display \
                (target="display"), walks that app's AX tree for interactive \
                controls (buttons, links, text fields, checkboxes, \
                pop-ups, sliders…), draws a numbered box over each, and \
                returns the image plus `elements`: \
                [{index, element_id, role, title, x, y, width, height, \
                center}] in GLOBAL SCREEN POINTS. Indices are 1-based and \
                are what is drawn on the image; `element_id` is live in the \
                element cache, so it can be passed straight to \
                perform_element_action / get_element_attributes, and \
                `center` is click-ready for `click`. Defaults: max_depth 24, \
                max_elements 200, artifact path (inline=true adds base64), \
                png (format/quality/max_width behave as in \
                capture_screen_v2). The response reports pixels_per_point \
                and scale for mapping image pixels back to points. NOTE: the \
                AX walk happens just before the capture — if the window moves \
                or scrolls in between, the boxes are stale by that much; \
                re-capture before clicking in an animating UI.
                """,
            inputSchema: schema(
                properties: withImageOutputProperties([
                    "pid": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("App whose window is captured and whose elements are numbered. Defaults to the frontmost app.")
                    ]),
                    "title_contains": .object([
                        "type": .string("string"),
                        "description": .string("Pick the window whose title contains this (case-insensitive). Ignored for target=\"display\".")
                    ]),
                    "target": .object([
                        "type": .string("string"),
                        "enum": .array([.string("window"), .string("display")]),
                        "description": .string("\"window\" (default) captures the app's best window; \"display\" captures the whole main display and still numbers the pid's elements.")
                    ]),
                    "max_depth": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("AX walk depth (default \(AnnotateDefaults.maxDepth)). Electron/Chromium UIs need 20+.")
                    ]),
                    "max_elements": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Cap on numbered boxes (default \(AnnotateDefaults.maxElements), max \(AnnotateDefaults.maxElementsCeiling)).")
                    ]),
                    "inline": .object([
                        "type": .string("boolean"),
                        "description": .string("Also return the image as base64. Off by default — a Retina window easily blows past the client's context limit.")
                    ]),
                    "max_bytes": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Reject the artifact if it is still larger than this after encoding (default 4 MB).")
                    ])
                ])
            )
        )
    ]

    // MARK: - Handler

    func callCaptureAnnotated(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        // Target app: explicit pid, else the frontmost app. The AX walk
        // needs a pid either way — an annotated screenshot of a display
        // with nobody's elements on it would be a plain screenshot.
        let pid: pid_t
        if arguments["pid"] != nil && arguments["pid"] != .null {
            guard let parsed = parsePID(arguments["pid"]) else {
                return invalidArgument("capture_annotated: pid must be a positive integer.")
            }
            pid = parsed
        } else if let focused = await accessibility.getFocusedApp() {
            pid = focused.pid
        } else {
            return errorResult(
                "capture_annotated could not determine a target app: no pid given and no frontmost app.",
                ["ok": .bool(false), "error_code": .string("no_target_app")]
            )
        }
        if let dead = noSuchProcessResult(pid: pid, tool: "capture_annotated") { return dead }

        let rawTarget = (arguments["target"]?.stringValue ?? "window").lowercased()
        let titleContains = arguments["title_contains"]?.stringValue
        let target: ScreenController.AnnotateTarget
        switch rawTarget {
        case "window": target = .window(pid: pid, titleContains: titleContains)
        case "display": target = .mainDisplay
        default:
            return invalidArgument("capture_annotated: target must be \"window\" or \"display\" (got \"\(rawTarget)\").")
        }

        let maxDepth = max(1, min(arguments["max_depth"]?.intValue ?? AnnotateDefaults.maxDepth, 64))
        let maxElements = max(
            1,
            min(arguments["max_elements"]?.intValue ?? AnnotateDefaults.maxElements,
                AnnotateDefaults.maxElementsCeiling)
        )
        let inline = arguments["inline"]?.boolValue ?? false
        let maxBytes = arguments["max_bytes"]?.intValue ?? (4 * 1024 * 1024)
        let options: ImageOutputOptions
        switch parseImageOutputOptions(arguments, tool: "capture_annotated") {
        case .success(let parsed): options = parsed
        case .failure(let box): return box.result
        }

        // 1. Walk the AX tree once. The node cap is the element-cache
        //    capacity for the same reason get_ui_tree uses it: an id we
        //    hand out must still resolve.
        let nodes = await accessibility.treeWalk(
            pid: pid, maxDepth: maxDepth, nodeCap: elementCache.maxEntries
        )
        let geometries = nodes.map { node -> ScreenAnnotator.ElementGeometry in
            let frame: CGRect
            if let p = node.position, let s = node.size {
                frame = CGRect(x: p.x, y: p.y, width: s.width, height: s.height)
            } else {
                // No geometry → zero rect → dropped by filterInteractive.
                frame = .zero
            }
            return ScreenAnnotator.ElementGeometry(role: node.role, title: node.title, frame: frame)
        }

        // 2. Capture + filter + draw + encode (one actor hop; no CGImage
        //    crosses an isolation boundary).
        let capture: ScreenController.AnnotatedCapture
        do {
            capture = try await screen.captureAnnotated(
                target: target, elements: geometries, limit: maxElements, options: options
            )
        } catch let error as ScreenController.ScreenError {
            return errorResult(
                "capture_annotated failed: \(error.description)",
                [
                    "ok": .bool(false),
                    "pid": .number(Double(pid)),
                    "error_code": .string(Self.annotateErrorCode(error))
                ]
            )
        } catch {
            return errorResult(
                "capture_annotated failed: \(error)",
                ["ok": .bool(false), "pid": .number(Double(pid))]
            )
        }

        // 3. Store exactly the drawn elements, in draw order, so
        //    `elements[i].element_id` is the box labelled i+1.
        //
        //    The AX path from the walk goes with them, so the id is the
        //    content-addressed one from v0.9 C-5: `capture_annotated`
        //    returns the SAME `element_id` that find_elements /
        //    get_ui_tree / element_at_point return for that element, and
        //    the handle can be repaired by re-walking the path if the
        //    cached AXUIElement goes dead.
        let ids = await elementCache.storeMany(
            withPaths: capture.drawnIndices.map { (nodes[$0].element, nodes[$0].path) },
            pid: pid
        )

        // 4. Artifact.
        guard let artifact = await artifactStore.storeEncoded(
            data: capture.data, format: capture.encoded.format, maxBytes: maxBytes
        ) else {
            return errorResult(
                "artifact store rejected the annotated image (likely exceeds max_bytes=\(maxBytes)) — retry with max_width or format=\"jpeg\".",
                ["ok": .bool(false), "pid": .number(Double(pid))]
            )
        }

        var encodedElements: [JSONValue] = []
        encodedElements.reserveCapacity(capture.drawnIndices.count)
        for (offset, nodeIndex) in capture.drawnIndices.enumerated() {
            let node = nodes[nodeIndex]
            let frame = geometries[nodeIndex].frame
            var entry: [String: JSONValue] = [
                "index": .number(Double(offset + 1)),
                "role": node.role.map(JSONValue.string) ?? .null,
                "title": node.title.map(JSONValue.string) ?? .null,
                "x": .number(Double(frame.origin.x)),
                "y": .number(Double(frame.origin.y)),
                "width": .number(Double(frame.width)),
                "height": .number(Double(frame.height)),
                "center": .object([
                    "x": .number(Double(frame.midX)),
                    "y": .number(Double(frame.midY))
                ])
            ]
            entry["element_id"] = ids.indices.contains(offset)
                ? (ids[offset].map(JSONValue.string) ?? .null)
                : .null
            encodedElements.append(.object(entry))
        }

        let bounds = capture.pointBounds
        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "pid": .number(Double(pid)),
            "target": .string(rawTarget),
            "content_ref": .string(artifact.contentRef),
            "bytes": .number(Double(artifact.bytes)),
            "sha256": .string(artifact.sha256),
            "mime_type": .string(artifact.mimeType),
            "_schema": .string(artifact.schema),
            "format": .string(capture.encoded.format.rawValue),
            "width": .number(Double(capture.encoded.width)),
            "height": .number(Double(capture.encoded.height)),
            "source_width": .number(Double(capture.encoded.sourceWidth)),
            "source_height": .number(Double(capture.encoded.sourceHeight)),
            "scale": .number(ImageEncoder.scale(
                outputWidth: capture.encoded.width, sourceWidth: capture.encoded.sourceWidth
            )),
            "annotated": .bool(capture.annotated),
            "max_depth": .number(Double(maxDepth)),
            "max_elements": .number(Double(maxElements)),
            "element_cap_reached": .bool(capture.drawnIndices.count >= maxElements),
            "nodes_walked": .number(Double(nodes.count)),
            "count": .number(Double(encodedElements.count)),
            "elements": .array(encodedElements),
            // Origin + extent of what was captured, so image pixels map
            // back to global points: point = origin + pixel / pixels_per_point.
            "capture_bounds": .object([
                "x": .number(Double(bounds.origin.x)),
                "y": .number(Double(bounds.origin.y)),
                "width": .number(Double(bounds.width)),
                "height": .number(Double(bounds.height))
            ]),
            "geometry_source": .string("ax_frames_before_capture")
        ]
        if let ppp = ImageEncoder.pixelsPerPoint(
            outputWidth: capture.encoded.width, pointWidth: Double(bounds.width)
        ) {
            payload["pixels_per_point"] = .number(ppp)
        }
        if inline {
            payload["inline_base64"] = .string(capture.data.base64EncodedString())
        }
        if encodedElements.isEmpty, let hint = await axEmptyHint(pid: pid, whenEmpty: true) {
            payload["ax_tree_hint"] = .string(hint)
        }

        return successResult(
            "Captured \(artifact.contentRef) with \(encodedElements.count) numbered elements.",
            payload
        )
    }

    static func annotateErrorCode(_ error: ScreenController.ScreenError) -> String {
        switch error {
        case .permissionDenied: return "permission_missing"
        case .windowNotOnCurrentSpace: return "window_off_space"
        case .noMatchingWindow: return "no_matching_window"
        case .windowCaptureFailed: return "capture_failed"
        case .noDisplay: return "no_display"
        case .captureFailed: return "capture_failed"
        case .encodingFailed: return "encoding_failed"
        case .writeFailed: return "write_failed"
        }
    }
}
