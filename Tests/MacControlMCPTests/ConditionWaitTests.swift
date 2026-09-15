import Testing
import Foundation
@testable import MacControlMCP

// v0.10 C3/C8: scripted observations exercise the real poller without desktop access.
@Suite("Condition waits", .serialized)
struct ConditionWaitTests {
    actor Samples {
        var states: [[[String: JSONValue]]]
        var reads = 0
        init(_ states: [[[String: JSONValue]]]) { self.states = states }
        func next() -> ConditionWait.Sample {
            reads += 1
            return .states(states.count > 1 ? states.removeFirst() : states[0])
        }
    }

    @Test("each condition distinguishes missing attributes from known values")
    func predicates() {
        let state: [String: JSONValue] = ["enabled": .bool(false), "focused": .bool(true), "value": .string("hello world"), "title": .string("Save Document")]
        #expect(ConditionWait.Condition.appears.matches(state, value: nil, title: nil))
        #expect(ConditionWait.Condition.disappears.matches(nil, value: nil, title: nil))
        #expect(!ConditionWait.Condition.disappears.matches(state, value: nil, title: nil))
        #expect(!ConditionWait.Condition.enabled.matches(state, value: nil, title: nil))
        #expect(ConditionWait.Condition.disabled.matches(state, value: nil, title: nil))
        #expect(!ConditionWait.Condition.disabled.matches([:], value: nil, title: nil))
        #expect(ConditionWait.Condition.focused.matches(state, value: nil, title: nil))
        #expect(ConditionWait.Condition.valueEquals.matches(state, value: "hello world", title: nil))
        #expect(!ConditionWait.Condition.valueEquals.matches(state, value: "world", title: nil))
        #expect(ConditionWait.Condition.valueContains.matches(state, value: "world", title: nil))
        #expect(ConditionWait.Condition.titleContains.matches(state, value: nil, title: "DOCUMENT"))
    }

    @Test("wait finds a later matching candidate and returns its state")
    func laterCandidate() async {
        let samples = Samples([[["enabled": .bool(false)], ["enabled": .bool(true), "element_id": .string("second")]]])
        let result = await ConditionWait.poll(timeout: 1, intervalMS: 50, condition: .enabled) { await samples.next() }
        #expect(result.matched)
        #expect(result.state?["element_id"] == .string("second"))
        #expect(result.attempts == 1)
    }

    @Test("polling sees transitions")
    func transitions() async {
        let samples = Samples([[["focused": .bool(false)]], [["focused": .bool(true)]]])
        let result = await ConditionWait.poll(timeout: 1, intervalMS: 50, condition: .focused) { await samples.next() }
        #expect(result.matched)
        #expect(result.attempts == 2)
        #expect(result.elapsedMS >= 40)
    }

    @Test("deadline prevents a fresh sample after the wait has expired")
    func deadline() async {
        let samples = Samples([[], [["element_id": .string("too late")]]])
        let result = await ConditionWait.poll(timeout: 0.05, intervalMS: 60_000, condition: .appears) { await samples.next() }
        #expect(!result.matched)
        #expect(await samples.reads == 1)
        #expect(result.elapsedMS < 500)
    }

    @Test("a failed observation cannot satisfy disappears")
    func failures() async {
        let result = await ConditionWait.poll(timeout: 0, intervalMS: 50, condition: .disappears) {
            .failed(ToolCallResult(text: "stale", structuredContent: .object(["error_code": .string("stale_element")]), isError: true))
        }
        #expect(!result.matched)
        #expect(result.failure?.structuredContent.objectValue?["error_code"] == .string("stale_element"))
    }
}
