import Testing
import Foundation
import AppKit
import ApplicationServices
@testable import MacControlMCP

/// C-4 — `element_at_point`, the inverse of `ground`.
@Suite("element_at_point (C-4)")
struct ElementAtPointTests {

    private func registry() -> ToolRegistry {
        ToolRegistry(accessibility: AccessibilityController())
    }

    @Test("the tool is registered with x/y required and pid optional")
    func registered() throws {
        let definition = try #require(
            registry().toolDefinitions.first { $0.name == "element_at_point" }
        )
        let schema = try #require(definition.inputSchema.objectValue)
        let properties = try #require(schema["properties"]?.objectValue)
        #expect(Set(properties.keys) == ["x", "y", "pid"])
        let required = Set((schema["required"]?.arrayValue ?? []).compactMap { $0.stringValue })
        #expect(required == ["x", "y"])
    }

    @Test("missing or non-numeric coordinates are rejected")
    func requiresCoordinates() async {
        let result = await registry().callTool(name: "element_at_point", arguments: ["x": .number(10)])
        #expect(result.isError)
        let nonFinite = await registry().callTool(
            name: "element_at_point",
            arguments: ["x": .number(.infinity), "y": .number(0)]
        )
        #expect(nonFinite.isError)
    }

    @Test("a malformed or dead pid is an explicit error, not a silent system-wide hit-test")
    func rejectsBadPID() async {
        let malformed = await registry().callTool(
            name: "element_at_point",
            arguments: ["x": .number(10), "y": .number(10), "pid": .string("nope")]
        )
        #expect(malformed.isError)

        guard AXIsProcessTrusted() else { return }
        let dead = await registry().callTool(
            name: "element_at_point",
            arguments: ["x": .number(10), "y": .number(10), "pid": .number(999_999)]
        )
        #expect(dead.isError)
        #expect(dead.structuredContent.objectValue?["error_code"]?.stringValue == "no_such_process")
    }

    @Test("without Accessibility trust the failure names the permission and the pane")
    func permissionSurface() async {
        guard !AXIsProcessTrusted() else { return }  // trusted here — nothing to assert
        let result = await registry().callTool(
            name: "element_at_point",
            arguments: ["x": .number(10), "y": .number(10)]
        )
        let payload = result.structuredContent.objectValue ?? [:]
        #expect(payload["error_code"]?.stringValue == "permission_missing")
        #expect(payload["pane"]?.stringValue == "accessibility")
    }

    @Test("an off-screen coordinate reports not_found, not a bare false")
    func notFound() async {
        guard AXIsProcessTrusted() else { return }
        let result = await registry().callTool(
            name: "element_at_point",
            arguments: ["x": .number(-99_999), "y": .number(-99_999)]
        )
        #expect(result.isError)
        #expect(result.structuredContent.objectValue?["error_code"]?.stringValue == "not_found")
    }

    @Test("hit-testing a real control returns its role, bounds, owner and a stable id")
    func liveHitTest() async throws {
        guard AXIsProcessTrusted(),
              let finder = NSWorkspace.shared.runningApplications
                  .first(where: { $0.bundleIdentifier == "com.apple.finder" })?.processIdentifier
        else { return }

        let registry = self.registry()
        // Take a real element from find_elements and hit-test its centre:
        // the two tools must agree about what lives at that point.
        let found = await registry.callTool(
            name: "find_elements",
            arguments: ["pid": .number(Double(finder)), "role": .string("AXButton"), "limit": .number(20)]
        )
        let elements = found.structuredContent.objectValue?["elements"]?.arrayValue ?? []
        guard let target = elements.first(where: { element in
            guard let size = element.objectValue?["size"]?.objectValue,
                  let width = size["width"]?.doubleValue, let height = size["height"]?.doubleValue
            else { return false }
            return width > 4 && height > 4
        })?.objectValue,
            let position = target["position"]?.objectValue,
            let size = target["size"]?.objectValue,
            let x = position["x"]?.doubleValue, let y = position["y"]?.doubleValue,
            let width = size["width"]?.doubleValue, let height = size["height"]?.doubleValue
        else { return }

        let result = await registry.callTool(
            name: "element_at_point",
            arguments: ["x": .number(x + width / 2), "y": .number(y + height / 2), "pid": .number(Double(finder))]
        )
        let payload = result.structuredContent.objectValue ?? [:]
        guard payload["ok"]?.boolValue == true else { return }  // covered by another window
        #expect(payload["pid"]?.intValue == Int(finder))
        #expect(payload["role"]?.stringValue != nil)
        #expect(payload["element_id"]?.stringValue?.hasPrefix("el_") == true)
        #expect(payload["ancestors"]?.arrayValue != nil)
        #expect((payload["ancestors"]?.arrayValue?.count ?? 0) <= 8)
        #expect(payload["bounds"]?.objectValue?["width"]?.doubleValue != nil)
    }
}
