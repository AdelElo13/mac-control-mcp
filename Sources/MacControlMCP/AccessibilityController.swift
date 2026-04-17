import Foundation
import ApplicationServices
import CoreGraphics
import AppKit

// `AXUIElement` is documented as safe to use from any thread — the
// Accessibility framework internally serialises AX requests. It has no
// Swift-visible mutable state; the handle is an opaque CF reference.
// Sendable conformance is therefore sound in practice; `@unchecked` is
// used only because Apple does not mark the type `Sendable` themselves.
extension AXUIElement: @retroactive @unchecked Sendable {}

/// A Hashable wrapper around AXUIElement for use as a Set element during
/// tree walks. Hashes via CFHash (logical identity, stable across CFRef
/// allocator churn) and compares via CFEqual (handles the theoretical
/// hash-collision case where two distinct elements share a hash). This
/// is the canonical Foundation pattern for CF types and gives Set its
/// expected semantics without any pointer-address heuristics.
struct AXKey: Hashable {
    let element: AXUIElement
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    static func == (lhs: AXKey, rhs: AXKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

actor AccessibilityController {
    struct Point: Codable, Sendable {
        let x: Double
        let y: Double
    }

    struct Size: Codable, Sendable {
        let width: Double
        let height: Double
    }

    struct ElementInfo: Codable, Sendable {
        let role: String?
        let title: String?
        let value: String?
        let position: Point?
        let size: Size?
        let depth: Int?
    }

    struct TypeTextResult: Codable, Sendable {
        let success: Bool
        let strategy: String
    }

    struct AppInfo: Codable, Sendable {
        let pid: Int32
        let name: String
        let bundleIdentifier: String?
        let isActive: Bool
    }

    /// A node in a UI tree walk. `children` is only populated when the walk
    /// reached that depth; leaves have an empty array.
    struct TreeNode: Sendable {
        let element: AXUIElement
        let role: String?
        let title: String?
        let value: String?
        let position: Point?
        let size: Size?
        let depth: Int
        let childIndices: [Int]   // indices into the flat array returned by treeWalk
    }

    /// Result of querying attributes. Missing attrs are omitted.
    struct AttributeValues: Codable, Sendable {
        let values: [String: String]
        let unavailable: [String]
    }

    // Codex v8 #9 — expanded to include every role `list_elements`
    // should surface as actionable: AXSwitch, AXStepper, AXLevelIndicator
    // (custom meters), AXIncrementor, AXDecrementor, AXRow. Previously
    // these were exposed via get_ui_tree but filtered OUT by list_elements'
    // whitelist — a confusing divergence.
    private let actionableRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXComboBox",
        "AXDecrementor",
        "AXDisclosureTriangle",
        "AXIncrementor",
        "AXLevelIndicator",
        "AXLink",
        "AXMenuButton",
        "AXPopUpButton",
        "AXRadioButton",
        "AXRow",
        "AXSecureTextField",
        "AXSlider",
        "AXStepper",
        "AXSwitch",
        "AXTextArea",
        "AXTextField"
    ]

    func checkPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func requestPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func listElements(pid: pid_t, maxDepth: Int = 8) -> [ElementInfo] {
        let root = AXUIElementCreateApplication(pid)
        var visited = Set<AXKey>()
        var output: [ElementInfo] = []

        _ = walk(element: root, depth: 0, maxDepth: max(1, maxDepth), visited: &visited) { element, depth, role in
            guard self.actionableRoles.contains(role) else { return false }
            output.append(self.buildElementInfo(element: element, depth: depth, cachedRole: role))
            return false
        }

        return output
    }

    func findElement(pid: pid_t, role: String?, title: String?) -> AXUIElement? {
        // Inline recurse mirrors findElements — see that function for the
        // explanation of why the private `walk` helper is avoided here.
        let root = AXUIElementCreateApplication(pid)
        var visited = Set<AXKey>()
        var match: AXUIElement?

        func recurse(element: AXUIElement, depth: Int) -> Bool {
            guard depth <= 20 else { return false }
            // AXKey wraps CFHash + CFEqual — see its definition for why
            // the pointer address is wrong here.
            guard visited.insert(AXKey(element: element)).inserted else { return false }

            let currentRole = stringAttribute(of: element, attribute: kAXRoleAttribute as CFString) ?? "AXUnknown"
            let roleMatches: Bool = {
                guard let role, !role.isEmpty else { return true }
                return currentRole.range(of: role, options: [.caseInsensitive]) != nil
            }()
            let titleMatches: Bool = {
                guard let title, !title.isEmpty else { return true }
                let candidate = self.title(for: element) ?? self.stringAttribute(of: element, attribute: kAXValueAttribute as CFString)
                return candidate?.range(of: title, options: [.caseInsensitive]) != nil
            }()
            if roleMatches && titleMatches {
                match = element
                return true
            }
            for child in childElements(of: element) {
                if recurse(element: child, depth: depth + 1) { return true }
            }
            return false
        }
        _ = recurse(element: root, depth: 0)
        return match
    }

    func clickElement(element: AXUIElement) -> Bool {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }

        guard
            let position = pointAttribute(of: element, attribute: kAXPositionAttribute as CFString),
            let size = sizeAttribute(of: element, attribute: kAXSizeAttribute as CFString)
        else {
            return false
        }

        let center = CGPoint(x: position.x + (size.width / 2.0), y: position.y + (size.height / 2.0))
        return click(at: center)
    }

