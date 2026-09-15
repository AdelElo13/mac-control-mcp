import Testing
import Foundation
import ApplicationServices
@testable import MacControlMCP

/// v0.9 review (workstream E): the write paths that matter most — "the
/// element accepted the range write and ignored it", "the AXSelectedText
/// write silently no-op'd", "this is a password field" — used to be
/// reachable only by driving a real GUI app. They now run against a fake
/// `AXTextBackend`, so a regression fails in `swift test` rather than in
/// production.
///
/// Every offset/length here is in UTF-16 code units, matching AX.
@Suite("Text editing — AX backend seam (C-7 review)")
struct TextEditingBackendTests {

    // MARK: - Fake backend

    /// A tiny in-memory text element. Reference type so the controller's
    /// writes are visible to the test afterwards.
    final class FakeElement: @unchecked Sendable {
        var role: String
        var value: String
        var selection: TextEditingController.TextRange?
        var attributeNames: [String]
        var attributeNamesStatus: AXError = .success
        /// Selection the element will actually report after a write (nil =
        /// "apply what was asked"); models an element that ignores the write.
        var forcedSelectionAfterWrite: TextEditingController.TextRange??
        /// When true, AXSelectedText writes return .success and change nothing.
        var ignoresTextWrites = false
        /// When set, AXSelectedText writes insert this instead (autocorrect-ish).
        var substituteWrite: String?
        /// Hide AXValue so the count/string_for_range verification path runs.
        var exposesValue = true
        /// Hide AXStringForRange so the count-only verification path runs.
        var exposesStringForRange = true
        /// Hide AXNumberOfCharacters so nothing at all can be verified.
        var exposesCharacterCount = true
        /// Report THIS as AXNumberOfCharacters instead of the real count —
        /// models an app whose count is nonsense (Codex r3: Int.max).
        var forcedCharacterCount: Int?
        var selectedTextWriteStatus: AXError = .success
        var rangeWriteStatus: AXError = .success
        var visibleRange: TextEditingController.TextRange?
        var insertionLine: Int?

        init(
            role: String = "AXTextArea",
            value: String = "",
            selection: TextEditingController.TextRange? = .init(location: 0, length: 0),
            attributeNames: [String] = [
                "AXRole", "AXValue", "AXSelectedText", "AXSelectedTextRange", "AXNumberOfCharacters"
            ]
        ) {
            self.role = role
            self.value = value
            self.selection = selection
            self.attributeNames = attributeNames
        }
    }

    struct FakeBackend: AXTextBackend {
        let element: FakeElement

        func focusedElement(pid: pid_t) -> AXUIElement? { nil }

        func attributeNames(of _: AXUIElement) -> (status: AXError, names: [String]) {
            (element.attributeNamesStatus, element.attributeNames)
        }

        func stringAttribute(_: AXUIElement, _ name: String) -> String? {
            switch name {
            case "AXRole": return element.role
            case "AXValue": return element.exposesValue ? element.value : nil
            case "AXSelectedText":
                guard let selection = element.selection else { return nil }
                return TextEditingController.replacingUTF16(
                    "", range: .init(location: 0, length: 0), with: slice(selection)
                )
            default: return nil
            }
        }

        private func slice(_ range: TextEditingController.TextRange) -> String {
            let units = Array(element.value.utf16)
            let end = min(range.location + range.length, units.count)
            guard range.location <= end else { return "" }
            return String(utf16CodeUnits: Array(units[range.location..<end]), count: end - range.location)
        }

        func intAttribute(_: AXUIElement, _ name: String) -> Int? {
            if name == "AXInsertionPointLineNumber" { return element.insertionLine }
            guard name == "AXNumberOfCharacters", element.exposesCharacterCount else { return nil }
            return element.forcedCharacterCount ?? element.value.utf16.count
        }

        func rangeAttribute(_: AXUIElement, _ name: String) -> TextEditingController.TextRange? {
            name == "AXSelectedTextRange" ? element.selection : element.visibleRange
        }

        func setRangeAttribute(
            _: AXUIElement, _ name: String, location: Int, length: Int
        ) -> AXError {
            guard element.rangeWriteStatus == .success else { return element.rangeWriteStatus }
            if let forced = element.forcedSelectionAfterWrite {
                element.selection = forced
            } else {
                element.selection = .init(location: location, length: length)
            }
            return .success
        }

