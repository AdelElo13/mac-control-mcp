import Testing
import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
@testable import MacControlMCP

/// C-9 / B-11 — knobs that trade verbosity for size, instead of the
/// old ones that traded correctness for size.
@Suite("AX payload budget (C-9)")
struct AXPayloadBudgetTests {

    // MARK: - fields

    @Test("omitted fields means every field")
    func fieldsDefault() {
        let resolved = AXPayload.resolveFields(nil, known: AXPayload.elementFields)
        #expect(resolved.fields == nil)
        #expect(resolved.unknown.isEmpty)
        let object: [String: JSONValue] = ["role": .string("AXButton"), "title": .string("Save")]
        #expect(AXPayload.project(object, fields: nil) == object)
    }

    @Test("fields keeps only the requested keys and reports typos")
    func fieldsProjection() {
        let resolved = AXPayload.resolveFields(
            .array([.string("id"), .string("role"), .string("colour")]),
            known: AXPayload.elementFields
        )
        #expect(resolved.fields == ["id", "role"])
        #expect(resolved.unknown == ["colour"])

        let object: [String: JSONValue] = [
            "id": .string("el_1"), "role": .string("AXButton"),
            "title": .string("Save"), "position": .object([:])
        ]
        let projected = AXPayload.project(object, fields: resolved.fields)
        #expect(Set(projected.keys) == ["id", "role"])
    }

    @Test("an empty fields array is treated as 'all', never as 'nothing'")
    func fieldsEmptyArray() {
        #expect(AXPayload.resolveFields(.array([]), known: AXPayload.elementFields).fields == nil)
    }

    // MARK: - interactive filter

    @Test("interactive filter matches the list_elements whitelist")
    func interactiveRoles() {
        #expect(AXPayload.isInteractive(role: "AXButton"))
        #expect(AXPayload.isInteractive(role: "AXTextField"))
        #expect(!AXPayload.isInteractive(role: "AXGroup"))
        #expect(!AXPayload.isInteractive(role: "AXStaticText"))
        #expect(!AXPayload.isInteractive(role: nil))
    }

    @Test("interactive_only keeps actionable nodes AND their ancestors")
    func interactiveKeepsAncestors() {
        // 0 root → 1 group → 2 button, plus 3 static text under root.
        let nodes = [
            AXPayload.ShapeNode(role: "AXApplication", frame: nil, childIndices: [1, 3]),
            AXPayload.ShapeNode(role: "AXGroup", frame: nil, childIndices: [2]),
            AXPayload.ShapeNode(role: "AXButton", frame: nil, childIndices: []),
            AXPayload.ShapeNode(role: "AXStaticText", frame: nil, childIndices: [])
        ]
        let kept = AXPayload.keptIndices(nodes: nodes, interactiveOnly: true, viewportOnly: false, windows: [])
        #expect(kept == [0, 1, 2])

        // Child indices are rewritten into the compacted array, so the
        // tree stays walkable.
        let remapped = AXPayload.remapChildren(nodes: nodes, kept: kept)
        #expect(remapped[0] == [1])
        #expect(remapped[1] == [2])
        #expect(remapped[2] == [])
    }

    @Test("no filters means no shaping at all")
    func noFilters() {
        let nodes = (0..<4).map { _ in AXPayload.ShapeNode(role: "AXGroup", frame: nil, childIndices: []) }
        #expect(AXPayload.keptIndices(nodes: nodes, interactiveOnly: false, viewportOnly: false, windows: []) == [0, 1, 2, 3])
    }

    // MARK: - viewport filter

    @Test("viewport filter keeps on-screen frames and drops parked ones")
    func viewport() {
        let window = CGRect(x: 0, y: 39, width: 1800, height: 1056)
        #expect(AXPayload.isInViewport(frame: CGRect(x: 100, y: 100, width: 20, height: 20), windows: [window]))
        // The classic parked-menu-item signature: 0×0 at y = screen height.
        #expect(!AXPayload.isInViewport(frame: CGRect(x: 0, y: 1169, width: 0, height: 0), windows: [window]))
        // A zero-sized frame INSIDE a window is still in the viewport.
        #expect(AXPayload.isInViewport(frame: CGRect(x: 500, y: 500, width: 0, height: 0), windows: [window]))
        // No geometry, or no windows to compare against → keep (absence
        // of evidence is not evidence of being off-screen).
        #expect(AXPayload.isInViewport(frame: nil, windows: [window]))
        #expect(AXPayload.isInViewport(frame: CGRect(x: 9_000, y: 9_000, width: 10, height: 10), windows: []))
    }

