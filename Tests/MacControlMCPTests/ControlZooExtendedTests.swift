import Testing
import Foundation
@testable import MacControlMCP

/// Second ControlZoo column: the AppKit controls the first matrix did not
/// cover. Every check asserts on an observable status label that the
/// harness updates from the control's own target/action or delegate, so a
/// pass proves the APP saw the change — not only that an AX call returned 0.
///
/// Lives in an extension of ControlZooMatrixTests so it shares that suite's
/// `.serialized` trait: two suites driving the same harness window in
/// parallel would steal focus from each other.
extension ControlZooMatrixTests {
    static let extendedIdentifiers = [
        "rb_a", "rb_b", "rb_c", "rb_label", "seg_one", "seg_one_label",
        "combo_one", "combo_one_label", "sf_one", "sf_one_label",
        "dp_one", "dp_one_label", "cw_one", "cw_close_panel",
        "disc_one", "disc_one_label", "prog_one", "tab_one", "tab_one_label",
        "table_one", "table_one_label",
    ]

    @Test(
        "every extended AppKit control in ControlZoo passes",
        .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                 "ControlZoo spawns a GUI AppKit app, which can't run on a headless CI runner. Skipped when CI=true.")
    )
    func extendedMatrix() async throws {
        guard let pid = try await Self.launchHarness() else { return }
        guard let driver = MCPDriver.start() else {
            Issue.record("failed to launch mac-control-mcp binary at \(Self.serverBinary())")
            return
        }
        defer { driver.close() }
        _ = driver.request(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        _ = driver.toolResult(name: "activate_app", arguments: #"{"pid":\#(pid)}"#)
        try? await Task.sleep(nanoseconds: 500_000_000)

        let ids = Self.identifierMap(driver: driver, pid: pid)
        let missing = Self.extendedIdentifiers.filter { ids[$0] == nil }
        #expect(missing.isEmpty, "extended controls missing from the AX tree: \(missing)")
        guard missing.isEmpty else { return }

        try await runRadioGroup(driver: driver, ids: ids)
        try await runSegmented(driver: driver, pid: pid, ids: ids)
        try await runComboBox(driver: driver, pid: pid)
        try await runSearchFieldTyping(driver: driver, pid: pid, ids: ids)
        try await runDatePicker(driver: driver, ids: ids)
        try await runColorWell(driver: driver, pid: pid, ids: ids)
        try await runDisclosure(driver: driver, ids: ids)
        runProgressIndicator(driver: driver, ids: ids)
        try await runTabView(driver: driver, pid: pid, ids: ids)
        try await runTable(driver: driver, pid: pid, ids: ids)
    }

    // MARK: - Probes

    /// AXRadioButton: AXPress selects one option and deselects the others.
    func runRadioGroup(driver: MCPDriver, ids: [String: String]) async throws {
        let a = ids["rb_a"]!, b = ids["rb_b"]!, c = ids["rb_c"]!
        _ = driver.performAction(elementID: a, action: "AXPress")          // known start
        try? await Task.sleep(nanoseconds: 150_000_000)
        _ = driver.performAction(elementID: b, action: "AXPress")
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(driver.readValue(elementID: b) == "1", "AXRadioButton: pressed option not selected")
        #expect(driver.readValue(elementID: a) == "0", "AXRadioButton: previous option still selected")
        #expect(driver.readValue(elementID: c) == "0", "AXRadioButton: unrelated option selected")
        #expect(driver.readValue(elementID: ids["rb_label"]!) == "selected_rb_b",
                "AXRadioButton: app did not see the selection")
        _ = driver.performAction(elementID: a, action: "AXPress")          // restore
    }

    /// Segmented control (AXRadioGroup of AXRadioButton/AXSegment): press a segment.
    func runSegmented(driver: MCPDriver, pid: pid_t, ids: [String: String]) async throws {
        let segments = Self.descendants(driver: driver, pid: pid, role: "AXRadioButton", subrole: "AXSegment")
        guard let week = segments["Week"], let day = segments["Day"] else {
            Issue.record("Segmented: segments not found (got \(segments.keys.sorted()))"); return
        }
        _ = driver.performAction(elementID: week, action: "AXPress")
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(driver.readValue(elementID: week) == "1", "Segmented: pressed segment not selected")
        #expect(driver.readValue(elementID: ids["seg_one_label"]!) == "segment_1",
                "Segmented: app did not see the change")
        _ = driver.performAction(elementID: day, action: "AXPress")        // restore
    }

    /// AXComboBox: AXValue write is read back (verified) by set_element_attribute.
    func runComboBox(driver: MCPDriver, pid: pid_t) async throws {
        // AppKit gives the combo's drop-down button the same identifier, so
        // resolve by identifier AND role.
        guard let combo = Self.element(driver: driver, pid: pid, identifier: "combo_one", role: "AXComboBox") else {
            Issue.record("AXComboBox: element not found"); return
        }
        let before = driver.readValue(elementID: combo) ?? ""
        let target = before == "Hybrid" ? "Sativa" : "Hybrid"
        let result = driver.setAttribute(elementID: combo, name: "AXValue", value: .string(target))
        #expect(result?["verified"] == .bool(true), "AXComboBox: write not verified: \(String(describing: result))")
        #expect(driver.readValue(elementID: combo) == target, "AXComboBox: value not written")
        _ = driver.setAttribute(elementID: combo, name: "AXValue", value: .string(before))
    }

    /// AXSearchField: targeted type_text with the default `auto` strategy.
    /// ControlZoo has no Edit menu, so Cmd+V is swallowed — this proves the
    /// auto fallback to key events AND that typing reaches the app (the
    /// delegate's text-change label), which an AXValue write never does.
    func runSearchFieldTyping(driver: MCPDriver, pid: pid_t, ids: [String: String]) async throws {
        let field = ids["sf_one"]!
        _ = driver.toolResult(name: "activate_app", arguments: #"{"pid":\#(pid)}"#)
        _ = driver.setAttribute(elementID: field, name: "AXValue", value: .string(""))
        let word = "zoo\(Int.random(in: 100...999))"
        let typed = driver.toolResult(
            name: "type_text",
            arguments: #"{"element_id":"\#(field)","text":"\#(word)","expected_app":"ControlZoo"}"#
        )
        guard case .object(let payload)? = typed else { Issue.record("AXSearchField: type_text returned nothing"); return }
        #expect(payload["verified"] == .bool(true), "AXSearchField: typing not verified: \(payload)")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(driver.readValue(elementID: field) == word, "AXSearchField: field does not hold the typed text")
        #expect(driver.readValue(elementID: ids["sf_one_label"]!) == "search_\(word)",
                "AXSearchField: app was not notified of the typed text")
        _ = driver.setAttribute(elementID: field, name: "AXValue", value: .string(""))
    }

    /// Date picker (AXDateTimeArea): AXValue is not writable, AXIncrement is.
    func runDatePicker(driver: MCPDriver, ids: [String: String]) async throws {
        let picker = ids["dp_one"]!
        guard let before = driver.readValue(elementID: picker), let start = Self.isoDate(before) else {
            Issue.record("Date picker: unreadable value"); return
        }
        _ = driver.performAction(elementID: picker, action: "AXIncrement")
        try? await Task.sleep(nanoseconds: 150_000_000)
        let expected = Self.isoDay(start.addingTimeInterval(86_400))
        #expect(driver.readValue(elementID: ids["dp_one_label"]!) == "date_\(expected)",
                "Date picker: app did not see the increment to \(expected)")
        #expect(driver.readValue(elementID: picker).flatMap(Self.isoDate).map(Self.isoDay) == expected,
                "Date picker: value did not advance one day")
        _ = driver.performAction(elementID: picker, action: "AXDecrement")  // restore
    }

    /// AXColorWell: an AXValue write is honestly reported as no_effect;
    /// AXPress opens the Colors panel; the harness button closes it.
    func runColorWell(driver: MCPDriver, pid: pid_t, ids: [String: String]) async throws {
        let well = ids["cw_one"]!
        let write = driver.setAttribute(elementID: well, name: "AXValue", value: .string("red"))
        #expect(write?["error_code"] == .string("no_effect"),
                "AXColorWell: ignored write must be reported as no_effect, got \(String(describing: write))")
        _ = driver.performAction(elementID: well, action: "AXPress")
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(Self.windowTitles(driver: driver, pid: pid).contains("Colors"), "AXColorWell: AXPress did not open the Colors panel")
        _ = driver.performAction(elementID: ids["cw_close_panel"]!, action: "AXPress")
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(!Self.windowTitles(driver: driver, pid: pid).contains("Colors"), "AXColorWell: Colors panel still open")
    }

    /// AXDisclosureTriangle: AXPress toggles the value and reaches the app.
    func runDisclosure(driver: MCPDriver, ids: [String: String]) async throws {
        let tri = ids["disc_one"]!
        let before = driver.readValue(elementID: tri)
        _ = driver.performAction(elementID: tri, action: "AXPress")
        try? await Task.sleep(nanoseconds: 150_000_000)
        let after = driver.readValue(elementID: tri)
        #expect(before != nil && after != nil && before != after, "Disclosure: value did not toggle (\(before ?? "nil") → \(after ?? "nil"))")
        let expectedLabel = after == "1" ? "expanded" : "collapsed"
        #expect(driver.readValue(elementID: ids["disc_one_label"]!) == expectedLabel, "Disclosure: app did not see the toggle")
        _ = driver.performAction(elementID: tri, action: "AXPress")         // restore
    }

    /// AXProgressIndicator: read-only value (42 of 0...100, reported as 0.42).
    func runProgressIndicator(driver: MCPDriver, ids: [String: String]) {
        let value = driver.readValue(elementID: ids["prog_one"]!).flatMap(Double.init)
        #expect(value.map { abs($0 - 0.42) < 0.001 } == true, "AXProgressIndicator: unexpected value \(String(describing: value))")
    }

    /// AXTabGroup: AXPress on a tab switches the visible content.
    func runTabView(driver: MCPDriver, pid: pid_t, ids: [String: String]) async throws {
        let tabs = Self.descendants(driver: driver, pid: pid, role: "AXRadioButton", subrole: "AXTabButton")
        guard let advanced = tabs["Advanced"], let general = tabs["General"] else {
            Issue.record("AXTabGroup: tabs not found (got \(tabs.keys.sorted()))"); return
        }
        _ = driver.performAction(elementID: advanced, action: "AXPress")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(driver.readValue(elementID: ids["tab_one_label"]!) == "tab_tab_advanced", "AXTabGroup: app did not switch tab")
        let visible = Self.identifierMap(driver: driver, pid: pid)
        #expect(visible["tab_advanced_content"] != nil, "AXTabGroup: Advanced content not in the AX tree")
        #expect(visible["tab_general_content"] == nil, "AXTabGroup: General content still visible")
        _ = driver.performAction(elementID: general, action: "AXPress")    // restore
    }

    /// AXTable: select a row through AXSelected; the app's selection follows.
    func runTable(driver: MCPDriver, pid: pid_t, ids: [String: String]) async throws {
        let rows = Self.tableRows(driver: driver, pid: pid, tableID: ids["table_one"]!)
        #expect(rows.count == 5, "AXTable: expected 5 rows, got \(rows.count)")
        guard rows.count == 5 else { return }
        _ = driver.setAttribute(elementID: rows[2], name: "AXSelected", value: .bool(true))
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(driver.readAttribute(elementID: rows[2], name: "AXSelected") == "1", "AXTable: row not selected")
        #expect(driver.readValue(elementID: ids["table_one_label"]!) == "row_Utrecht", "AXTable: app selection did not follow")
        _ = driver.setAttribute(elementID: rows[2], name: "AXSelected", value: .bool(false))
    }

    // MARK: - Helpers

    /// Title/description → element id for nodes of a role/subrole.
    static func descendants(driver: MCPDriver, pid: pid_t, role: String, subrole: String) -> [String: String] {
        guard case .object(let tree)? = driver.toolResult(name: "get_ui_tree", arguments: #"{"pid":\#(pid),"max_depth":16}"#),
              case .array(let nodes) = tree["nodes"] ?? .null else { return [:] }
        var out: [String: String] = [:]
        for node in nodes {
            guard case .object(let o) = node, o["role"] == .string(role),
                  case .string(let id) = o["id"] ?? .null,
                  driver.readAttribute(elementID: id, name: "AXSubrole") == subrole else { continue }
            let label = driver.readAttribute(elementID: id, name: "AXTitle").flatMap { $0.isEmpty ? nil : $0 }
                ?? driver.readAttribute(elementID: id, name: "AXDescription")
            if let label { out[label] = id }
        }
        return out
    }

    static func element(driver: MCPDriver, pid: pid_t, identifier: String, role: String) -> String? {
        guard case .object(let tree)? = driver.toolResult(name: "get_ui_tree", arguments: #"{"pid":\#(pid),"max_depth":16}"#),
              case .array(let nodes) = tree["nodes"] ?? .null else { return nil }
        for node in nodes {
            guard case .object(let o) = node, o["role"] == .string(role),
                  case .string(let id) = o["id"] ?? .null,
                  driver.readAttribute(elementID: id, name: "AXIdentifier") == identifier else { continue }
            return id
        }
        return nil
    }

    /// Rows of the table whose first cell carries a `table_cell_<row>_city` identifier.
    static func tableRows(driver: MCPDriver, pid: pid_t, tableID: String) -> [String] {
        guard case .object(let tree)? = driver.toolResult(name: "get_ui_tree", arguments: #"{"pid":\#(pid),"max_depth":16}"#),
              case .array(let nodes) = tree["nodes"] ?? .null else { return [] }
        var rows: [String] = []
        var currentRow: String?
        for node in nodes {
            guard case .object(let o) = node, case .string(let id) = o["id"] ?? .null else { continue }
            if o["role"] == .string("AXRow") { currentRow = id; continue }
            if let row = currentRow,
               let ident = driver.readAttribute(elementID: id, name: "AXIdentifier"),
               ident.hasPrefix("table_cell_"), ident.hasSuffix("_city") {
                rows.append(row)
                currentRow = nil
            }
        }
        return rows
    }

    static func windowTitles(driver: MCPDriver, pid: pid_t) -> [String] {
        guard case .object(let w)? = driver.toolResult(name: "list_windows", arguments: #"{"pid":\#(pid)}"#),
              case .array(let list) = w["windows"] ?? .null else { return [] }
        return list.compactMap { entry in
            guard case .object(let o) = entry, case .string(let t) = o["title"] ?? .null else { return nil }
            return t
        }
    }

    /// AXDateTimeArea values look like "2026-06-15 00:00:00 +0000".
    static func isoDate(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.date(from: text)
    }

    static func isoDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

extension MCPDriver {
    /// set_element_attribute with a typed JSON value; returns the payload
    /// (including verified / error_code) so callers can assert on it.
    func setAttribute(elementID: String, name: String, value: JSONValue) -> [String: JSONValue]? {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else { return nil }
        guard case .object(let payload)? = toolResult(
            name: "set_element_attribute",
            arguments: #"{"element_id":"\#(elementID)","name":"\#(name)","value":\#(json)}"#
        ) else { return nil }
        return payload
    }
}
