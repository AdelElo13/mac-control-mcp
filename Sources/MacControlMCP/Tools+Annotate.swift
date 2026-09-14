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
                Captures ONE window (window_id — preferred; or pid + optional \
                title_contains, same selection as capture_window) or the main \
                display (target="display"), walks THAT WINDOW's AX subtree \
                for interactive controls (buttons, links, text fields, \
                checkboxes, pop-ups, sliders…), draws a numbered box over \
                each, and returns the image plus `elements`: \
                [{index, element_id, role, title, x, y, width, height, \
                center, visible, fully_visible}] in GLOBAL SCREEN POINTS. \
                Indices are 1-based and are what is drawn on the image; \
                `element_id` is live in the element cache, so it can be \
                passed straight to perform_element_action / \
                get_element_attributes. `center` is click-ready: it is the \
                centre of the element's VISIBLE part (clipped to the \
                captured window and to the displays), so it is GUARANTEED to \
                lie inside the returned image — `visible` reports that \
                clipped rect and `fully_visible` says whether any clipping \
                happened. Elements with under 4 pt² visible are dropped. \
                `ax_scope` says which AX tree the boxes come from: \
                "window_subtree" when the walk was rooted at the captured \
                window's Accessibility window (the only scope under which \
                every box belongs to the pictured window); "app_root" only \
                for target="display", where the whole pid tree is walked \
                behind a geometric filter and no single-window claim is \
                made; "none" when a window WAS targeted but has no \
                attributable Accessibility window (Chrome browser windows, \
                parts of Electron, minimized windows, or several \
                indistinguishable AX windows) — then the image is still \
                returned but `elements` is EMPTY, `annotated` is false, \
                `ax_scope_reason` is "no_ax_window" or "ambiguous_window" \
                (with `candidates`), and `hint` names the alternatives \
                (ocr_screen with the same window_id, or element_at_point). \
                AX elements are never taken from an app-wide walk for a \
                targeted window, because a box over this window's pixels \
                could then carry the element_id of an overlapping window of \
                the same app. Defaults: max_depth 24, max_elements 200, \
                artifact path (inline=true adds base64), png \
                (format/quality/max_width behave as in capture_screen_v2). \
                The response reports pixels_per_point and scale for mapping \
                image pixels back to points. NOTE: the AX walk happens just \
                before the capture — if the window moves or scrolls in \
                between, the boxes are stale by that much; re-capture before \
                clicking in an animating UI.
                """,
            inputSchema: schema(
                properties: ToolRegistry.withWindowIDProperty(withImageOutputProperties([
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
                ]))
            )
        )
    ]

    // MARK: - Withheld-AX payload (Codex r2 #2)

    /// The response fields for a window that was targeted but has no
    /// attributable AXWindow: the image still comes back, the AX side is
    /// explicitly empty, and the reason + escape routes are spelled out.
    /// Pure, so the shape is unit-tested without a capture.
    static func withheldAnnotateFields(
        reason: AXScopePolicy.WithheldReason,
        windowID: CGWindowID?,
        ownerName: String,
        candidates: [WindowTargeting.Candidate]?
    ) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "annotated": .bool(false),
            "element_cap_reached": .bool(false),
            "nodes_walked": .number(0),
            "count": .number(0),
            "elements": .array([]),
            "ax_scope": .string(AXScopePolicy.Decision.withheld(reason).axScope),
            "ax_scope_reason": .string(reason.rawValue),
            "hint": .string(AXScopePolicy.withheldHint(
                tool: "capture_annotated", reason: reason, windowID: windowID, ownerName: ownerName
            ))
        ]
        if let candidates {
            fields["candidate_count"] = .number(Double(candidates.count))
            fields["candidates"] = .array(candidates.map { .object($0.payload) })
        }
        return fields
    }

    // MARK: - Handler

    func callCaptureAnnotated(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        // v0.9.0 (Codex r1 #2): `window_id` names the window to photograph
        // AND the AX subtree to number. Codex filed this as a 0.9.1 item,
        // but it is the same change as scoping the walk, so it lands here.
        let targeted: WindowController.ResolvedWindow?
        switch await resolveWindowTarget(arguments, tool: "capture_annotated") {
        case .success(let resolved): targeted = resolved
        case .failure(let box): return box.result
        }

        // Target app: the window_id's owner, else an explicit pid, else the
        // frontmost app. The AX walk needs a pid either way — an annotated
        // screenshot of a display with nobody's elements on it would be a
        // plain screenshot.
        let pid: pid_t
        if let targeted {
            pid = targeted.pid
        } else if arguments["pid"] != nil && arguments["pid"] != .null {
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
        guard rawTarget == "window" || rawTarget == "display" else {
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

        // Select the window BEFORE the AX walk, so the walk can be rooted
        // at that window's AX element (v0.9.0, Codex r1 #2). Previously the
        // walk ran over the whole pid tree and the capture picked its own
        // window afterwards, so with two overlapping windows of one app a
        // box could carry the element_id of the window BEHIND the one in
        // the picture.
        var selected: ScreenController.SelectedWindowInfo?
        if rawTarget == "window" {
            if let targeted {
                selected = Self.selectedWindow(targeted)
            } else {
                do {
                    selected = try await screen.selectWindowInfo(ownerPID: pid, titleContains: titleContains)
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
            }
        }

        // The AX window element behind the selected window, when the app
        // publishes one. `targeted` already went through the resolver when
        // a window_id was given; a pid/title selection resolves here.
        // Chrome browser windows and parts of Electron publish no AX
        // window, and a minimized window's AX frame no longer matches its
        // window-server bounds.
        var resolved: WindowController.ResolvedWindow?
        var walkRoot: AccessibilityController.WalkRoot?
        if let selected {
            if let targeted {
                resolved = targeted
            } else {
                resolved = await windows.resolve(windowID: selected.windowID)
            }
            if let element = resolved?.element {
                walkRoot = await accessibility.windowWalkRoot(element: element, index: resolved?.index ?? 0)
            }
        }

        // Codex r2 #2: a selected window IS a window claim. If it has no
        // attributable AXWindow, the AX side is withheld — never degraded
        // to an app-root walk behind a geometric filter, which could box
        // this window's pixels with an overlapping sibling's element_id.
        // Only target="display" (no window selected) walks the app root,
        // and it says so.
        let decision = AXScopePolicy.decide(
            windowRequested: selected != nil,
            hasAXWindow: walkRoot != nil,
            ambiguous: resolved?.ambiguousCandidates != nil
        )

        let target: ScreenController.AnnotateTarget = selected.map { .selectedWindow($0) } ?? .mainDisplay

        // 1. Walk the AX tree once — unless the scope decision withheld
        //    it, in which case there is nothing to number. The node cap is
        //    the element-cache capacity for the same reason get_ui_tree
        //    uses it: an id we hand out must still resolve.
        //    AXMenuBar is pruned: a closed menu bar is hundreds to
        //    thousands of AXMenuItem nodes (Safari 1031, Chrome 319) that
        //    are walked BEFORE the windows and can consume the walk's
        //    whole 5 s deadline, so the window being photographed never
        //    gets reached — measured live: Safari walked 1095 nodes and
        //    numbered 0 controls without this. Menu items are also never
        //    drawable (a closed menu parks them off-screen at 0×0, gap
        //    audit A-4). Pruning keeps the menu bar NODE and its ordinal,
        //    so every other element's path-derived id is unchanged.
        let nodes: [AccessibilityController.TreeNode]
        if decision.reason == nil {
            nodes = await accessibility.treeWalk(
                pid: pid,
                root: walkRoot,
                maxDepth: maxDepth,
                nodeCap: elementCache.maxEntries,
                pruneRoles: ["AXMenuBar"]
            )
        } else {
            nodes = []
        }
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
        //    crosses an isolation boundary). With no geometries this is a
        //    plain capture of the window.
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
            // v0.9.0 (Codex r1 #2): `center` is the centre of the VISIBLE
            // part, clipped to the captured window and the display union,
            // so it is always inside the returned image. The raw frame is
            // still reported (x/y/width/height) alongside `visible`, so a
            // caller can see how much of the element is cut off.
            let visible = ScreenAnnotator.visibleRect(of: frame, clippedTo: capture.clipRects) ?? frame
            var entry: [String: JSONValue] = [
                "index": .number(Double(offset + 1)),
                "role": node.role.map(JSONValue.string) ?? .null,
                "title": node.title.map(JSONValue.string) ?? .null,
                "x": .number(Double(frame.origin.x)),
                "y": .number(Double(frame.origin.y)),
                "width": .number(Double(frame.width)),
                "height": .number(Double(frame.height)),
                "center": .object([
                    "x": .number(Double(visible.midX)),
                    "y": .number(Double(visible.midY))
                ]),
                "visible": .object([
                    "x": .number(Double(visible.origin.x)),
                    "y": .number(Double(visible.origin.y)),
                    "width": .number(Double(visible.width)),
                    "height": .number(Double(visible.height))
                ]),
                "fully_visible": .bool(visible == frame)
            ]
            entry["element_id"] = ids.indices.contains(offset)
                ? (ids[offset].map(JSONValue.string) ?? .null)
                : .null
            encodedElements.append(.object(entry))
        }

        let bounds = capture.pointBounds
        // Split out of the literal below: the type checker times out on
        // the full dictionary once it also has to infer these.
        let scaleValue = ImageEncoder.scale(
            outputWidth: capture.encoded.width, sourceWidth: capture.encoded.sourceWidth
        )
        let captureBounds: JSONValue = .object([
            "x": .number(Double(bounds.origin.x)),
            "y": .number(Double(bounds.origin.y)),
            "width": .number(Double(bounds.width)),
            "height": .number(Double(bounds.height))
        ])
        let capReached = capture.drawnIndices.count >= maxElements
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
            "scale": .number(scaleValue),
            "annotated": .bool(capture.annotated),
            "max_depth": .number(Double(maxDepth)),
            "max_elements": .number(Double(maxElements)),
            "element_cap_reached": .bool(capReached),
            "nodes_walked": .number(Double(nodes.count)),
            "count": .number(Double(encodedElements.count)),
            "elements": .array(encodedElements),
            // Origin + extent of what was captured, so image pixels map
            // back to global points: point = origin + pixel / pixels_per_point.
            "capture_bounds": captureBounds,
            "geometry_source": .string("ax_frames_before_capture"),
            // Which AX tree the boxes come from: the captured window's
            // subtree, the app root (target="display" only — an honest
            // app-wide walk, not a window claim), or none at all when a
            // targeted window has no attributable AXWindow (Codex r2 #2).
            "ax_scope": .string(decision.axScope)
        ]
        if let selected {
            payload["window_id"] = .number(Double(selected.windowID))
            payload["window_title"] = .string(selected.title)
        }
        if let reason = decision.reason {
            // Codex r2 #2: the withheld case overrides the AX-side fields
            // (elements/count/annotated/...) with the explicit empty shape
            // plus reason, hint and any ambiguity candidates.
            let withheld = Self.withheldAnnotateFields(
                reason: reason,
                windowID: selected?.windowID,
                ownerName: resolved?.ownerName ?? "the app",
                candidates: resolved?.ambiguousCandidates
            )
            payload.merge(withheld) { _, new in new }
        }
        if let ppp = ImageEncoder.pixelsPerPoint(
            outputWidth: capture.encoded.width, pointWidth: Double(bounds.width)
        ) {
            payload["pixels_per_point"] = .number(ppp)
        }
        if inline {
            payload["inline_base64"] = .string(capture.data.base64EncodedString())
        }
        if decision.reason == nil, encodedElements.isEmpty,
           let hint = await axEmptyHint(pid: pid, whenEmpty: true) {
            payload["ax_tree_hint"] = .string(hint)
        }

        let summary = decision.reason == nil
            ? "Captured \(artifact.contentRef) with \(encodedElements.count) numbered elements."
            : "Captured \(artifact.contentRef); AX elements withheld (\(decision.reason?.rawValue ?? "")) — see hint."
        return successResult(summary, payload)
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
