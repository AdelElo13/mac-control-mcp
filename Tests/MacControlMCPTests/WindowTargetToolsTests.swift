import Testing
import Foundation
@testable import MacControlMCP

/// v0.9 workstream A (C-2/C-3): every window-scoped tool accepts
/// `window_id` as an alternative target. These tests only exercise the
/// *rejection* paths — an id that no window carries, and a malformed one
/// — so they are safe on any machine (they never move, focus, resize or
/// capture a real window).
@Suite("window_id targeting")
struct WindowTargetToolsTests {

    /// CGWindowIDs are allocated from a low, monotonically increasing
    /// counter; no live window will ever carry a value this close to
    /// UInt32.max on a machine that has not been running for decades.
    static let absentWindowID: Double = 4_294_967_290

    /// Every tool that must accept `window_id`, with the other arguments
    /// it needs. `window_id` takes precedence, so the pid/index given
    /// here must NOT be used — the call has to fail with no_such_window
    /// rather than acting on pid 1.
    static let cases: [(tool: String, args: [String: JSONValue])] = [
        ("capture_window", [:]),
        ("focus_window", [:]),
        ("move_window", ["x": .number(10), "y": .number(10)]),
        ("resize_window", ["width": .number(100), "height": .number(100)]),
        ("set_window_state", ["state": .string("main")]),
        ("move_window_to_display", ["display_index": .number(0)]),
        ("ground", ["target": .string("anything")]),
        ("ax_tree_augmented", [:]),
        ("ocr_screen", [:])
    ]

    static func field(_ result: ToolCallResult, _ key: String) -> String? {
        guard case .object(let payload) = result.structuredContent,
              case .string(let value)? = payload[key] else { return nil }
        return value
    }

    @Test("every window-scoped tool accepts window_id in its schema")
    func schemaAdvertisesWindowID() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let byName = Dictionary(uniqueKeysWithValues: registry.toolDefinitions.map { ($0.name, $0) })
        for (tool, _) in Self.cases {
            guard let definition = byName[tool] else {
                Issue.record("tool \(tool) is not registered")
                continue
            }
            guard case .object(let schema) = definition.inputSchema,
                  case .object(let properties)? = schema["properties"] else {
                Issue.record("tool \(tool) has no schema properties")
                continue
            }
            #expect(properties["window_id"] != nil, "\(tool) must accept window_id")
            // window_id must never be *required* — pid/index stay valid.
            if case .array(let required)? = schema["required"] {
                #expect(!required.contains(.string("window_id")), "\(tool) must not require window_id")
            }
        }
    }

    @Test("an unknown window_id fails with error_code no_such_window and points at list_windows")
    func unknownWindowID() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        for (tool, extra) in Self.cases {
            var arguments = extra
            arguments["window_id"] = .number(Self.absentWindowID)
            // Deliberately supply a pid/index too: window_id must win, and
            // the call must NOT fall back to acting on this pid.
            arguments["pid"] = .number(1)
            arguments["index"] = .number(0)
            let result = await registry.callTool(name: tool, arguments: arguments)
            #expect(result.isError == true, "\(tool) should fail for an unknown window_id")
            #expect(Self.field(result, "error_code") == "no_such_window",
                    "\(tool) returned error_code \(Self.field(result, "error_code") ?? "nil")")
            #expect(Self.field(result, "hint")?.contains("list_windows") == true,
                    "\(tool) hint should mention list_windows")
        }
    }

    @Test("a malformed window_id is an invalid_argument, not a no_such_window")
    func malformedWindowID() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        for (tool, extra) in Self.cases {
            var arguments = extra
            arguments["window_id"] = .string("not-a-number")
            let result = await registry.callTool(name: tool, arguments: arguments)
            #expect(result.isError == true, "\(tool) should reject a non-numeric window_id")
            #expect(Self.field(result, "error_code") != "no_such_window")
        }
    }
}
