import Testing
import Foundation
import ApplicationServices
@testable import MacControlMCP

// v0.10 C5: model the observed AX quirks without driving the desktop.
@Suite("Semantic search (v0.10 C5)")
struct SemanticSearchTests {
    func node(_ role: String, _ title: String = "", value: String = "", identifier: String = "", parent: Int? = nil, subrole: String = "") -> AXSearch.Node {
        let slots: [AnyObject] = [role as NSString, title as NSString, kCFNull, identifier as NSString, value as NSString, kCFNull, kCFNull, subrole as NSString]
        return AXSearch.Node(attrs: AXAttributeBatch.decode(slots, includeChildren: false), parent: parent)
    }

    @Test("exact window button wins before menu item, prefix group and color well")
    func ranking() {
        let nodes = [node("AXMenuBar"), node("AXMenuItem", "Back", parent: 0), node("AXWindow"), node("AXGroup", "Back/Forward", parent: 2), node("AXColorWell", "Back", parent: 2), node("AXButton", "Back", parent: 3)]
        let hits = AXSearch.search(nodes, title: "back")
        #expect(hits.first?.index == 5)
        #expect(hits.first?.field == "title")
        #expect(hits.first?.kind == "exact")
        #expect(AXSearch.search(nodes, semantic: "back").map(\.index) == [5])
    }

    @Test("untitled Settings field outranks neighboring Search button; Finder button remains a fallback")
    func searchField() {
        let nodes = [node("AXWindow"), node("AXGroup", parent: 0), node("AXButton", "Search", parent: 1), node("AXTextField", parent: 1)]
        #expect(AXSearch.search(nodes, semantic: "search_field").first?.index == 3)
        #expect(AXSearch.search(Array(nodes.prefix(3)), semantic: "search_field").first?.index == 2)
    }

    @Test("sidebar labels come from static text values, tabs and links stay role constrained")
    func namedTargets() {
        let nodes = [node("AXOutline"), node("AXRow", parent: 0), node("AXCell", parent: 1), node("AXStaticText", value: "Downloads", parent: 2), node("AXTabGroup"), node("AXRadioButton", "News", parent: 4), node("AXLink", value: "Read more")]
        #expect(AXSearch.search(nodes, semantic: "sidebar_item(Downloads)").first?.index == 2)
        #expect(AXSearch.search(nodes, semantic: "tab(News)").first?.index == 5)
        #expect(AXSearch.search(nodes, semantic: "link(Read more)").first?.index == 6)
        #expect(AXSearch.search(nodes, role: "Button").isEmpty)
    }

    @Test("forward close ok cancel use button labels or close subrole")
    func buttonTargets() {
        let nodes = [node("AXButton", "Go forward"), node("AXButton", subrole: "AXCloseButton"), node("AXButton", "OK"), node("AXButton", "Cancel")]
        for (target, index) in [("forward", 0), ("close", 1), ("ok", 2), ("cancel", 3)] {
            #expect(AXSearch.search(nodes, semantic: target).first?.index == index)
        }
    }

    @Test("regex labels cover description value and identifier with matched-field provenance")
    func regexLabels() {
        let nodes = [node("AXStaticText", "identifier-like-title", value: "Family", identifier: "family-id")]
        let value = AXSearch.search(nodes, title: "^Family$", regex: true)
        #expect(value.first?.field == "value")
        #expect(value.first?.kind == "exact")
        #expect(AXSearch.search(nodes, title: "^family-id$", regex: true).first?.field == "identifier")
    }
}
