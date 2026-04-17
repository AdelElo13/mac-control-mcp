import Testing
import Foundation
@testable import MacControlMCP

/// End-to-end compat matrix run against the ControlZoo AppKit harness.
///
/// ControlZoo is a minimal NSWindow with one of every AppKit control type,
/// each tagged with a stable `accessibilityIdentifier`. This test suite
/// builds the harness, launches it, then drives every control through
/// read / write / action via the mac-control-mcp binary over stdio.
///
/// A failure here means the MCP has a real bug against a known-good
/// AppKit control — not a Space/navigation edge case, not a third-party
/// app quirk. This is the deterministic baseline Codex review v7 asked
/// for.
@Suite("ControlZoo — deterministic AppKit compat matrix", .serialized, .timeLimit(.minutes(3)))
struct ControlZooMatrixTests {
    static let harnessIdentifier = "ControlZoo"

    static func projectRoot() -> URL {
        let dir = (#filePath as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: dir).deletingLastPathComponent().deletingLastPathComponent()
    }

    static func serverBinary() -> String {
        projectRoot().appendingPathComponent(".build/debug/mac-control-mcp").path
    }

    static func harnessBinary() -> String {
        projectRoot().appendingPathComponent("TestHarness/ControlZoo/.build/debug/ControlZoo").path
    }

    /// Launches ControlZoo if not already running, then returns its PID.
    /// Returns nil + logs if the harness wasn't built.
    static func launchHarness() async throws -> Int32? {
        let binary = harnessBinary()
        guard FileManager.default.fileExists(atPath: binary) else {
            Issue.record("Harness binary missing at \(binary). Build it with:\n  cd TestHarness/ControlZoo && swift build --disable-sandbox")
            return nil
        }

        if let existing = runningHarnessPID() { return existing }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()

        // Wait up to 5 s for the AppKit window to come up.
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let pid = runningHarnessPID() { return pid }
        }
        Issue.record("ControlZoo launched but did not register as a running app in 5 s")
        return nil
    }

