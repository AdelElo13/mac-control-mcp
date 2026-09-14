import Testing
import Foundation
@testable import MacControlMCP

/// Regression coverage for the osascript error classifier (BUG-FIX
/// fix/browser-errors): `browser_list_tabs` / `browser_get_active_tab`
/// were silently turning "Apple Events permission not granted" into
/// `tabs: []` plus a misleading `multi_process_hint`. This suite locks
/// down the pure classification logic (stderr string -> structured
/// error_code/hint/pane) plus the tab-parsing robustness fix.
@Suite("Browser error classification")
struct BrowserErrorClassificationTests {

    // MARK: - permission_missing (-1743, Automation not granted)

    @Test("Chrome -1743 Apple Events denial classifies as permission_missing")
    func chromeNotAuthorized() {
        let stderr = "execution error: Not authorized to send Apple events to Google Chrome. (-1743)"
        let c = BrowserErrorClassifier.classify(stderr: stderr, browser: .chrome)
        #expect(c.errorCode == "permission_missing")
        #expect(c.pane == "automation")
        #expect(c.hint?.lowercased().contains("automation") == true)
    }

    @Test("Safari -1743 Apple Events denial classifies as permission_missing")
    func safariNotAuthorized() {
        let stderr = "execution error: Not authorized to send Apple events to Safari. (-1743)"
        let c = BrowserErrorClassifier.classify(stderr: stderr, browser: .safari)
        #expect(c.errorCode == "permission_missing")
        #expect(c.pane == "automation")
        #expect(c.hint?.contains("Safari") == true)
    }

    // MARK: - permission_policy_denied (JS from Apple Events disabled)

    @Test("Chrome JS-from-AppleScript-disabled classifies as permission_policy_denied")
    func chromeJSDisabled() {
        let stderr = "Google Chrome got an error: Executing JavaScript through AppleScript is turned off. " +
            "To turn it on, from the menu bar, go to View > Developer > Allow JavaScript from Apple Events."
        let c = BrowserErrorClassifier.classify(stderr: stderr, browser: .chrome)
        #expect(c.errorCode == "permission_policy_denied")
        #expect(c.hint?.contains("View") == true)
        #expect(c.hint?.contains("Developer") == true)
    }

    @Test("Safari JS-from-AppleEvents-disabled classifies as permission_policy_denied")
    func safariJSDisabled() {
        let stderr = "Safari got an error: Allow JavaScript from Apple Events is not enabled."
        let c = BrowserErrorClassifier.classify(stderr: stderr, browser: .safari)
        #expect(c.errorCode == "permission_policy_denied")
        #expect(c.hint?.contains("Develop") == true)
        #expect(c.hint?.contains("Advanced") == true)
    }

    // MARK: - not_running (-600)

    @Test("-600 application isn't running classifies as not_running")
    func appNotRunning() {
        let stderr = "execution error: Google Chrome got an error: Application isn't running. (-600)"
        let c = BrowserErrorClassifier.classify(stderr: stderr, browser: .chrome)
        #expect(c.errorCode == "not_running")
    }

    @Test("'isn't running' text without the numeric code still classifies as not_running")
    func appNotRunningTextOnly() {
        let stderr = "Safari isn't running."
        let c = BrowserErrorClassifier.classify(stderr: stderr, browser: .safari)
        #expect(c.errorCode == "not_running")
    }

    // MARK: - timeout (-1712)

    @Test("-1712 timeout classifies as timeout")
    func timeout() {
        let stderr = "execution error: Google Chrome got an error: AppleEvent timed out. (-1712)"
        let c = BrowserErrorClassifier.classify(stderr: stderr, browser: .chrome)
        #expect(c.errorCode == "timeout")
    }

    // MARK: - fallback

    @Test("Unrecognized stderr classifies as failed and preserves raw text")
    func unrecognizedFailure() {
        let stderr = "execution error: Some completely different AppleScript failure. (-2753)"
        let c = BrowserErrorClassifier.classify(stderr: stderr, browser: .safari)
        #expect(c.errorCode == "failed")
        #expect(c.error == stderr)
        #expect(c.pane == nil)
    }

    // MARK: - permission_missing takes priority over generic "apple event" mentions

    @Test("permission_missing is not confused with the JS policy error")
    func noCrossClassification() {
        let permissionErr = "Not authorized to send Apple events to Safari. (-1743)"
        let policyErr = "Executing JavaScript through AppleScript is turned off."
        #expect(BrowserErrorClassifier.classify(stderr: permissionErr, browser: .safari).errorCode == "permission_missing")
        #expect(BrowserErrorClassifier.classify(stderr: policyErr, browser: .chrome).errorCode == "permission_policy_denied")
    }

    // MARK: - parseTabs robustness (record/unit separators, not tab/newline)

    @Test("parseTabs handles a tab character embedded in a page title")
    func parseTabsWithEmbeddedTabCharacter() async {
        let browser = BrowserController()
        let rs = String(UnicodeScalar(30)) // record separator
        let us = String(UnicodeScalar(31)) // unit separator
        // Title contains a literal tab character (\t) and a newline — both of
        // which would have corrupted the old tab/linefeed-delimited format.
        let messyTitle = "Report\tQ3\nSummary"
        let raw = "1\(us)1\(us)\(messyTitle)\(us)https://example.com/report\(us)true\(rs)"
            + "1\(us)2\(us)Second Tab\(us)https://example.com/second\(us)false"
        let tabs = await browser.parseTabs(browser: "Safari", raw: raw)
        #expect(tabs.count == 2)
        #expect(tabs[0].title == messyTitle)
        #expect(tabs[0].active == true)
        #expect(tabs[1].title == "Second Tab")
        #expect(tabs[1].active == false)
    }

    @Test("parseTabs returns empty array for empty input")
    func parseTabsEmpty() async {
        let browser = BrowserController()
        let tabs = await browser.parseTabs(browser: "Safari", raw: "")
        #expect(tabs.isEmpty)
    }
}