    @Test("viewport_only keeps an off-screen container that holds an on-screen control")
    func viewportKeepsAncestors() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let nodes = [
            AXPayload.ShapeNode(role: "AXApplication", frame: nil, childIndices: [1]),
            AXPayload.ShapeNode(role: "AXGroup", frame: CGRect(x: 5_000, y: 0, width: 1, height: 1), childIndices: [2]),
            AXPayload.ShapeNode(role: "AXButton", frame: CGRect(x: 10, y: 10, width: 50, height: 20), childIndices: [])
        ]
        let kept = AXPayload.keptIndices(nodes: nodes, interactiveOnly: false, viewportOnly: true, windows: [window])
        #expect(kept == [0, 1, 2])
    }

    // MARK: - byte budget

    @Test("max_bytes stops emission and flags truncation")
    func byteBudget() {
        let items = (0..<10).map { index in
            JSONValue.object(["id": .string("el_\(index)"), "role": .string("AXButton")])
        }
        let full = AXPayload.applyByteBudget(items, maxBytes: nil)
        #expect(full.items.count == 10)
        #expect(!full.truncated)

        let oneItem = AXPayload.encodedSize(items[0]) + 1
        let capped = AXPayload.applyByteBudget(items, maxBytes: oneItem * 3)
        #expect(capped.items.count == 3)
        #expect(capped.truncated)
        #expect(AXPayload.encodedSize(.array(capped.items)) < AXPayload.encodedSize(.array(items)))
    }

    @Test("max_bytes <= 0 means no cap, not an empty response")
    func byteBudgetZero() {
        #expect(AXPayload.resolveMaxBytes(.number(0)) == nil)
        #expect(AXPayload.resolveMaxBytes(.number(-1)) == nil)
        #expect(AXPayload.resolveMaxBytes(nil) == nil)
        #expect(AXPayload.resolveMaxBytes(.string("4096")) == 4_096)
    }

    @Test("encodedSize is the real JSON byte count")
    func encodedSize() {
        #expect(AXPayload.encodedSize(.string("ab")) == 4)          // "ab"
        #expect(AXPayload.encodedSize(.array([])) == 2)             // []
    }

    @Test("flag parses bools and the string forms clients send")
    func flags() {
        #expect(AXPayload.flag(.bool(true)))
        #expect(AXPayload.flag(.string("true")))
        #expect(AXPayload.flag(.string("1")))
        #expect(!AXPayload.flag(.string("no")))
        #expect(!AXPayload.flag(nil))
        #expect(!AXPayload.flag(.null))
    }

    // MARK: - handler wiring

    @Test("get_ui_tree reports the budget fields and honours interactive_only")
    func liveTreeBudget() async throws {
        guard let finder = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.finder" })?.processIdentifier,
              AXIsProcessTrusted()
        else { return }

        let registry = ToolRegistry(accessibility: AccessibilityController())
        func tree(_ extra: [String: JSONValue]) async -> [String: JSONValue] {
            var args: [String: JSONValue] = ["pid": .number(Double(finder))]
            args.merge(extra) { _, new in new }
            let result = await registry.callTool(name: "get_ui_tree", arguments: args)
            return result.structuredContent.objectValue ?? [:]
        }

        let full = await tree([:])
        #expect(full["max_depth_used"]?.intValue == AXDepth.default)
        #expect(full["nodes_visited"]?.intValue ?? 0 > 0)
        #expect(full["truncated"]?.boolValue != nil)
        let fullBytes = try #require(full["bytes"]?.intValue)

        let lean = await tree([
            "interactive_only": .bool(true),
            "fields": .array([.string("id"), .string("role"), .string("title")])
        ])
        let leanBytes = try #require(lean["bytes"]?.intValue)
        #expect(leanBytes < fullBytes)
        // Every surviving node is actionable or an ancestor, and carries
        // only the requested keys.
        for node in lean["nodes"]?.arrayValue ?? [] {
            let keys = Set(node.objectValue?.keys ?? [:].keys)
            #expect(keys.isSubset(of: ["id", "role", "title"]))
        }

        let capped = await tree(["max_bytes": .number(2_000)])
        #expect(capped["truncated"]?.boolValue == true)
        #expect((capped["bytes"]?.intValue ?? .max) < fullBytes)
    }
    @Test("B6 byte accounting does not serialize the container payload a second time")
    func countWithoutSerializingPayload() throws {
        let payload = JSONValue.object([
            "nodes": .array((0..<2000).map { .object([
                "id": .string("node_\($0)"), "role": .string("AXGroup"),
                "position": .object(["x": .number(10), "y": .number(20)])
            ]) }),
            "ok": .bool(true)
        ])
        var encodedContainers = 0
        let count = AXPayload.encodedSize(payload) { value in
            if value.arrayValue != nil || value.objectValue != nil { encodedContainers += 1 }
            return (try? JSONEncoder().encode(value))?.count ?? 0
        }
        #expect(count == (try JSONEncoder().encode(payload)).count)
        #expect(encodedContainers == 0)
    }

    @Test("B6 byte count matches transport escaping and numeric representations")
    func transportByteCount() throws {
        let values: [JSONValue] = [
            .string("é漢字😀/\"\\\n\t\r\u{0}\u{8}\u{12}\u{1F}\u{2028}\u{2029}"),
            .object(["/\"": .array([.null, .bool(false), .object([:]), .array([])])]),
            .array([0.0, -0.0, 1.25, 1e-10, 1e20, .infinity, -.infinity, .nan].map(JSONValue.number))
        ]
        for value in values {
            #expect(AXPayload.encodedSize(value) == (try JSONEncoder().encode(value)).count)
        }
    }
    @Test("B6 phase reporting includes byte accounting without changing encoded size")
    func byteAccountingPhase() throws {
        var payload: [String: JSONValue] = [
            "nodes": .array((0..<100).map { .object(["title": .string("row/\($0)")]) }),
            "timings_ms": .object(["walk": .number(1.25)])
        ]
        PayloadOptions([:], known: AXPayload.treeFields).annotate(
            &payload, maxDepthUsed: 24, nodesVisited: 100, truncated: false)
        #expect(payload["timings_ms"]?.objectValue?["byte_accounting"] != nil)
        let bytes = payload.removeValue(forKey: "bytes")?.intValue
        #expect(bytes == (try JSONEncoder().encode(JSONValue.object(payload))).count)
    }

}