        func setStringAttribute(_: AXUIElement, _ name: String, _ value: String) -> AXError {
            guard name == "AXSelectedText" else { return .attributeUnsupported }
            guard element.selectedTextWriteStatus == .success else { return element.selectedTextWriteStatus }
            guard !element.ignoresTextWrites else { return .success }
            guard let selection = element.selection else { return .success }
            let inserted = element.substituteWrite ?? value
            guard let updated = TextEditingController.replacingUTF16(
                element.value, range: selection, with: inserted
            ) else { return .illegalArgument }
            element.value = updated
            element.selection = .init(
                location: selection.location + inserted.utf16.count, length: 0
            )
            return .success
        }

        func boundsForRange(_: AXUIElement, location: Int, length: Int) -> TextEditingController.Bounds? {
            .init(x: 0, y: 0, width: Double(length), height: 10)
        }

        func lineForIndex(_: AXUIElement, index: Int) -> Int? { 0 }

        func stringForRange(_: AXUIElement, location: Int, length: Int) -> String? {
            guard element.exposesStringForRange else { return nil }
            return slice(.init(location: location, length: length))
        }
    }

    /// Any handle works — the fake never dereferences it.
    static func dummyElement() -> AXUIElement { AXUIElementCreateApplication(0) }

    static func controller(_ element: FakeElement) -> TextEditingController {
        TextEditingController(backend: FakeBackend(element: element), isTrusted: { true })
    }

    // v0.10 C7: stale app ranges must not survive a shorter value.
    @Test("selection clamps stale visible range after an emoji edit")
    func refreshedVisibleRange() async throws {
        let element = FakeElement(value: "Hello 👋 wereld 🇳🇱 café")
        element.visibleRange = .init(location: 0, length: 25)
        element.insertionLine = 3
        let controller = Self.controller(element)
        _ = try await controller.replaceRange(of: Self.dummyElement(), location: 6, length: 2, text: "")
        let selection = try await controller.selection(of: Self.dummyElement())
        #expect(selection.visibleRange == .init(location: 0, length: 23))
        #expect(selection.insertionPointLine == 3)
    }

    @Test("selection reports bounds for the entire selected UTF-16 range")
    func selectedRangeBounds() async throws {
        let element = FakeElement(value: "Hello 👋 wereld 🇳🇱 café", selection: .init(location: 6, length: 2))
        let selection = try await Self.controller(element).selection(of: Self.dummyElement())
        let bounds = selection.bounds
        #expect(bounds?.width == 2)
        #expect(selection.text == "👋")
    }

    // MARK: - UTF-16 units

    @Test("inserted_characters is the UTF-16 delta, not the grapheme count")
    func insertedCharactersAreUTF16() async throws {
        let element = FakeElement(value: "abc", selection: .init(location: 3, length: 0))
        let controller = Self.controller(element)
        // "a😀b🇳🇱c" = 1 + 2 + 1 + 4 + 1 = 9 UTF-16 units, but only 5 graphemes.
        let payload = "a😀b🇳🇱c"
        #expect(payload.count == 5)
        #expect(payload.utf16.count == 9)

        let before = element.value.utf16.count
        let outcome = try await controller.insertAtCaret(of: Self.dummyElement(), text: payload)
        #expect(outcome.insertedCharacters == 9)
        #expect(element.value.utf16.count - before == outcome.insertedCharacters)
        #expect(outcome.applied == true)
        #expect(element.value == "abca😀b🇳🇱c")
    }

    @Test("number_of_characters is UTF-16 consistent across the value and selection paths")
    func numberOfCharactersConsistent() async throws {
        let element = FakeElement(value: "a😀b🇳🇱c", selection: .init(location: 0, length: 0))
        let controller = Self.controller(element)
        let value = try await controller.value(of: Self.dummyElement(), maxUTF16Units: nil)
        let selection = try await controller.selection(of: Self.dummyElement())
        #expect(value.numberOfCharacters == 9)
        #expect(selection.numberOfCharacters == 9)
        #expect(value.text.utf16.count == 9)
    }

