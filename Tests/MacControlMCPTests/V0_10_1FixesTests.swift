import Foundation
import Testing
@testable import MacControlMCP

/// v0.10.1 — fixes for failures seen in a month of real agent use.
@Suite("v0.10.1 fixes", .serialized)
struct V0_10_1FixesTests {

    // MARK: - #1 mcp_server_info must not suggest killing live instances

    private func row(_ pid: Int, _ ppid: Int, _ command: String) -> ToolRegistry.PsRow {
        ToolRegistry.PsRow(pid: pid, ppid: ppid, start: "Wed Oct 14 00:28:52 2026", command: command)
    }

    private let desktopExe = "/Users/x/Library/Application Support/Claude/Claude Extensions/local.mcpb.x.mac-control-mcp/MacControlMCP.app/Contents/MacOS/MacControlMCP"
    private let appsExe = "/Users/x/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"

    @Test("ps rows parse with lstart and commands containing spaces")
    func parsesPsRows() {
        let text = """
          36105 36104 Wed Oct 14 01:00:35 2026     \(desktopExe)
             10     1 Tue Oct 13 20:51:49 2026 /sbin/launchd
        """
        let rows = ToolRegistry.parsePsRows(text)
        #expect(rows.count == 2)
        #expect(rows[0] == row(36105, 36104, desktopExe).withStart("Wed Oct 14 01:00:35 2026"))
        #expect(rows[1].command == "/sbin/launchd")
    }

    @Test("disclaimer wrappers are not counted as server instances")
    func wrapperIsNotAnInstance() {
        #expect(ToolRegistry.serverExecutable(of: desktopExe) == desktopExe)
        #expect(ToolRegistry.serverExecutable(of: "/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- \(desktopExe)") == nil)
        #expect(ToolRegistry.serverExecutable(of: "\(appsExe)-helper") == nil)
    }

    @Test("program names come from argv[0], not from arguments")
    func programNames() {
        #expect(ToolRegistry.programName(of: "/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- \(desktopExe)") == "disclaimer")
        #expect(ToolRegistry.programName(of: "/Applications/Claude.app/Contents/MacOS/Claude") == "Claude")
        #expect(ToolRegistry.programName(of: "/Users/x/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude --output-format stream-json") == "claude")
        #expect(ToolRegistry.programName(of: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex -c x app-server") == "codex")
        #expect(ToolRegistry.programName(of: "/opt/homebrew/bin/node /x/y.js") == "node")
    }

    @Test("instances of live clients are connected; only orphans are offered for kill")
    func classifiesInstances() {
        let rows = [
            row(1, 0, "/sbin/launchd"),
            row(500, 1, "/Applications/Claude.app/Contents/MacOS/Claude"),
            row(501, 500, "/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- \(desktopExe)"),
            row(502, 501, desktopExe),                       // Desktop, connected via wrapper
            row(600, 1, "/Users/x/claude.app/Contents/MacOS/claude --output-format stream-json"),
            row(601, 600, appsExe),                          // Claude Code, connected
            row(602, 600, appsExe),                          // this process
            row(700, 1, appsExe),                            // orphan: re-parented to launchd
            row(801, 1, "/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- \(desktopExe)"),
            row(802, 801, desktopExe),                       // orphan behind a wrapper whose client died
            row(900, 1, "/x/codex.app/Contents/MacOS/codex app-server"),
            row(901, 900, "/old/MacControlMCP.app/Contents/MacOS/MacControlMCP"), // older build, connected
        ]
        let others = ToolRegistry.classifyInstances(rows: rows, excluding: 602, selfVersion: "0.10.1") { exe in
            exe.hasPrefix("/old/") ? "0.9.0" : "0.10.1"
        }
        let byPid = Dictionary(uniqueKeysWithValues: others.map { ($0.pid, $0) })
        #expect(Set(byPid.keys) == [502, 601, 700, 802, 901])
        #expect(byPid[502]?.status == .connected)
        #expect(byPid[502]?.client == "Claude Desktop")
        #expect(byPid[502]?.clientPid == 500)
        #expect(byPid[601]?.status == .connected)
        #expect(byPid[601]?.client == "Claude Code")
        #expect(byPid[700]?.status == .orphaned)
        #expect(byPid[802]?.status == .orphaned)
        #expect(byPid[802]?.wrapperPids == [801])
        #expect(byPid[901]?.status == .outdated)
        #expect(byPid[901]?.client == "Codex")

        let hint = ToolRegistry.otherInstancesHint(others, selfPid: 602, selfVersion: "0.10.1") ?? ""
        #expect(hint.contains("`kill 700 802 801`"))
        #expect(!hint.contains("502"))
        #expect(!hint.contains("601"))
        #expect(!hint.contains("901 "))
        #expect(hint.contains("Do NOT kill"))
        #expect(hint.contains("Codex"))
    }

