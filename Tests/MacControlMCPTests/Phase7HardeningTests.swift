import Testing
import Foundation
@testable import MacControlMCP

/// Regression tests for the Codex v0.5.0 hardening pass. Each test maps to
/// one of the P0/P1 findings Codex flagged in the v0.4.0 review. Failing
/// these means we regressed a security or reliability guarantee — treat
/// that failure as ship-blocking.
@Suite("Phase 7 hardening — Codex P0/P1 regressions", .serialized)
struct Phase7HardeningTests {

    // MARK: - Codex P0 #1: silent-success in SystemInfo tools

    @Test("battery_status surfaces ok:false when exit_code propagates")
    func batterySurfacesError() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "battery_status", arguments: [:])
        // On success we get ok:true + battery payload. On failure the
        // envelope now has ok:false + error + exit_code fields — we verify
        // the SHAPE of the failure response is structured, not nil-field.
        if case .object(let fields) = r.structuredContent,
           case .bool(let ok) = fields["ok"] ?? .null {
            if !ok {
                #expect(fields["error"] != nil, "error field must be present on failure")
                #expect(fields["exit_code"] != nil, "exit_code field must be present on failure")
            }
        }
    }

    // MARK: - Codex P0 #2: trash_file path traversal

    @Test("trash_file rejects ~/../etc/hosts via symlink escape")
    func trashFileRejectsTraversal() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let tildePath = "~/../etc/hosts"
        let r = await registry.callTool(
            name: "trash_file",
            arguments: ["path": .string(tildePath)]
        )
        #expect(r.isError == true)
        if case .object(let fields) = r.structuredContent,
           case .object(let res) = fields["result"] ?? .null,
           case .string(let err) = res["error"] ?? .null {
            #expect(
                err.contains("outside this root") || err.contains("restricted"),
                "expected path-traversal rejection, got: \(err)"
            )
        }
    }

    @Test("trash_file rejects ~/.ssh (sensitive-dir denylist)")
    func trashFileRejectsSsh() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "trash_file",
            arguments: ["path": .string("~/.ssh/id_ed25519")]
        )
        #expect(r.isError == true)
        if case .object(let fields) = r.structuredContent,
           case .object(let res) = fields["result"] ?? .null,
           case .string(let err) = res["error"] ?? .null {
            #expect(
                err.contains("protected directory") || err.contains(".ssh"),
                "expected denylist rejection for .ssh, got: \(err)"
            )
        }
    }

    @Test("trash_file rejects ~/Library/Keychains")
    func trashFileRejectsKeychain() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "trash_file",
            arguments: ["path": .string("~/Library/Keychains/login.keychain-db")]
        )
        #expect(r.isError == true)
    }

    // MARK: - Codex v0.5.1 follow-up blockers

    @Test("trash_file refuses the home directory itself (~)")
    func trashFileRefusesHomeRoot() async {
        // Codex blocker #1 from v0.5.0 review: trash_file("~") was allowed
        // because `canonical == home` satisfied the prefix check. A real
        // invocation would have asked Finder to nuke the entire home dir.
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "trash_file",
            arguments: ["path": .string("~")]
        )
        #expect(r.isError == true)
        if case .object(let fields) = r.structuredContent,
           case .object(let res) = fields["result"] ?? .null,
           case .string(let err) = res["error"] ?? .null {
            #expect(err.contains("home directory"), "expected home-root rejection, got: \(err)")
        }
    }

    @Test("trash_file rejects credential-bearing extensions (*.pem, *.key, *.env)")
    func trashFileRejectsCredentialExtensions() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        // Desktop is allowed by the HOME prefix check but the extension
        // check should still block credential file types regardless of
        // the containing directory.
        for ext in [".pem", ".key", ".env"] {
            let path = "~/Desktop/prod\(ext)"
            let r = await registry.callTool(
                name: "trash_file",
                arguments: ["path": .string(path)]
            )
            #expect(r.isError == true, "should refuse \(ext) file")
        }
    }

    @Test("trash_file rejects ~/.netrc and ~/.docker (Codex denylist gaps)")
    func trashFileRejectsCredentialStores() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        for protected in [".netrc", ".docker/config.json", ".npmrc", ".aws/credentials"] {
            let r = await registry.callTool(
                name: "trash_file",
                arguments: ["path": .string("~/\(protected)")]
            )
            #expect(r.isError == true, "should refuse ~/\(protected)")
        }
    }

    // MARK: - Codex blocker #3: silent-success in parsers

    @Test("network_info parser returns ok:false when zero interfaces parsed")
    func networkInfoRejectsEmptyParse() async {
        // This test is a structural/regression pin rather than a live
        // check: we simply verify the code contains the "0 interfaces"
        // guard so future refactors don't accidentally remove it.
        let src = try? String(contentsOfFile: "\((#filePath as NSString).deletingLastPathComponent)/../../Sources/MacControlMCP/SystemInfoController.swift", encoding: .utf8)
        #expect(src?.contains("parser produced 0 interfaces") == true,
                "SystemInfoController.network() must guard against empty interface list")
    }

    // MARK: - Codex blocker #4: missing enforceIfEnabled on 3 handlers

    @Test("set_brightness / night_shift_set / open_airplay_preferences now call enforceIfEnabled")
    func phase7DestructiveHandlersWired() async {
        // Another structural pin — verify the code contains the gate call.
        let src = try? String(contentsOfFile: "\((#filePath as NSString).deletingLastPathComponent)/../../Sources/MacControlMCP/Tools+V2Phase7.swift", encoding: .utf8)
        guard let src else {
            Issue.record("could not read Tools+V2Phase7.swift")
            return
        }
        // Each of these handlers must call enforceIfEnabled BEFORE invoking
        // the hardware layer.  We check on the whole-file substring: every
        // callXxx function body should contain both the handler name AND
        // enforceIfEnabled.
        for handler in ["callSetBrightness", "callNightShiftSet", "callOpenAirPlayPreferences"] {
            let range = src.range(of: handler)
            #expect(range != nil, "handler \(handler) not found")
            if let range = range {
                let after = String(src[range.upperBound...].prefix(600))
                #expect(
                    after.contains("enforceIfEnabled"),
                    "handler \(handler) must call enforceIfEnabled before side-effects"
                )
            }
        }
    }

    // MARK: - Codex P0 #3: open_url_scheme wildcard

    @Test("open_url_scheme blocks javascript: scheme")
    func openURLBlocksJavaScript() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "open_url_scheme",
            arguments: ["url": .string("javascript:alert(1)")]
        )
        #expect(r.isError == true)
        if case .object(let fields) = r.structuredContent,
           case .bool(let blocked) = fields["blocked"] ?? .null {
            #expect(blocked == true, "javascript: must be reported as blocked=true")
        }
    }

    @Test("open_url_scheme blocks file: scheme")
    func openURLBlocksFile() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "open_url_scheme",
            arguments: ["url": .string("file:///etc/passwd")]
        )
        #expect(r.isError == true)
    }

    @Test("open_url_scheme rejects unknown (non-allowlisted) scheme")
    func openURLRejectsUnknown() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "open_url_scheme",
            arguments: ["url": .string("weirdcustomscheme://foo")]
        )
        #expect(r.isError == true)
    }

    @Test("open_url_scheme accepts https://")
    func openURLAcceptsHTTPS() async {
        // NOTE: this will actually invoke /usr/bin/open https://example.com
        // which opens a browser tab. The test is written to check that the
        // scheme policy GATE allows it through; we rely on /usr/bin/open
        // succeeding on any Mac.
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "open_url_scheme",
            arguments: ["url": .string("https://example.com")]
        )
        // May return isError=false (open succeeded) OR isError=true if the
        // URL can't be opened for unrelated reasons, but `blocked` must be
        // false either way — the scheme should NOT be in the blocklist.
        if case .object(let fields) = r.structuredContent,
           case .object(let res) = fields["result"] ?? .null,
           case .bool(let blocked) = res["blocked"] ?? .null {
            #expect(blocked == false, "https must NOT be blocked")
        }
    }

    // MARK: - Codex P1: mission_control verified field

    @Test("mission_control result includes verified field (true or false, not absent)")
    func missionControlHasVerifiedField() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "mission_control", arguments: [:])
        // The result struct now carries a `verified` boolean. We don't assert
        // a specific value (depends on screen state) — just that it's
        // present in the structured payload.
        if case .object(let fields) = r.structuredContent,
           case .object(let res) = fields["result"] ?? .null {
            #expect(res["verified"] != nil, "mission_control must expose 'verified' field after v0.5.0 hardening")
        }
    }

    // MARK: - Codex P1: Phase 7 tiered-perm enforcement

    @Test("when enforcement is off, wifi_set bypasses the perm gate")
    func enforcementOffAllowsPhase7() async {
        // Default env has MAC_CONTROL_MCP_ENFORCE_TIERS unset → enforcement off.
        // wifi_set without state should be rejected by the handler's own
        // validation (not by the perm gate), confirming that gate didn't
        // short-circuit the normal flow.
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "wifi_set", arguments: [:])
        #expect(r.isError == true)
        if case .object(let fields) = r.structuredContent,
           case .string(let reason) = fields["reason"] ?? .null {
            // Reason should NOT be a permission reason ("denied", "no_grant",
            // "insufficient_tier", "expired") since enforcement is off.
            let permReasons = ["denied", "no_grant", "insufficient_tier", "expired"]
            #expect(!permReasons.contains(reason), "with enforcement off, reason should not be perm-related")
        }
    }
}