    @Test("a decomposed é counts as its two UTF-16 units")
    func decomposedGrapheme() async throws {
        let decomposed = "e\u{0301}"          // e + COMBINING ACUTE
        #expect(decomposed.count == 1)
        #expect(decomposed.utf16.count == 2)
        let element = FakeElement(value: decomposed, selection: .init(location: 2, length: 0))
        let controller = Self.controller(element)
        let value = try await controller.value(of: Self.dummyElement(), maxUTF16Units: nil)
        #expect(value.numberOfCharacters == 2)

        let outcome = try await controller.insertAtCaret(of: Self.dummyElement(), text: decomposed)
        #expect(outcome.insertedCharacters == 2)
        #expect(element.value.utf16.count == 4)
    }

    @Test("truncate never splits a surrogate pair")
    func truncateNeverSplitsSurrogates() {
        // "a😀b": a=1, 😀=2, b=1 → 4 UTF-16 units. A cap of 2 must stop at "a".
        let cut = TextEditingController.truncate("a😀b", maxUTF16Units: 2)
        #expect(cut.text == "a")
        #expect(cut.truncated == true)
        for unit in cut.text.utf16 {
            #expect(!(0xD800...0xDFFF).contains(unit), "emitted a lone surrogate")
        }
        // A cap of 3 fits the emoji exactly.
        let fits = TextEditingController.truncate("a😀b", maxUTF16Units: 3)
        #expect(fits.text == "a😀")
        #expect(fits.text.utf16.count == 3)
        // The flag is 4 units (two regional indicators): a 2-unit cap keeps one.
        let flag = TextEditingController.truncate("🇳🇱x", maxUTF16Units: 2)
        #expect(flag.text.utf16.count == 2)
        #expect(String(decoding: Array(flag.text.utf16), as: UTF16.self) == flag.text)
    }

    @Test("text_get_value truncation is reported in UTF-16 units")
    func valueTruncationUTF16() async throws {
        let element = FakeElement(value: "a😀b🇳🇱c")
        let controller = Self.controller(element)
        let value = try await controller.value(of: Self.dummyElement(), maxUTF16Units: 3)
        #expect(value.text == "a😀")
        #expect(value.truncated == true)
        #expect(value.numberOfCharacters == 9)   // full length, not the cut one
    }

