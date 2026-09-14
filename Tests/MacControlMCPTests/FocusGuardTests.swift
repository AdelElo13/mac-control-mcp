import Testing
@testable import MacControlMCP

/// Regression tests for the input-focus guard (`FocusGuard`) added to
/// close the "two concurrent MCP clients steal focus between check and
/// keystroke" bug: `press_key` with cmd+a / cmd+v landed in the wrong
/// window because synthetic CGEvent input always goes to whatever app is
/// frontmost *at delivery time*, not whatever the caller last observed.
///
/// The pure matcher (`FocusGuard.evaluate`) is tested directly here with
/// no AX/NSWorkspace dependency. A handler-level test at the bottom
/// exercises the actual `press_key` tool end-to-end and asserts no key is
/// sent on mismatch.
@Suite("FocusGuard — input focus matching")
struct FocusGuardTests {

    @Test("matches by bundle id")
    func matchesByBundleId() {
        let result = FocusGuard.evaluate(
            expectedApp: "com.google.Chrome",
            expectedWindow: nil,
            actualAppName: "Google Chrome",
            actualBundleIdentifier: "com.google.Chrome",
            actualWindowTitle: "New Tab"
        )
        #expect(result == .match)
    }

    @Test("matches by localized app name, case-insensitive")
    func matchesByNameCaseInsensitive() {
        let result = FocusGuard.evaluate(
            expectedApp: "GOOGLE CHROME",
            expectedWindow: nil,
            actualAppName: "Google Chrome",
            actualBundleIdentifier: "com.google.Chrome",
            actualWindowTitle: nil
        )
        #expect(result == .match)
    }

    @Test("app mismatch when neither bundle id nor name matches")
    func appMismatch() {
        let result = FocusGuard.evaluate(
            expectedApp: "com.nonexistent.app",
            expectedWindow: nil,
            actualAppName: "Google Chrome",
            actualBundleIdentifier: "com.google.Chrome",
            actualWindowTitle: nil
        )
        guard case .mismatch(let reason) = result else {
            Issue.record("expected mismatch, got \(result)")
            return
        }
        #expect(reason.contains("com.nonexistent.app"))
    }

    @Test("window substring match, case-insensitive")
    func windowSubstringMatch() {
        let result = FocusGuard.evaluate(
            expectedApp: nil,
            expectedWindow: "PULL REQUEST",
            actualAppName: "Google Chrome",
            actualBundleIdentifier: "com.google.Chrome",
            actualWindowTitle: "Fix input focus guard · Pull Request #12 — mac-control-mcp"
        )
        #expect(result == .match)
    }

    @Test("window substring mismatch")
    func windowSubstringMismatch() {
        let result = FocusGuard.evaluate(
            expectedApp: nil,
            expectedWindow: "Gmail",
            actualAppName: "Google Chrome",
            actualBundleIdentifier: "com.google.Chrome",
            actualWindowTitle: "Fix input focus guard · Pull Request #12"
        )
        guard case .mismatch(let reason) = result else {
            Issue.record("expected mismatch, got \(result)")
            return
        }
        #expect(reason.contains("Gmail"))
    }

    @Test("only expected_app given — window is not checked")
    func onlyAppGiven() {
        let result = FocusGuard.evaluate(
            expectedApp: "com.apple.finder",
            expectedWindow: nil,
            actualAppName: "Finder",
            actualBundleIdentifier: "com.apple.finder",
            actualWindowTitle: nil
        )
        #expect(result == .match)
    }

    @Test("only expected_window given — app is not checked")
    func onlyWindowGiven() {
        let result = FocusGuard.evaluate(
            expectedApp: nil,
            expectedWindow: "Untitled",
            actualAppName: "TextEdit",
            actualBundleIdentifier: "com.apple.TextEdit",
            actualWindowTitle: "Untitled"
        )
        #expect(result == .match)
    }

    @Test("neither expected_app nor expected_window given — always matches")
    func neitherGivenAlwaysMatches() {
        let result = FocusGuard.evaluate(
            expectedApp: nil,
            expectedWindow: nil,
            actualAppName: nil,
            actualBundleIdentifier: nil,
            actualWindowTitle: nil
        )
        #expect(result == .match)
    }

    @Test("nil actual window title with expected_window given — mismatch")
    func nilActualWindowWithExpectedWindow() {
        let result = FocusGuard.evaluate(
            expectedApp: nil,
            expectedWindow: "Untitled",
            actualAppName: "TextEdit",
            actualBundleIdentifier: "com.apple.TextEdit",
            actualWindowTitle: nil
        )
        guard case .mismatch(let reason) = result else {
            Issue.record("expected mismatch, got \(result)")
            return
        }
        #expect(reason.contains("Untitled"))
    }

    @Test("empty-string expected_app / expected_window are treated as omitted")
    func emptyStringsTreatedAsOmitted() {
        let result = FocusGuard.evaluate(
            expectedApp: "",
            expectedWindow: "   ",
            actualAppName: "Finder",
            actualBundleIdentifier: "com.apple.finder",
            actualWindowTitle: nil
        )
        #expect(result == .match)
    }

    // MARK: - Handler-level test

    @Test("press_key with a non-frontmost expected_app returns focus_mismatch and sends no key")
    func pressKeyHonorsFocusGuard() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(
            name: "press_key",
            arguments: [
                "key": .string("shift"),
                "expected_app": .string("com.nonexistent.app")
            ]
        )

        #expect(result.isError == true)
        let payload = result.structuredContent.objectValue
        #expect(payload?["ok"]?.boolValue == false)
        #expect(payload?["error_code"]?.stringValue == "focus_mismatch")
        #expect(payload?["expected_app"]?.stringValue == "com.nonexistent.app")
        #expect(payload?["actual_app"] != nil)
        #expect(payload?["hint"] != nil)
    }

    @Test("click with coordinates and a non-frontmost expected_app returns focus_mismatch and clicks nothing")
    func clickCoordinatesHonorsFocusGuard() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(
            name: "click",
            arguments: [
                "x": .number(5),
                "y": .number(5),
                "expected_app": .string("com.nonexistent.app")
            ]
        )

        #expect(result.isError == true)
        let payload = result.structuredContent.objectValue
        #expect(payload?["ok"]?.boolValue == false)
        #expect(payload?["error_code"]?.stringValue == "focus_mismatch")
        #expect(payload?["expected_app"]?.stringValue == "com.nonexistent.app")
        #expect(payload?["actual_app"] != nil)
    }

    @Test("checkFocusGuard matches when expected_app is the live frontmost app — no input injected")
    func checkFocusGuardMatchesLiveFrontmostApp() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())

        // Read the real frontmost app via the no-op `focused_app` tool
        // rather than injecting any real input, per the review request.
        let focused = await registry.callTool(name: "focused_app", arguments: [:])
        guard let bundleID = focused.structuredContent.objectValue?["app"]?.objectValue?["bundleIdentifier"]?.stringValue else {
            Issue.record("focused_app did not report a bundleIdentifier — cannot verify a positive match live.")
            return
        }

        // Exercise `ToolRegistry.checkFocusGuard` directly (not a tool
        // that injects input) with the live frontmost bundle id: a
        // matching expected_app must return nil (no mismatch, nothing
        // to inject or abort).
        let outcome = await registry.checkFocusGuard(["expected_app": .string(bundleID)])
        #expect(outcome == nil)
    }
}
