import Foundation
import ApplicationServices

extension ToolRegistry {
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
                guard let pid = await elementCache.pid(for: id) else { return .failed(unknownElementResult(id)) }
                return .states([actionSnapshot(ActionTarget(id: id, element: element, pid: pid))])
            case .unknown: return .failed(unknownElementResult(id))
            case .stale(let reason):
                // v0.10 C3: only confirmed invalid AX handles prove disappearance;
                // an expired cache entry or identity mismatch must not pass a wait.
                if let original, Self.actionDefinitelyGone(original.element) { return .states([]) }
                return .failed(staleElementResult(id, reason: reason))
            }
        }
        if let raw = arguments["window_id"]?.intValue {
            guard let window = await windows.resolve(windowID: UInt32(raw)) else { return .states([]) }
            var payload = window.payload
            if let element = window.element {
                payload["focused"] = Self.actionBool(element, "AXFocused").map(JSONValue.bool) ?? .null
                payload["enabled"] = Self.actionBool(element, "AXEnabled").map(JSONValue.bool) ?? .null
            }
            payload["window"] = .object(window.payload)
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

    func callWaitFor(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let request = parseWait(arguments), waitTargetIsValid(arguments) else {
            return actionFailure("invalid_argument", "wait_for needs one target, a valid condition and its value/title, timeout_seconds 0...60 and poll_interval_ms 50...60000.")
        }
        var original: ActionTarget?
        if arguments["element_id"] != nil {
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
        input["element_id"] = .string(target.id)
        if ["set_value", "type", "key", "focus"].contains(action), Self.actionIsSecure(target.element) {
            return actionFailure("not_supported", "secure_field: refusing to edit a password field.")
        }
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
        let checked = await callWaitFor(waitArguments)
        let check = checked.structuredContent.objectValue ?? [:]
        payload["verified"] = check["verified"] ?? .null
        payload["verification"] = check["verification"] ?? check["error_code"] ?? .string("verification_unavailable")
        payload["after"] = check["element"] ?? .null
        payload["verification_result"] = checked.structuredContent
        payload["ok"] = .bool(check["verified"] == .bool(true))
        return check["verified"] == .bool(true) ? successResult("Action and verification completed.", payload) : errorResult("Action completed; verification did not pass.", payload)
    }
}