    @Test("no kill command at all when every other instance is connected")
    func noKillWhenAllConnected() {
        let rows = [
            row(600, 1, "/x/claude.app/Contents/MacOS/claude"),
            row(601, 600, appsExe),
            row(602, 600, appsExe),
        ]
        let others = ToolRegistry.classifyInstances(rows: rows, excluding: 602, selfVersion: "0.10.1") { _ in "0.10.1" }
        let hint = ToolRegistry.otherInstancesHint(others, selfPid: 602, selfVersion: "0.10.1") ?? ""
        #expect(!hint.contains("`kill"))
        #expect(hint.contains("1 connected"))
    }

    @Test("bundle version is read from the .app's Info.plist")
    func readsBundleVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-ver-\(UUID().uuidString)")
        let macos = dir.appendingPathComponent("MacControlMCP.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist: [String: Any] = ["CFBundleShortVersionString": "9.8.7"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: dir.appendingPathComponent("MacControlMCP.app/Contents/Info.plist"))
        let exe = macos.appendingPathComponent("MacControlMCP").path
        #expect(ToolRegistry.bundleVersion(forExecutable: exe) == "9.8.7")
        #expect(ToolRegistry.bundleVersion(forExecutable: "/nonexistent/X.app/Contents/MacOS/X") == nil)
    }

    // MARK: - #2 output_path inside a private per-user dir under /tmp

    private func makeTmpDir(mode: mode_t) throws -> String {
        let path = "/tmp/mcp-pv-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        chmod(path, mode)
        return path
    }

    @Test("a 0700 directory we own under /tmp is accepted, nested paths too")
    func acceptsPrivateTmpDir() throws {
        let dir = try makeTmpDir(mode: 0o700)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let nested = dir + "/scratchpad/car"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let resolved = try PathValidator.validate(nested + "/img.jpg")
        #expect(resolved.hasSuffix("/scratchpad/car/img.jpg"))
        // Same dir spelled through /private/tmp.
        _ = try PathValidator.validate("/private" + dir + "/x.png")
    }

    @Test("a group/world-accessible /tmp dir, /tmp itself and traversal stay rejected")
    func rejectsSharedTmp() throws {
        let open = try makeTmpDir(mode: 0o755)
        defer { try? FileManager.default.removeItem(atPath: open) }
        #expect(throws: PathValidator.ValidationError.self) { try PathValidator.validate(open + "/x.png") }
        #expect(throws: PathValidator.ValidationError.self) { try PathValidator.validate("/tmp/x.png") }
        #expect(throws: PathValidator.ValidationError.self) { try PathValidator.validate("/private/tmp/x.png") }
        let priv = try makeTmpDir(mode: 0o700)
        defer { try? FileManager.default.removeItem(atPath: priv) }
        #expect(throws: PathValidator.ValidationError.self) { try PathValidator.validate(priv + "/../../etc/x.png") }
    }

    @Test("a symlink planted directly under /tmp does not count as a private dir")
    func rejectsSymlinkedTopDir() throws {
        let target = try makeTmpDir(mode: 0o700)
        defer { try? FileManager.default.removeItem(atPath: target) }
        let link = "/tmp/mcp-pv-link-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        defer { try? FileManager.default.removeItem(atPath: link) }
        #expect(PathValidator.isPrivateOwnedDirectory(link) == false)
        #expect(PathValidator.isPrivateOwnedDirectory(target) == true)
    }

    // MARK: - #3 wait_for_window accepts the arguments agents actually send

    private func parsed(_ args: [String: JSONValue]) -> ToolRegistry.WindowWaitRequest? {
        if case .success(let r) = ToolRegistry.parseWindowWait(args) { return r }
        return nil
    }

    @Test("wait_for_window: app/name/bundle_id targets and title/timeout_ms aliases")
    func windowWaitAliases() {
        let byApp = parsed(["app": .string("Bambu Studio"), "timeout_ms": .number(15000), "title": .string("Export")])
        #expect(byApp?.pid == nil)
        #expect(byApp?.appName == "Bambu Studio")
        #expect(byApp?.timeout == 15)
        #expect(byApp?.titleContains == "export")

        let byPid = parsed(["pid": .number(123), "timeout_seconds": .number(30), "title_contains": .string("Save")])
        #expect(byPid?.pid == 123)
        #expect(byPid?.timeout == 30)
        #expect(byPid?.titleContains == "save")

        // timeout_seconds wins over an alias; legacy `timeout` is seconds.
        #expect(parsed(["pid": .number(1), "timeout_seconds": .number(2), "timeout_ms": .number(9000)])?.timeout == 2)
        #expect(parsed(["name": .string("Finder"), "timeout": .number(7)])?.timeout == 7)
        #expect(parsed(["bundle_id": .string("com.apple.finder")])?.timeout == 5)
        // clamped to the server's max wait
        #expect(parsed(["pid": .number(1), "timeout_seconds": .number(600)])?.timeout == 60)
    }

