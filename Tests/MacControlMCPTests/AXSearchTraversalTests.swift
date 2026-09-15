import Testing
import Foundation
import ApplicationServices
@testable import MacControlMCP

// v0.10 C5 regression: measure the production traversal without desktop IPC.
@Suite("AX search traversal (v0.10 C5)")
struct AXSearchTraversalTests {
    struct Fixture {
        let role: String
        var title: String = ""
        var value: String = ""
        var children: [Int] = []

        var attrs: AXAttributeBatch.Values {
            let slots: [AnyObject] = [role as NSString, title as NSString, kCFNull, kCFNull,
                                      value as NSString, kCFNull, kCFNull, kCFNull]
            return AXAttributeBatch.decode(slots, includeChildren: false)
        }
    }

    func walk(_ fixture: [Fixture], query: AXSearch.Query, limit: Int = 1, nodeCap: Int = 5000, deadline: Date = .distantFuture) -> AXSearch.WalkResult<Int> {
        var reads = 0
        let result = AXSearch.walk(root: 0, maxDepth: 24, nodeCap: nodeCap, deadline: deadline, query: query, limit: limit) { index, _, _ in
            reads += 1
            return (fixture[index].attrs, fixture[index].children)
        }
        #expect(reads == result.entries.count)
        return result
    }

    @Test("early exact and role-only hits avoid the remaining thousand nodes")
    func earlyExact() {
        let fixture = [Fixture(role: "AXWindow", children: Array(1...1000))]
            + (1...1000).map { Fixture(role: "AXButton", title: $0 == 1 ? "Save" : "Other") }
        for query in [AXSearch.Query(role: "AXButton"), AXSearch.Query(role: "AXButton", title: "Save")] {
            let result = walk(fixture, query: query)
            print("C5 early limit=1 nodes_visited=\(result.entries.count) tree_size=\(fixture.count)")
            #expect(result.entries.count == 2)
            #expect(result.stoppedEarly)
            #expect(result.hits.first?.index == 1)
        }
        let five = walk(fixture, query: .init(role: "AXButton"), limit: 5)
        print("C5 role limit=5 nodes_visited=\(five.entries.count) tree_size=\(fixture.count)")
        #expect(five.entries.count == 6)
        #expect(five.hits.count == 5)
    }

    @Test("substring and prefix hits keep walking and ranking beats DFS")
    func partialHitsKeepRanking() {
        let fixture = [Fixture(role: "AXWindow", children: [1, 2, 3]),
                       Fixture(role: "AXButton", title: "Please Save"),
                       Fixture(role: "AXButton", title: "Save changes"),
                       Fixture(role: "AXButton", title: "Save document")]
        let result = walk(fixture, query: .init(role: "AXButton", title: "Save"))
        #expect(result.entries.count == 4)
        #expect(result.hits.first?.index == 2)
        #expect(result.hits.first?.kind == "prefix")
        #expect(!result.stoppedEarly)
    }

    @Test("single exact menu hit cannot hide the first exact window hit")
    func menuDoesNotStop() {
        let fixture = [Fixture(role: "AXApplication", children: [1, 3]),
                       Fixture(role: "AXMenuBar", children: [2]),
                       Fixture(role: "AXButton", title: "Save"),
                       Fixture(role: "AXWindow", children: [4, 5]),
                       Fixture(role: "AXButton", title: "Save"),
                       Fixture(role: "AXButton", title: "Later")]
        let result = walk(fixture, query: .init(role: "AXButton", title: "Save"))
        #expect(result.entries.count == 5)
        #expect(result.hits.first?.index == 4)
    }

    @Test("both title and value must be exact before early exit")
    func allFiltersMustBeExact() {
        let fixture = [Fixture(role: "AXWindow", children: [1, 2, 3]),
                       Fixture(role: "AXButton", title: "Save", value: "Draft copy"),
                       Fixture(role: "AXButton", title: "Save", value: "Draft"),
                       Fixture(role: "AXButton", title: "Later")]
        let result = walk(fixture, query: .init(role: "AXButton", title: "Save", value: "Draft"))
        #expect(result.entries.count == 3)
        #expect(result.hits.first?.index == 2)
    }

    @Test("semantic targets scan fully and retain node cap and deadline")
    func semanticBudget() {
        let fixture = [Fixture(role: "AXWindow", children: [1, 2, 3]),
                       Fixture(role: "AXButton", title: "Search"),
                       Fixture(role: "AXTextField", title: "Search query"),
                       Fixture(role: "AXButton", title: "Later")]
        let query = AXSearch.Query(semantic: "search_field")
        let result = walk(fixture, query: query)
        #expect(result.entries.count == 4)
        #expect(result.hits.first?.index == 2)
        #expect(!result.stoppedEarly)
        #expect(walk(fixture, query: query, nodeCap: 2).entries.count == 2)
        #expect(walk(fixture, query: query, nodeCap: 2).truncated)
        #expect(walk(fixture, query: query, deadline: .distantPast).entries.isEmpty)
    }
}
