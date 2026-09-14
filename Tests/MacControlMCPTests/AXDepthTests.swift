import Testing
@testable import MacControlMCP

/// D-2: the AX search surface used to ship seven different depth
/// defaults (4 / 8 / 12 / 12 / 16 / 20 / 32), so "not found" could mean
/// either "absent" or "below this particular tool's ceiling". One
/// project-wide default, one cap, and every response echoes the depth it
/// actually used.
@Suite("AX depth defaults (D-2)")
struct AXDepthTests {
    @Test("one project-wide default and cap")
    func defaults() {
        #expect(AXDepth.default == 24)
        #expect(AXDepth.maxAllowed == 64)
        #expect(AXDepth.resolve(nil) == 24)
    }

    @Test("caller-supplied depth is honoured and clamped")
    func clamping() {
        #expect(AXDepth.resolve(1) == 1)
        #expect(AXDepth.resolve(17) == 17)
        #expect(AXDepth.resolve(64) == 64)
        #expect(AXDepth.resolve(0) == 1)
        #expect(AXDepth.resolve(-5) == 1)
        #expect(AXDepth.resolve(9_999) == AXDepth.maxAllowed)
    }

    @Test("ground shares the project-wide default")
    func groundingSharesDefault() {
        #expect(GroundingController.defaultMaxDepth == AXDepth.default)
        #expect(GroundingController.maxAllowedDepth == AXDepth.maxAllowed)
        #expect(GroundingController.resolveMaxDepth(nil) == AXDepth.default)
    }
}
