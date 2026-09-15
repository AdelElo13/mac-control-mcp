import Testing
import Foundation
import ApplicationServices
import CoreGraphics
@testable import MacControlMCP

/// v0.10 B1/B3/B4/A4: exercise the real walks with only AX IPC replaced.
@Suite("AX walk performance regressions", .serialized)
struct AXWalkPerformanceTests {
    final class Fixture: @unchecked Sendable {
        let pid = getpid()
        let lock = NSLock()
        var values: [pid_t: AXAttributeBatch.Values] = [:]
        var reads: [pid_t] = []
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)

        func node(_ id: pid_t, _ role: String, _ title: String = "", frame: CGRect? = nil, children: [pid_t] = []) {
            values[id] = .init(role: role, title: title, identifier: nil, subrole: nil, value: nil,
                               position: frame?.origin, size: frame?.size,
                               children: children.map { AXUIElementCreateApplication($0) })
        }

        func controller() -> AccessibilityController {
            AccessibilityController(readAttributes: { element, children in
                var id: pid_t = 0
                AXUIElementGetPid(element, &id)
                self.lock.lock()
                self.reads.append(id)
                let v = self.values[id]!
                self.lock.unlock()
                return .init(role: v.role, title: v.title, identifier: v.identifier, subrole: v.subrole,
                             value: v.value, position: v.position, size: v.size, children: children ? v.children : [])
            }, prepareAccessibility: { _ in }, readWindowFrames: { _ in [self.window] })
        }

        func call(_ tool: String, _ args: [String: JSONValue] = [:]) async -> [String: JSONValue] {
            var args = args
            args["pid"] = .number(Double(pid))
            return await ToolRegistry(accessibility: controller()).callTool(name: tool, arguments: args).structuredContent.objectValue ?? [:]
        }
    }

    @Test("A4 filters hidden rows before counting the match limit")
    func filterBeforeLimit() async {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: [101, 102])
        f.node(101, "AXRow", "hidden", frame: CGRect(x: 900, y: 900, width: 20, height: 20))
        f.node(102, "AXRow", "visible", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        let result = await f.call("find_elements", ["role": .string("AXRow"), "viewport_only": .bool(true), "limit": .number(1)])
        #expect(result["count"]?.intValue == 1)
        #expect(result["elements"]?.arrayValue?.first?.objectValue?["title"]?.stringValue == "visible")
    }

    @Test("A4 filters noninteractive matches before counting the limit")
    func interactiveBeforeLimit() async {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: [101, 102])
        f.node(101, "AXStaticText", "label")
        f.node(102, "AXButton", "button")
        let result = await f.call("find_elements", ["interactive_only": .bool(true), "limit": .number(1)])
        #expect(result["count"]?.intValue == 1)
        #expect(result["elements"]?.arrayValue?.first?.objectValue?["role"]?.stringValue == "AXButton")
    }

    @Test("B1 skips off-window descendants but descends through zero-size groups")
    func viewportPruning() async {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: [101, 103])
        f.node(101, "AXGroup", frame: CGRect(x: 900, y: 900, width: 20, height: 20), children: [102])
        f.node(102, "AXButton", "offscreen", frame: CGRect(x: 900, y: 900, width: 10, height: 10))
        f.node(103, "AXGroup", frame: .zero, children: [104])
        f.node(104, "AXButton", "visible", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        let result = await f.call("get_ui_tree", ["viewport_only": .bool(true)])
        #expect(!f.reads.contains(102))
        #expect(f.reads.contains(104))
        #expect(result["nodes"]?.arrayValue?.contains { $0.objectValue?["title"]?.stringValue == "visible" } == true)
    }

    @Test("B3 excludes menu descendants by default and opt-in restores them", arguments: ["get_ui_tree", "find_elements", "find_element", "query_elements", "list_elements"])
    func menus(_ tool: String) async {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: [101, 103])
        f.node(101, "AXMenuBar", children: [102])
        f.node(102, "AXButton", "menu")
        f.node(103, "AXButton", "window")
        let result = await f.call(tool, ["role": .string("AXButton")])
        #expect(result["menus_excluded"]?.boolValue == true)
        #expect(!f.reads.contains(102))
        f.reads = []
        let included = await f.call(tool, ["role": .string("AXButton"), "include_menus": .bool(true)])
        #expect(included["menus_excluded"]?.boolValue == false)
        #expect(f.reads.contains(102))
    }

    @Test("B4 finds a shallow match before an earlier deep match and falls back when needed")
    func shallowFirst() async throws {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: [101, 120])
        for id: pid_t in 101...109 { f.node(id, "AXGroup", children: [id + 1]) }
        f.node(110, "AXButton", "Search deep")
        f.node(120, "AXButton", "Search shallow")
        let controller = f.controller()
        let hit = try #require(await controller.findElementWithPath(pid: f.pid, role: "AXButton", title: "Search"))
        #expect(CFEqual(hit.element, AXUIElementCreateApplication(120)))
        let deep = try #require(await controller.findElementWithPath(pid: f.pid, role: "AXButton", title: "Search deep"))
        #expect(CFEqual(deep.element, AXUIElementCreateApplication(110)))
    }

    @Test("B3 query and list stop at the requested node cap", arguments: ["query_elements", "list_elements"])
    func nodeCap(_ tool: String) async {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: [101, 102])
        f.node(101, "AXButton", "first")
        f.node(102, "AXButton", "second")
        let result = await f.call(tool, ["node_cap": .number(2), "role_regex": .string("AXButton")])
        #expect(result["count"]?.intValue == 1)
        #expect(result["node_cap_reached"]?.boolValue == true)
        #expect(result["nodes_visited"]?.intValue == 2)
        #expect(!f.reads.contains(102))
    }
    final class Overlap: @unchecked Sendable {
        let condition = NSCondition()
        var active = 0
        var peak = 0

        func read(_ element: AXUIElement, _ children: Bool) -> AXAttributeBatch.Values {
            condition.lock()
            active += 1
            peak = max(peak, active)
            condition.broadcast()
            if active < 2 { _ = condition.wait(until: Date().addingTimeInterval(0.2)) }
            active -= 1
            condition.unlock()
            return .init(role: "AXApplication", title: nil, identifier: nil, subrole: nil,
                         value: nil, position: nil, size: nil, children: [])
        }
    }

    @Test("B7 different pids overlap while same-pid walks remain serialized")
    func concurrentPIDs() async {
        let different = Overlap()
        let c = AccessibilityController(readAttributes: different.read, prepareAccessibility: { _ in })
        async let a = c.treeWalk(pid: 101, maxDepth: 1)
        async let b = c.treeWalk(pid: 102, maxDepth: 1)
        _ = await (a, b)
        #expect(different.peak == 2)

        let same = Overlap()
        let d = AccessibilityController(readAttributes: same.read, prepareAccessibility: { _ in })
        async let x = d.treeWalk(pid: 101, maxDepth: 1)
        async let y = d.treeWalk(pid: 101, maxDepth: 1)
        _ = await (x, y)
        #expect(same.peak == 1)
    }

}
