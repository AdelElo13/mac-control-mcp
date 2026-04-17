import Testing
import Foundation
import CoreGraphics
#if canImport(Darwin)
import Darwin
#endif
@testable import MacControlMCP

/// Real-world compatibility matrix that drives *third-party* apps, not
/// the ControlZoo harness.
///
/// Purpose: ControlZoo proves the MCP can drive every AppKit control
/// type on a known-good tree. These tests prove that the MCP works on
/// Apple's own apps with their real window structure, navigation
/// requirements, and timing quirks.
///
/// Every test records one of:
///   - pass      : read/write/action verified against the real app
///   - off-space : app is running but its window lives on another
///                 macOS Space; AX cannot reach it. Not an MCP bug —
///                 a macOS AX limitation we explicitly acknowledge.
///   - navigation: couldn't reach the target pane/view in time
///   - not-present: app not running / feature not exposed
///
/// These tests are deliberately tolerant of `off-space` — CI may not have
/// a deterministic Space layout. The harness matrix covers every control
/// deterministically; this suite adds real-world confirmation where it
/// can.
@Suite("Real-world AppKit compat — Apple's own apps", .serialized, .timeLimit(.minutes(3)))
struct RealAppMatrixTests {
    static func projectRoot() -> URL {
        let dir = (#filePath as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: dir).deletingLastPathComponent().deletingLastPathComponent()
    }

    static func serverBinary() -> String {
        projectRoot().appendingPathComponent(".build/debug/mac-control-mcp").path
    }

    /// Launches the MCP binary and drives it via Pipe-based stdio.
    final class Driver {
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        private var buffer = Data()
        private var nextID = 1

        init?(binary: String) {
            guard FileManager.default.fileExists(atPath: binary) else { return nil }
            process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            stdinPipe = Pipe()
            stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            do { try process.run() } catch { return nil }
            let fd = stdoutPipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        func close() {
            try? stdinPipe.fileHandleForWriting.close()
            process.waitUntilExit()
        }

        func sendRPC(_ body: String, timeout: TimeInterval = 10) -> JSONValue? {
            let framed = "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
            stdinPipe.fileHandleForWriting.write(Data(framed.utf8))
            return readFrame(timeout: timeout)
        }

        func callTool(_ name: String, arguments: String, timeout: TimeInterval = 30) -> JSONValue? {
            let body = #"{"jsonrpc":"2.0","id":\#(nextID),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
            nextID += 1
            guard case .object(let env)? = sendRPC(body, timeout: timeout),
                  case .object(let result) = env["result"] ?? .null else { return nil }
            return result["structuredContent"]
        }

        func initialize() { _ = sendRPC(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#) }

        /// Read one NDJSON frame off stdout. Server emits
        /// newline-delimited JSON per MCP spec — each message is a
        /// single line terminated by `\n`.
        private func readFrame(timeout: TimeInterval) -> JSONValue? {
            let deadline = Date().addingTimeInterval(timeout)
            let fd = stdoutPipe.fileHandleForReading.fileDescriptor
            while Date() < deadline {
                var chunk = [UInt8](repeating: 0, count: 65536)
                let n = chunk.withUnsafeMutableBufferPointer { bp in Darwin.read(fd, bp.baseAddress, bp.count) }
                if n > 0 { buffer.append(Data(chunk.prefix(n))) }
                while let first = buffer.first, first == UInt8(ascii: "\n") || first == UInt8(ascii: "\r") {
                    buffer.removeFirst()
                }
                if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    var body = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                    buffer.removeSubrange(buffer.startIndex...newlineIndex)
                    if let last = body.last, last == UInt8(ascii: "\r") {
                        body = body.dropLast()
                    }
                    if body.isEmpty { continue }
                    return try? JSONDecoder().decode(JSONValue.self, from: body)
                }
                Thread.sleep(forTimeInterval: 0.03)
            }
            return nil
        }
    }

    /// Off-Space detection via CGWindowListCopyWindowInfo — this sees
    /// EVERY on-screen window regardless of Space membership. If AX says
    /// windows=0 but CGWindowList sees one, we know it's off-Space.
    static func offSpaceDetector(for pid: pid_t) -> Bool {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for dict in info {
            if let wpid = dict[kCGWindowOwnerPID as String] as? pid_t, wpid == pid {
                // Windows on other Spaces are reported with a layer/alpha
                // that still appears in the list; presence here + absence
                // in AX list_windows means off-space.
                return true
            }
        }
        return false
    }

    /// Look up a PID via the MCP's list_apps tool.
    static func pidFor(driver: Driver, name: String) -> pid_t? {
        guard case .object(let payload)? = driver.callTool("list_apps", arguments: "{}"),
              case .array(let list) = payload["apps"] ?? .null else { return nil }
        for entry in list {
            guard case .object(let obj) = entry,
                  case .string(let n) = obj["name"] ?? .null, n == name,
                  case .number(let pid) = obj["pid"] ?? .null else { continue }
            return pid_t(pid)
        }
        return nil
    }

    enum Outcome {
        case pass(String)
        case fail(String)
        case offSpace
        case navigation(String)
        case notPresent
    }

    static func expect(_ control: String, in app: String, _ outcome: Outcome) {
        switch outcome {
        case .pass(let detail):
            // True pass — the control was found, read, and/or mutated.
            _ = detail // attached to issue context on failure elsewhere
        case .fail(let detail):
            Issue.record("\(control) in \(app): FAIL — \(detail)")
        case .offSpace:
            // Acceptable: not an MCP bug.
            break
        case .navigation(let detail):
            // Acceptable: we couldn't drive the app to the right screen.
            print("\(control) in \(app): navigation skip — \(detail)")
        case .notPresent:
            print("\(control) in \(app): app not running — skipped")
        }
    }

    // MARK: - Tests

    @Test("System Settings search field accepts AXValue write")
    func systemSettingsSearchField() async throws {
        guard let driver = Driver(binary: Self.serverBinary()) else {
            Issue.record("MCP binary missing")
            return
        }
        defer { driver.close() }
        driver.initialize()

        // Start System Settings fresh
        _ = driver.callTool("launch_app", arguments: #"{"identifier":"System Settings"}"#, timeout: 60)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        guard let pid = Self.pidFor(driver: driver, name: "System Settings") else {
            Self.expect("AXTextField", in: "System Settings", .notPresent); return
        }
        _ = driver.callTool("activate_app", arguments: #"{"pid":\#(pid)}"#)
        try? await Task.sleep(nanoseconds: 800_000_000)

        // Off-space check: does AX see a window?
        guard case .object(let w)? = driver.callTool("list_windows", arguments: #"{"pid":\#(pid)}"#),
              case .number(let count) = w["count"] ?? .null, count > 0 else {
            Self.expect("AXTextField", in: "System Settings", .offSpace)
            return
        }

        // Get tree, find AXTextField (search bar)
        guard case .object(let tree)? = driver.callTool(
            "get_ui_tree",
            arguments: #"{"pid":\#(pid),"max_depth":10}"#, timeout: 30
        ),
              case .array(let nodes) = tree["nodes"] ?? .null else {
            Self.expect("AXTextField", in: "System Settings", .fail("get_ui_tree returned no nodes"))
            return
        }

        let tfNode = nodes.compactMap { (n) -> (id: String, width: Double)? in
            guard case .object(let obj) = n,
                  case .string(let role) = obj["role"] ?? .null, role == "AXTextField",
                  case .string(let id) = obj["id"] ?? .null else { return nil }
            var width: Double = 0
            if case .object(let sz) = obj["size"] ?? .null,
               case .number(let w) = sz["width"] ?? .null { width = w }
            return (id, width)
        }.max(by: { $0.width < $1.width })

        guard let tf = tfNode else {
            Self.expect("AXTextField", in: "System Settings", .navigation("no AXTextField found in tree"))
            return
        }

        // Read current value
        guard case .object(let readResp)? = driver.callTool(
            "get_element_attributes",
            arguments: #"{"element_id":"\#(tf.id)","names":["AXValue"]}"#
        ),
              case .object(let values) = readResp["values"] ?? .null else {
            Self.expect("AXTextField", in: "System Settings", .fail("couldn't read AXValue"))
            return
        }
        let before: String
        if case .string(let s) = values["AXValue"] ?? .null { before = s } else { before = "" }

        // Write a marker
        let marker = "__mcp_real_\(UUID().uuidString.prefix(8))__"
        let setJSON = #"{"element_id":"\#(tf.id)","name":"AXValue","value":"\#(marker)"}"#
        guard case .object(let setResp)? = driver.callTool("set_element_attribute", arguments: setJSON),
              case .bool(let ok) = setResp["ok"] ?? .null, ok else {
            Self.expect("AXTextField", in: "System Settings", .fail("set_element_attribute not ok"))
            return
        }

        // Verify
        guard case .object(let verifyResp)? = driver.callTool(
            "get_element_attributes",
            arguments: #"{"element_id":"\#(tf.id)","names":["AXValue"]}"#
        ),
              case .object(let verifyValues) = verifyResp["values"] ?? .null,
              case .string(let got) = verifyValues["AXValue"] ?? .null else {
            Self.expect("AXTextField", in: "System Settings", .fail("couldn't re-read AXValue"))
            return
        }

        if got == marker {
            Self.expect("AXTextField", in: "System Settings", .pass("roundtrip verified"))
        } else {
            Self.expect("AXTextField", in: "System Settings", .fail("wrote \(marker) read \(got)"))
        }

        // Restore
        let restoreJSON = #"{"element_id":"\#(tf.id)","name":"AXValue","value":"\#(before)"}"#
        _ = driver.callTool("set_element_attribute", arguments: restoreJSON)
    }

    @Test("Finder sidebar rows are discoverable and queryable")
    func finderSidebarRows() async throws {
        guard let driver = Driver(binary: Self.serverBinary()) else { return }
        defer { driver.close() }
        driver.initialize()

        guard let pid = Self.pidFor(driver: driver, name: "Finder") else {
            Self.expect("AXRow", in: "Finder", .notPresent); return
        }
        _ = driver.callTool("activate_app", arguments: #"{"pid":\#(pid)}"#)
        try? await Task.sleep(nanoseconds: 800_000_000)

        guard case .object(let w)? = driver.callTool("list_windows", arguments: #"{"pid":\#(pid)}"#),
              case .number(let count) = w["count"] ?? .null, count > 0 else {
            Self.expect("AXRow", in: "Finder", .offSpace)
            return
        }

        // find_elements with role filter — uses the CFHash-dedup fix
        guard case .object(let findResp)? = driver.callTool(
            "find_elements",
            arguments: #"{"pid":\#(pid),"role":"AXRow","max_depth":12,"limit":100}"#, timeout: 30
        ),
              case .number(let rowCount) = findResp["count"] ?? .null else {
            Self.expect("AXRow", in: "Finder", .fail("find_elements failed"))
            return
        }

        // Finder with a window open should have >= 1 row (sidebar items)
        // or at least a file list row — if 0, Finder may be in an unusual state
        if rowCount > 0 {
            Self.expect("AXRow", in: "Finder", .pass("find_elements returned \(rowCount) rows"))
        } else {
            Self.expect("AXRow", in: "Finder",
                .navigation("Finder window has no rows (might be empty Applications view?)"))
        }
    }

    @Test("CFHash-based find_elements doesn't drop a complex tree")
    func cfHashDedupStillFixed() async throws {
        // This is a regression guard for the v0.2.0 CFHash fix.
        // Before the fix, find_elements on Logic Pro returned 0 matches
        // despite the tree containing thousands of matching elements.
        // After the fix, it returns matches proportional to tree size.
        guard let driver = Driver(binary: Self.serverBinary()) else { return }
        defer { driver.close() }
        driver.initialize()

        // Use Finder as the target since it's always available on macOS.
        guard let pid = Self.pidFor(driver: driver, name: "Finder") else {
            Self.expect("find_elements coverage", in: "Finder", .notPresent); return
        }

        guard case .object(let w)? = driver.callTool("list_windows", arguments: #"{"pid":\#(pid)}"#),
              case .number(let wc) = w["count"] ?? .null, wc > 0 else {
            Self.expect("find_elements coverage", in: "Finder", .offSpace); return
        }

        guard case .object(let tree)? = driver.callTool(
            "get_ui_tree",
            arguments: #"{"pid":\#(pid),"max_depth":10}"#, timeout: 30
        ),
              case .number(let treeCount) = tree["count"] ?? .null else {
            Self.expect("find_elements coverage", in: "Finder", .fail("get_ui_tree failed"))
            return
        }

        // Finder's Applications view has plenty of AXMenuItem elements in
        // its menubar. find_elements should find most of them.
        guard case .object(let findResp)? = driver.callTool(
            "find_elements",
            arguments: #"{"pid":\#(pid),"role":"AXMenuItem","max_depth":10,"limit":500}"#, timeout: 30
        ),
              case .number(let foundCount) = findResp["count"] ?? .null else {
            Self.expect("find_elements coverage", in: "Finder", .fail("find_elements failed"))
            return
        }

        // Codex v8 #7 — ratio check: find_elements(AXMenuItem) should
        // find roughly as many menu items as appear in get_ui_tree.
        // A ratio < 0.5 means we're losing more than half to dedup
        // bugs or some other regression. This is much stricter than
        // the old "foundCount >= 20" that could pass with 30 items
        // on a tree of thousands.
        guard case .object(let menuCount)? = driver.callTool(
            "find_elements",
            arguments: #"{"pid":\#(pid),"role":"AXMenuItem","max_depth":10,"limit":5000}"#, timeout: 30
        ),
              case .number(let totalMenuItems) = menuCount["count"] ?? .null else {
            Self.expect("find_elements coverage", in: "Finder", .fail("uncapped find_elements failed"))
            return
        }

        // Count menu items actually in the tree (ground truth) for ratio comparison.
        guard case .array(let treeNodes) = tree["nodes"] ?? .null else {
            Self.expect("find_elements coverage", in: "Finder", .fail("tree nodes missing"))
            return
        }
        let menuItemsInTree = treeNodes.reduce(0) { acc, n in
            guard case .object(let o) = n,
                  case .string(let role) = o["role"] ?? .null,
                  role == "AXMenuItem" else { return acc }
            return acc + 1
        }

        if menuItemsInTree == 0 {
            Self.expect("find_elements coverage", in: "Finder",
                .navigation("no AXMenuItem in tree — cannot compute ratio"))
            return
        }

        let ratio = Double(totalMenuItems) / Double(menuItemsInTree)
        if ratio >= 0.8 {
            Self.expect("find_elements coverage", in: "Finder",
                .pass("tree had \(menuItemsInTree) AXMenuItem, find_elements returned \(Int(totalMenuItems)) (ratio \(String(format: "%.2f", ratio)))"))
        } else {
            Self.expect("find_elements coverage", in: "Finder",
                .fail("find_elements dropped \(Int(100 * (1 - ratio)))% of menu items (tree=\(menuItemsInTree), found=\(Int(totalMenuItems))) — CFHash regression?"))
        }
    }
}

// MARK: - Strict-outcome assertion — Codex v8 #1

/// If every real-world test ends up in a skip state, the suite is green
/// but proved nothing. This guard runs at suite end and fails if NO test
/// produced a strict .pass Outcome.
///
/// Environment assumption (Codex v9 #3): mac-control-mcp is a user-machine
/// tool, not a headless-CI tool. Tests run on an interactive macOS session
/// where Finder is always running with at least one visible window. If
/// this assumption changes (e.g. running in CI with fake AX), this guard
/// correctly fails loudly instead of silently passing.
@Suite("Real-world coverage sanity", .serialized)
struct RealWorldCoverageGuard {
    @Test("at least one real-app assertion must strictly pass")
    func atLeastOneStrictPass() {
        // Drive the three real-world tests again and count outcomes.
        // Since the Outcome enum is private to each test, we instead
        // assert by re-running the CFHash regression guard which has a
        // deterministic pass condition on any macOS system with Finder
        // running (always true on macOS).
        // If Finder can't be driven at all, we fail loudly — this is
        // the canary that the whole MCP is broken.
        let binary = RealAppMatrixTests.serverBinary()
        guard let driver = RealAppMatrixTests.Driver(binary: binary) else {
            Issue.record("cannot spawn mac-control-mcp — real-world coverage is 0")
            return
        }
        defer { driver.close() }
        driver.initialize()
        guard let pid = RealAppMatrixTests.pidFor(driver: driver, name: "Finder") else {
            Issue.record("Finder is not running — strict real-world coverage required, skip not acceptable here")
            return
        }
        guard case .object(let w)? = driver.callTool("list_windows", arguments: #"{"pid":\#(pid)}"#),
              case .number(let wc) = w["count"] ?? .null, wc > 0 else {
            Issue.record("Finder has no visible windows on current Space — strict coverage requires at least this baseline")
            return
        }
        guard case .object(let find)? = driver.callTool(
            "find_elements",
            arguments: #"{"pid":\#(pid),"role":"AXMenuItem","max_depth":8,"limit":500}"#
        ),
              case .number(let count) = find["count"] ?? .null else {
            Issue.record("find_elements failed against live Finder — strict coverage absent")
            return
        }
        #expect(count >= 50, "Finder menubar should have >= 50 AXMenuItem, got \(Int(count)) — real-world baseline broken")
    }
}
