import Foundation
import ApplicationServices
import CoreGraphics

/// v0.6.0 B1 + B2 — mixture-of-grounding + AX tree augmentation.
///
/// Agent S2 pattern: try AX first (fast + structured), fall back to OCR
/// when AX returns nothing useful (Electron / Canvas / games / Chromium
/// iframes). All three grounding paths are Swift-native — no Python
/// sidecar. The Screen2AX vision-fallback path is deferred to v0.7.0
/// behind a feature flag.
actor GroundingController {

    // MARK: - B1: ground(target, strategy?)

    enum Strategy: String, Sendable {
        case ax    // AX find_elements only, fastest
        case ocr   // Screenshot + OCR only, slowest but works on everything
        case auto  // AX first, fall through to OCR on zero results or ambiguity
    }

    struct Bounds: Codable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct GroundResult: Codable, Sendable {
        let ok: Bool
        let strategyUsed: String         // "ax" | "ocr" | "none"
        let x: Double?
        let y: Double?
        /// Frame of the matched element (AX) or OCR text block, in global
        /// screen points — so a caller can hit-test, scroll or drag it
        /// rather than only click its center.
        let bounds: Bounds?
        /// ElementCache id of the matched AX element, resolvable by
        /// get_element_attributes / perform_element_action. nil for OCR
        /// matches, which have no AX element behind them.
        let elementId: String?
        let confidence: Double           // 0.0 - 1.0
        /// The AX depth ceiling actually used for this call (A-2 / D-2:
        /// every search response says how deep it looked, so "not found"
        /// is distinguishable from "below the ceiling").
        let maxDepthUsed: Int
        let candidates: [Candidate]
        let error: String?
        let errorCode: String?
        /// Codex r2 #2: set when a window scope was given but the AX
        /// strategy did NOT run because the window has no attributable
        /// AXWindow ("no_ax_window" / "ambiguous_window"). nil whenever AX
        /// ran (or was not asked for). Lets a caller tell "AX found
        /// nothing" from "AX was never consulted".
        let axSkippedReason: String?
        var nodesVisited: Int = 0
        var timingsMS: [String: Double] = [:]
        var truncated: Bool = false
    }

    struct Candidate: Codable, Sendable {
        let role: String?
        let title: String?
        let x: Double
        let y: Double
        let bounds: Bounds?
        let elementId: String?
        let source: String               // "ax" | "ocr"
        let confidence: Double
    }

    /// Default AX depth ceiling — the project-wide `AXDepth.default`
    /// (v0.9 D-2), shared with find_element(s) / query_elements /
    /// list_elements / get_ui_tree. `ground` used to hard-code 16, so
    /// elements at depth 17 — routine in Electron apps — were invisible
    /// to `ground` while `find_elements` returned them (A-2 / B-7).
    static let defaultMaxDepth = AXDepth.default
    static let maxAllowedDepth = AXDepth.maxAllowed

    static func resolveMaxDepth(_ requested: Int?) -> Int {
        AXDepth.resolve(requested)
    }

    /// Classify a window-capture failure so callers get an actionable
    /// `error_code` instead of a bare "no grounding candidate".
    static func errorCode(for error: Error) -> String {
        if let e = error as? ScreenController.ScreenError {
            switch e {
            case .permissionDenied: return "permission_missing"
            case .noMatchingWindow, .windowNotOnCurrentSpace: return "not_found"
            default: return "capture_failed"
            }
        }
        if let e = error as? ScreenCaptureKitBridge.BridgeError {
            switch e {
            case .permissionDenied: return "permission_missing"
            case .windowNotFound: return "not_found"
            case .captureFailed: return "capture_failed"
            }
        }
        return "capture_failed"
    }

    /// v0.9 (C-2/C-3): one window, named by its `CGWindowID`, as the
    /// scope of a grounding call. When present, AX candidates are limited
    /// to elements inside the window's frame and the OCR pass captures
    /// exactly this window (never the app's "largest" window, never the
    /// display).
    struct WindowScope: Sendable {
        let windowID: CGWindowID
        let pid: pid_t
        let ownerName: String
        let title: String
        let bounds: CGRect
        let isOnscreen: Bool
        /// v0.9.0 blocker fix (Codex r1 #2): the resolved `AXWindow`
        /// element, used as the AX search ROOT. Scoping by frame alone let
        /// an element of an overlapping window of the SAME app match;
        /// rooting the search here makes that window's subtree
        /// unreachable. nil for apps that publish no AX window (Chrome
        /// browser windows) — and then (Codex r2 #2) the AX strategy is
        /// SKIPPED rather than run app-wide behind a geometric filter,
        /// because a frame filter cannot tell this window's elements from
        /// an overlapping sibling's.
        let axElement: AXUIElement?
        /// That window's ordinal in `kAXWindowsAttribute`, needed to seed
        /// the AX path so element ids stay identical to an app-rooted walk.
        let axIndex: Int?
        /// Codex r2 #2: the indistinguishable AX windows the resolver
        /// found, when it found several. Carried so `ground` can report
        /// `ambiguous_window` with the candidates instead of `no_ax_window`.
        let ambiguousCandidates: [WindowTargeting.Candidate]?

        init(
            windowID: CGWindowID,
            pid: pid_t,
            ownerName: String,
            title: String,
            bounds: CGRect,
            isOnscreen: Bool,
            axElement: AXUIElement? = nil,
            axIndex: Int? = nil,
            ambiguousCandidates: [WindowTargeting.Candidate]? = nil
        ) {
            self.windowID = windowID
            self.pid = pid
            self.ownerName = ownerName
            self.title = title
            self.bounds = bounds
            self.isOnscreen = isOnscreen
            self.axElement = axElement
            self.axIndex = axIndex
            self.ambiguousCandidates = ambiguousCandidates
        }

        /// The scope decision for this window: a scope always means a
        /// window was requested, so the only outcomes are the subtree
        /// walk or a withheld AX pass (Codex r2 #2).
        var scopeDecision: AXScopePolicy.Decision {
            AXScopePolicy.decide(
                windowRequested: true,
                hasAXWindow: axElement != nil,
                ambiguous: ambiguousCandidates != nil
            )
        }

        /// Did the AX search actually run inside this window's subtree
        /// ("window_subtree"), or was it withheld ("none")?
        var axScope: String { scopeDecision.axScope }

        /// "no_ax_window" / "ambiguous_window" when AX is withheld, else nil.
        var axSkippedReason: String? { scopeDecision.reason?.rawValue }

        /// Identity echo for the tool response — which window the id
        /// actually resolved to (ids are recycled after a window closes).
        var payload: [String: JSONValue] {
            [
                "window_id": .number(Double(windowID)),
                "owner_pid": .number(Double(pid)),
                "owner_name": .string(ownerName),
                "title": .string(title)
            ]
        }

        var selected: ScreenController.SelectedWindowInfo {
            ScreenController.SelectedWindowInfo(
                windowID: windowID, title: title, bounds: bounds, isOnscreen: isOnscreen
            )
        }
    }

    private let accessibility: AccessibilityController
    private let screen: ScreenController
    private let elementCache: ElementCache?
    // v0.10 B4: keep display IPC at the boundary so shallow/full-pass
    // selection can be verified without a live desktop.
    private let readDisplayBounds: @Sendable () -> [WindowIdentity.DisplayBounds]

    init(accessibility: AccessibilityController, screen: ScreenController, elementCache: ElementCache? = nil,
         readDisplayBounds: @escaping @Sendable () -> [WindowIdentity.DisplayBounds] = WindowIdentity.displayBounds) {
        self.accessibility = accessibility
        self.screen = screen
        self.elementCache = elementCache
        self.readDisplayBounds = readDisplayBounds
    }

    /// Find coordinates to click for `target` text. `strategy`:
    ///   .ax   → only AX lookup (fast). Returns nil if AX has nothing.
    ///   .ocr  → only OCR lookup (slow but universal).
    ///   .auto → AX first; if 0 matches or >3 ambiguous, fall through
    ///           to OCR for disambiguation.
    func ground(
        target: String,
        pid rawPID: pid_t,
        strategy: Strategy = .auto,
        maxDepth: Int? = nil,
        window: WindowScope? = nil,
        includeMenus: Bool = false
    ) async -> GroundResult {
        let pid = window?.pid ?? rawPID
        let depth = Self.resolveMaxDepth(maxDepth)
        var walk = AccessibilityController.WalkResult()

        // Codex r2 #2: a window scope with no attributable AXWindow means
        // the AX strategy cannot keep its promise, so it does not run at
        // all. Before this, `walkRoot = nil` silently degraded the search
        // to the whole app behind a frame filter, and a match from an
        // overlapping window of the same app came back with `ok: true`.
        let axSkippedReason: String? = window?.axSkippedReason
        let wantsAX = (strategy == .ax || strategy == .auto) && axSkippedReason == nil
        let wantsOCR = strategy == .ocr || strategy == .auto

        // strategy "ax" was asked for explicitly and cannot be honoured:
        // fail with the resolver's own code rather than answer from a
        // tree the caller did not ask about. The tool layer attaches the
        // ambiguity candidates from the scope.
        if strategy == .ax, let axSkippedReason, let window {
            let reason = AXScopePolicy.WithheldReason(rawValue: axSkippedReason) ?? .noAXWindow
            return GroundResult(
                ok: false, strategyUsed: "none",
                x: nil, y: nil, bounds: nil, elementId: nil, confidence: 0,
                maxDepthUsed: depth,
                candidates: [],
                error: AXScopePolicy.withheldHint(
                    tool: "ground", reason: reason,
                    windowID: window.windowID, ownerName: window.ownerName
                ),
                errorCode: axSkippedReason,
                axSkippedReason: axSkippedReason,
                nodesVisited: walk.nodesVisited, timingsMS: walk.timingsMS,
                truncated: walk.nodeCapReached || walk.timedOut
            )
        }

        // 1. AX attempt. `findElements` returns [(AXUIElement, ElementInfo)]
        var axCandidates: [Candidate] = []
        if wantsAX {
            // v0.9.0 blocker fix (Codex r1 #2): with a window_id the search
            // starts AT that AXWindow, so an element of an overlapping
            // window of the same app is not merely filtered out by
            // geometry — it is never visited. The geometric filter below
            // stays as the second line of defence. Without a window scope
            // the root is the app (an honest app-wide search, not a window
            // claim); a scope WITHOUT an element never reaches this branch
            // (Codex r2 #2, see `axSkippedReason` above).
            let walkRoot: AccessibilityController.WalkRoot?
            if let window, let element = window.axElement {
                walkRoot = await accessibility.windowWalkRoot(
                    element: element, index: window.axIndex ?? 0
                )
            } else {
                walkRoot = nil
            }
            // v0.7.1 fix (BUG 5): filter off-screen AX candidates. macOS
            // parks hidden menu items at (0, screen_height) with size
            // (0,0) — those are technically "AX-matched" but cannot be
            // clicked.
            //
            // v0.9 (C-14): the visible universe is the UNION of every
            // attached display, not the main display. The old filter
            // dropped any candidate with `x > mainWidth * 2`, i.e. most of
            // a third display and all of a large secondary one, and
            // measured the parked-menu-item signature against the main
            // display's height only. `parkedHeights` keeps that signature
            // check per display.
            let displayList = readDisplayBounds()
            let visibleBounds = WindowIdentity.unionBounds(of: displayList)
                ?? CGDisplayBounds(CGMainDisplayID())
            let parkedHeights: [Double] = displayList.isEmpty
                ? [Double(CGDisplayBounds(CGMainDisplayID()).height)]
                : WindowIdentity.bottomEdges(of: displayList)
            // v0.10 B4: BFS reads each node once; the first exact usable
            // label ends the search. Keep shallow substring fallbacks while
            // looking for an exact hit, filtering geometry before selection.
            let result = await accessibility.search(
                pid: pid, root: walkRoot, maxDepth: depth, limit: 20,
                includeMenus: includeMenus, shallowFirst: true,
                stopOnBest: { AccessibilityController.textMatches(filter: target, candidate: $0.title ?? "", exact: true) },
                predicate: { attrs in
                    guard AccessibilityController.textMatches(filter: target, candidate: attrs.title ?? "", exact: false),
                          attrs.role != "AXApplication",
                          let pos = attrs.position, let size = attrs.size,
                          size.width >= 1, size.height >= 1 else { return false }
                    if abs(pos.x) < 1, parkedHeights.contains(where: { abs(pos.y - $0) < 1 }) { return false }
                    let frame = CGRect(origin: pos, size: size)
                    guard frame.intersects(visibleBounds) else { return false }
                    if let window, !WindowIdentity.rect(frame, isWithin: window.bounds) { return false }
                    return true
                }
            )
            walk = result
            let survivors = result.matches

            // Element ids for every surviving AX match, in ONE cache hop,
            // so the caller can act on the match (get_element_attributes /
            // perform_element_action) instead of only clicking a point.
            var ids: [String?] = Array(repeating: nil, count: survivors.count)
            if let elementCache {
                // Content-addressed ids (v0.9 C-5): ground now hands back the
                // same id find_elements would for the same element.
                ids = await elementCache.storeMany(withPaths: survivors.map { ($0.element, $0.path) }, pid: pid)
            }

            for (index, survivor) in survivors.enumerated() {
                let info = survivor.info
                guard let pos = info.position, let size = info.size else { continue }
                let centerX = pos.x + size.width / 2
                let centerY = pos.y + size.height / 2
                let titleLower = info.title?.lowercased() ?? ""
                let exact = titleLower == target.lowercased()
                let conf = exact ? 1.0 : 0.8
                axCandidates.append(.init(
                    role: info.role,
                    title: info.title,
                    x: centerX, y: centerY,
                    bounds: Bounds(x: pos.x, y: pos.y, width: size.width, height: size.height),
                    elementId: ids[index],
                    source: "ax",
                    confidence: conf
                ))
            }
        }

        // Happy path: exactly one AX hit, or a clear winner with the rest weak.
        if strategy == .ax || (strategy == .auto && axCandidates.count == 1) {
            if let best = axCandidates.max(by: { $0.confidence < $1.confidence }) {
                return GroundResult(
                    ok: true,
                    strategyUsed: "ax",
                    x: best.x, y: best.y,
                    bounds: best.bounds,
                    elementId: best.elementId,
                    confidence: best.confidence,
                    maxDepthUsed: depth,
                    candidates: axCandidates,
                    error: nil,
                    errorCode: nil,
                    axSkippedReason: axSkippedReason,
                nodesVisited: walk.nodesVisited, timingsMS: walk.timingsMS,
                truncated: walk.nodeCapReached || walk.timedOut
                )
            }
            if strategy == .ax {
                return GroundResult(
                    ok: false, strategyUsed: "ax",
                    x: nil, y: nil, bounds: nil, elementId: nil, confidence: 0,
                    maxDepthUsed: depth,
                    candidates: [],
                    error: "no AX match at depth \(depth)",
                    errorCode: "not_found",
                    axSkippedReason: axSkippedReason,
                nodesVisited: walk.nodesVisited, timingsMS: walk.timingsMS,
                truncated: walk.nodeCapReached || walk.timedOut
                )
            }
        }

        // 2. OCR fallback / disambiguation — scoped to the TARGET app's
        // window, never the whole display (A-3).
        var ocrCandidates: [Candidate] = []
        var ocrFailure: (message: String, code: String)?
        if wantsOCR {
            do {
                ocrCandidates = try await ocrLookup(target: target, pid: pid, window: window)
            } catch {
                ocrFailure = (
                    "OCR capture of pid \(pid)'s window failed: \(error)",
                    Self.errorCode(for: error)
                )
            }
        }

        // Merge and rank
        let all = axCandidates + ocrCandidates
        if let best = all.max(by: { $0.confidence < $1.confidence }) {
            return GroundResult(
                ok: true,
                strategyUsed: best.source,
                x: best.x, y: best.y,
                bounds: best.bounds,
                elementId: best.elementId,
                confidence: best.confidence,
                maxDepthUsed: depth,
                candidates: all,
                error: nil,
                errorCode: nil,
                axSkippedReason: axSkippedReason,
                nodesVisited: walk.nodesVisited, timingsMS: walk.timingsMS,
                truncated: walk.nodeCapReached || walk.timedOut
            )
        }

        // Nothing matched. A capture failure is reported as itself — the
        // old code silently OCR'd the main display instead, which could
        // "ground" text belonging to a completely different app.
        if let ocrFailure {
            return GroundResult(
                ok: false, strategyUsed: "none",
                x: nil, y: nil, bounds: nil, elementId: nil, confidence: 0,
                maxDepthUsed: depth,
                candidates: [],
                error: ocrFailure.message,
                errorCode: ocrFailure.code,
                axSkippedReason: axSkippedReason,
                nodesVisited: walk.nodesVisited, timingsMS: walk.timingsMS,
                truncated: walk.nodeCapReached || walk.timedOut
            )
        }

        return GroundResult(
            ok: false, strategyUsed: "none",
            x: nil, y: nil, bounds: nil, elementId: nil, confidence: 0,
            maxDepthUsed: depth,
            candidates: [],
            error: "no grounding candidate from \(strategy.rawValue)",
            errorCode: "not_found",
            axSkippedReason: axSkippedReason,
                nodesVisited: walk.nodesVisited, timingsMS: walk.timingsMS,
                truncated: walk.nodeCapReached || walk.timedOut
        )
    }

    /// Convert an OCR block's center from image-pixel space to global
    /// screen POINTS.
    ///
    /// `ScreenController.ocr` emits block coordinates in **image pixels**:
    /// a full-screen capture on a 2× Retina display is 3024×1964px for a
    /// 1512×982pt display, so a block center at pixel (300,240) sits at
    /// point (150,120). AX frames and click targets are in points, so OCR
    /// centers MUST be scaled down by the backing factor before they are
    /// used as click coordinates (`ground`) or compared against AX rects
    /// (`axTreeAugmented`) — otherwise every OCR hit is 2× off on Retina.
    ///
    /// The scale is derived from the actual captured image dimensions vs
    /// the display's point dimensions, so it is exact for any backing
    /// factor (2.0 or a fractional scaled mode) and collapses to identity
    /// on a 1× display. Zero/missing dimensions fall back to identity so
    /// the conversion can never divide by zero.
    static func ocrPixelCenterToPoints(
        blockX: Double, blockY: Double, blockW: Double, blockH: Double,
        imagePixelWidth: Int, imagePixelHeight: Int,
        displayPointWidth: Double, displayPointHeight: Double
    ) -> CGPoint {
        let centerX = blockX + blockW / 2
        let centerY = blockY + blockH / 2
        let sx = imagePixelWidth > 0 ? displayPointWidth / Double(imagePixelWidth) : 1
        let sy = imagePixelHeight > 0 ? displayPointHeight / Double(imagePixelHeight) : 1
        return CGPoint(x: centerX * sx, y: centerY * sy)
    }

    /// Map an OCR block center from WINDOW-image pixel space to a GLOBAL
    /// screen point.
    ///
    /// A per-window ScreenCaptureKit capture is an image of just that
    /// window, so block (0,0) is the window's top-left corner, not the
    /// display's. Two steps: scale pixels → points using the window's own
    /// point size (exact for any backing factor, identity on 1×), then
    /// offset by the window's global origin.
    static func ocrPixelCenterToGlobalPoints(
        blockX: Double, blockY: Double, blockW: Double, blockH: Double,
        imagePixelWidth: Int, imagePixelHeight: Int,
        windowBounds: CGRect
    ) -> CGPoint {
        let local = ocrPixelCenterToPoints(
            blockX: blockX, blockY: blockY, blockW: blockW, blockH: blockH,
            imagePixelWidth: imagePixelWidth, imagePixelHeight: imagePixelHeight,
            displayPointWidth: Double(windowBounds.width),
            displayPointHeight: Double(windowBounds.height)
        )
        return CGPoint(x: Double(windowBounds.origin.x) + local.x,
                       y: Double(windowBounds.origin.y) + local.y)
    }

    /// Scale a window-pixel LENGTH to points using the same exact ratio.
    private static func pixelsToPoints(_ value: Double, pixels: Int, points: Double) -> Double {
        guard pixels > 0 else { return value }
        return value * (points / Double(pixels))
    }

    /// OCR the TARGET app's window (never the whole display) and return
    /// every block whose text matches `target`, with coordinates already
    /// mapped to global screen points.
    ///
    /// Throws on capture failure. There is no display-wide fallback on
    /// purpose: OCR'ing the main display for an occluded window returns
    /// the text of whatever is on top of it, which is how A-1 produced
    /// confident labels belonging to a different application.
    private func ocrLookup(target: String, pid: pid_t, window: WindowScope? = nil) async throws -> [Candidate] {
        // With a window_id the exact window is captured; without one the
        // app's best window is picked by the existing heuristic.
        let (capture, result) = window == nil
            ? try await screen.ocrWindow(ownerPID: pid)
            : try await screen.ocrWindow(selected: window!.selected)
        guard let windowBounds = capture.pointBounds, windowBounds.width > 0, windowBounds.height > 0 else {
            throw ScreenController.ScreenError.captureFailed
        }
        let needle = target.lowercased()
        var out: [Candidate] = []
        for block in result.blocks {
            let text = block.text.lowercased()
            let exact = text == needle
            let contains = text.contains(needle)
            if !exact && !contains { continue }
            let center = Self.ocrPixelCenterToGlobalPoints(
                blockX: block.x, blockY: block.y,
                blockW: block.width, blockH: block.height,
                imagePixelWidth: capture.width, imagePixelHeight: capture.height,
                windowBounds: windowBounds
            )
            let widthPt = Self.pixelsToPoints(block.width, pixels: capture.width,
                                              points: Double(windowBounds.width))
            let heightPt = Self.pixelsToPoints(block.height, pixels: capture.height,
                                               points: Double(windowBounds.height))
            out.append(.init(
                role: nil,
                title: block.text,
                x: center.x, y: center.y,
                bounds: Bounds(x: center.x - widthPt / 2, y: center.y - heightPt / 2,
                               width: widthPt, height: heightPt),
                elementId: nil,
                source: "ocr",
                confidence: exact ? 0.9 : (contains ? 0.6 : 0.3)
            ))
        }
        return out
    }

    // MARK: - B2: ax_tree_augmented (single-pass OCR + geometric join)

    struct AugmentedNode: Codable, Sendable {
        let role: String?
        let title: String?
        let value: String?
        let x: Double?
        let y: Double?
        let width: Double?
        let height: Double?
        let inferredLabel: String?       // from OCR-geometric match, if any
        let labelSource: String?         // "ax" | "ocr_geometric" | "none"
        let labelConfidence: Double?     // 0..1, <=0.5 when overlapping frames
    }

    struct AugmentedTreeResult: Codable, Sendable {
        let ok: Bool
        let pid: Int32
        let nodeCount: Int
        let inferredCount: Int
        let nodes: [AugmentedNode]
        let elapsedMs: Int
        let maxDepthUsed: Int
        let error: String?
        let errorCode: String?
        /// Codex r2 #2: which AX tree the nodes come from —
        /// "window_subtree" (rooted at the scoped window's AXWindow),
        /// "app_root" (no window requested), or "none" (a window was
        /// requested but has no attributable AXWindow; `nodes` is empty).
        let axScope: String
        /// "no_ax_window" / "ambiguous_window" when `axScope` is "none".
        let axScopeReason: String?
    }

    /// Codex v3 design — single OCR pass + geometric join instead of
    /// per-node OCR. Latency: <500ms for typical app windows.
    /// Overlapping-frame risk: innermost-match wins, confidence reduced
    /// to ≤0.5 when multiple AX frames contain the same OCR bbox.
    ///
    /// v0.7.1 fix (BUG 6): added `maxNodes` cap (default 300). Without it
    /// a mid-size app like Terminal (~370 nodes) blows past the Claude
    /// Code 20MB context limit because each node is a fat JSON object.
    /// The cap trims child arrays after the top-N elements in
    /// breadth-first order, preserving structural integrity of the tree
    /// rather than chopping the serialization mid-way.
    func axTreeAugmented(
        pid rawPID: pid_t,
        maxDepth: Int = 12,
        maxNodes: Int = 300,
        window: WindowScope? = nil
    ) async -> AugmentedTreeResult {
        let start = Date()
        let pid = window?.pid ?? rawPID

        // Codex r2 #2: same rule as `ground` / `capture_annotated`. A
        // window scope without an attributable AXWindow gets NO nodes —
        // the old app-root walk behind a frame filter let an overlapping
        // window of the same app contribute nodes, which the OCR join
        // then labelled with THIS window's text.
        let decision = window?.scopeDecision ?? .appRoot
        if let reason = decision.reason, let window {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return AugmentedTreeResult(
                ok: false, pid: Int32(pid), nodeCount: 0, inferredCount: 0,
                nodes: [], elapsedMs: ms, maxDepthUsed: maxDepth,
                error: AXScopePolicy.withheldHint(
                    tool: "ax_tree_augmented", reason: reason,
                    windowID: window.windowID, ownerName: window.ownerName
                ),
                errorCode: reason.rawValue,
                axScope: decision.axScope,
                axScopeReason: reason.rawValue
            )
        }
        let axScope = decision.axScope

        // 1. Walk the AX tree, collect nodes with frames. With a window
        //    scope the walk is ROOTED at that window's AXWindow, so a
        //    sibling window's subtree is never visited (Codex r2 #2);
        //    without one it is the app root, honestly reported as such.
        let root = window?.axElement ?? AXUIElementCreateApplication(pid)
        var axBoxes: [(node: AugmentedNode, rect: CGRect)] = []
        walk(element: root, depth: 0, maxDepth: maxDepth, into: &axBoxes)
        // v0.9 (C-2): the frame filter stays as the second line of
        // defence — nodes parked outside the window's frame are not this
        // window's UI and would be joined against OCR text they cannot
        // contain.
        if let window {
            axBoxes = axBoxes.filter { WindowIdentity.rect($0.rect, isWithin: window.bounds) }
        }

        if axBoxes.isEmpty {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return AugmentedTreeResult(
                ok: false, pid: Int32(pid), nodeCount: 0, inferredCount: 0,
                nodes: [], elapsedMs: ms, maxDepthUsed: maxDepth,
                error: "no AX nodes found — app may lack AX support",
                errorCode: "not_found",
                axScope: axScope,
                axScopeReason: nil
            )
        }

        // 2. Single OCR pass over the TARGET APP'S WINDOW (A-1/A-3).
        //
        // This used to OCR the main display. On a laptop the target window
        // is usually partly or fully covered, so the OCR text belonged to
        // whatever sat ON TOP of it — and the geometric join then stamped
        // that foreign text onto the covered app's AX nodes as
        // `inferredLabel` with confidence 0.8. A per-window capture can
        // only ever see the target's own content.
        //
        // Block coordinates come back in WINDOW-image PIXELS; convert
        // their centers to global screen POINTS so the join below compares
        // like with like against AX frames (which are in global points).
        let capture: ScreenController.CaptureResult
        let ocrBlocks: [ScreenController.OCRBlock]
        do {
            let (cap, result) = window == nil
                ? try await screen.ocrWindow(ownerPID: pid)
                : try await screen.ocrWindow(selected: window!.selected)
            capture = cap
            ocrBlocks = result.blocks
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return AugmentedTreeResult(
                ok: false, pid: Int32(pid), nodeCount: axBoxes.count, inferredCount: 0,
                nodes: axBoxes.map { $0.node }, elapsedMs: ms, maxDepthUsed: maxDepth,
                error: "window OCR pass failed for pid \(pid): \(error)",
                errorCode: Self.errorCode(for: error),
                axScope: axScope,
                axScopeReason: nil
            )
        }
        guard let windowBounds = capture.pointBounds,
              windowBounds.width > 0, windowBounds.height > 0 else {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return AugmentedTreeResult(
                ok: false, pid: Int32(pid), nodeCount: axBoxes.count, inferredCount: 0,
                nodes: axBoxes.map { $0.node }, elapsedMs: ms, maxDepthUsed: maxDepth,
                error: "window capture for pid \(pid) reported no point bounds; cannot map OCR to screen coordinates",
                errorCode: "capture_failed",
                axScope: axScope,
                axScopeReason: nil
            )
        }
        let ocrPointCenters: [CGPoint] = ocrBlocks.map { block in
            Self.ocrPixelCenterToGlobalPoints(
                blockX: block.x, blockY: block.y,
                blockW: block.width, blockH: block.height,
                imagePixelWidth: capture.width, imagePixelHeight: capture.height,
                windowBounds: windowBounds
            )
        }

        // 3. Geometric join
        var inferredCount = 0
        var out: [AugmentedNode] = []
        for box in axBoxes {
            // Nodes that already have an AX title/value keep their source.
            if let title = box.node.title, !title.isEmpty {
                out.append(box.node.withLabel(
                    inferred: nil, source: "ax", confidence: 1.0
                ))
                continue
            }
            if let value = box.node.value, !value.isEmpty {
                out.append(box.node.withLabel(
                    inferred: value, source: "ax", confidence: 1.0
                ))
                continue
            }
            // Unlabeled — find innermost AX frame that contains each OCR text.
            // (We iterate OCR observations ONCE, so innermost-match is
            // checked by comparing frame areas — the smaller containing
            // frame wins.)
            var bestOCR: (text: String, area: Double, overlapping: Bool)?
            for (blockIndex, block) in ocrBlocks.enumerated() {
                let ocrCenter = ocrPointCenters[blockIndex]
                guard box.rect.contains(ocrCenter) else { continue }

                // Check whether any OTHER ax box also contains this center
                // AND is smaller than the current one. If so, this ocr
                // belongs to the smaller box, not to `box`.
                let currentArea = Double(box.rect.width) * Double(box.rect.height)
                var smallerContaining = false
                var sameSizeContainer = false
                for other in axBoxes {
                    if other.rect == box.rect { continue }
                    if !other.rect.contains(ocrCenter) { continue }
                    let otherArea = Double(other.rect.width) * Double(other.rect.height)
                    if otherArea < currentArea { smallerContaining = true; break }
                    if abs(otherArea - currentArea) < 1.0 { sameSizeContainer = true }
                }
                if smallerContaining { continue }

                let overlapping = sameSizeContainer
                if bestOCR == nil || currentArea < bestOCR!.area {
                    bestOCR = (block.text, currentArea, overlapping)
                }
            }

            if let ocr = bestOCR {
                inferredCount += 1
                let conf = ocr.overlapping ? 0.5 : 0.8
                // v0.7.2 (BUG 6 re-fix): also cap OCR-sourced labels,
                // not just AX strings from walk(). An OCR pass over a
                // dense document can produce multi-thousand-char blocks.
                out.append(box.node.withLabel(
                    inferred: truncateAXString(ocr.text, max: 200),
                    source: "ocr_geometric",
                    confidence: conf
                ))
            } else {
                out.append(box.node.withLabel(
                    inferred: nil, source: "none", confidence: nil
                ))
            }
        }

        // v0.7.1 (BUG 6): apply maxNodes cap. Prefer nodes with a
        // resolved label (ax or ocr_geometric) so the truncated output
        // stays useful — unlabeled placeholders get dropped first.
        let capped: [AugmentedNode]
        if out.count > maxNodes {
            let labelled = out.filter { $0.labelSource != "none" }
            let unlabelled = out.filter { $0.labelSource == "none" }
            capped = Array((labelled + unlabelled).prefix(maxNodes))
        } else {
            capped = out
        }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return AugmentedTreeResult(
            ok: true,
            pid: Int32(pid),
            nodeCount: capped.count,
            inferredCount: inferredCount,
            nodes: capped,
            elapsedMs: ms,
            maxDepthUsed: maxDepth,
            error: capped.count < out.count
                ? "truncated to \(maxNodes) nodes of \(out.count) total (labelled first)"
                : nil,
            errorCode: nil,
            axScope: axScope,
            axScopeReason: nil
        )
    }

    private func walk(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        into out: inout [(node: AugmentedNode, rect: CGRect)]
    ) {
        if depth > maxDepth { return }
        let role = stringAttr(element, kAXRoleAttribute)
        // v0.7.2 fix (BUG 6 re-fix): truncate per-node strings at capture
        // time so a single AXValue carrying a Terminal scrollback buffer
        // (measured at 707K chars in the wild) can't blow past the 20MB
        // MCP context limit even though `maxNodes` already caps the
        // array length. Title/inferredLabel cap to 200 chars (display
        // text); value caps to 1000 chars (free-form content).
        let title = truncateAXString(stringAttr(element, kAXTitleAttribute), max: 200)
        let value = truncateAXString(stringAttr(element, kAXValueAttribute), max: 1000)
        let pos = pointAttr(element, kAXPositionAttribute)
        let size = sizeAttr(element, kAXSizeAttribute)

        let node = AugmentedNode(
            role: role, title: title, value: value,
            x: pos?.x, y: pos?.y,
            width: size?.width, height: size?.height,
            inferredLabel: nil, labelSource: nil, labelConfidence: nil
        )
        let rect: CGRect
        if let p = pos, let s = size {
            rect = CGRect(x: p.x, y: p.y, width: s.width, height: s.height)
        } else {
            rect = .zero
        }
        out.append((node, rect))

        var raw: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        if res == .success, let children = raw as? [AXUIElement] {
            for c in children {
                walk(element: c, depth: depth + 1, maxDepth: maxDepth, into: &out)
            }
        }
    }

    private func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    private func pointAttr(_ el: AXUIElement, _ attr: String) -> (x: Double, y: Double)? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return (Double(point.x), Double(point.y))
    }

    private func sizeAttr(_ el: AXUIElement, _ attr: String) -> (width: Double, height: Double)? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return (Double(size.width), Double(size.height))
    }
}

extension GroundingController.AugmentedNode {
    func withLabel(inferred: String?, source: String, confidence: Double?) -> Self {
        .init(
            role: role, title: title, value: value,
            x: x, y: y, width: width, height: height,
            inferredLabel: inferred,
            labelSource: source,
            labelConfidence: confidence
        )
    }
}

/// v0.7.2 (BUG 6): truncate large AX strings with an explicit marker so
/// callers can tell the value was clipped. Nil in → nil out; strings
/// within `max` pass through unchanged. Any longer string is chopped to
/// `max` Unicode scalars plus a `…[truncated N chars]` suffix so the
/// downstream JSON stays legible.
fileprivate func truncateAXString(_ s: String?, max: Int) -> String? {
    guard let s else { return nil }
    if s.count <= max { return s }
    let dropped = s.count - max
    return String(s.prefix(max)) + "…[truncated \(dropped) chars]"
}