    func click(at point: CGPoint) -> Bool {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
            ),
            let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            )
        else {
            return false
        }

        mouseDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)
        mouseUp.post(tap: .cghidEventTap)
        return true
    }

    func typeText(text: String) async -> TypeTextResult {
        if setFocusedElementValue(text) {
            return TypeTextResult(success: true, strategy: "ax_set_value")
        }

        if typeWithUnicodeEvents(text) {
            return TypeTextResult(success: true, strategy: "cg_unicode")
        }

        if await pasteTextViaClipboard(text) {
            return TypeTextResult(success: true, strategy: "clipboard_paste")
        }

        return TypeTextResult(success: false, strategy: "none")
    }

    func readValue(element: AXUIElement) -> String? {
        if let value = stringAttribute(of: element, attribute: kAXValueAttribute as CFString) {
            return value
        }

        guard let rawValue = attributeValue(of: element, attribute: kAXValueAttribute as CFString) else {
            return nil
        }

        return String(describing: rawValue)
    }

    /// Press and hold a key without releasing. Pair with `keyUp` to release.
    /// Useful for building custom modifier-held sequences.
    func keyDown(keyCode: CGKeyCode, modifiers: [CGEventFlags] = []) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        else { return false }
        event.flags = modifiers.reduce(into: CGEventFlags()) { $0.formUnion($1) }
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Release a previously held key.
    func keyUp(keyCode: CGKeyCode, modifiers: [CGEventFlags] = []) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        event.flags = modifiers.reduce(into: CGEventFlags()) { $0.formUnion($1) }
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Post a sequence of keys in order. Each step is an independent
    /// down+up pair with its own modifier set, separated by `delay` seconds.
    func pressKeySequence(_ steps: [(CGKeyCode, [CGEventFlags])], delay: TimeInterval = 0.03) -> Bool {
        for (code, modifiers) in steps {
            guard pressKey(keyCode: code, modifiers: modifiers) else { return false }
            Thread.sleep(forTimeInterval: delay)
        }
        return true
    }

    // `nonisolated` so @Sendable closures (notably the pasteTextViaClipboard
    // body passed to PasteboardSnapshot.withSnapshot) can post keystrokes
    // without crossing actor boundaries. CGEvent posting is stateless
    // relative to this actor.
    nonisolated func pressKey(keyCode: CGKeyCode, modifiers: [CGEventFlags] = []) -> Bool {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }

        let flags = modifiers.reduce(into: CGEventFlags()) { partialResult, modifier in
            partialResult.formUnion(modifier)
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    func getFocusedApp() -> AppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return AppInfo(
            pid: app.processIdentifier,
            name: app.localizedName ?? "Unknown",
            bundleIdentifier: app.bundleIdentifier,
            isActive: app.isActive
        )
    }

    func listApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular && app.processIdentifier > 0
            }
            .sorted { lhs, rhs in
                (lhs.localizedName ?? "") < (rhs.localizedName ?? "")
            }
            .map { app in
                AppInfo(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? "Unknown",
                    bundleIdentifier: app.bundleIdentifier,
                    isActive: app.isActive
                )
            }
    }

    func getElementInfo(element: AXUIElement) -> ElementInfo {
        buildElementInfo(element: element, depth: nil, cachedRole: nil)
    }

    // MARK: - v0.2.0 deep UI

    /// Walks the AX tree for an app and returns every node (including
    /// non-actionable containers) up to `maxDepth`. Each node's `childIndices`
    /// points into the returned array so the tree can be reconstructed.
    func treeWalk(pid: pid_t, maxDepth: Int) -> [TreeNode] {
        let root = AXUIElementCreateApplication(pid)
        var visited = Set<AXKey>()
        var nodes: [TreeNode] = []

        func recurse(element: AXUIElement, depth: Int) -> Int {
            // AXKey wraps CFHash + CFEqual — see its definition for why
            // the pointer address is wrong here.
            let key = AXKey(element: element)
            guard visited.insert(key).inserted else { return -1 }

            let placeholderIndex = nodes.count
            nodes.append(
                TreeNode(
                    element: element,
                    role: stringAttribute(of: element, attribute: kAXRoleAttribute as CFString),
                    title: title(for: element),
                    value: stringAttribute(of: element, attribute: kAXValueAttribute as CFString),
                    position: pointAttribute(of: element, attribute: kAXPositionAttribute as CFString)
                        .map { Point(x: Double($0.x), y: Double($0.y)) },
                    size: sizeAttribute(of: element, attribute: kAXSizeAttribute as CFString)
                        .map { Size(width: Double($0.width), height: Double($0.height)) },
                    depth: depth,
                    childIndices: []
                )
            )

            guard depth < max(1, maxDepth) else { return placeholderIndex }

            var childIndices: [Int] = []
            for child in childElements(of: element) {
                let idx = recurse(element: child, depth: depth + 1)
                if idx >= 0 { childIndices.append(idx) }
            }

            let node = nodes[placeholderIndex]
            nodes[placeholderIndex] = TreeNode(
                element: node.element,
                role: node.role,
                title: node.title,
                value: node.value,
                position: node.position,
                size: node.size,
                depth: node.depth,
                childIndices: childIndices
            )
            return placeholderIndex
        }

        _ = recurse(element: root, depth: 0)
        return nodes
    }

    /// Returns all elements matching the given filters. Unlike `findElement`
    /// which returns only the first match.
    func findElements(
        pid: pid_t,
        role: String?,
        title: String?,
        value: String?,
        maxDepth: Int = 32,
        limit: Int = 100
    ) -> [(AXUIElement, ElementInfo)] {
        // Inline recurse (same structure as treeWalk) instead of going
        // through the private `walk(...)` helper. An earlier implementation
        // used `walk` with an `inout` visited set and a closure visitor; it
        // lost ~95% of the tree to spurious dedup hits on Logic Pro's AX
        // graph (43 nodes visited vs treeWalk's 936). The interaction of
        // actor isolation + inout parameters + capturing closures appears
        // to confuse the compiler's reference handling enough to break the
        // set's identity semantics in that code path.
        let root = AXUIElementCreateApplication(pid)
        var visited = Set<AXKey>()
        var matches: [(AXUIElement, ElementInfo)] = []

        func recurse(element: AXUIElement, depth: Int) {
            guard matches.count < limit, depth <= maxDepth else { return }
            // AXKey wraps CFHash + CFEqual — see its definition.
            guard visited.insert(AXKey(element: element)).inserted else { return }

            let currentRole = stringAttribute(of: element, attribute: kAXRoleAttribute as CFString) ?? "AXUnknown"
            if matchesFilter(element: element, currentRole: currentRole, role: role, title: title, value: value) {
                matches.append((element, buildElementInfo(element: element, depth: depth, cachedRole: currentRole)))
                if matches.count >= limit { return }
            }

            for child in childElements(of: element) {
                recurse(element: child, depth: depth + 1)
                if matches.count >= limit { return }
            }
        }

        recurse(element: root, depth: 0)
        return matches
    }

    /// Regex-aware search. Matches on role/title/value with case-insensitive
    /// regex semantics. Invalid regex falls back to literal substring.
    func queryElements(
        pid: pid_t,
        rolePattern: String?,
        titlePattern: String?,
        valuePattern: String?,
        maxDepth: Int = 32,
        limit: Int = 200
    ) -> [(AXUIElement, ElementInfo)] {
        let roleRegex = rolePattern.flatMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        let titleRegex = titlePattern.flatMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        let valueRegex = valuePattern.flatMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

        // Inline recurse for the same reason documented in findElements:
        // the private `walk(...)` helper's inout-visited-set + capturing-
        // visitor + actor-isolation interaction drops most of the tree on
        // real applications.
        let root = AXUIElementCreateApplication(pid)
        var visited = Set<AXKey>()
        var matches: [(AXUIElement, ElementInfo)] = []

        func recurse(element: AXUIElement, depth: Int) {
            guard matches.count < limit, depth <= maxDepth else { return }
            // AXKey wraps CFHash + CFEqual — see its definition for why
            // the pointer address is wrong here.
            let key = AXKey(element: element)
            guard visited.insert(key).inserted else { return }

            let currentRole = stringAttribute(of: element, attribute: kAXRoleAttribute as CFString) ?? "AXUnknown"
            let roleOk = Self.matches(regex: roleRegex, literal: rolePattern, candidate: currentRole)
            let titleCandidate = title(for: element) ?? ""
            let titleOk = Self.matches(regex: titleRegex, literal: titlePattern, candidate: titleCandidate)
            let valueCandidate = stringAttribute(of: element, attribute: kAXValueAttribute as CFString) ?? ""
            let valueOk = Self.matches(regex: valueRegex, literal: valuePattern, candidate: valueCandidate)
            if roleOk && titleOk && valueOk {
                matches.append((element, buildElementInfo(element: element, depth: depth, cachedRole: currentRole)))
                if matches.count >= limit { return }
            }

            for child in childElements(of: element) {
                recurse(element: child, depth: depth + 1)
                if matches.count >= limit { return }
            }
        }

        recurse(element: root, depth: 0)
        return matches
    }

    /// List every AX attribute name exposed by this element.
    func attributeNames(element: AXUIElement) -> [String] {
        var names: CFArray?
        let status = AXUIElementCopyAttributeNames(element, &names)
        guard status == .success, let names = names as? [String] else { return [] }
        return names
    }

    /// List every AX action name supported by this element (e.g. AXPress).
    func actionNames(element: AXUIElement) -> [String] {
        var names: CFArray?
        let status = AXUIElementCopyActionNames(element, &names)
        guard status == .success, let names = names as? [String] else { return [] }
        return names
    }

    /// Read multiple attributes at once. Returns their string representations
    /// plus a list of attributes that weren't available on this element.
    func getAttributes(element: AXUIElement, names: [String]) -> AttributeValues {
        var values: [String: String] = [:]
        var unavailable: [String] = []

        for name in names {
            guard let raw = attributeValue(of: element, attribute: name as CFString) else {
                unavailable.append(name)
                continue
            }
            values[name] = Self.describe(raw)
        }

        return AttributeValues(values: values, unavailable: unavailable)
    }

    /// Set an attribute value. Accepts String, Bool, or Number values.
    /// Returns the AXError rawValue; 0 (.success) means it worked.
    func setAttribute(element: AXUIElement, name: String, value: JSONValue) -> Int32 {
        let cfValue: CFTypeRef
        switch value {
        case .string(let s):
            cfValue = s as CFString
        case .bool(let b):
            cfValue = NSNumber(value: b)
        case .number(let n):
            cfValue = NSNumber(value: n)
        case .null:
            return AXError.illegalArgument.rawValue
        case .array, .object:
            return AXError.illegalArgument.rawValue
        }
        let status = AXUIElementSetAttributeValue(element, name as CFString, cfValue)
        return status.rawValue
    }

    /// Perform an arbitrary AX action on an element (AXPress, AXShowMenu,
    /// AXIncrement, AXDecrement, AXCancel, etc). Returns 0 on success.
    func performAction(element: AXUIElement, action: String) -> Int32 {
        let status = AXUIElementPerformAction(element, action as CFString)
        return status.rawValue
    }

    // MARK: - helpers for v0.2.0

    private func matchesFilter(
        element: AXUIElement,
        currentRole: String,
        role: String?,
        title: String?,
        value: String?
    ) -> Bool {
        if let role, !role.isEmpty, currentRole.range(of: role, options: [.caseInsensitive]) == nil {
            return false
        }
        if let title, !title.isEmpty {
            let candidate = self.title(for: element) ?? ""
            if candidate.range(of: title, options: [.caseInsensitive]) == nil { return false }
        }
        if let value, !value.isEmpty {
            let candidate = stringAttribute(of: element, attribute: kAXValueAttribute as CFString) ?? ""
            if candidate.range(of: value, options: [.caseInsensitive]) == nil { return false }
        }
        return true
    }

    private static func matches(regex: NSRegularExpression?, literal: String?, candidate: String) -> Bool {
        if let regex {
            let range = NSRange(candidate.startIndex..., in: candidate)
            return regex.firstMatch(in: candidate, range: range) != nil
        }
        guard let literal, !literal.isEmpty else { return true }
        return candidate.range(of: literal, options: [.caseInsensitive]) != nil
    }

    private static func describe(_ value: AnyObject) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let arr = value as? [AnyObject] { return "[\(arr.count) items]" }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return "<AXUIElement>" }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let axValue = unsafeDowncast(value, to: AXValue.self)
            switch AXValueGetType(axValue) {
            case .cgPoint:
                var p = CGPoint.zero
                if AXValueGetValue(axValue, .cgPoint, &p) { return "point(\(p.x),\(p.y))" }
            case .cgSize:
                var s = CGSize.zero
                if AXValueGetValue(axValue, .cgSize, &s) { return "size(\(s.width),\(s.height))" }
            case .cgRect:
                var r = CGRect.zero
                if AXValueGetValue(axValue, .cgRect, &r) {
                    return "rect(\(r.origin.x),\(r.origin.y),\(r.size.width),\(r.size.height))"
                }
            case .cfRange:
                var rng = CFRange(location: 0, length: 0)
                if AXValueGetValue(axValue, .cfRange, &rng) { return "range(\(rng.location),\(rng.length))" }
            default:
                break
            }
        }
        return String(describing: value)
    }

    private func buildElementInfo(element: AXUIElement, depth: Int?, cachedRole: String?) -> ElementInfo {
        let role = cachedRole ?? stringAttribute(of: element, attribute: kAXRoleAttribute as CFString)
        let title = title(for: element)
        let value = stringAttribute(of: element, attribute: kAXValueAttribute as CFString)

        let position = pointAttribute(of: element, attribute: kAXPositionAttribute as CFString).map { point in
            Point(x: Double(point.x), y: Double(point.y))
        }

        let size = sizeAttribute(of: element, attribute: kAXSizeAttribute as CFString).map { size in
            Size(width: Double(size.width), height: Double(size.height))
        }

        return ElementInfo(
            role: role,
            title: title,
            value: value,
            position: position,
            size: size,
            depth: depth
        )
    }

    @discardableResult
    // Legacy helper retained only for `listElements` (v0.1 code path).
    // Uses CFHash(element) for cycle detection — see findElements for the
    // detailed rationale. Core Foundation recycles freed CFRef pointers,
    // so a pointer-keyed visited set silently drops most of a real app's
    // AX tree once elements get released and their addresses reused.
    private func walk(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        visited: inout Set<AXKey>,
        visitor: (AXUIElement, Int, String) -> Bool
    ) -> Bool {
        guard depth <= maxDepth else { return false }

        guard visited.insert(AXKey(element: element)).inserted else { return false }

        let role = stringAttribute(of: element, attribute: kAXRoleAttribute as CFString) ?? "AXUnknown"
        if visitor(element, depth, role) {
            return true
        }

        for child in childElements(of: element) {
            if walk(element: child, depth: depth + 1, maxDepth: maxDepth, visited: &visited, visitor: visitor) {
                return true
            }
        }

        return false
    }

    private func title(for element: AXUIElement) -> String? {
        stringAttribute(of: element, attribute: kAXTitleAttribute as CFString)
            ?? stringAttribute(of: element, attribute: kAXDescriptionAttribute as CFString)
            ?? stringAttribute(of: element, attribute: "AXIdentifier" as CFString)
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        guard let rawChildren = attributeValue(of: element, attribute: kAXChildrenAttribute as CFString) else {
            return []
        }

        if let children = rawChildren as? [AXUIElement] {
            return children
        }

        if let children = rawChildren as? NSArray {
            return children.compactMap { child in
                guard CFGetTypeID(child as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
                return unsafeDowncast(child as AnyObject, to: AXUIElement.self)
            }
        }

        return []
    }

    private func attributeValue(of element: AXUIElement, attribute: CFString) -> AnyObject? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else { return nil }
        return value
    }

    private func stringAttribute(of element: AXUIElement, attribute: CFString) -> String? {
        guard let value = attributeValue(of: element, attribute: attribute) else { return nil }

        if let string = value as? String {
            return string
        }

        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        return nil
    }

    private func pointAttribute(of element: AXUIElement, attribute: CFString) -> CGPoint? {
        // Every conversion step is guarded — Optional return signals
        // "no valid geometry" cleanly. AXValueGetValue returns false if
        // the stored type doesn't match the requested kind, in which case
        // the pointee is undefined (NOT zero), so we must honour the bool.
        guard let raw = attributeValue(of: element, attribute: attribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(of element: AXUIElement, attribute: CFString) -> CGSize? {
        guard let raw = attributeValue(of: element, attribute: attribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func setFocusedElementValue(_ text: String) -> Bool {
        guard let focused = focusedElement() else { return false }
        let status = AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, text as CFTypeRef)
        return status == .success
    }

    private func typeWithUnicodeEvents(_ text: String) -> Bool {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            return false
        }

        let characters = Array(text.utf16)
        characters.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func pasteTextViaClipboard(_ text: String) async -> Bool {
        // withSnapshot guarantees restore runs before we return (was a
        // detached Task in the previous version, which Codex flagged as a
        // race against the next pasteboard op).
        await PasteboardSnapshot.withSnapshot {
            let setOK = await MainActor.run { () -> Bool in
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
            }
            guard setOK else { return false }
            let pasted = pressKey(keyCode: 9, modifiers: [.maskCommand])
            try? await Task.sleep(nanoseconds: 50_000_000)
            return pasted
        }
    }
}
