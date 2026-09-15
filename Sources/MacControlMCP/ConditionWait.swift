import Foundation

// v0.10 C3/C8: the poll loop and predicates are shared by waits and act.
// Missing AX attributes are unknown, never false (especially AXEnabled).
enum ConditionWait {
    enum Condition: String, CaseIterable, Sendable {
        case appears, disappears, enabled, disabled, focused
        case valueEquals = "value_equals"
        case valueContains = "value_contains"
        case titleContains = "title_contains"

        func matches(_ state: [String: JSONValue]?, value: String?, title: String?) -> Bool {
            if self == .disappears { return state == nil }
            guard let state else { return false }
            switch self {
            case .appears: return true
            case .disappears: return false
            case .enabled: return state["enabled"] == .bool(true)
            case .disabled: return state["enabled"] == .bool(false)
            case .focused: return state["focused"] == .bool(true)
            case .valueEquals: return value != nil && state["value"]?.stringValue == value
            case .valueContains:
                guard let value, let actual = state["value"]?.stringValue else { return false }
                return actual.contains(value)
            case .titleContains:
                guard let title, let actual = state["title"]?.stringValue else { return false }
                return actual.localizedCaseInsensitiveContains(title)
            }
        }
    }

    enum Sample: Sendable {
        case states([[String: JSONValue]])
        case failed(ToolCallResult)
    }

    struct Outcome: Sendable {
        let matched: Bool
        let state: [String: JSONValue]?
        let attempts: Int
        let elapsedMS: Double
        let failure: ToolCallResult?
        let cancelled: Bool
    }

    static func poll(
        timeout: Double, intervalMS: Int,
        condition: Condition, value: String? = nil, title: String? = nil,
        sample: @Sendable () async -> Sample
    ) async -> Outcome {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: .seconds(timeout))
        var attempts = 0
        var last: [String: JSONValue]?
        func result(_ matched: Bool, _ failure: ToolCallResult? = nil, cancelled: Bool = false) -> Outcome {
            let duration = start.duration(to: .now).components
            return Outcome(matched: matched, state: last, attempts: attempts,
                           elapsedMS: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15,
                           failure: failure, cancelled: cancelled)
        }
        while true {
            if Task.isCancelled { return result(false, cancelled: true) }
            if attempts > 0, ContinuousClock.now >= deadline { return result(false) }
            attempts += 1
            switch await sample() {
            case .failed(let failure): return result(false, failure)
            case .states(let states):
                last = states.first
                if states.isEmpty, condition.matches(nil, value: value, title: title) { return result(true) }
                if let match = states.first(where: { condition.matches($0, value: value, title: title) }) {
                    last = match
                    return result(true)
                }
            }
            let now = ContinuousClock.now
            guard now < deadline else { return result(false) }
            do {
                // v0.10 C3: a long poll interval must not extend the requested deadline.
                try await ContinuousClock().sleep(until: min(deadline, now.advanced(by: .milliseconds(intervalMS))))
            } catch { return result(false, cancelled: true) }
        }
    }
}
