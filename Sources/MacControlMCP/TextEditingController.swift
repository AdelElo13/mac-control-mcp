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
/// Elements that refuse `AXSelectedText` writes (many Electron/Chromium text
/// surfaces expose the attribute read-only) are reported as `not_supported`
/// with a pointer at `type_text`, rather than silently doing nothing.
actor TextEditingController {

    // MARK: - Typed values

    /// A character range in an AX text element. This is the typed form of
    /// what `get_element_attributes` stringifies as `"range(2115,0)"`.
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
        /// The element is alive but is not a text element, or refuses the
        /// write (read-only AXSelectedText).
        case notSupported(String)
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

        var message: String {
            switch self {
            case .permissionMissing:
                return "Accessibility permission is not granted to this process."
            case .notFound:
                return "The target element is gone (stale element_id, or the app has no focused element)."
            case .notSupported(let detail), .invalidRange(let detail):
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
            case .notSupported:
                return "This element does not accept AX text edits. Focus it and use type_text (clipboard/keys strategy) instead, or set the whole value with set_element_attribute(AXValue)."
            case .invalidRange:
                return "Read the current length first (text_get_selection reports number_of_characters) and clamp the range to it."
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
        let range: TextRange
        let insertedCharacters: Int
        /// Selection the element reports *after* the write, when it exposes one.
        let selectionAfter: TextRange?
        /// True when a non-empty selection was collapsed before inserting.
        let collapsedSelection: Bool
    }

    struct Value: Sendable {
        let text: String
        let numberOfCharacters: Int?
        let truncated: Bool
    }

    // MARK: - Pure helpers (unit-testable without a live element)

    /// Decode an `AXValue` that carries a `CFRange`. Returns nil for any
    /// other AXValue type — a wrong-typed attribute is a bug to surface, not
    /// something to coerce.
    static func textRange(from value: AXValue) -> TextRange? {
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return TextRange(location: range.location, length: range.length)
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

    /// Validate a caller-supplied range. Returns nil when acceptable, else a
    /// human-readable reason. `numberOfCharacters` nil means the element does
    /// not report a length — we then check signs only rather than guessing.
    static func validateRange(location: Int, length: Int, numberOfCharacters: Int?) -> String? {
        if location < 0 { return "location must be >= 0 (got \(location))." }
        if length < 0 { return "length must be >= 0 (got \(length))." }
        guard let total = numberOfCharacters else { return nil }
        if location > total {
            return "location \(location) is past the end of the text (number_of_characters=\(total))."
        }
        if location + length > total {
            return "range \(location)+\(length) exceeds the text length (number_of_characters=\(total))."
        }
        return nil
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

    /// Character-accurate truncation for `text_get_value`.
    static func truncate(_ text: String, maxChars: Int?) -> (text: String, truncated: Bool) {
        guard let maxChars, text.count > maxChars else { return (text, false) }
        return (String(text.prefix(maxChars)), true)
    }

    // MARK: - Element resolution

    /// The element that currently has keyboard focus inside `pid`'s app.
    /// Deliberately app-scoped (`AXUIElementCreateApplication`) rather than
    /// system-wide: the caller named an app, and the system-wide focused
    /// element belongs to whatever is frontmost right now.
    func focusedElement(pid: pid_t) throws(Failure) -> AXUIElement {
        try requireTrust()
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw .notFound
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    // MARK: - Reads

    func selection(of element: AXUIElement) throws(Failure) -> Selection {
        try requireTrust()
        try requireTextCapable(element)
        return Selection(
            text: string(element, kAXSelectedTextAttribute as String),
            range: range(element, kAXSelectedTextRangeAttribute as String),
            numberOfCharacters: integer(element, kAXNumberOfCharactersAttribute as String),
            visibleRange: range(element, kAXVisibleCharacterRangeAttribute as String),
            insertionPointLine: Self.sanitizeLineNumber(
                integer(element, kAXInsertionPointLineNumberAttribute as String)
            )
        )
    }

    func caret(of element: AXUIElement) throws(Failure) -> Caret {
        try requireTrust()
        try requireTextCapable(element)
        guard let selected = range(element, kAXSelectedTextRangeAttribute as String) else {
            throw .notSupported("Element does not expose AXSelectedTextRange, so it has no addressable caret.")
        }
        let index = selected.location
        let line = Self.sanitizeLineNumber(lineForIndex(element, index: index))
            ?? Self.sanitizeLineNumber(integer(element, kAXInsertionPointLineNumberAttribute as String))

        // A zero-length range is the true caret rect, but several apps answer
        // an empty rect (or nothing) for it — fall back to the bounds of the
        // character the caret sits in front of.
        var usedLength = 0
        var rect = boundsForRange(element, location: index, length: 0)
        if rect == nil || (rect?.width == 0 && rect?.height == 0) {
            if let wider = boundsForRange(element, location: index, length: 1) {
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

    func value(of element: AXUIElement, maxChars: Int?) throws(Failure) -> Value {
        try requireTrust()
        guard let raw = string(element, kAXValueAttribute as String) else {
            try assertAlive(element)
            throw .notSupported("Element exposes no string AXValue.")
        }
        let cut = Self.truncate(raw, maxChars: maxChars)
        return Value(
            text: cut.text,
            numberOfCharacters: integer(element, kAXNumberOfCharactersAttribute as String) ?? raw.count,
            truncated: cut.truncated
        )
    }

    // MARK: - Writes

    @discardableResult
    func setSelection(of element: AXUIElement, location: Int, length: Int) throws(Failure) -> TextRange {
        try requireTrust()
        try requireTextCapable(element)
        if let reason = Self.validateRange(
            location: location,
            length: length,
            numberOfCharacters: integer(element, kAXNumberOfCharactersAttribute as String)
        ) {
            throw .invalidRange(reason)
        }
        guard let value = Self.makeRangeValue(location: location, length: length) else {
            throw .axError(AXError.illegalArgument.rawValue, "Could not build an AXValue for the range.")
        }
        let status = AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, value
        )
        guard status == .success else { throw Self.classify(status, action: "set AXSelectedTextRange") }
        return TextRange(location: location, length: length)
    }

    /// Insert at the caret. A non-empty selection is collapsed to its end
    /// first, so "insert" never destroys selected text (use replaceRange when
    /// that is what you want).
    func insertAtCaret(of element: AXUIElement, text: String) throws(Failure) -> WriteOutcome {
        try requireTrust()
        try requireTextCapable(element)
        guard let current = range(element, kAXSelectedTextRangeAttribute as String) else {
            throw .notSupported("Element does not expose AXSelectedTextRange, so there is no caret to insert at.")
        }
        var collapsed = false
        var caret = current
        if current.length != 0 {
            caret = try setSelection(
                of: element, location: current.location + current.length, length: 0
            )
            collapsed = true
        }
        try writeSelectedText(element, text)
        return WriteOutcome(
            range: caret,
            insertedCharacters: text.count,
            selectionAfter: range(element, kAXSelectedTextRangeAttribute as String),
            collapsedSelection: collapsed
        )
    }

    func replaceRange(
        of element: AXUIElement, location: Int, length: Int, text: String
    ) throws(Failure) -> WriteOutcome {
        let target = try setSelection(of: element, location: location, length: length)
        try writeSelectedText(element, text)
        return WriteOutcome(
            range: target,
            insertedCharacters: text.count,
            selectionAfter: range(element, kAXSelectedTextRangeAttribute as String),
            collapsedSelection: false
        )
    }

    private func writeSelectedText(_ element: AXUIElement, _ text: String) throws(Failure) {
        let status = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        guard status == .success else {
            throw Self.classify(status, action: "write AXSelectedText")
        }
    }

    // MARK: - Guards

    private func requireTrust() throws(Failure) {
        guard AXIsProcessTrusted() else { throw .permissionMissing }
    }

    /// Distinguishes "not a text element" (not_supported) from "element is
    /// gone" (not_found) — both look like a failed attribute read otherwise.
    private func requireTextCapable(_ element: AXUIElement) throws(Failure) {
        var names: CFArray?
        let status = AXUIElementCopyAttributeNames(element, &names)
        if status == .invalidUIElement || status == .cannotComplete {
            throw .notFound
        }
        guard status == .success, let available = names as? [String] else {
            throw Self.classify(status, action: "list attribute names")
        }
        let textMarkers: Set<String> = [
            kAXSelectedTextRangeAttribute as String,
            kAXSelectedTextAttribute as String,
            kAXNumberOfCharactersAttribute as String
        ]
        guard !textMarkers.isDisjoint(with: available) else {
            let role = string(element, kAXRoleAttribute as String) ?? "unknown"
            throw .notSupported(
                "Element (role=\(role)) exposes none of AXSelectedTextRange/AXSelectedText/AXNumberOfCharacters — it is not an editable text element."
            )
        }
    }

    private func assertAlive(_ element: AXUIElement) throws(Failure) {
        var names: CFArray?
        let status = AXUIElementCopyAttributeNames(element, &names)
        if status == .invalidUIElement || status == .cannotComplete { throw .notFound }
    }

    static func classify(_ status: AXError, action: String) -> Failure {
        switch status {
        case .invalidUIElement, .cannotComplete:
            return .notFound
        case .attributeUnsupported, .actionUnsupported, .notImplemented, .illegalArgument:
            return .notSupported("Could not \(action): the element rejects it (AXError=\(status.rawValue)).")
        default:
            return .axError(status.rawValue, "Could not \(action)")
        }
    }

    // MARK: - Typed attribute reads

    private func rawAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard status == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        rawAttribute(element, name) as? String
    }

    private func integer(_ element: AXUIElement, _ name: String) -> Int? {
        (rawAttribute(element, name) as? NSNumber)?.intValue
    }

    private func range(_ element: AXUIElement, _ name: String) -> TextRange? {
        guard let raw = rawAttribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        return Self.textRange(from: unsafeDowncast(raw, to: AXValue.self))
    }

    private func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> Bounds? {
        guard let parameter = Self.makeRangeValue(location: location, length: length) else { return nil }
        var result: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result
        )
        guard status == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else {
            return nil
        }
        return Self.bounds(from: unsafeDowncast(result, to: AXValue.self))
    }

    private func lineForIndex(_ element: AXUIElement, index: Int) -> Int? {
        let parameter = NSNumber(value: index)
        var result: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element, kAXLineForIndexParameterizedAttribute as CFString, parameter, &result
        )
        guard status == .success else { return nil }
        return (result as? NSNumber)?.intValue
    }
}