    /// Query NSWorkspace via the MCP list_apps tool — lets the test
    /// target the same PID discovery mechanism the MCP uses at runtime.
    static func runningHarnessPID() -> Int32? {
        guard let driver = MCPDriver.start() else { return nil }
        defer { driver.close() }
        _ = driver.request(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        guard let apps = driver.toolResult(name: "list_apps", arguments: "{}"),
              case .object(let payload) = apps,
              case .array(let list) = payload["apps"] ?? .null else { return nil }

        for entry in list {
            guard case .object(let obj) = entry,
                  case .string(let name) = obj["name"] ?? .null,
                  name == harnessIdentifier,
                  case .number(let pid) = obj["pid"] ?? .null else { continue }
            return Int32(pid)
        }
        return nil
    }

    /// Resolve the ControlZoo element identifiers → element IDs the MCP
    /// handed out, so subsequent probes can reference them.
    static func identifierMap(driver: MCPDriver, pid: Int32) -> [String: String] {
        guard let tree = driver.toolResult(
            name: "get_ui_tree",
            arguments: #"{"pid":\#(pid),"max_depth":12}"#
        ),
            case .object(let root) = tree,
            case .array(let nodes) = root["nodes"] ?? .null
        else { return [:] }

        var map: [String: String] = [:]
        for node in nodes {
            guard case .object(let nodeObj) = node,
                  case .string(let elementID) = nodeObj["id"] ?? .null else { continue }
            let attrs = driver.toolResult(
                name: "get_element_attributes",
                arguments: #"{"element_id":"\#(elementID)","names":["AXIdentifier"]}"#
            )
            guard case .object(let payload) = attrs,
                  case .object(let values) = payload["values"] ?? .null,
                  case .string(let ident) = values["AXIdentifier"] ?? .null
            else { continue }
            map[ident] = elementID
        }
        return map
    }

    // MARK: - The test

    @Test("every AppKit control type in ControlZoo passes")
    func compatMatrix() async throws {
        guard let pid = try await Self.launchHarness() else { return }

        guard let driver = MCPDriver.start() else {
            Issue.record("failed to launch mac-control-mcp binary at \(Self.serverBinary())")
            return
        }
        defer { driver.close() }
        _ = driver.request(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        _ = driver.toolResult(name: "activate_app", arguments: #"{"pid":\#(pid)}"#)
        try? await Task.sleep(nanoseconds: 500_000_000)

        let idMap = Self.identifierMap(driver: driver, pid: pid)
        #expect(idMap.count >= 11, "expected 11 identified controls, got \(idMap.count): \(idMap.keys.sorted())")

        // tf_single: read → write → read back → restore
        try runTextRoundtrip(driver: driver, elementID: idMap["tf_single"], label: "AXTextField")

        // ta_multi: same shape on NSTextView
        try runTextRoundtrip(driver: driver, elementID: idMap["ta_multi"], label: "AXTextArea")

        // cb_one: AXPress toggles AXValue between 0 and 1
        try await runToggleViaPress(driver: driver, elementID: idMap["cb_one"], label: "AXCheckBox")

        // sw_one: same shape
        try await runToggleViaPress(driver: driver, elementID: idMap["sw_one"], label: "AXSwitch")

        // sl_one: numeric AXValue set to a specific value
        try runNumericWrite(driver: driver, elementID: idMap["sl_one"], target: 73.5, label: "AXSlider")

        // li_meter: same
        try runNumericWrite(driver: driver, elementID: idMap["li_meter"], target: 0.35, label: "AXLevelIndicator")

        // st_one: AXIncrement action
        try await runStepperIncrement(driver: driver, elementID: idMap["st_one"], label: "AXStepper")

        // btn_click: AXPress action returns ax_status == 0
        try runButtonPress(driver: driver, elementID: idMap["btn_click"], label: "AXButton")
    }

    // MARK: - Per-control probes

    func runTextRoundtrip(driver: MCPDriver, elementID: String?, label: String) throws {
        guard let elementID else { Issue.record("\(label): missing element id"); return }
        let marker = "mcp_zoo_\(UUID().uuidString.prefix(8))"
        let before = driver.readValue(elementID: elementID) ?? ""
        driver.setValueString(elementID: elementID, value: marker)
        let after = driver.readValue(elementID: elementID)
        #expect(after == marker, "\(label) write failed: wanted \(marker) got \(after ?? "nil")")
        driver.setValueString(elementID: elementID, value: before) // restore
    }

    func runToggleViaPress(driver: MCPDriver, elementID: String?, label: String) async throws {
        guard let elementID else { Issue.record("\(label): missing element id"); return }
        let before = driver.readValue(elementID: elementID) ?? ""
        _ = driver.performAction(elementID: elementID, action: "AXPress")
        try? await Task.sleep(nanoseconds: 150_000_000)
        let after = driver.readValue(elementID: elementID)
        #expect(after != before, "\(label) AXPress did not flip AXValue (\(before))")
        _ = driver.performAction(elementID: elementID, action: "AXPress") // restore
    }

    func runNumericWrite(driver: MCPDriver, elementID: String?, target: Double, label: String) throws {
        guard let elementID else { Issue.record("\(label): missing element id"); return }
        let before = Double(driver.readValue(elementID: elementID) ?? "") ?? 0
        driver.setValueNumber(elementID: elementID, value: target)
        let after = Double(driver.readValue(elementID: elementID) ?? "") ?? .nan
        #expect(abs(after - target) < 0.01, "\(label) numeric write failed: wanted \(target) got \(after)")
        driver.setValueNumber(elementID: elementID, value: before) // restore
    }

    func runStepperIncrement(driver: MCPDriver, elementID: String?, label: String) async throws {
        guard let elementID else { Issue.record("\(label): missing element id"); return }
        let before = Double(driver.readValue(elementID: elementID) ?? "") ?? 0
        _ = driver.performAction(elementID: elementID, action: "AXIncrement")
        try? await Task.sleep(nanoseconds: 150_000_000)
        let after = Double(driver.readValue(elementID: elementID) ?? "") ?? before
        #expect(after > before, "\(label) AXIncrement did not raise AXValue (\(before) → \(after))")
        _ = driver.performAction(elementID: elementID, action: "AXDecrement")
    }

    func runButtonPress(driver: MCPDriver, elementID: String?, label: String) throws {
        guard let elementID else { Issue.record("\(label): missing element id"); return }
        let response = driver.performAction(elementID: elementID, action: "AXPress")
        guard case .object(let payload) = response,
              case .number(let status) = payload["ax_status"] ?? .null else {
            Issue.record("\(label) AXPress returned unexpected shape: \(response)")
            return
        }
        #expect(Int(status) == 0, "\(label) AXPress ax_status != 0 (got \(status))")
    }
}

// MARK: - Minimal MCP driver over stdio

final class MCPDriver {
    private let process: Process
    private let inputPipe: Pipe
    private let outputPipe: Pipe
    private var buffer = Data()
    private var nextID: Int = 1

    init(process: Process, inputPipe: Pipe, outputPipe: Pipe) {
        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
    }

    static func start() -> MCPDriver? {
        let path = ControlZooMatrixTests.serverBinary()
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe
        do { try p.run() } catch { return nil }
        // Non-blocking stdout so we can time-bound reads
        let fd = stdoutPipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return MCPDriver(process: p, inputPipe: stdinPipe, outputPipe: stdoutPipe)
    }

    func close() {
        try? inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    func request(_ body: String) -> JSONValue? {
        let framed = "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        inputPipe.fileHandleForWriting.write(Data(framed.utf8))
        return readNextFrame(timeout: 5)
    }

    func toolResult(name: String, arguments: String) -> JSONValue? {
        let body = #"{"jsonrpc":"2.0","id":\#(nextID),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
        nextID += 1
        guard let envelope = request(body),
              case .object(let wrapper) = envelope,
              case .object(let result) = wrapper["result"] ?? .null else { return nil }
        return result["structuredContent"]
    }

    func readValue(elementID: String) -> String? {
        guard let response = toolResult(
            name: "get_element_attributes",
            arguments: #"{"element_id":"\#(elementID)","names":["AXValue"]}"#
        ),
              case .object(let payload) = response,
              case .object(let values) = payload["values"] ?? .null,
              case .string(let value) = values["AXValue"] ?? .null else { return nil }
        return value
    }

    func setValueString(elementID: String, value: String) {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        _ = toolResult(
            name: "set_element_attribute",
            arguments: #"{"element_id":"\#(elementID)","name":"AXValue","value":"\#(escaped)"}"#
        )
    }

    func setValueNumber(elementID: String, value: Double) {
        _ = toolResult(
            name: "set_element_attribute",
            arguments: #"{"element_id":"\#(elementID)","name":"AXValue","value":\#(value)}"#
        )
    }

    @discardableResult
    func performAction(elementID: String, action: String) -> JSONValue {
        toolResult(
            name: "perform_element_action",
            arguments: #"{"element_id":"\#(elementID)","action":"\#(action)"}"#
        ) ?? .null
    }

    private func readNextFrame(timeout: TimeInterval) -> JSONValue? {
        let deadline = Date().addingTimeInterval(timeout)
        let fd = outputPipe.fileHandleForReading.fileDescriptor

        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = chunk.withUnsafeMutableBufferPointer { bp in Darwin.read(fd, bp.baseAddress, bp.count) }
            if n > 0 { buffer.append(Data(chunk.prefix(n))) }

            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                guard let header = String(data: headerData, encoding: .utf8) else { return nil }
                let lenLine = header.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                guard let lenLine,
                      let len = Int(lenLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
                else { return nil }

                let bodyStart = range.upperBound
                if buffer.count >= bodyStart + len {
                    let body = buffer.subdata(in: bodyStart..<(bodyStart + len))
                    buffer.removeSubrange(0..<(bodyStart + len))
                    return try? JSONDecoder().decode(JSONValue.self, from: body)
                }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return nil
    }
}
