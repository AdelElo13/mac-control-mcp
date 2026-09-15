import Testing
@testable import MacControlMCP

/// v0.10 A7: Safari's empty result and browser policy denials need actionable codes.
@Suite("Browser DOM failures")
struct BrowserDOMFailureTests {
    @Test func evaluationFailuresAlwaysHaveRecoveryHints() {
        for code in [String?.none, "failed"] {
            let failure = BrowserDOMController.domResult(evaluation: .init(success: false, value: nil,
                error: "Evaluation failed", errorCode: code, hint: nil, pane: nil), browser: "Safari")
            #expect(failure.errorCode != nil)
            #expect(failure.hint?.isEmpty == false)
        }
        let failure = BrowserDOMController.domResult(evaluation: .init(success: false, value: nil,
            error: "Policy", errorCode: "permission_policy_denied", hint: "Allow JavaScript from Apple Events",
            pane: nil), browser: "Chrome")
        #expect(failure.errorCode == "permission_policy_denied")
        #expect(failure.hint == "Allow JavaScript from Apple Events")
    }

    @Test func missingSafariResultHasCodeAndSetting() {
        let failure = BrowserDOMController.decodeDOM("missing value", browser: "Safari")
        #expect(!failure.ok)
        #expect(failure.errorCode == "js_disabled")
        #expect(failure.hint?.contains("Enable JavaScript") == true)
    }
    @Test func nullDOMAndMalformedResultAreExplicit() {
        #expect(BrowserDOMController.decodeDOM("null", browser: "Safari").errorCode == "no_active_tab")
        #expect(BrowserDOMController.decodeDOM("broken JSON", browser: "Chrome").errorCode == "invalid_response")
    }
    @Test func browserPolicyAndMissingTabs() {
        for browser in [BrowserController.Browser.safari, .chrome] {
            let failure = BrowserErrorClassifier.classify(stderr: "JavaScript from Apple Events is disabled", browser: browser)
            #expect(failure.errorCode == "permission_policy_denied")
            #expect(failure.hint?.contains("Allow JavaScript from Apple Events") == true)
            #expect(BrowserErrorClassifier.classify(stderr: "Can't get current tab of window 1. (-1728)", browser: browser).errorCode == "no_active_tab")
        }
    }
}
