import Testing
import Foundation
@testable import MacControlMCP

/// v0.10.2 — tools must not report success for an action that did nothing.
/// Found by extending ControlZoo: NSColorWell accepted an AXValue write with
/// ax_status 0 and kept its colour, and targeted type_text reported
/// verified:true because it counted the focus it had set itself.
@Suite("Verification honesty (v0.10.2)")
struct VerificationHonestyTests {
    typealias C = ToolRegistry.ComparableAttribute

    @Test("a write that reads back as requested is applied")
    func applied() {
        #expect(ToolRegistry.writeVerdict(requested: .string("abc"), before: .text("x"), after: .text("abc")) == .applied)
        #expect(ToolRegistry.writeVerdict(requested: .number(73.5), before: .number(25), after: .number(73.5)) == .applied)
        #expect(ToolRegistry.writeVerdict(requested: .bool(true), before: .number(0), after: .number(1)) == .applied)
        #expect(ToolRegistry.writeVerdict(requested: .bool(false), before: .number(1), after: .number(0)) == .applied)
        #expect(ToolRegistry.writeVerdict(requested: .string("42"), before: .number(1), after: .number(42)) == .applied)
        // writing the value it already has is still "applied", not a no-op
        #expect(ToolRegistry.writeVerdict(requested: .string("same"), before: .text("same"), after: .text("same")) == .applied)
    }

    @Test("an ignored write (value unchanged, not as requested) is no_effect")
    func noEffect() {
        #expect(ToolRegistry.writeVerdict(requested: .string("red"),
                                          before: .text("System systemBlueColor"),
                                          after: .text("System systemBlueColor")) == .noEffect)
        #expect(ToolRegistry.writeVerdict(requested: .number(5), before: .number(3), after: .number(3)) == .noEffect)
    }

    @Test("a clamped or normalised write is adjusted, not a failure")
    func adjusted() {
        #expect(ToolRegistry.writeVerdict(requested: .number(150), before: .number(25), after: .number(100)) == .adjusted)
        #expect(ToolRegistry.writeVerdict(requested: .string("  padded "), before: .text(""), after: .text("padded")) == .adjusted)
    }

    @Test("an unreadable attribute is unreadable, never a claimed success")
    func unreadable() {
        #expect(ToolRegistry.writeVerdict(requested: .string("x"), before: nil, after: nil) == .unreadable)
        #expect(ToolRegistry.writeVerdict(requested: .object([:]), before: .text("a"), after: .text("b")) == .unreadable)
    }

    @Test("typing is judged on the value only")
    func typingVerdict() {
        typealias T = ToolRegistry
        #expect(T.typingVerdict(before: .string(""), after: .string("utrecht")) == .changed)
        #expect(T.typingVerdict(before: .string("haarlem"), after: .string("haarlem")) == .unchanged)
        // secure fields / non-text elements have no readable value
        #expect(T.typingVerdict(before: .null, after: .null) == .unknown)
        #expect(T.typingVerdict(before: .string("a"), after: nil) == .unknown)
    }
}