    @Test("replacingUTF16 splices in AX space")
    func spliceInUTF16Space() {
        let original = "a😀b"
        // The emoji occupies units 1..<3.
        #expect(TextEditingController.replacingUTF16(
            original, range: .init(location: 1, length: 2), with: "X") == "aXb")
        // Out-of-bounds returns nil rather than trapping.
        #expect(TextEditingController.replacingUTF16(
            original, range: .init(location: 3, length: 5), with: "X") == nil)
    }

    // MARK: - Write verification

    @Test("a selection write the element ignores is reported, and no text is written")
    func selectionNotApplied() async {
        let element = FakeElement(value: "hello world", selection: .init(location: 0, length: 0))
        element.forcedSelectionAfterWrite = .some(.init(location: 0, length: 0))
        let controller = Self.controller(element)
        await #expect(throws: TextEditingController.Failure.self) {
            try await controller.setSelection(of: Self.dummyElement(), location: 2, length: 3)
        }
        do {
            _ = try await controller.replaceRange(
                of: Self.dummyElement(), location: 2, length: 3, text: "XYZ"
            )
            Issue.record("replaceRange should have failed on an unapplied selection")
        } catch {
            #expect(error.code == "not_supported")
            #expect(error.reason == "selection_not_applied")
        }
        // Crucially: the value is untouched — no blind AXSelectedText write.
        #expect(element.value == "hello world")
    }

    @Test("a text write the element ignores reports write_not_applied")
    func writeNotApplied() async {
        let element = FakeElement(value: "hello", selection: .init(location: 0, length: 0))
        element.ignoresTextWrites = true
        let controller = Self.controller(element)
        do {
            _ = try await controller.insertAtCaret(of: Self.dummyElement(), text: "abc")
            Issue.record("insertAtCaret should have failed on an ignored write")
        } catch {
            #expect(error.code == "not_supported")
            #expect(error.reason == "write_not_applied")
        }
        #expect(element.value == "hello")
    }

    // MARK: - Honest `applied` reporting (Codex review 6)

    /// An element that exposes neither AXValue nor AXStringForRange can only
    /// be checked by its character count — which says nothing about WHAT was
    /// written. Reporting `applied: true` there was an unverified claim.
    @Test("a count-only verification reports applied: nil, not true")
    func countOnlyIsNotApplied() async throws {
        let element = FakeElement(value: "hello", selection: .init(location: 0, length: 0))
        element.exposesValue = false
        element.exposesStringForRange = false
        let controller = Self.controller(element)
        let outcome = try await controller.insertAtCaret(of: Self.dummyElement(), text: "abc")
        #expect(outcome.verification == "count_only")
        #expect(outcome.applied == nil, "a count match must never be reported as applied")
        #expect(element.value == "abchello")
    }

    /// Nothing readable at all: neither value, nor slice, nor count.
    @Test("an entirely unverifiable write reports applied: nil")
    func unverifiedIsNotApplied() async throws {
        let element = FakeElement(value: "hello", selection: .init(location: 0, length: 0))
        element.exposesValue = false
        element.exposesStringForRange = false
        element.exposesCharacterCount = false
        let controller = Self.controller(element)
        let outcome = try await controller.insertAtCaret(of: Self.dummyElement(), text: "abc")
        #expect(outcome.verification == "unverified")
        #expect(outcome.applied == nil)
    }

    @Test("a read-back match is still reported as applied: true")
    func readBackMatchIsApplied() async throws {
        let element = FakeElement(value: "hello", selection: .init(location: 0, length: 0))
        let outcome = try await Self.controller(element)
            .insertAtCaret(of: Self.dummyElement(), text: "abc")
        #expect(outcome.applied == true)
        #expect(outcome.verification == "value")
    }

    // MARK: - Range arithmetic overflow (Codex review 6)

    @Test("location + length overflow is an argument error, not a trap")
    func rangeOverflowRejected() {
        #expect(TextEditingController.validateRange(
            location: Int.max, length: 1, numberOfCharacters: 100) != nil)
        #expect(TextEditingController.validateRange(
            location: Int.max, length: Int.max, numberOfCharacters: nil) != nil)
        #expect(TextEditingController.validateRange(
            location: 1, length: Int.max, numberOfCharacters: nil) != nil)
        // The overflow guard must not reject honest ranges.
        #expect(TextEditingController.validateRange(
            location: 5, length: 5, numberOfCharacters: 10) == nil)
        #expect(TextEditingController.validateRange(
            location: Int.max, length: 0, numberOfCharacters: nil) == nil)
    }

    @Test("an overflowing range never reaches the element")
    func overflowNeverWrites() async {
        let element = FakeElement(value: "hello", selection: .init(location: 0, length: 0))
        let controller = Self.controller(element)
        do {
            _ = try await controller.replaceRange(
                of: Self.dummyElement(), location: Int.max, length: Int.max, text: "x"
            )
            Issue.record("an overflowing range should be rejected")
        } catch {
            #expect(error.code == "invalid_argument")
        }
        #expect(element.value == "hello")
    }

    @Test("replacingUTF16 rejects an overflowing range instead of trapping")
    func spliceOverflowReturnsNil() {
        #expect(TextEditingController.replacingUTF16(
            "abc", range: .init(location: Int.max, length: Int.max), with: "x") == nil)
    }

    @Test("a write that lands differently returns applied=false with the observed text")
    func partialWriteReported() async throws {
        let element = FakeElement(value: "hello", selection: .init(location: 0, length: 0))
        element.substituteWrite = "ABC"     // element "autocorrects" our input
        let controller = Self.controller(element)
        let outcome = try await controller.insertAtCaret(of: Self.dummyElement(), text: "abc")
        #expect(outcome.applied == false)
        #expect(outcome.observedText == "ABChello")
        #expect(outcome.verification == "value")
    }

    @Test("verification falls back to AXStringForRange when AXValue is unreadable")
    func verificationWithoutValue() async throws {
        let element = FakeElement(value: "hello", selection: .init(location: 0, length: 0))
        element.exposesValue = false
        let controller = Self.controller(element)
        let outcome = try await controller.insertAtCaret(of: Self.dummyElement(), text: "abc")
        #expect(outcome.applied == true)
        #expect(outcome.verification == "string_for_range")
        #expect(element.value == "abchello")
    }

    @Test("insert_at_caret collapses a non-empty selection instead of overwriting it")
    func insertCollapsesSelection() async throws {
        let element = FakeElement(value: "hello world", selection: .init(location: 0, length: 5))
        let controller = Self.controller(element)
        let outcome = try await controller.insertAtCaret(of: Self.dummyElement(), text: "!")
        #expect(outcome.collapsedSelection == true)
        #expect(outcome.range == .init(location: 5, length: 0))
        // "hello" survived; the text landed after it.
        #expect(element.value == "hello! world")
    }

    @Test("replace_range does overwrite the range it was given")
    func replaceOverwrites() async throws {
        let element = FakeElement(value: "hello world", selection: .init(location: 0, length: 0))
        let controller = Self.controller(element)
        let outcome = try await controller.replaceRange(
            of: Self.dummyElement(), location: 0, length: 5, text: "goodbye"
        )
        #expect(outcome.applied == true)
        #expect(outcome.collapsedSelection == false)
        #expect(element.value == "goodbye world")
    }

    // MARK: - Secure fields

    @Test("secure text fields are refused for reads", arguments: ["selection", "caret", "value"])
    func secureFieldReads(kind: String) async {
        let element = FakeElement(role: TextEditingController.secureTextFieldRole, value: "hunter2")
        let controller = Self.controller(element)
        do {
            switch kind {
            case "selection": _ = try await controller.selection(of: Self.dummyElement())
            case "caret":     _ = try await controller.caret(of: Self.dummyElement())
            default:          _ = try await controller.value(of: Self.dummyElement(), maxUTF16Units: nil)
            }
            Issue.record("\(kind) should refuse an AXSecureTextField")
        } catch {
            #expect(error.code == "not_supported")
            #expect(error.reason == "secure_field")
        }
    }

    @Test("secure text fields are refused for writes")
    func secureFieldWrites() async {
        let element = FakeElement(role: TextEditingController.secureTextFieldRole, value: "hunter2")
        let controller = Self.controller(element)
        do {
            _ = try await controller.insertAtCaret(of: Self.dummyElement(), text: "x")
            Issue.record("insert should refuse an AXSecureTextField")
        } catch {
            #expect(error.reason == "secure_field")
        }
        do {
            _ = try await controller.replaceRange(
                of: Self.dummyElement(), location: 0, length: 1, text: "x"
            )
            Issue.record("replace should refuse an AXSecureTextField")
        } catch {
            #expect(error.reason == "secure_field")
        }
        #expect(element.value == "hunter2")
    }

    // MARK: - Permission + liveness

    @Test("an untrusted process reports permission_missing before touching AX")
    func untrusted() async {
        let element = FakeElement()
        let controller = TextEditingController(
            backend: FakeBackend(element: element), isTrusted: { false }
        )
        do {
            _ = try await controller.selection(of: Self.dummyElement())
            Issue.record("expected permission_missing")
        } catch {
            #expect(error.code == "permission_missing")
        }
    }

    @Test("a dead element reports not_found")
    func deadElement() async {
        let element = FakeElement()
        element.attributeNamesStatus = .invalidUIElement
        let controller = Self.controller(element)
        do {
            _ = try await controller.selection(of: Self.dummyElement())
            Issue.record("expected not_found")
        } catch {
            #expect(error.code == "not_found")
        }
    }

    /// Live observation (2026-09-14, TextEdit on a locked session): an app
    /// that is not frontmost answers AXFocusedUIElement with the
    /// AXApplication, and the pid path then landed on it.
    @Test("an app element from the pid path reports no_focused_element, not not_text_element")
    func focusedElementIsTheApp() async {
        let element = FakeElement(role: "AXApplication", attributeNames: ["AXRole", "AXWindows"])
        let controller = Self.controller(element)
        do {
            _ = try await controller.selection(of: Self.dummyElement())
            Issue.record("expected not_supported")
        } catch {
            #expect(error.code == "not_supported")
            #expect(error.reason == "no_focused_element")
            #expect(error.hint?.contains("activate_app") == true)
        }
    }

    @Test("a non-text element reports not_text_element")
    func nonTextElement() async {
        let element = FakeElement(role: "AXButton", attributeNames: ["AXRole", "AXTitle"])
        let controller = Self.controller(element)
        do {
            _ = try await controller.selection(of: Self.dummyElement())
            Issue.record("expected not_supported")
        } catch {
            #expect(error.code == "not_supported")
            #expect(error.reason == "not_text_element")
        }
    }
}