    @Test("wait_for_window: a missing target or bad pid gives an actionable error")
    func windowWaitErrors() {
        guard case .failure(let e) = ToolRegistry.parseWindowWait(["title": .string("x")]) else {
            Issue.record("expected failure"); return
        }
        #expect(e.message.contains("bundle_id"))
        #expect(e.message.contains("app"))
        guard case .failure = ToolRegistry.parseWindowWait(["pid": .string("abc")]) else {
            Issue.record("expected failure for bad pid"); return
        }
    }

    @Test("wait_for_window by bundle_id of an app that never starts reports app_running=false")
    func windowWaitForMissingApp() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(
            name: "wait_for_window",
            arguments: ["bundle_id": .string("com.example.never-installed-\(UUID().uuidString)"), "timeout_ms": .number(300)]
        )
        #expect(result.isError == true)
        guard case .object(let payload) = result.structuredContent else { Issue.record("no payload"); return }
        #expect(payload["timed_out"] == .bool(true))
        #expect(payload["app_running"] == .bool(false))
        #expect(payload["timeout_seconds"] == .number(0.3))
    }

    // MARK: - #4 activate_app resolves names and reports not-running honestly

    private func app(_ pid: pid_t, _ name: String?, _ bundle: String?, path: String? = nil, regular: Bool = true) -> AppLifecycleController.AppSnapshot {
        AppLifecycleController.AppSnapshot(pid: pid, name: name, bundleIdentifier: bundle, bundlePath: path, isRegular: regular)
    }

    @Test("pickRunningApp: pid, bundle id (regular app preferred) and case-insensitive name")
    func picksRunningApp() {
        let apps = [
            app(10, "Bambu Studio Helper", "com.bambulab.bambu-studio", regular: false),
            app(11, "Bambu Studio", "com.bambulab.bambu-studio", path: "/Applications/BambuStudio.app"),
            app(12, "Finder", "com.apple.finder", path: "/System/Library/CoreServices/Finder.app"),
        ]
        typealias C = AppLifecycleController
        #expect(C.pickRunningApp(apps, pid: 12, bundleIdentifier: nil, name: nil)?.pid == 12)
        #expect(C.pickRunningApp(apps, pid: 99, bundleIdentifier: nil, name: "Finder") == nil)
        #expect(C.pickRunningApp(apps, pid: nil, bundleIdentifier: "com.bambulab.bambu-studio", name: nil)?.pid == 11)
        #expect(C.pickRunningApp(apps, pid: nil, bundleIdentifier: nil, name: "bambu studio")?.pid == 11)
        #expect(C.pickRunningApp(apps, pid: nil, bundleIdentifier: nil, name: "BambuStudio.app")?.pid == 11)
        #expect(C.pickRunningApp(apps, pid: nil, bundleIdentifier: "com.snapmaker.orca", name: nil) == nil)
    }

    @Test("activate_app for an app that is not running says so and points to launch_app")
    func activateNotRunning() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: "activate_app", arguments: ["bundle_id": .string("com.example.not-running-\(UUID().uuidString)")])
        #expect(result.isError == true)
        guard case .object(let payload) = result.structuredContent else { Issue.record("no payload"); return }
        #expect(payload["error_code"] == .string("not_running"))
        #expect(payload["hint"]?.stringValue?.contains("launch_app") == true)
    }

    @Test("activate_app accepts name/app and rejects an empty request")
    func activateArguments() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let empty = await registry.callTool(name: "activate_app", arguments: [:])
        #expect(empty.isError == true)
        let byName = await registry.callTool(name: "activate_app", arguments: ["app": .string("No Such App \(UUID().uuidString)")])
        guard case .object(let payload) = byName.structuredContent else { Issue.record("no payload"); return }
        #expect(payload["error_code"] == .string("not_running"))
    }
}

private extension ToolRegistry.PsRow {
    func withStart(_ start: String) -> ToolRegistry.PsRow {
        ToolRegistry.PsRow(pid: pid, ppid: ppid, start: start, command: command)
    }
}
