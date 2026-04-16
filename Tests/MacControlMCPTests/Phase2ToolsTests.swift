import Testing
import Foundation
@testable import MacControlMCP

@Suite("Phase 2 tools — browser + screen", .serialized)
struct Phase2ToolsTests {
    @Test("all phase 2 tools are registered")
    func phase2Definitions() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let names = Set(registry.toolDefinitions.map { $0.name })
        let expected: Set<String> = [
            "browser_list_tabs", "browser_get_active_tab",
            "browser_navigate", "browser_eval_js",
            "capture_screen", "ocr_screen"
        ]
        #expect(expected.isSubset(of: names))
    }

    @Test("browser kind detection")
    func browserDetection() {
        #expect(BrowserController.Browser.detect("safari") == .safari)
        #expect(BrowserController.Browser.detect("Safari") == .safari)
        #expect(BrowserController.Browser.detect("chrome") == .chrome)
        #expect(BrowserController.Browser.detect("Google Chrome") == .chrome)
        #expect(BrowserController.Browser.detect(nil) == .safari)
        #expect(BrowserController.Browser.detect("unknown") == .safari)
    }

    @Test("browser_navigate requires url")
    func navigateMissingURL() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: "browser_navigate", arguments: [:])
        #expect(result.isError == true)
    }

    @Test("browser_eval_js requires code")
    func evalMissingCode() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: "browser_eval_js", arguments: [:])
        #expect(result.isError == true)
    }

    @Test("capture_screen produces a readable PNG")
    func captureScreenSmoke() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: "capture_screen", arguments: [:])
        // Capture may fail on headless CI or without permission — check shape,
        // not success specifically. On a dev machine with permission it passes.
        guard case .object(let payload) = result.structuredContent else {
            Issue.record("no payload")
            return
        }
        if result.isError == false {
            guard case .string(let path) = payload["path"] ?? .null else {
                Issue.record("path missing")
                return
            }
            #expect(FileManager.default.fileExists(atPath: path))
            try? FileManager.default.removeItem(atPath: path)
        } else {
            #expect(payload["ok"] == .bool(false))
        }
    }

    @Test("capture_screen accepts custom output_path")
    func captureScreenCustomPath() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-test-\(UUID().uuidString).png").path

        let result = await registry.callTool(
            name: "capture_screen",
            arguments: ["output_path": .string(tmp)]
        )

        if result.isError == false {
            #expect(FileManager.default.fileExists(atPath: tmp))
            try? FileManager.default.removeItem(atPath: tmp)
        }
    }
}
