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
        var readDelay: TimeInterval = 0
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)

        func node(_ id: pid_t, _ role: String, _ title: String = "", frame: CGRect? = nil, children: [pid_t] = []) {
            values[id] = .init(role: role, title: title, identifier: nil, subrole: nil, value: nil,
                               position: frame?.origin, size: frame?.size,
                               children: children.map { AXUIElementCreateApplication($0) })
        }

        func controller() -> AccessibilityController {
            AccessibilityController(readAttributes: { element, children in
                if self.readDelay > 0 { Thread.sleep(forTimeInterval: self.readDelay) }
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
        // v0.10 B4: BFS may find the window button first; explicitly
        // target the menu label when testing opt-in reachability.
        var args: [String: JSONValue] = ["role": .string("AXButton"), "include_menus": .bool(true)]
        if tool == "find_element" { args["title"] = .string("menu") }
        let included = await f.call(tool, args)
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
        let hit = try #require(await controller.findElementWithPath(pid: f.pid, role: "AXButton", title: "Search", includeMenus: false, shallowFirst: true))
        #expect(CFEqual(hit.element, AXUIElementCreateApplication(120)))
        let deep = try #require(await controller.findElementWithPath(pid: f.pid, role: "AXButton", title: "Search deep", includeMenus: false, shallowFirst: true))
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
        let required: Int

        init(required: Int = 2) { self.required = required }

        func read(_ element: AXUIElement, _ children: Bool) -> AXAttributeBatch.Values {
            condition.lock()
            active += 1
            peak = max(peak, active)
            condition.broadcast()
            let deadline = Date().addingTimeInterval(0.2)
            while peak < required {
                if !condition.wait(until: deadline) { break }
            }
            active -= 1
            condition.unlock()
            return .init(role: "AXApplication", title: nil, identifier: nil, subrole: nil,
                         value: nil, position: nil, size: nil, children: [])
        }
    }

    @Test("B7 different pids overlap while same-pid walks remain serialized")
    func concurrentPIDs() async {
        let different = Overlap(required: 3)
        let c = AccessibilityController(readAttributes: different.read, prepareAccessibility: { _ in })
        async let a = c.treeWalk(pid: 101, maxDepth: 1)
        async let b = c.treeWalk(pid: 102, maxDepth: 1)
        async let third = c.treeWalk(pid: 103, maxDepth: 1)
        _ = await (a, b, third)
        #expect(different.peak == 3)

        let same = Overlap()
        let d = AccessibilityController(readAttributes: same.read, prepareAccessibility: { _ in })
        async let x = d.treeWalk(pid: 101, maxDepth: 1)
        async let y = d.treeWalk(pid: 101, maxDepth: 1)
        _ = await (x, y)
        #expect(same.peak == 1)
    }

    @Test("B4 grounding prefers shallow candidates and continues after unusable shallow hits")
    func groundShallowFirst() async {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: [101, 120])
        for id: pid_t in 101...109 { f.node(id, "AXGroup", children: [id + 1]) }
        f.node(110, "AXButton", "Search deep", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        f.node(120, "AXButton", "Search", frame: CGRect(x: 40, y: 10, width: 20, height: 20))
        let c = GroundingController(accessibility: f.controller(), screen: ScreenController(),
                                    readDisplayBounds: { [.init(index: 0, rect: f.window)] })
        let result = await c.ground(target: "Search", pid: f.pid, strategy: .ax)
        #expect(result.ok)
        #expect(result.candidates.map(\.title) == ["Search"])
        #expect(!f.reads.contains(110))

        f.node(120, "AXButton", "Search", frame: .zero)
        let fallback = await c.ground(target: "Search", pid: f.pid, strategy: .ax)
        #expect(fallback.ok)
        #expect(fallback.candidates.map(\.title) == ["Search deep"])
    }

    @Test("B7 first-touch preparation for different pids also overlaps")
    func concurrentPreparation() async {
        let overlap = Overlap()
        let c = AccessibilityController(readAttributes: { _, _ in
            .init(role: "AXApplication", title: nil, identifier: nil, subrole: nil,
                  value: nil, position: nil, size: nil, children: [])
        }, prepareAccessibility: { pid in
            _ = overlap.read(AXUIElementCreateApplication(pid), false)
        })
        async let a = c.treeWalk(pid: 101, maxDepth: 1)
        async let b = c.treeWalk(pid: 102, maxDepth: 1)
        _ = await (a, b)
        #expect(overlap.peak == 2)
    }

    @Test("B3 retains the uncapped search space for a target beyond 2000 nodes")
    func lateSearchMatch() async throws {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: Array(101...2201))
        for id: pid_t in 101...2200 { f.node(id, "AXGroup") }
        f.node(2201, "AXButton", "late")
        let c = f.controller()
        let first = await c.findElementWithPath(pid: f.pid, role: "AXButton", title: "late")
        #expect(first != nil)
        let all = await c.findElements(pid: f.pid, role: "AXButton", title: "late", value: nil)
        #expect(all.count == 1)
    }

    @Test("B3 read-tool defaults must not make legacy wait/scroll helpers lose menus")
    func legacyHelperMenus() async {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: [101])
        f.node(101, "AXMenuBar", children: [102])
        f.node(102, "AXMenuItem", "Open")
        let hit = await f.controller().findElementWithPath(pid: f.pid, role: "AXMenuItem", title: "Open")
        #expect(hit != nil)
    }

    @Test("B3 menu opt-in and node budgets are discoverable on their read tools")
    func readSchemas() throws {
        let definitions = ToolRegistry(accessibility: AccessibilityController()).toolDefinitions
        for name in ["get_ui_tree", "find_elements", "find_element", "query_elements", "list_elements", "ground"] {
            let definition = try #require(definitions.first { $0.name == name })
            let props = try #require(definition.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(props["include_menus"]?.objectValue?["type"]?.stringValue == "boolean")
            if ["get_ui_tree", "query_elements", "list_elements"].contains(name) {
                #expect(props["node_cap"] != nil)
            }
        }
    }

    @Test("B2 clipped annotation preserves the ordered visible elements and path ids")
    func annotationIdentity() async {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: [101, 110])
        f.node(101, "AXGroup", frame: CGRect(x: 900, y: 900, width: 30, height: 30), children: [102])
        f.node(102, "AXButton", "hidden", frame: CGRect(x: 901, y: 901, width: 20, height: 20))
        f.node(110, "AXGroup", frame: .zero, children: [111, 112])
        f.node(111, "AXButton", "visible", frame: CGRect(x: 10, y: 10, width: 30, height: 30))
        f.node(112, "AXTextField", "partly visible", frame: CGRect(x: 790, y: 10, width: 30, height: 30))
        let c = f.controller()
        let before = await c.treeWalk(pid: f.pid, maxDepth: 24)
        let after = await c.treeWalk(pid: f.pid, maxDepth: 24, clipRects: [f.window])
        func elements(_ nodes: [AccessibilityController.TreeNode]) -> [JSONValue] {
            let geometry = nodes.map { ScreenAnnotator.ElementGeometry(
                role: $0.role, title: $0.title,
                frame: ToolRegistry.frame(position: $0.position, size: $0.size) ?? .zero
            ) }
            return ScreenAnnotator.filterInteractive(geometry, captureRect: f.window, limit: 200).map { index in
                .object(["id": .string(AXPath.identifier(pid: f.pid, path: nodes[index].path)),
                         "title": .string(nodes[index].title ?? ""),
                         "x": .number(geometry[index].frame.minX)])
            }
        }
        #expect(after.count < before.count)
        #expect(elements(before).count == 2)
        #expect(elements(before) == elements(after))
    }

    @Test("B7 same-pid health reads wait for pending AX preparation")
    func healthWaitsForPreparation() async {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let c = AccessibilityController(readAttributes: { _, _ in
            .init(role: "AXApplication", title: nil, identifier: nil, subrole: nil,
                  value: nil, position: nil, size: nil, children: [])
        }, prepareAccessibility: { _ in
            started.signal()
            _ = release.wait(timeout: .now() + 2)
        })
        let walk = Task { await c.treeWalk(pid: 101, maxDepth: 1) }
        #expect(await Self.received(started, timeout: 1))
        let probe = Task {
            _ = await c.probeAXTree(pid: 101)
            finished.signal()
        }
        #expect(await !Self.received(finished, timeout: 0.1))
        release.signal()
        _ = await walk.value
        await probe.value
    }

    @Test("B3 grounding excludes menus by default and restores them on opt-in")
    func groundingMenus() async {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: [101, 103])
        f.node(101, "AXMenuBar", children: [102])
        f.node(102, "AXButton", "Search menu", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        f.node(103, "AXButton", "Search window", frame: CGRect(x: 40, y: 10, width: 20, height: 20))
        let c = GroundingController(accessibility: f.controller(), screen: ScreenController(),
                                    readDisplayBounds: { [.init(index: 0, rect: f.window)] })
        let excluded = await c.ground(target: "Search", pid: f.pid, strategy: .ax)
        #expect(excluded.candidates.map(\.title) == ["Search window"])
        let included = await c.ground(target: "Search", pid: f.pid, strategy: .ax, includeMenus: true)
        #expect(included.candidates.map(\.title) == ["Search window", "Search menu"])
    }

    @Test("B4 ground stops on an exact usable hit without reading the remaining subtree")
    func groundExactEarlyExit() async {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: [101, 102, 103])
        f.node(101, "AXButton", "Search", frame: .zero)
        f.node(102, "AXButton", "Search", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        f.node(103, "AXGroup", children: Array(200...1200))
        for id: pid_t in 200...1200 { f.node(id, "AXStaticText") }
        let c = GroundingController(accessibility: f.controller(), screen: ScreenController(),
                                    readDisplayBounds: { [.init(index: 0, rect: f.window)] })
        let result = await c.ground(target: "Search", pid: f.pid, strategy: .ax)
        #expect(result.ok && result.confidence == 1)
        #expect(result.candidates.count == 1)
        #expect(f.reads.count == 3)
        print("[B4 ground] nodes_visited=\(result.nodesVisited) candidates=\(result.candidates.count)")
        #expect(!f.reads.contains(103))
    }

    @Test("B4 find_element prefers a later exact label over shallow substring fallbacks")
    func findExactEarlyExit() async {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: Array(101...123))
        for id: pid_t in 101...121 { f.node(id, "AXButton", "Search nearby") }
        f.node(122, "AXButton", "Search")
        f.node(123, "AXButton", "Search later")
        let result = await f.call("find_element", ["title": .string("Search")])
        #expect(result["element"]?.objectValue?["title"]?.stringValue == "Search")
        #expect(result["nodes_visited"]?.intValue == 23)
        #expect(f.reads.count == 23)
        #expect(!f.reads.contains(123))
    }

    @Test("B4 BFS reaches a depth-12 match without visiting the wide earlier sibling's children")
    func breadthFirstDeepMatch() async throws {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: [101])
        for id: pid_t in 101...110 { f.node(id, "AXGroup", children: [id + 1]) }
        f.node(111, "AXGroup", children: [112, 113])
        f.node(112, "AXGroup", children: Array(200...1200))
        f.node(113, "AXButton", "Search")
        for id: pid_t in 200...1200 { f.node(id, "AXStaticText") }
        let result = await f.controller().search(pid: f.pid, limit: 1, shallowFirst: true,
                                                predicate: { $0.title == "Search" })
        #expect(result.matches.first?.info.title == "Search")
        #expect(result.matches.first?.info.depth == 12)
        #expect(result.nodesVisited == 14)
        print("[B4 BFS] nodes_visited=\(result.nodesVisited) depth=\(result.matches.first?.info.depth ?? -1)")
        #expect(f.reads.count == Set(f.reads).count)
        #expect(!f.reads.contains(200))
    }

    @Test("B1/B3 read defaults bound expensive rows and expose phase measurements")
    func boundedReadDefaults() async {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: Array(101...2200))
        for id: pid_t in 101...2200 { f.node(id, "AXRow") }
        for tool in ["get_ui_tree", "query_elements", "list_elements"] {
            let result = await f.call(tool, tool == "query_elements" ? ["title_regex": .string("^missing$")] : [:])
            #expect(result["truncated"]?.boolValue == true)
            #expect((result["nodes_visited"]?.intValue ?? .max) <= (tool == "get_ui_tree" ? 1000 : 500))
            print("[B1/B3 bounded] \(tool) nodes_visited=\(result["nodes_visited"]?.intValue ?? -1) truncated=\(result["truncated"]?.boolValue ?? false)")
            let phases = result["timings_ms"]?.objectValue
            #expect(phases?["queue"] != nil)
            #expect(phases?["ax_fetch"] != nil)
            #expect(phases?["walk"] != nil)
        }
        let expanded = await f.call("get_ui_tree", ["node_cap": .number(2000)])
        #expect(expanded["nodes_visited"]?.intValue == 2000)
    }

    @Test("B3 list prunes offscreen descendants by default and permits explicit inclusion")
    func listDefaultViewport() async {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: [101, 103])
        f.node(101, "AXGroup", frame: CGRect(x: 900, y: 900, width: 20, height: 20), children: [102])
        f.node(102, "AXButton", "hidden", frame: CGRect(x: 901, y: 901, width: 10, height: 10))
        f.node(103, "AXButton", "visible", frame: CGRect(x: 10, y: 10, width: 10, height: 10))
        let result = await f.call("list_elements")
        #expect(!f.reads.contains(102))
        #expect(result["count"]?.intValue == 1)
        #expect(result["offscreen_excluded"]?.boolValue == true)
        f.reads = []
        let included = await f.call("list_elements", ["include_offscreen": .bool(true)])
        #expect(f.reads.contains(102))
        #expect(included["count"]?.intValue == 2)
    }

    @Test("B3 exact anchored query stops at limit before a wide early subtree")
    func anchoredQueryEarlyExit() async {
        let f = Fixture()
        f.node(f.pid, "AXApplication", children: [101, 102])
        f.node(101, "AXGroup", children: Array(200...1200))
        f.node(102, "AXButton", "Eject")
        for id: pid_t in 200...1200 { f.node(id, "AXStaticText") }
        let result = await f.call("query_elements", ["title_regex": .string("^Eject$"), "limit": .number(1)])
        #expect(result["count"]?.intValue == 1)
        #expect(result["nodes_visited"]?.intValue == 3)
        #expect(result["limit_reached"]?.boolValue == true)
        #expect(!f.reads.contains(200))
    }

    @Test("B1/B3 expensive AX reads stop at a reported elapsed budget")
    func elapsedReadBudget() async {
        let f = Fixture()
        f.readDelay = 0.002
        f.node(f.pid, "AXApplication", children: Array(101...200))
        for id: pid_t in 101...200 { f.node(id, "AXButton") }
        for tool in ["get_ui_tree", "query_elements", "list_elements"] {
            let result = await f.call(tool, ["time_budget_ms": .number(20)])
            #expect(result["truncated"]?.boolValue == true)
            #expect(result["timed_out"]?.boolValue == true)
            #expect((result["nodes_visited"]?.intValue ?? .max) < 30)
        }
    }

    @Test("B1/B4 exhausted budgets do not materialize a wide child frontier")
    func boundedFrontier() async {
        let child = AXUIElementCreateApplication(102)
        let wide = Array(repeating: child, count: 200_000)
        func controller(_ children: [AXUIElement]) -> AccessibilityController {
            AccessibilityController(readAttributes: { _, _ in
                .init(role: "AXApplication", title: nil, identifier: nil, subrole: nil,
                      value: nil, position: nil, size: nil, children: children)
            }, prepareAccessibility: { _ in })
        }
        let thin = controller([child])
        let broad = controller(wide)
        for collect in [false, true] {
            var thinTimes: [Double] = []
            var wideTimes: [Double] = []
            for _ in 0..<3 {
                let a = await thin.search(pid: 101, nodeCap: 1, limit: 1, collectNodes: collect)
                let b = await broad.search(pid: 101, nodeCap: 1, limit: 1, collectNodes: collect)
                #expect(a.nodesVisited == 1 && b.nodesVisited == 1)
                thinTimes.append(a.timingsMS["walk"] ?? .infinity)
                wideTimes.append(b.timingsMS["walk"] ?? .infinity)
            }
            // v0.10 B1/B4: a reached budget must not allocate one frame per
            // unvisited child. Compare medians outside fake-array construction.
            #expect(wideTimes.sorted()[1] <= thinTimes.sorted()[1] * 20 + 2)
            print("[B1/B4 frontier] collect=\(collect) thin=\(thinTimes.sorted()[1]) wide=\(wideTimes.sorted()[1]) ms")
        }
    }

    final class Lifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var live = 0
        private var highWater = 0
        func enter() { lock.lock(); live += 1; highWater = max(highWater, live); lock.unlock() }
        func leave() { lock.lock(); live -= 1; lock.unlock() }
        var peak: Int { lock.lock(); defer { lock.unlock() }; return highWater }
    }

    final class Temporary: NSObject {
        let lifetime: Lifetime
        init(_ lifetime: Lifetime) { self.lifetime = lifetime; super.init(); lifetime.enter() }
        deinit { lifetime.leave() }
    }

    @Test("B1/B7 consecutive walks drain AX temporaries and second walk stays within 20 percent")
    func consecutiveWalks() async {
        let lifetime = Lifetime()
        let pid = getpid()
        let c = AccessibilityController(readAttributes: { element, children in
            // v0.10 B1/B7: model autoreleased Foundation objects created by AX bridging.
            let temporary = Temporary(lifetime)
            _ = Unmanaged.passRetained(temporary).takeUnretainedValue().perform(NSSelectorFromString("autorelease"))
            Thread.sleep(forTimeInterval: 0.002)
            var id: pid_t = 0
            AXUIElementGetPid(element, &id)
            return .init(role: id == pid ? "AXApplication" : "AXButton", title: nil,
                         identifier: nil, subrole: nil, value: nil,
                         position: CGPoint(x: 10, y: 10), size: CGSize(width: 10, height: 10),
                         children: id == pid && children ? (101...150).map { AXUIElementCreateApplication($0) } : [])
        }, prepareAccessibility: { _ in })
        let start = ProcessInfo.processInfo.systemUptime
        let first = await c.treeWalkResult(pid: pid, maxDepth: 24)
        let firstMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let next = ProcessInfo.processInfo.systemUptime
        let second = await c.treeWalkResult(pid: pid, maxDepth: 24,
                                          clipRects: [CGRect(x: 0, y: 0, width: 800, height: 600)])
        let secondMS = (ProcessInfo.processInfo.systemUptime - next) * 1000
        #expect(first.nodesVisited == 51 && second.nodesVisited == 51)
        #expect(secondMS <= firstMS * 1.2)
        #expect(lifetime.peak == 1)
        print("[B1/B7 consecutive] first=\(firstMS) ms second=\(secondMS) ms peak_temporaries=\(lifetime.peak)")
    }

    private static func received(_ semaphore: DispatchSemaphore, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

}
