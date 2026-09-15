import Foundation
import ApplicationServices
import CoreGraphics

// v0.10 C1/C4/C8: all element input uses live identity, owner guards and
// read-back here, including calls dispatched by act.
extension ToolRegistry {
    struct ActionTarget: Sendable {
        let id: String
        let element: AXUIElement
        let pid: pid_t
        let identity: ProcessIdentity

        init(id: String, element: AXUIElement, pid: pid_t) {
            self.id = id
            self.element = element
            self.pid = pid
            self.identity = ProcessIdentity.current(pid: pid)
        }
    }

    enum ActionResolution {
        case target(ActionTarget)
        case failed(ToolCallResult)
    }

    func actionFailure(_ code: String, _ reason: String) -> ToolCallResult {
        errorResult(reason, ["ok": .bool(false), "error_code": .string(code), "error": .string(reason)])
    }

    func resolveActionTarget(_ raw: JSONValue?) async -> ActionResolution {
        guard let id = raw?.stringValue, !id.isEmpty else {
            return .failed(actionFailure("invalid_argument", "element_id must be a non-empty string."))
        }
        switch await elementCache.resolveLive(id) {
        case .unknown: return .failed(unknownElementResult(id))
        case .stale(let reason): return .failed(staleElementResult(id, reason: reason))
        case .evicted(let hint): return .failed(evictedElementResult(id, hint: hint))
        case .resolved(let element):
            // v0.10 C1: until the shared cache's A1 repair lands, never act
            // on an alive positional AX handle whose fingerprint changed.
            if let last = await elementCache.path(for: id)?.last,
               !AXPath.fingerprint(of: element).matches(last) {
                return .failed(staleElementResult(id, reason: "the live element fingerprint no longer matches the recorded target"))
            }
            guard let pid = await elementCache.pid(for: id) else {
                return .failed(unknownElementResult(id))
            }
            return .target(ActionTarget(id: id, element: element, pid: pid))
        }
    }

    static func actionAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func actionBool(_ element: AXUIElement, _ name: String) -> Bool? {
        (actionAttribute(element, name) as? NSNumber)?.boolValue
    }

