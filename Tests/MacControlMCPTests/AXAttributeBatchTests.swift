import Testing
import Foundation
import ApplicationServices
import CoreGraphics
@testable import MacControlMCP

/// Pure decoding tests for the batched AX attribute read used by every
/// tree walk (get_ui_tree / find_element(s) / query_elements /
/// list_elements). The live-IPC half is covered by the ControlZoo and
/// real-app matrix suites; these pin the slot semantics.
@Suite("AXAttributeBatch")
struct AXAttributeBatchTests {
    /// A missing attribute comes back from
    /// AXUIElementCopyMultipleAttributeValues as an AXValue of type
    /// .axError in its slot.
    private func axError(_ code: AXError = .noValue) -> AnyObject {
        var err = code
        return AXValueCreate(.axError, &err)!
    }

    private func axPoint(_ x: CGFloat, _ y: CGFloat) -> AnyObject {
        var p = CGPoint(x: x, y: y)
        return AXValueCreate(.cgPoint, &p)!
    }

    private func axSize(_ w: CGFloat, _ h: CGFloat) -> AnyObject {
        var s = CGSize(width: w, height: h)
        return AXValueCreate(.cgSize, &s)!
    }

    @Test("attribute name order matches decode indices")
    func nameOrder() {
        #expect(AXAttributeBatch.infoAttributes == [
            "AXRole", "AXTitle", "AXDescription", "AXIdentifier", "AXValue", "AXPosition", "AXSize"
        ])
        #expect(AXAttributeBatch.nodeAttributes == AXAttributeBatch.infoAttributes + ["AXChildren", "AXSheets"])
    }

    @Test("decodes a fully populated node")
    func fullNode() {
        let child1 = AXUIElementCreateApplication(101)
        let child2 = AXUIElementCreateApplication(102)
        let sheet = AXUIElementCreateApplication(103)
        let slots: [AnyObject] = [
            "AXButton" as NSString,
            "Save" as NSString,
            "ignored description" as NSString,
            "save-id" as NSString,
            "hello" as NSString,
            axPoint(10, 20),
            axSize(30, 40),
            [child1, child2] as NSArray,
            [sheet] as NSArray
        ]
        let v = AXAttributeBatch.decode(slots, includeChildren: true)
        #expect(v.role == "AXButton")
        #expect(v.title == "Save")
        #expect(v.value == "hello")
        #expect(v.position == CGPoint(x: 10, y: 20))
        #expect(v.size == CGSize(width: 30, height: 40))
        #expect(v.children.count == 3)
        #expect(CFEqual(v.children[0], child1))
        #expect(CFEqual(v.children[2], sheet))
    }

    @Test("axError slots decode as absent")
    func missingAttributes() {
        let slots: [AnyObject] = Array(repeating: axError(), count: AXAttributeBatch.nodeAttributes.count)
        let v = AXAttributeBatch.decode(slots, includeChildren: true)
        #expect(v.role == nil)
        #expect(v.title == nil)
        #expect(v.value == nil)
        #expect(v.position == nil)
        #expect(v.size == nil)
        #expect(v.children.isEmpty)
    }

    @Test("title falls back past empty/whitespace AXTitle to AXDescription, then AXIdentifier")
    func titleFallback() {
        var slots: [AnyObject] = Array(repeating: axError(), count: AXAttributeBatch.infoAttributes.count)
        slots[1] = "   " as NSString
        slots[2] = "aria label" as NSString
        #expect(AXAttributeBatch.decode(slots, includeChildren: false).title == "aria label")

        slots[2] = "" as NSString
        slots[3] = "ident" as NSString
        #expect(AXAttributeBatch.decode(slots, includeChildren: false).title == "ident")

        slots[3] = axError()
        #expect(AXAttributeBatch.decode(slots, includeChildren: false).title == nil)
    }

    @Test("value conversions mirror the per-attribute helper")
    func valueConversions() {
        var slots: [AnyObject] = Array(repeating: kCFNull, count: AXAttributeBatch.infoAttributes.count)
        slots[4] = NSNumber(value: 1)
        #expect(AXAttributeBatch.decode(slots, includeChildren: false).value == "1")
        slots[4] = NSAttributedString(string: "rich")
        #expect(AXAttributeBatch.decode(slots, includeChildren: false).value == "rich")
        // An element-valued AXValue (e.g. a scroll area's value) is not a string.
        slots[4] = AXUIElementCreateSystemWide()
        #expect(AXAttributeBatch.decode(slots, includeChildren: false).value == nil)
    }

    @Test("geometry slots require the matching AXValue type")
    func geometryTypeChecks() {
        var slots: [AnyObject] = Array(repeating: kCFNull, count: AXAttributeBatch.infoAttributes.count)
        slots[5] = axSize(1, 2)     // wrong type in the position slot
        slots[6] = axPoint(3, 4)    // wrong type in the size slot
        let v = AXAttributeBatch.decode(slots, includeChildren: false)
        #expect(v.position == nil)
        #expect(v.size == nil)
    }

    @Test("children are ignored unless requested, and non-elements are filtered")
    func childrenHandling() {
        var slots: [AnyObject] = Array(repeating: kCFNull, count: AXAttributeBatch.nodeAttributes.count)
        slots[7] = [AXUIElementCreateSystemWide(), "not an element" as NSString] as NSArray
        #expect(AXAttributeBatch.decode(slots, includeChildren: true).children.count == 1)
        #expect(AXAttributeBatch.decode(slots, includeChildren: false).children.isEmpty)
        // Short slot arrays (info-only fetch) never index out of bounds.
        #expect(AXAttributeBatch.decode(Array(slots.prefix(7)), includeChildren: true).children.isEmpty)
    }

    @Test("live fetch on a non-existent pid degrades to all-absent, not a crash")
    func liveFetchInvalidPid() {
        let v = AXAttributeBatch.fetch(AXUIElementCreateApplication(999_999), includeChildren: true)
        #expect(v.role == nil)
        #expect(v.children.isEmpty)
    }
}
