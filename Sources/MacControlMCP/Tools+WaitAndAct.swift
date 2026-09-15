import Foundation
import ApplicationServices

extension ToolRegistry {
    // v0.10 C3: retain the legacy selectors, clamping and response shape,
    // while sharing the actual polling loop with wait_for.
    func callLegacyWait(_ arguments: [String: JSONValue], window: Bool) async -> ToolCallResult {
        let name = window ? "wait_for_window" : "wait_for_element"
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("\(name) requires a positive integer pid.")
        }
        let timeout = min(max(arguments["timeout_seconds"]?.doubleValue ?? 5, 0.1), 60)
        let interval = min(max(arguments["poll_interval_ms"]?.intValue ?? (window ? 250 : 200), 50), 60_000)
        let disappears = !window && arguments["expect_disappear"]?.boolValue == true
        let outcome = await ConditionWait.poll(timeout: timeout, intervalMS: interval,
                                              condition: disappears ? .disappears : .appears) {
            if window {
                let title = arguments["title_contains"]?.stringValue?.lowercased()
                let list = await self.windows.listAppWindows(pid: pid)
                guard let match = list.first(where: { title == nil || title!.isEmpty || $0.title.lowercased().contains(title!) }) else { return .states([]) }
                return .states([["window": encodeAsJSONValue(match)]])
            }
            guard let hit = await self.accessibility.findElementWithPath(pid: pid, role: arguments["role"]?.stringValue, title: arguments["title"]?.stringValue) else { return .states([]) }
            if disappears { return .states([[:]]) }
            let info = await self.accessibility.getElementInfo(element: hit.element)
            let id = await self.elementCache.store(hit.element, pid: pid, path: hit.path)
            return .states([["element_id": .string(id), "role": info.role.map(JSONValue.string) ?? .null, "title": info.title.map(JSONValue.string) ?? .null]])
        }
        var payload: [String: JSONValue] = ["ok": .bool(outcome.matched)]
        if !window { payload["attempts"] = .number(Double(outcome.attempts)) }
        if outcome.cancelled { payload["cancelled"] = .bool(true) }
        else if !outcome.matched { payload["timed_out"] = .bool(true) }
        else if window {
            payload["pid"] = .number(Double(pid)); payload["window"] = outcome.state?["window"]
        } else if disappears { payload["disappeared"] = .bool(true) }
        else { payload.merge(outcome.state ?? [:]) { _, new in new } }
        let message = outcome.matched ? (window ? "Window appeared." : "Element \(disappears ? "disappeared" : "appeared") after \(outcome.attempts) attempt(s).")
            : outcome.cancelled ? (window ? "Cancelled during poll." : "Cancelled after \(outcome.attempts) attempt(s).")
            : "Timed out after \(timeout)s\(window ? "" : " (\(outcome.attempts) attempts)")."
        return outcome.matched ? successResult(message, payload) : errorResult(message, payload)
    }

    struct WaitRequest: Sendable {
        let condition: ConditionWait.Condition
        let timeout: Double
        let intervalMS: Int
        let arguments: [String: JSONValue]
    }

    func parseWait(_ arguments: [String: JSONValue]) -> WaitRequest? {
        guard let raw = arguments["condition"]?.stringValue, let condition = ConditionWait.Condition(rawValue: raw) else { return nil }
        let timeout = arguments["timeout_seconds"]?.doubleValue ?? 5
        let interval = arguments["poll_interval_ms"]?.intValue ?? 200
        guard timeout.isFinite, timeout >= 0, timeout <= ToolTimeouts.maxWait, interval >= 50, interval <= 60_000 else { return nil }
        if arguments["timeout_seconds"] != nil && arguments["timeout_seconds"]?.doubleValue == nil { return nil }
        if arguments["poll_interval_ms"] != nil && arguments["poll_interval_ms"]?.intValue == nil { return nil }
        if [.valueEquals, .valueContains].contains(condition), arguments["value"]?.stringValue == nil { return nil }
        if condition == .titleContains, arguments["title"]?.stringValue == nil { return nil }
        return WaitRequest(condition: condition, timeout: timeout, intervalMS: interval, arguments: arguments)
    }

    func waitTargetIsValid(_ arguments: [String: JSONValue]) -> Bool {
        let count = ["element_id", "pid", "window_id"].filter { arguments[$0] != nil }.count
        guard count == 1 else { return false }
        if let raw = arguments["element_id"] { return raw.stringValue.map { !$0.isEmpty } == true }
        if let raw = arguments["window_id"] {
            guard let id = raw.intValue else { return false }
            return id > 0 && id <= Int(UInt32.max)
        }
        guard parsePID(arguments["pid"]) != nil else { return false }
        return ["role", "title", "value"].contains { arguments[$0]?.stringValue != nil }
    }

    func waitSample(_ arguments: [String: JSONValue], original: ActionTarget?) async -> ConditionWait.Sample {
        if let id = arguments["element_id"]?.stringValue {
            switch await elementCache.resolveLive(id) {
            case .resolved(let element):
                if let last = await elementCache.path(for: id)?.last,
                   !AXPath.fingerprint(of: element).matches(last) {
                    return .failed(staleElementResult(id, reason: "the live element fingerprint changed"))
                }
                guard let pid = await elementCache.pid(for: id) else { return .failed(unknownElementResult(id)) }
                return .states([actionSnapshot(ActionTarget(id: id, element: element, pid: pid))])
            case .unknown:
                if let original, Self.actionDefinitelyGone(original) { return .states([]) }
                return .failed(unknownElementResult(id))
            case .stale(let reason):
                // v0.10 C3: only confirmed invalid AX handles prove disappearance;
                // an expired cache entry or identity mismatch must not pass a wait.
                if let original, Self.actionDefinitelyGone(original) { return .states([]) }
                return .failed(staleElementResult(id, reason: reason))
            }
        }
        if let raw = arguments["window_id"]?.intValue {
            guard let window = await windows.resolve(windowID: UInt32(raw)) else { return .states([]) }
            var payload = window.payload
            if let element = window.element {
                let focusedWindow = Self.actionAttribute(AXUIElementCreateApplication(window.pid), "AXFocusedWindow")
                if let focusedWindow, CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
                    payload["focused"] = .bool(CFEqual(element, focusedWindow))
                } else { payload["focused"] = .null }
                payload["enabled"] = Self.actionBool(element, "AXEnabled").map(JSONValue.bool) ?? .null
            }
            return .states([payload])
        }
        guard let pid = parsePID(arguments["pid"]) else {
            return .failed(actionFailure("invalid_argument", "wait_for requires element_id, window_id or pid plus a selector."))
        }
        let matches = await accessibility.findElements(
            pid: pid, role: arguments["role"]?.stringValue, title: arguments["title"]?.stringValue,
            value: arguments["value"]?.stringValue, exact: arguments["exact"]?.boolValue ?? false
        )
        var states: [[String: JSONValue]] = []
        for match in matches {
            let id = await elementCache.store(match.element, pid: pid, path: match.path)
            states.append(actionSnapshot(ActionTarget(id: id, element: match.element, pid: pid)))
        }
        return .states(states)
    }

    func callWaitFor(_ arguments: [String: JSONValue], original: ActionTarget? = nil) async -> ToolCallResult {
        guard let request = parseWait(arguments), waitTargetIsValid(arguments) else {
            return actionFailure("invalid_argument", "wait_for needs one target, a valid condition and its value/title, timeout_seconds 0...60 and poll_interval_ms 50...60000.")
        }
        var original = original
        if original == nil, arguments["element_id"] != nil {
            switch await resolveActionTarget(arguments["element_id"]) {
            case .failed(let result): return result
            case .target(let target): original = target
            }
        }
        let target = original
        let outcome = await ConditionWait.poll(
            timeout: request.timeout, intervalMS: request.intervalMS, condition: request.condition,
            value: arguments["value"]?.stringValue, title: arguments["title"]?.stringValue
        ) { await self.waitSample(arguments, original: target) }
        if let failure = outcome.failure { return failure }
        let payload: [String: JSONValue] = [
            "ok": .bool(outcome.matched), "verified": .bool(outcome.matched),
            "condition": .string(request.condition.rawValue), "elapsed_ms": .number(outcome.elapsedMS),
            "attempts": .number(Double(outcome.attempts)), "timed_out": .bool(!outcome.matched && !outcome.cancelled),
            "cancelled": .bool(outcome.cancelled),
            "element": arguments["window_id"] == nil ? outcome.state.map(JSONValue.object) ?? .null : .null,
            "window": arguments["window_id"] != nil ? outcome.state.map(JSONValue.object) ?? .null : .null,
            "verification": .string(outcome.matched ? "condition_matched" : outcome.cancelled ? "cancelled" : "condition_not_met")
        ]
        return outcome.matched ? successResult("Wait condition matched.", payload) : errorResult("Wait condition not met.", payload)
    }

    func callAct(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let result = await executeAct(arguments)
        // v0.10 C8: even resolution/validation failures answer whether input ran.
        var payload: [String: JSONValue] = ["acted": .bool(false), "verified": .null,
            "before": .null, "after": .null, "element": .null,
            "verification": .string("action_not_started")]
        payload.merge(result.structuredContent.objectValue ?? [:]) { _, actual in actual }
        return ToolCallResult(text: result.text, structuredContent: .object(payload), isError: result.isError)
    }

    private func executeAct(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let verify = arguments["verify"]?.objectValue, parseWait(verify) != nil else {
            return actionFailure("invalid_argument", "act requires a valid verify condition, its value/title and bounded timeout.")
        }
        let actionObject = arguments["action"]?.objectValue
        let action = arguments["action"]?.stringValue ?? actionObject?["type"]?.stringValue
        guard let action, ["press", "click", "double_click", "right_click", "set_value", "focus", "type", "key"].contains(action) else {
            return actionFailure("invalid_argument", "Unsupported act action.")
        }
        var input = arguments.merging(actionObject ?? [:]) { _, new in new }
        if action == "type", input["text"]?.stringValue == nil { return actionFailure("invalid_argument", "type requires text.") }
        if action == "set_value", input["value"] == nil || input["value"] == .null { return actionFailure("invalid_argument", "set_value requires value.") }
        if action == "key", input["key"]?.stringValue == nil { return actionFailure("invalid_argument", "key requires key.") }
        // v0.10 C8: validate action data before even focus can be changed.
        if action == "key" {
            guard let key = input["key"]?.stringValue, KeyCodeMap.keyCode(for: key) != nil else {
                return actionFailure("invalid_argument", "Unsupported key.")
            }
            if case .failure(let error) = parseModifiers(input["modifiers"]) {
                return actionFailure("invalid_argument", error.description)
            }
        }
        if action == "type", AccessibilityController.TypeStrategy.resolve(argument: input["strategy"]?.stringValue) == nil {
            return actionFailure("invalid_argument", "Unsupported typing strategy.")
        }
        if action == "set_value" {
            switch input["value"] {
            case .string?, .bool?, .number?: break
            default: return actionFailure("invalid_argument", "set_value requires a string, boolean or number.")
            }
        }
        let overrideTarget = ["element_id", "pid", "window_id"].contains { verify[$0] != nil }
        if overrideTarget, !waitTargetIsValid(verify) { return actionFailure("invalid_argument", "verify target is invalid.") }
        let target: ActionTarget
        if let id = arguments["target"]?.stringValue {
            switch await resolveActionTarget(.string(id)) {
            case .failed(let result): return result
            case .target(let resolved): target = resolved
            }
        } else if let selector = arguments["target"]?.objectValue, let pid = parsePID(selector["pid"]),
                  selector["role"]?.stringValue != nil || selector["title"]?.stringValue != nil {
            let matches = await accessibility.findElements(pid: pid, role: selector["role"]?.stringValue,
                title: selector["title"]?.stringValue, value: nil, exact: selector["exact"]?.boolValue ?? false, limit: 2)
            guard matches.count == 1, let match = matches.first else {
                return actionFailure(matches.isEmpty ? "not_found" : "ambiguous_target", "act needs exactly one matching element.")
            }
            let id = await elementCache.store(match.element, pid: pid, path: match.path)
            switch await resolveActionTarget(.string(id)) {
            case .failed(let result): return result
            case .target(let resolved): target = resolved
            }
        } else { return actionFailure("invalid_argument", "target must be an element_id or {pid, role/title, exact}.") }
        // v0.10 C8: capture explicit verification handles BEFORE mutation;
        // an action may remove either itself or a different observed element.
        var verificationTarget: ActionTarget? = overrideTarget ? nil : target
        if let raw = verify["element_id"] {
            switch await resolveActionTarget(raw) {
            case .failed(let failure): return failure
            case .target(let resolved): verificationTarget = resolved
            }
        }
        input["element_id"] = .string(target.id)
        if ["set_value", "type", "key", "focus"].contains(action), Self.actionIsSecure(target.element) {
            return actionFailure("not_supported", "secure_field: refusing to edit a password field.")
        }
        if let mismatch = await checkActionOwner(target, arguments: input) { return mismatch }
        let before = actionSnapshot(target)
        let actionResult: ToolCallResult
        switch action {
        case "press": actionResult = await callElementMouse("press", input)
        case "click", "double_click", "right_click": actionResult = await callTool(name: action, arguments: input)
        case "set_value":
            actionResult = await callSetElementAttribute(["element_id": .string(target.id), "name": .string("AXValue"), "value": input["value"]!])
        case "focus": actionResult = await focusActionTarget(target, arguments: input)
        case "type": actionResult = await callTool(name: "type_text", arguments: input)
        case "key":
            let focused = await focusActionTarget(target, arguments: input)
            if focused.isError { actionResult = focused }
            else if let mismatch = await checkActionOwner(target, arguments: input) { actionResult = mismatch }
            else { actionResult = await callTool(name: "press_key", arguments: input) }
        default: return actionFailure("invalid_argument", "Unsupported action.")
        }
        var payload: [String: JSONValue] = [
            "ok": .bool(false), "acted": .bool(!actionResult.isError), "verified": .null,
            "before": .object(before), "after": .null, "element": .object(before), "result": actionResult.structuredContent
        ]
        guard !actionResult.isError else {
            payload["verification"] = .string("action_failed_verification_not_run")
            payload["error_code"] = actionResult.structuredContent.objectValue?["error_code"] ?? .string("action_failed")
            return errorResult("Action failed; verification was not run.", payload)
        }
        var waitArguments = verify
        if !overrideTarget { waitArguments["element_id"] = .string(target.id) }
        let checked = await callWaitFor(waitArguments, original: verificationTarget)
        let check = checked.structuredContent.objectValue ?? [:]
        payload["verified"] = check["verified"] ?? .null
        payload["verification"] = check["verification"] ?? check["error_code"] ?? .string("verification_unavailable")
        let post = await actionPostCheck(target, before: before, acted: true)
        payload["after"] = post["after"] ?? .null
        payload["verification_result"] = checked.structuredContent
        payload["ok"] = .bool(check["verified"] == .bool(true))
        return check["verified"] == .bool(true) ? successResult("Action and verification completed.", payload) : errorResult("Action completed; verification did not pass.", payload)
    }
}