    static func actionWindow(_ element: AXUIElement) -> AXUIElement? {
        if actionAttribute(element, "AXRole") as? String == "AXWindow" { return element }
        if let raw = actionAttribute(element, "AXWindow"), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            return unsafeDowncast(raw, to: AXUIElement.self)
        }
        // v0.10 C1: some controls omit AXWindow but still expose parents.
        var current = element
        for _ in 0..<64 {
            guard let raw = actionAttribute(current, "AXParent"), CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
            let parent = unsafeDowncast(raw, to: AXUIElement.self)
            if CFEqual(parent, current) { break }
            if actionAttribute(parent, "AXRole") as? String == "AXWindow" { return parent }
            current = parent
        }
        return nil
    }

    static func actionIsSecure(_ element: AXUIElement) -> Bool {
        actionAttribute(element, "AXRole") as? String == "AXSecureTextField"
            || actionAttribute(element, "AXSubrole") as? String == "AXSecureTextField"
    }

    func actionSnapshot(_ target: ActionTarget) -> [String: JSONValue] {
        let secure = Self.actionIsSecure(target.element)
        // v0.10 C4: never fetch or echo the value of a password field.
        var snapshot: [String: JSONValue] = [
            "element_id": .string(target.id), "pid": .number(Double(target.pid)),
            "role": (Self.actionAttribute(target.element, "AXRole") as? String).map(JSONValue.string) ?? .null,
            "title": (Self.actionAttribute(target.element, "AXTitle") as? String).map(JSONValue.string) ?? .null,
            "enabled": Self.actionBool(target.element, "AXEnabled").map(JSONValue.bool) ?? .null,
            "focused": Self.actionBool(target.element, "AXFocused").map(JSONValue.bool) ?? .null
        ]
        if !secure, let raw = Self.actionAttribute(target.element, "AXValue") {
            if let text = raw as? String { snapshot["value"] = .string(text) }
            else if let number = raw as? NSNumber { snapshot["value"] = .string(number.stringValue) }
        }
        snapshot["value"] = snapshot["value"] ?? .null
        return snapshot
    }

    func checkActionOwner(_ target: ActionTarget, arguments: [String: JSONValue]) async -> ToolCallResult? {
        let actual = await FocusGuard.currentFocus()
        if let mismatch = await checkFocusGuard(arguments, actual: actual) { return mismatch }
        guard actual.pid == target.pid else {
            return actionFailure("focus_mismatch", "The element's owning app is not frontmost; no input was sent.")
        }
        guard let ownerWindow = Self.actionWindow(target.element),
              let rawFocused = Self.actionAttribute(AXUIElementCreateApplication(target.pid), "AXFocusedWindow"),
              CFGetTypeID(rawFocused) == AXUIElementGetTypeID(), CFEqual(ownerWindow, rawFocused) else {
            return actionFailure("focus_mismatch", "The element's owning window is not the focused window (or cannot be verified).")
        }
        return nil
    }

    func actionPoint(_ target: ActionTarget) async -> CGPoint? {
        guard let frame = WindowController.axFrame(of: target.element),
              let window = Self.actionWindow(target.element),
              Self.actionBool(window, "AXMinimized") != true,
              let windowFrame = WindowController.axFrame(of: window) else { return nil }
        let displayFrames = await displays.list().map {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        return MouseController.visibleCenter(frame: frame, window: windowFrame, displays: displayFrames)
    }

    func actionPostCheck(_ target: ActionTarget, before: [String: JSONValue], acted: Bool) async -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "ok": .bool(acted), "acted": .bool(acted), "element_id": .string(target.id),
            "before": .object(before), "after": .null, "verified": .null
        ]
        guard acted else {
            payload["verified"] = .bool(false)
            payload["verification"] = .string("action_failed")
            return payload
        }
        switch await elementCache.resolveLive(target.id) {
        case .resolved(let element):
            if let last = await elementCache.path(for: target.id)?.last,
               !AXPath.fingerprint(of: element).matches(last) {
                payload["verification"] = .string("stale_element_fingerprint_mismatch")
                return payload
            }
            let after = actionSnapshot(ActionTarget(id: target.id, element: element, pid: target.pid))
            payload["after"] = .object(after)
            let changed = ["value", "focused"].first { before[$0] != .null && after[$0] != .null && before[$0] != after[$0] }
            payload["verified"] = changed == nil ? .null : .bool(true)
            payload["verification"] = .string(changed.map { "\($0)_changed" } ?? "element_still_resolves_effect_unobserved")
        case .evicted(let hint):
            payload["verification"] = .string("element_evicted_from_cache")
            payload["hint"] = .string(hint)
        case .stale(let reason):
            // v0.10 C1: an identity mismatch is not evidence of disappearance.
            let gone = Self.actionDefinitelyGone(target)
            payload["verified"] = gone ? .bool(true) : .null
            payload["verification"] = .string(gone ? "element_disappeared" : "stale_element: \(reason)")
        case .unknown:
            payload["verification"] = .string("element_id_expired_verification_unavailable")
        }
        return payload
    }

    static func actionDefinitelyGone(_ target: ActionTarget) -> Bool {
        // v0.10 C1/C3: process replacement is stale identity, not proof of
        // disappearance. Do not turn a recycled pid into successful verification.
        guard target.identity.matches(ProcessIdentity.current(pid: target.pid)) else { return false }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(target.element, "AXRole" as CFString, &value) == .invalidUIElement
    }

    func callElementMouse(_ name: String, _ arguments: [String: JSONValue]) async -> ToolCallResult {
        let sourceRaw = arguments["element_id"] ?? arguments["source_element_id"]
        var source: ActionTarget?
        var destination: ActionTarget?
        if let sourceRaw {
            switch await resolveActionTarget(sourceRaw) {
            case .failed(let result): return result
            case .target(let target): source = target
            }
        }
        if let raw = arguments["target_element_id"] {
            switch await resolveActionTarget(raw) {
            case .failed(let result): return result
            case .target(let target): destination = target
            }
        }
        guard let observed = source ?? destination else {
            return actionFailure("invalid_argument", "An element_id is required.")
        }
        if name == "scroll", (arguments["delta_x"]?.intValue ?? 0) == 0, (arguments["delta_y"]?.intValue ?? 0) == 0 {
            return actionFailure("invalid_argument", "scroll requires non-zero delta_x or delta_y.")
        }
        if ["click", "press", "double_click", "right_click"].contains(name),
           Self.actionBool(observed.element, "AXEnabled") == false {
            return actionFailure("element_disabled", "The target element is disabled; no input was sent.")
        }
        let before = actionSnapshot(observed)
        for target in [source, destination].compactMap({ $0 }) {
            if let mismatch = await checkActionOwner(target, arguments: arguments) { return mismatch }
        }
        if ["click", "press"].contains(name), let source,
           await accessibility.actionNames(element: source.element).contains("AXPress") {
            let outcome = await accessibility.pressElementViaAX(element: source.element)
            let ok: Bool
            switch outcome { case .succeeded: ok = true; default: ok = false }
            var payload = await actionPostCheck(source, before: before, acted: ok)
            payload["strategy"] = .string("AXPress")
            return ok ? successResult("Element pressed.", payload) : errorResult("AXPress failed.", payload)
        }
        if name == "press" { return actionFailure("not_supported", "Element does not support AXPress.") }
        func coordinate(_ x: String, _ y: String) -> CGPoint? {
            guard let x = arguments[x]?.doubleValue, let y = arguments[y]?.doubleValue, x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: x, y: y)
        }
        let start: CGPoint?
        if let source { start = await actionPoint(source) }
        else { start = coordinate("x1", "y1") }
        guard let start else {
            return actionFailure(source == nil ? "invalid_argument" : "not_visible", "Source has no visible center or valid coordinates.")
        }
        let end: CGPoint?
        if let destination { end = await actionPoint(destination) }
        else { end = coordinate("x2", "y2") }
        if name == "drag_and_drop", end == nil {
            return actionFailure(destination == nil ? "invalid_argument" : "not_visible", "Destination has no visible center or valid coordinates.")
        }
        // v0.10 C1: recheck ownership after geometry IPC, immediately before CGEvent.
        for target in [source, destination].compactMap({ $0 }) {
            if let mismatch = await checkActionOwner(target, arguments: arguments) { return mismatch }
        }
        let button = MouseController.Button(rawValue: arguments["button"]?.stringValue ?? "left") ?? .left
        let ok: Bool
        switch name {
        case "click": ok = await mouse.click(at: start)
        case "double_click": ok = await mouse.doubleClick(at: start, button: button)
        case "right_click": ok = await mouse.click(at: start, button: .right)
        case "scroll": ok = await mouse.scroll(deltaX: arguments["delta_x"]?.intValue ?? 0, deltaY: arguments["delta_y"]?.intValue ?? 0, at: start)
        case "drag_and_drop":
            guard let end else { return actionFailure("invalid_argument", "Missing drag destination.") }
            ok = await mouse.drag(from: start, to: end, button: button, steps: max(1, min(arguments["steps"]?.intValue ?? 20, 200)))
        default: return actionFailure("invalid_argument", "Unsupported element mouse action.")
        }
        var payload = await actionPostCheck(observed, before: before, acted: ok)
        payload["strategy"] = .string("coordinate")
        payload["x"] = .number(start.x)
        payload["y"] = .number(start.y)
        return ok ? successResult("Element input posted.", payload) : errorResult("Element input failed.", payload)
    }

    func focusActionTarget(_ target: ActionTarget, arguments: [String: JSONValue]) async -> ToolCallResult {
        await ElementInput.focusAndRun(secure: Self.actionIsSecure(target.element), focus: {
            if let mismatch = await self.checkActionOwner(target, arguments: arguments) { return mismatch }
            return await self.callSetElementAttribute([
                "element_id": .string(target.id), "name": .string("AXFocused"), "value": .bool(true)
            ])
        }, isFocused: {
            Self.actionBool(target.element, "AXFocused")
        }, input: {
            self.successResult("Element focus verified.", ["ok": .bool(true), "verified": .bool(true), "element_id": .string(target.id)])
        })
    }

    func callTargetedType(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let text = arguments["text"]?.stringValue,
              let strategy = AccessibilityController.TypeStrategy.resolve(argument: arguments["strategy"]?.stringValue) else {
            return actionFailure("invalid_argument", "type_text requires text and a valid strategy (auto, clipboard, keys, ax).")
        }
        let target: ActionTarget
        switch await resolveActionTarget(arguments["element_id"]) {
        case .failed(let result): return result
        case .target(let value): target = value
        }
        guard !Self.actionIsSecure(target.element) else {
            return actionFailure("not_supported", "secure_field: refusing to type into a password field.")
        }
        let before = actionSnapshot(target)
        let focus = await focusActionTarget(target, arguments: arguments)
        guard !focus.isError else { return focus }
        // v0.10 C4: focusing successfully is not enough if the user switched apps meanwhile.
        if let mismatch = await checkActionOwner(target, arguments: arguments) { return mismatch }
        guard Self.actionBool(target.element, "AXFocused") == true else {
            return actionFailure("focus_not_verified", "The target lost focus before typing.")
        }
        let result: ToolCallResult
        if strategy == .ax {
            result = await callSetElementAttribute([
                "element_id": .string(target.id), "name": .string("AXValue"), "value": .string(text)
            ])
        } else {
            var legacy = arguments
            legacy.removeValue(forKey: "element_id")
            result = await callTool(name: "type_text", arguments: legacy)
        }
        var payload = await actionPostCheck(target, before: before, acted: !result.isError)
        payload["result"] = result.structuredContent
        return result.isError ? errorResult("Targeted typing failed.", payload) : successResult("Typed into the focused element.", payload)
    }
}
