import Foundation
import ApplicationServices
import CoreGraphics

/// v0.9 workstream E — text editing primitives (gap-audit C-7, typing fix B-15).
///
/// Everything here was already reachable before this file existed, but only
/// the hard way: `find_elements` → `get_element_attributes` → regex-parse a
/// *stringified* struct (`AXSelectedTextRange: "range(2115,0)"`,
/// `AXNumberOfCharacters: "2146"`). Callers had to know the printf format of
/// an AXValue, and any app that printed it differently silently broke them.
///
/// This controller reads/writes the same attributes but hands back typed
/// values, and it edits text the way the Accessibility API is designed to be
/// used — by setting `AXSelectedTextRange` and writing `AXSelectedText` on
/// the element handle. No synthetic keystrokes, no focus stealing, no
/// select-all-and-retype: an element that is not frontmost can still be
/// edited, and text the agent did not intend to touch is not disturbed.
///
/// UNITS (v0.9 review, HIGH): every offset, length and count that crosses the
/// AX boundary is a **UTF-16 code unit**, because that is what AX itself uses
/// — `AXSelectedTextRange` on "a😀b" reports length 4, not 3. Swift's
/// `String.count` counts grapheme clusters and would have made
/// `inserted_characters`, the `number_of_characters` fallback and `max_chars`
/// disagree with the app for any non-BMP text. All of those now go through
/// `utf16.count`. `truncate` cuts on a scalar boundary so it can never emit a
/// lone surrogate.
///
/// WRITES ARE VERIFIED (v0.9 review, HIGH): AX happily returns `.success` for
/// a range/text write that the element then ignores — the exact silent-no-op
/// class this repo already hit with `AXPress` on disabled controls. Every
/// write is therefore read back: a selection that did not take reports
/// `not_supported` / `selection_not_applied` and no text is written; a text
/// write that changed nothing reports `not_supported` / `write_not_applied`;
/// a write that landed differently than requested still returns ok but with
/// `applied: false` and the observed text.
actor TextEditingController {

    // MARK: - Typed values

    /// A character range in an AX text element, in UTF-16 code units. This is
    /// the typed form of what `get_element_attributes` stringifies as
    /// `"range(2115,0)"`.
    struct TextRange: Codable, Sendable, Equatable {
        let location: Int
        let length: Int
    }

    /// On-screen bounds in top-left origin screen coordinates (the frame AX
    /// itself reports — the same convention as AXPosition/AXSize).
    struct Bounds: Codable, Sendable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    /// Stable machine-readable failure classes, shared by every tool here.
    enum Failure: Error, Sendable {
        /// AX is not trusted for this process — nothing below can work.
        case permissionMissing
        /// The element handle is stale/dead, or the pid has no focused element.
        case notFound
        /// The element is alive but cannot serve this request: not a text
        /// element, a secure field, or it rejected/ignored the write.
        case notSupported(String, reason: String)
        /// The caller asked for a range the document does not have. A caller
        /// mistake, not an element limitation — surfaced separately so the
        /// "use type_text instead" hint is not attached to it.
        case invalidRange(String)
        /// AX returned an error we do not classify further.
        case axError(Int32, String)

        var code: String {
            switch self {
            case .permissionMissing: return "permission_missing"
            case .notFound:          return "not_found"
            case .notSupported:      return "not_supported"
            case .invalidRange:      return "invalid_argument"
            case .axError:           return "ax_error"
            }
        }

        /// Machine-readable sub-reason. Stable across versions.
        var reason: String? {
            switch self {
            case .permissionMissing:          return "ax_not_trusted"
            case .notFound:                    return "element_gone"
            case .notSupported(_, let reason): return reason
            case .invalidRange:                return "range_out_of_bounds"
            case .axError:                     return "ax_error"
            }
        }

        var message: String {
            switch self {
            case .permissionMissing:
                return "Accessibility permission is not granted to this process."
            case .notFound:
                return "The target element is gone (stale element_id, or the app has no focused element)."
            case .notSupported(let detail, _):
                return detail
            case .invalidRange(let detail):
                return detail
            case .axError(let status, let detail):
                return "\(detail) (AXError=\(status))"
            }
        }

        var hint: String? {
            switch self {
            case .permissionMissing:
                return "Grant Accessibility in System Settings → Privacy & Security → Accessibility, then retry. open_permission_pane(pane=\"accessibility\") deep-links there."
            case .notFound:
                return "Re-resolve the element with find_elements/query_elements (ids expire after 5 minutes), or pass pid to target the app's currently focused element."
            case .notSupported(_, let reason):
                switch reason {
                case "secure_field":
                    return "This is an AXSecureTextField (password field). mac-control-mcp refuses to read or write it; ask the user to type the value themselves."
                case "selection_not_applied":
                    return "The element accepted the AXSelectedTextRange write but did not apply it — nothing was typed. Focus it and use type_text (clipboard/keys strategy) instead."
                case "write_not_applied":
                    return "The element accepted the AXSelectedText write but its value did not change. Focus it and use type_text (clipboard/keys strategy) instead."
                case "no_focused_element":
                    return "Nothing in that app currently has keyboard focus (it is in the background, or the screen is locked). Bring it forward with activate_app / focus_window, or address the text element directly with element_id."
                default:
                    return "This element does not accept AX text edits. Focus it and use type_text (clipboard/keys strategy) instead, or set the whole value with set_element_attribute(AXValue)."
                }
            case .invalidRange:
                return "Read the current length first (text_get_selection reports number_of_characters, in UTF-16 units) and clamp the range to it."
            case .axError:
                return nil
            }
        }
    }

    /// Everything `text_get_selection` reports, typed.
    struct Selection: Sendable {
        let text: String?
        let range: TextRange?
        let numberOfCharacters: Int?
        let visibleRange: TextRange?
        let insertionPointLine: Int?
    }

    struct Caret: Sendable {
        let index: Int
        let line: Int?
        let bounds: Bounds?
        /// Length of the range AXBoundsForRange was actually asked for — 0
        /// for a true caret rect, 1 when the element only answers for a real
        /// character (several apps return an empty rect for a 0-length range).
        let boundsRangeLength: Int
        let selectionLength: Int
    }

    struct WriteOutcome: Sendable {
        /// The range the write targeted (UTF-16 units).
        let range: TextRange
        /// UTF-16 code units of the inserted text.
        let insertedCharacters: Int
        /// Selection the element reports *after* the write, when it exposes one.
        let selectionAfter: TextRange?
        /// True when a non-empty selection was collapsed before inserting.
        let collapsedSelection: Bool
        /// Tri-state (Codex review 6, HIGH):
        ///   * `true`  — the text was read back and matched what we asked for;
        ///   * `false` — the element applied something else (see observedText);
        ///   * `nil`   — the write COULD NOT be verified. The element exposes
        ///               no readable text, so only its character count (or
        ///               nothing at all) could be checked. Never claim `true`
        ///               on that evidence.
        /// A write that demonstrably applied nothing throws instead.
        let applied: Bool?
        /// The element's text after the write, when it differs from what was
        /// requested (so the caller can see what actually happened).
        let observedText: String?
        /// How the write was verified: "value" | "string_for_range" |
        /// "count_only" | "unverified". "unverified" always pairs with
        /// `applied == nil`; "count_only" pairs with nil (count moved as
        /// requested) or false (count moved by a different amount).
        let verification: String
        /// Why `applied` is not true, in words the caller can act on. Set
        /// for nil, and for false when there is no `observedText` to show
        /// (the count-only case — Codex r3).
        var warning: String? {
            if applied == false {
                return observedText == nil
                    ? "AXNumberOfCharacters moved, but not by the requested amount — the element applied something other than the requested edit. Read it back with text_get_value before continuing."
                    : nil
            }
            guard applied == nil else { return nil }
            switch verification {
            case "count_only":
                return "The element exposes no readable text, only AXNumberOfCharacters. The count moved by exactly the amount requested, but WHAT was written could not be read back — verify with text_get_value or by another route before relying on it."
            case "unverified":
                return "The element exposes neither its value, nor AXStringForRange, nor AXNumberOfCharacters. AX reported success, but nothing could be read back to confirm the write landed — verify by another route before relying on it."
            default:
                return "The write could not be verified by reading the element back."
            }
        }
    }

    struct Value: Sendable {
        let text: String
        /// UTF-16 code units in the FULL value (not in the truncated text).
        let numberOfCharacters: Int?
        let truncated: Bool
    }

    // MARK: - Construction

    private let ax: any AXTextBackend
    private let isTrusted: @Sendable () -> Bool

    init(
        backend: any AXTextBackend = LiveAXTextBackend(),
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.ax = backend
        self.isTrusted = isTrusted
    }

    // MARK: - Pure helpers (unit-testable without a live element)

    /// Decode an `AXValue` that carries a `CFRange`. Returns nil for any
    /// other AXValue type — a wrong-typed attribute is a bug to surface, not
    /// something to coerce.
    static func textRange(from value: AXValue) -> TextRange? {
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return sanitized(location: range.location, length: range.length)
    }

    /// An app-reported range is untrusted input too (Codex r2 #6). A
    /// negative component or an end offset that overflows Int cannot
    /// describe any document; treat it as "no usable range" (nil) rather
    /// than carrying a value the arithmetic downstream would trap on.
    static func sanitized(location: Int, length: Int) -> TextRange? {
        guard location >= 0, length >= 0 else { return nil }
        let (_, overflowed) = location.addingReportingOverflow(length)
        guard !overflowed else { return nil }
        return TextRange(location: location, length: length)
    }

    /// Decode an `AXValue` that carries a `CGRect` (AXBoundsForRange).
    static func bounds(from value: AXValue) -> Bounds? {
        guard AXValueGetType(value) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return Bounds(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    /// Build the `AXValue` an `AXSelectedTextRange` write expects.
    static func makeRangeValue(location: Int, length: Int) -> AXValue? {
        var range = CFRange(location: location, length: length)
        return AXValueCreate(.cfRange, &range)
    }

    /// Validate a caller-supplied range, in UTF-16 units. Returns nil when
    /// acceptable, else a human-readable reason. `numberOfCharacters` nil
    /// means the element does not report a length — we then check signs only
    /// rather than guessing.
    /// `location + length` is computed with `addingReportingOverflow`: a
    /// caller passing `Int.max` for both used to TRAP the whole server
    /// process on the overflow (Codex review 6, HIGH). An end offset that
    /// does not fit in an Int cannot address any real document, so it is
    /// rejected as an argument error before AX is touched — including when
    /// the element does not report a length.
    static func validateRange(location: Int, length: Int, numberOfCharacters: Int?) -> String? {
        if location < 0 { return "location must be >= 0 (got \(location))." }
        if length < 0 { return "length must be >= 0 (got \(length))." }
        let (end, overflowed) = location.addingReportingOverflow(length)
        if overflowed {
            return "range \(location)+\(length) overflows Int — no document can have an end offset that large."
        }
        guard let total = numberOfCharacters else { return nil }
        if location > total {
            return "location \(location) is past the end of the text (number_of_characters=\(total), UTF-16 units)."
        }
        if end > total {
            return "range \(location)+\(length) exceeds the text length (number_of_characters=\(total), UTF-16 units)."
        }
        return nil
    }

    /// Truncate to at most `maxUTF16Units` UTF-16 code units, cutting only on
    /// a Unicode scalar boundary so the result can never end in a lone
    /// surrogate (which would be an invalid string on the wire).
    ///
    /// Grapheme clusters MAY be split (a 🇳🇱 flag is two scalars): the caller
    /// asked for a byte-budget-like cap, and silently returning fewer units
    /// than asked is better than returning broken UTF-16.
    static func truncate(_ text: String, maxUTF16Units: Int?) -> (text: String, truncated: Bool) {
        guard let limit = maxUTF16Units, text.utf16.count > limit else { return (text, false) }
        var out = String()
        var used = 0
        for scalar in text.unicodeScalars {
            let width = UTF16.width(scalar)
            if used + width > limit { break }
            out.unicodeScalars.append(scalar)
            used += width
        }
        return (out, true)
    }

    /// Splice in UTF-16 space — the same space AX ranges live in. Returns nil
    /// when the range does not fit the original.
    static func replacingUTF16(_ original: String, range: TextRange, with replacement: String) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        var units = Array(original.utf16)
        // Overflow-safe: Int.max + Int.max would trap (Codex review 6).
        let (end, overflowed) = range.location.addingReportingOverflow(range.length)
        guard !overflowed, end <= units.count else { return nil }
        units.replaceSubrange(range.location..<end, with: Array(replacement.utf16))
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// AppKit answers AXInsertionPointLineNumber with a sentinel (Int.max, or
    /// a negative value) when there is no insertion point — e.g. while a
    /// non-empty selection is active. Verified live against TextEdit on
    /// 2026-09-14: a 3-character selection reported 9223372036854775807.
    /// Report "unknown" rather than passing a sentinel off as a line number.
    static func sanitizeLineNumber(_ raw: Int?) -> Int? {
        guard let raw, raw >= 0, raw <= maxPlausibleLineNumber else { return nil }
        return raw
    }

    /// No real document has a billion lines; anything above this is a sentinel.
    static let maxPlausibleLineNumber = 1_000_000_000

    /// AXRole of a password field. Refused in both directions.
    static let secureTextFieldRole = "AXSecureTextField"

    // MARK: - Element resolution

    /// The element that currently has keyboard focus inside `pid`'s app.
    /// Deliberately app-scoped rather than system-wide: the caller named an
    /// app, and the system-wide focused element belongs to whatever is
    /// frontmost right now.
    func focusedElement(pid: pid_t) throws(Failure) -> AXUIElement {
        try requireTrust()
        guard let element = ax.focusedElement(pid: pid) else { throw .notFound }
        return element
    }

    // MARK: - Reads

    func selection(of element: AXUIElement) throws(Failure) -> Selection {
        try requireTrust()
        try requireTextCapable(element)
        return Selection(
            text: ax.stringAttribute(element, kAXSelectedTextAttribute as String),
            range: ax.rangeAttribute(element, kAXSelectedTextRangeAttribute as String),
            numberOfCharacters: ax.intAttribute(element, kAXNumberOfCharactersAttribute as String),
            visibleRange: ax.rangeAttribute(element, kAXVisibleCharacterRangeAttribute as String),
            insertionPointLine: Self.sanitizeLineNumber(
                ax.intAttribute(element, kAXInsertionPointLineNumberAttribute as String)
            )
        )
    }

    func caret(of element: AXUIElement) throws(Failure) -> Caret {
        try requireTrust()
        try requireTextCapable(element)
        guard let selected = ax.rangeAttribute(element, kAXSelectedTextRangeAttribute as String) else {
            throw .notSupported(
                "Element does not expose AXSelectedTextRange, so it has no addressable caret.",
                reason: "no_selection_range"
            )
        }
        let index = selected.location
        let line = Self.sanitizeLineNumber(ax.lineForIndex(element, index: index))
            ?? Self.sanitizeLineNumber(ax.intAttribute(element, kAXInsertionPointLineNumberAttribute as String))

        // A zero-length range is the true caret rect, but several apps answer
        // an empty rect (or nothing) for it — fall back to the bounds of the
        // character the caret sits in front of.
        var usedLength = 0
        var rect = ax.boundsForRange(element, location: index, length: 0)
        if rect == nil || (rect?.width == 0 && rect?.height == 0) {
            if let wider = ax.boundsForRange(element, location: index, length: 1) {
                rect = wider
                usedLength = 1
            }
        }
        return Caret(
            index: index,
            line: line,
            bounds: rect,
            boundsRangeLength: usedLength,
            selectionLength: selected.length
        )
    }

    func value(of element: AXUIElement, maxUTF16Units: Int?) throws(Failure) -> Value {
        try requireTrust()
        try requireNotSecure(element)
        guard let raw = ax.stringAttribute(element, kAXValueAttribute as String) else {
            try assertAlive(element)
            throw .notSupported("Element exposes no string AXValue.", reason: "no_string_value")
        }
        let cut = Self.truncate(raw, maxUTF16Units: maxUTF16Units)
        return Value(
            text: cut.text,
            numberOfCharacters: ax.intAttribute(element, kAXNumberOfCharactersAttribute as String)
                ?? raw.utf16.count,
            truncated: cut.truncated
        )
    }

    // MARK: - Writes

    /// Set the selection and CONFIRM it took. An element that accepts the
    /// write and ignores it would otherwise send the following
    /// `AXSelectedText` write to the wrong place (or to the whole field).
    @discardableResult
    func setSelection(of element: AXUIElement, location: Int, length: Int) throws(Failure) -> TextRange {
        try requireTrust()
        try requireTextCapable(element)
        if let reason = Self.validateRange(
            location: location,
            length: length,
            numberOfCharacters: ax.intAttribute(element, kAXNumberOfCharactersAttribute as String)
        ) {
            throw .invalidRange(reason)
        }
        let status = ax.setRangeAttribute(
            element, kAXSelectedTextRangeAttribute as String, location: location, length: length
        )
        guard status == .success else { throw Self.classify(status, action: "set AXSelectedTextRange") }

        let requested = TextRange(location: location, length: length)
        let observed = ax.rangeAttribute(element, kAXSelectedTextRangeAttribute as String)
        guard let observed else {
            throw .notSupported(
                "AXSelectedTextRange write returned success but the element reports no selection back.",
                reason: "selection_not_applied"
            )
        }
        guard observed == requested else {
            throw .notSupported(
                "AXSelectedTextRange write returned success but the element's selection is \(observed.location)+\(observed.length), not \(location)+\(length). Nothing was typed.",
                reason: "selection_not_applied"
            )
        }
        return requested
    }

    /// Insert at the caret. A non-empty selection is COLLAPSED TO ITS END
    /// first, so "insert" never destroys selected text — use `replaceRange`
    /// when overwriting a selection is what you want. The collapse is
    /// reported back as `collapsed_selection: true`.
    func insertAtCaret(of element: AXUIElement, text: String) throws(Failure) -> WriteOutcome {
        try requireTrust()
        try requireTextCapable(element)
        guard let current = ax.rangeAttribute(element, kAXSelectedTextRangeAttribute as String) else {
            throw .notSupported(
                "Element does not expose AXSelectedTextRange, so there is no caret to insert at.",
                reason: "no_selection_range"
            )
        }
        var collapsed = false
        var caret = current
        if current.length != 0 {
            // Codex r2 #6: this range comes from the APP, not the caller, so
            // `validateRange` never saw it. An app answering AXSelectedTextRange
            // with `Int.max + 1` trapped the whole server on this addition.
            // `textRange(from:)` now rejects negative or overflowing ranges
            // at decode time; this is the belt to that suspender.
            let (end, overflowed) = current.location.addingReportingOverflow(current.length)
            guard !overflowed else {
                throw .notSupported(
                    "Element reported a selection range \(current.location)+\(current.length) whose end does not fit in an Int; refusing to act on it.",
                    reason: "invalid_selection_range"
                )
            }
            caret = try setSelection(of: element, location: end, length: 0)
            collapsed = true
        }
        return try write(element, at: caret, text: text, collapsedSelection: collapsed)
    }

    func replaceRange(
        of element: AXUIElement, location: Int, length: Int, text: String
    ) throws(Failure) -> WriteOutcome {
        let target = try setSelection(of: element, location: location, length: length)
        return try write(element, at: target, text: text, collapsedSelection: false)
    }

    /// Shared write + read-back verification for insert and replace.
    private func write(
        _ element: AXUIElement, at range: TextRange, text: String, collapsedSelection: Bool
    ) throws(Failure) -> WriteOutcome {
        let beforeValue = ax.stringAttribute(element, kAXValueAttribute as String)
        let beforeCount = ax.intAttribute(element, kAXNumberOfCharactersAttribute as String)

        let status = ax.setStringAttribute(element, kAXSelectedTextAttribute as String, text)
        guard status == .success else {
            throw Self.classify(status, action: "write AXSelectedText")
        }

        let verdict = try verify(
            element, range: range, text: text, beforeValue: beforeValue, beforeCount: beforeCount
        )
        return WriteOutcome(
            range: range,
            insertedCharacters: text.utf16.count,
            selectionAfter: ax.rangeAttribute(element, kAXSelectedTextRangeAttribute as String),
            collapsedSelection: collapsedSelection,
            applied: verdict.applied,
            observedText: verdict.observed,
            verification: verdict.method
        )
    }

    /// Read the element back and decide whether the write landed.
    ///
    /// Throws `write_not_applied` when the element is demonstrably unchanged;
    /// returns `applied: false` plus what it observed when it changed into
    /// something other than what was asked for; returns `applied: nil` when
    /// the element exposes nothing that could confirm the CONTENT of the
    /// write (Codex review 6 — a matching character count is not evidence
    /// that the right text was written).
    private func verify(
        _ element: AXUIElement,
        range: TextRange,
        text: String,
        beforeValue: String?,
        beforeCount: Int?
    ) throws(Failure) -> (applied: Bool?, observed: String?, method: String) {
        if let beforeValue,
           let afterValue = ax.stringAttribute(element, kAXValueAttribute as String) {
            let expected = Self.replacingUTF16(beforeValue, range: range, with: text)
            if afterValue == expected { return (true, nil, "value") }
            if afterValue == beforeValue {
                throw .notSupported(
                    "AXSelectedText write returned success but the element's value is unchanged.",
                    reason: "write_not_applied"
                )
            }
            return (false, afterValue, "value")
        }

        // No readable AXValue (big text views often refuse it) — fall back to
        // the character count plus the text that now occupies the range we
        // wrote into.
        let afterCount = ax.intAttribute(element, kAXNumberOfCharactersAttribute as String)
        let observedSlice = ax.stringForRange(
            element, location: range.location, length: text.utf16.count
        )
        if let observedSlice {
            if observedSlice == text { return (true, nil, "string_for_range") }
            if let beforeCount, let afterCount, beforeCount == afterCount, text.utf16.count != range.length {
                throw .notSupported(
                    "AXSelectedText write returned success but the element's character count and text are unchanged.",
                    reason: "write_not_applied"
                )
            }
            return (false, observedSlice, "string_for_range")
        }

        if let beforeCount, let afterCount {
            // Codex r3: `beforeCount` is app-reported. An element answering
            // AXNumberOfCharacters with Int.max made the plain arithmetic
            // here trap the server. A count the arithmetic cannot follow is
            // no evidence either way — fall through to "unverified".
            guard let expectedCount = Self.expectedCount(
                before: beforeCount, replaced: range.length, inserted: text.utf16.count
            ) else {
                return (nil, nil, "unverified")
            }
            // The count moving as predicted is consistent with the write, but
            // says nothing about WHAT was written — report "unknown", never
            // "applied" (Codex review 6).
            if afterCount == expectedCount { return (nil, nil, "count_only") }
            if afterCount == beforeCount, expectedCount != beforeCount {
                throw .notSupported(
                    "AXSelectedText write returned success but AXNumberOfCharacters is unchanged.",
                    reason: "write_not_applied"
                )
            }
            // The count moved, but not by the requested amount: the element
            // demonstrably did something else.
            return (false, nil, "count_only")
        }

        // Nothing readable at all. AX said success; that is all we know.
        return (nil, nil, "unverified")
    }

    /// `before - replaced + inserted` with overflow checking (Codex r3):
    /// nil when the app-reported `before` cannot be combined with the
    /// requested edit inside an Int — never a trap.
    static func expectedCount(before: Int, replaced: Int, inserted: Int) -> Int? {
        let (afterRemoval, underflowed) = before.subtractingReportingOverflow(replaced)
        guard !underflowed else { return nil }
        let (total, overflowed) = afterRemoval.addingReportingOverflow(inserted)
        return overflowed ? nil : total
    }

    // MARK: - Guards

    private func requireTrust() throws(Failure) {
        guard isTrusted() else { throw .permissionMissing }
    }

    /// Password fields are off limits in both directions — reading one would
    /// hand a secret to the model, writing one would type into a credential
    /// prompt. Both are refused before any AX traffic happens.
    private func requireNotSecure(_ element: AXUIElement) throws(Failure) {
        guard let role = ax.stringAttribute(element, kAXRoleAttribute as String) else { return }
        // "AXSecureTextField" has no exported kAX… constant in
        // ApplicationServices (unlike kAXTextFieldRole), so the literal is
        // the only way to name it.
        if role == Self.secureTextFieldRole {
            throw .notSupported(
                "Refusing to read or edit an AXSecureTextField (password field).",
                reason: "secure_field"
            )
        }
    }

    /// Distinguishes "not a text element" (not_supported) from "element is
    /// gone" (not_found) — both look like a failed attribute read otherwise.
    private func requireTextCapable(_ element: AXUIElement) throws(Failure) {
        try requireNotSecure(element)
        let (status, available) = ax.attributeNames(of: element)
        if status == .invalidUIElement || status == .cannotComplete {
            throw .notFound
        }
        guard status == .success else {
            throw Self.classify(status, action: "list attribute names")
        }
        let textMarkers: Set<String> = [
            kAXSelectedTextRangeAttribute as String,
            kAXSelectedTextAttribute as String,
            kAXNumberOfCharactersAttribute as String
        ]
        guard !textMarkers.isDisjoint(with: Set(available)) else {
            let role = ax.stringAttribute(element, kAXRoleAttribute as String) ?? "unknown"
            // Observed live (2026-09-14, TextEdit while the session was
            // locked): an app that is not frontmost answers
            // AXFocusedUIElement with the AXApplication itself. Saying "not
            // an editable text element" is true but useless — the caller's
            // real problem is that the app has no focused element right now.
            if role == (kAXApplicationRole as String) {
                throw .notSupported(
                    "The app reports no focused UI element — AXFocusedUIElement came back as the application itself (role=AXApplication).",
                    reason: "no_focused_element"
                )
            }
            throw .notSupported(
                "Element (role=\(role)) exposes none of AXSelectedTextRange/AXSelectedText/AXNumberOfCharacters — it is not an editable text element.",
                reason: "not_text_element"
            )
        }
    }

    private func assertAlive(_ element: AXUIElement) throws(Failure) {
        let (status, _) = ax.attributeNames(of: element)
        if status == .invalidUIElement || status == .cannotComplete { throw .notFound }
    }

    static func classify(_ status: AXError, action: String) -> Failure {
        switch status {
        case .invalidUIElement, .cannotComplete:
            return .notFound
        case .attributeUnsupported, .actionUnsupported, .notImplemented, .illegalArgument:
            return .notSupported(
                "Could not \(action): the element rejects it (AXError=\(status.rawValue)).",
                reason: "ax_rejected"
            )
        default:
            return .axError(status.rawValue, "Could not \(action)")
        }
    }
}
