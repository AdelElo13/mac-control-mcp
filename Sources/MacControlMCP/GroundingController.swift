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

    struct GroundResult: Codable, Sendable {
        let ok: Bool
        let strategyUsed: String         // "ax" | "ocr" | "none"
        let x: Double?
        let y: Double?
        let confidence: Double           // 0.0 - 1.0
        let candidates: [Candidate]
        let error: String?
    }

    struct Candidate: Codable, Sendable {
        let role: String?
        let title: String?
        let x: Double
        let y: Double
        let source: String               // "ax" | "ocr"
        let confidence: Double
    }

    private let accessibility: AccessibilityController
    private let screen: ScreenController

    init(accessibility: AccessibilityController, screen: ScreenController) {
        self.accessibility = accessibility
        self.screen = screen
    }

    /// Find coordinates to click for `target` text. `strategy`:
    ///   .ax   → only AX lookup (fast). Returns nil if AX has nothing.
    ///   .ocr  → only OCR lookup (slow but universal).
    ///   .auto → AX first; if 0 matches or >3 ambiguous, fall through
    ///           to OCR for disambiguation.
    func ground(
        target: String,
        pid: pid_t,
        strategy: Strategy = .auto
    ) async -> GroundResult {
        let wantsAX = strategy == .ax || strategy == .auto
        let wantsOCR = strategy == .ocr || strategy == .auto

        // 1. AX attempt. `findElements` returns [(AXUIElement, ElementInfo)]
        var axCandidates: [Candidate] = []
        if wantsAX {
            let results = await accessibility.findElements(
                pid: pid,
                role: nil,
                title: target,
                value: nil,
                maxDepth: 16,
                limit: 20
            )
            // v0.7.1 fix (BUG 5): pull main display bounds to filter
            // off-screen AX candidates. macOS parks hidden menu items at
            // (0, screen_height) with size (0,0) — those are technically
            // "AX-matched" but cannot be clicked.
            let mainBounds = CGDisplayBounds(CGMainDisplayID())
            for (_, info) in results {
                guard let pos = info.position, let size = info.size else { continue }

                // Filter: AXApplication is a container, not a clickable
                // target. Clicking the app root is meaningless.
                if info.role == "AXApplication" { continue }

                // Filter: zero-size elements are off-screen / hidden.
                if size.width < 1 || size.height < 1 { continue }

                // Filter: parked-off-screen default (x≈0, y≈screen_height).
                // This is the classic "hidden menu item position" signature.
                if abs(pos.x) < 1 && abs(pos.y - Double(mainBounds.height)) < 1 {
                    continue
                }

                // Filter: outside visible display entirely (multi-monitor
                // agents may still want these, but for the common case we
                // drop them; caller can pass strategy=ocr to bypass).
                if pos.x + size.width < 0 || pos.y + size.height < 0 ||
                   pos.x > Double(mainBounds.width) * 2 {
                    continue
                }

                let centerX = pos.x + size.width / 2
                let centerY = pos.y + size.height / 2
                let titleLower = info.title?.lowercased() ?? ""
                let exact = titleLower == target.lowercased()
                let conf = exact ? 1.0 : 0.8
                axCandidates.append(.init(
                    role: info.role,
                    title: info.title,
                    x: centerX, y: centerY,
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
                    confidence: best.confidence,
                    candidates: axCandidates,
                    error: nil
                )
            }
            if strategy == .ax {
                return GroundResult(
                    ok: false, strategyUsed: "ax",
                    x: nil, y: nil, confidence: 0,
                    candidates: [], error: "no AX match"
                )
            }
        }

        // 2. OCR fallback / disambiguation
        var ocrCandidates: [Candidate] = []
        if wantsOCR {
            ocrCandidates = await ocrLookup(target: target)
        }

        // Merge and rank
        let all = axCandidates + ocrCandidates
        if let best = all.max(by: { $0.confidence < $1.confidence }) {
            return GroundResult(
                ok: true,
                strategyUsed: best.source,
                x: best.x, y: best.y,
                confidence: best.confidence,
                candidates: all,
                error: nil
            )
        }

        return GroundResult(
            ok: false, strategyUsed: "none",
            x: nil, y: nil, confidence: 0,
            candidates: [], error: "no grounding candidate from \(strategy.rawValue)"
        )
    }

    private func ocrLookup(target: String) async -> [Candidate] {
        // Use the screen controller's OCR pass. The OCR result contains
        // blocks with bounding boxes; we find the block whose text best
        // matches the target.
        let ocrBlocks: [ScreenController.OCRBlock]
        do {
            let (_, result) = try await screen.captureAndOCR(keepImage: false)
            ocrBlocks = result.blocks
        } catch {
            return []
        }
        let needle = target.lowercased()
        var out: [Candidate] = []
        for block in ocrBlocks {
            let text = block.text.lowercased()
            let exact = text == needle
            let contains = text.contains(needle)
            if !exact && !contains { continue }
            let centerX = block.x + block.width / 2
            let centerY = block.y + block.height / 2
            out.append(.init(
                role: nil,
                title: block.text,
                x: centerX, y: centerY,
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
        let error: String?
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
    func axTreeAugmented(pid: pid_t, maxDepth: Int = 12, maxNodes: Int = 300) async -> AugmentedTreeResult {
        let start = Date()

        // 1. Walk the AX tree, collect nodes with frames
        let root = AXUIElementCreateApplication(pid)
        var axBoxes: [(node: AugmentedNode, rect: CGRect)] = []
        walk(element: root, depth: 0, maxDepth: maxDepth, into: &axBoxes)

        if axBoxes.isEmpty {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return AugmentedTreeResult(
                ok: false, pid: Int32(pid), nodeCount: 0, inferredCount: 0,
                nodes: [], elapsedMs: ms,
                error: "no AX nodes found — app may lack AX support"
            )
        }

        // 2. Single OCR pass over the visible region
        let ocrBlocks: [ScreenController.OCRBlock]
        do {
            let (_, result) = try await screen.captureAndOCR(keepImage: false)
            ocrBlocks = result.blocks
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return AugmentedTreeResult(
                ok: false, pid: Int32(pid), nodeCount: axBoxes.count, inferredCount: 0,
                nodes: axBoxes.map { $0.node }, elapsedMs: ms,
                error: "OCR pass failed: \(error)"
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
            for block in ocrBlocks {
                let ocrCenter = CGPoint(
                    x: block.x + block.width / 2,
                    y: block.y + block.height / 2
                )
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
            error: capped.count < out.count
                ? "truncated to \(maxNodes) nodes of \(out.count) total (labelled first)"
                : nil
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
