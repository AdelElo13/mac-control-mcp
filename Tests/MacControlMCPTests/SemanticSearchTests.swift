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

    // v0.10 C5: Finder publishes one text field per file; semantic alias
    // checks must not compile regular expressions for every row.
    @Test("search aliases reject 5000 ordinary file fields in under 50 ms")
    func fileFieldAliasCost() {
        let fields = (0..<5000).map { index in
            node("AXTextField", "Document \(index).pdf", value: "Document \(index).pdf", identifier: "fileNameTextField")
        }
        _ = AXSearch.search([node("AXTextField", identifier: "toolbarSearchField")], semantic: "search_field")
        let start = ProcessInfo.processInfo.systemUptime
        let hits = AXSearch.search(fields, semantic: "search_field")
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        print("C5 search_field synthetic_fields=5000 elapsed_ms=\(milliseconds) hits=\(hits.count)")
        #expect(hits.isEmpty)
        #expect(milliseconds < 50)
    }

    @Test("alias prefix rejection preserves camelCase, acronyms and embedded words")
    func aliasPrefixSemantics() {
        for identifier in ["toolbarSearchField", "AXSearchField", "addressAndSearchField", "omniboxField"] {
            #expect(AXSearch.search([node("AXTextField", identifier: identifier)], semantic: "search_field").count == 1)
        }
        #expect(AXSearch.search([node("AXButton", identifier: "toolbarGoBackButton")], semantic: "back").count == 1)
        #expect(AXSearch.search([node("AXButton", "Search this folder")], semantic: "search_field").first?.kind == "prefix")
        #expect(AXSearch.search([node("AXButton", "Start search now")], semantic: "search_field").first?.kind == "substring")
        #expect(AXSearch.search([node("AXTextField", "Research notes")], semantic: "search_field").isEmpty)
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

    @Test("search activation buttons are fallback only, including prefix-named fields")
    func searchButtonFallbackOnly() {
        let nodes = [node("AXWindow"), node("AXButton", "Search", parent: 0), node("AXTextField", "Search query", parent: 0)]
        #expect(AXSearch.search(nodes, semantic: "search_field").first?.index == 2)
        let subrole = [node("AXWindow"), node("AXButton", "Search", parent: 0), node("AXTextField", parent: 0, subrole: "AXSearchField")]
        #expect(AXSearch.search(subrole, semantic: "search_field").first?.index == 2)
    }

    @Test("semantic aliases do not match fragments of unrelated words")
    func aliasesHaveBoundaries() {
        let nodes = [node("AXButton", "Book"), node("AXButton", "Background Color"), node("AXButton", "Backup"), node("AXButton", "Research")]
        for target in ["ok", "back", "search_field"] {
            #expect(AXSearch.search(nodes, semantic: target).isEmpty)
        }
        #expect(AXSearch.search([node("AXButton", identifier: "goBackButton")], semantic: "back").count == 1)
    }

    @Test("a labeled unrelated field does not inherit a neighboring Search button")
    func searchNeighborMustBeUntitled() {
        let nodes = [node("AXWindow"), node("AXButton", "Search", parent: 0), node("AXTextField", "Name", parent: 0)]
        #expect(AXSearch.search(nodes, semantic: "search_field").map(\.index) == [1])
    }

    @Test("role-only regex results report the actual prefix or substring match")
    func roleRegexProvenance() {
        let nodes = [node("AXButton"), node("AXRadioButton")]
        let hits = AXSearch.search(nodes, role: "Button", regex: true)
        #expect(hits.map(\.field) == ["role", "role"])
        #expect(hits.map(\.kind) == ["substring", "substring"])
        #expect(AXSearch.search(nodes, role: "AXRadio", regex: true).first?.kind == "prefix")
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
