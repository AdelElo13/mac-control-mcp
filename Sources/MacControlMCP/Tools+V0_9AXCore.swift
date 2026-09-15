import Foundation
import ApplicationServices
import AppKit

// MARK: - v0.9 AX core tools

extension ToolRegistry {
    static let definitionsV0_9AXCore: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "element_at_point",
            description: "AX hit-test: what accessibility element is under a global screen coordinate? "
                + "The inverse of `ground` — use it to verify a coordinate BEFORE clicking it, to turn an OCR/vision box into a real AX element (with an element_id for perform_element_action / get_element_attributes), and to diagnose a click that did nothing. "
                + "Returns role, title, value, bounds, enabled, owning pid + app name, a stable element_id, hit_test_quality (direct, geometric, container, or direct_out_of_frame when an inconsistent direct hit could not be resolved), and the ancestor chain (nearest first, up to 8) so you can see which container you actually hit. "
                + "Omit pid to hit-test the whole screen (the topmost window wins); pass pid to ask that application specifically, which is the only way to hit-test a window another app is covering. "
                + "Coordinates are global screen points, top-left origin — the same space find_elements' position/size and ground's x/y use.",
            inputSchema: schema(
                properties: [
                    "x": .object(["type": .string("number"), "description": .string("Global screen X in points.")]),
                    "y": .object(["type": .string("number"), "description": .string("Global screen Y in points.")]),
                    "pid": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Optional — restrict the hit-test to this application instead of asking the system-wide element.")
                    ])
                ],
                required: ["x", "y"]
            )
        )
    ]

    /// v0.9 (C-4) — `element_at_point`.
    ///
    /// `grep -rn CopyElementAtPosition Sources/` returned nothing before
    /// this: there was no way to ask "what is under this coordinate",
    /// so an agent could not verify a coordinate before clicking, could
    /// not turn a vision/OCR box into an AX element, and had no way to
    /// diagnose a click that landed on nothing.
    func callElementAtPoint(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue else {
            return invalidArgument("element_at_point requires numeric x and y (global screen points).")
        }
        guard x.isFinite, y.isFinite else {
            return invalidArgument("element_at_point: x and y must be finite numbers.")
        }

        // AX hit-testing is an accessibility API call like any other:
        // without the trust grant it fails for every coordinate, which
        // would otherwise look identical to "nothing is there".
        guard await accessibility.checkPermission() else {
            return errorResult(
                "element_at_point needs Accessibility access — AXIsProcessTrusted() is false.",
                [
                    "ok": .bool(false),
                    "error_code": .string("permission_missing"),
                    "pane": .string("accessibility"),
                    "hint": .string("Grant Accessibility to the app macOS attributes this server to (see permissions_status.responsible_app), e.g. via open_permission_pane pane=accessibility, then retry.")
                ]
            )
        }

        // pid is optional, but a present-and-malformed pid is an error
        // rather than a silent fall-through to the system-wide element.
        var pid: pid_t?
        if let raw = arguments["pid"], raw != .null {
            guard let parsed = parsePID(raw) else {
                return invalidArgument("element_at_point: pid must be a positive integer.")
            }
            if let dead = noSuchProcessResult(pid: parsed, tool: "element_at_point") { return dead }
            pid = parsed
        }

        guard let direct = await accessibility.elementAtPoint(x: x, y: y, pid: pid) else {
            return errorResult(
                "No accessibility element at (\(x), \(y)).",
                [
                    "ok": .bool(false),
                    "error_code": .string("not_found"),
                    "x": .number(x),
                    "y": .number(y),
                    "pid": pid.map { .number(Double($0)) } ?? .null,
                    "hint": .string("Nothing is there, the point is off-screen, or the owning app exposes no AX tree (check probe_ax_tree). With a pid, only that app is hit-tested — omit it to ask the topmost window instead.")
                ]
            )
        }

        let refined = await accessibility.refinedHit(element: direct, x: x, y: y)
        let element = refined.element
        guard let hit = await accessibility.describeHit(element: element, ancestorLimit: 8) else {
            return errorResult("Hit element disappeared.", ["ok": .bool(false), "error_code": .string("not_found")])
        }

        // A hit-tested element has no downward walk behind it, so its id
        // comes from the upward path reconstruction (AXPath.upwardPath).
        // Same (pid, path) → same id as find_elements would mint for it.
        let id = await elementCache.store(element, pid: hit.pid, path: hit.path)

        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "hit_test_quality": .string(refined.quality),
            "x": .number(x),
            "y": .number(y),
            "pid": .number(Double(hit.pid)),
            "app_name": hit.appName.map(JSONValue.string) ?? .null,
            "element_id": .string(id),
            "stable_id": .bool(hit.path != nil),
            "role": hit.info.role.map(JSONValue.string) ?? .null,
            "title": hit.info.title.map(JSONValue.string) ?? .null,
            "value": hit.info.value.map(JSONValue.string) ?? .null,
            "enabled": hit.enabled.map(JSONValue.bool) ?? .null,
            "ancestors": .array(hit.ancestors.map { ancestor in
                .object([
                    "role": ancestor.role.map(JSONValue.string) ?? .null,
                    "title": ancestor.title.map(JSONValue.string) ?? .null
                ])
            })
        ]
        if let position = hit.info.position, let size = hit.info.size {
            payload["bounds"] = .object([
                "x": .number(position.x),
                "y": .number(position.y),
                "width": .number(size.width),
                "height": .number(size.height)
            ])
        } else {
            payload["bounds"] = .null
        }

        let label = hit.info.title.map { " \"\($0)\"" } ?? ""
        return successResult(
            "Hit \(hit.info.role ?? "AXUnknown")\(label) in \(hit.appName ?? "pid \(hit.pid)").",
            payload
        )
    }
}
