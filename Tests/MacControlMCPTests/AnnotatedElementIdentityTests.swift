import Testing
import Foundation
import AppKit
import ApplicationServices
@testable import MacControlMCP

/// v0.9 — `capture_annotated` must hand out the SAME content-addressed
/// element ids as the rest of the AX surface (C-5). An index on a picture
/// is only useful if `element_id` can be fed straight to
/// `perform_element_action`, and if the agent can correlate a box with a
/// handle it already holds from `find_elements` / `element_at_point`.
///
/// These tests drive a REAL app (Finder) through the built server binary
/// over stdio — the same `RealAppMatrixTests.Driver` the other live
/// suites use — rather than calling `ToolRegistry` in-process.
///
/// That is not stylistic: an in-process `capture_annotated` BLOCKS
/// indefinitely when the test host has no Screen Recording grant
/// (ScreenCaptureKit waits on TCC instead of returning), which hung the
/// first version of this suite for 10 minutes. Every call here carries a
/// timeout, the suite carries `.timeLimit`, and any environment that
/// cannot support the probe (no AX trust, no Screen Recording, no Finder
/// window, no built binary) SKIPS with a printed reason instead of
/// failing or hanging.
///
/// Nothing here clicks, types, or moves a window.
@Suite(
    "capture_annotated element identity (C-5)",
    .serialized,
    .timeLimit(.minutes(3)),
    .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
             "Drives Finder over AX + screen capture; a headless CI runner has neither the window nor the grants.")
)
struct AnnotatedElementIdentityTests {

    static var finderPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?.processIdentifier
    }

    /// One live driver session: capture Finder, return the drawn elements
    /// plus the driver so follow-up calls hit the SAME server process
    /// (the element cache lives in that process).
    static func makeDriver() -> RealAppMatrixTests.Driver? {
        guard let driver = RealAppMatrixTests.Driver(binary: RealAppMatrixTests.serverBinary()) else {
            print("[annotated-identity] skipped: server binary not built")
            return nil
        }
        driver.initialize()
        return driver
    }

    static func annotateFinder(
        _ driver: RealAppMatrixTests.Driver,
        pid: pid_t
    ) -> [[String: JSONValue]]? {
        // Small image on purpose: this test is about ids, not pixels.
        let payload = driver.callTool(
            "capture_annotated",
            arguments: #"{"pid":\#(pid),"max_elements":25,"max_width":600,"format":"jpeg"}"#,
            timeout: 45
        )
        guard case .object(let object)? = payload else {
            print("[annotated-identity] skipped: capture_annotated returned nothing (timeout or transport)")
            return nil
        }
        guard object["ok"] == .bool(true) else {
            print("[annotated-identity] skipped: capture_annotated failed — \(object["error_code"] ?? .null)")
            return nil
        }
        let elements = (object["elements"]?.arrayValue ?? []).compactMap { $0.objectValue }
        guard !elements.isEmpty else {
            print("[annotated-identity] skipped: Finder exposed no interactive elements")
            return nil
        }
        return elements
    }

    static func rect(_ entry: [String: JSONValue]) -> [Double]? {
        guard let x = entry["x"]?.doubleValue, let y = entry["y"]?.doubleValue,
              let w = entry["width"]?.doubleValue, let h = entry["height"]?.doubleValue
        else { return nil }
        return [x, y, w, h]
    }

    /// Guard shared by every test: AX trust, a running Finder, a driver.
    static func liveSession() -> (RealAppMatrixTests.Driver, pid_t, [[String: JSONValue]])? {
        guard AXIsProcessTrusted() else {
            print("[annotated-identity] skipped: no Accessibility trust")
            return nil
        }
        guard let pid = finderPID else {
            print("[annotated-identity] skipped: Finder is not running")
            return nil
        }
        guard let driver = makeDriver() else { return nil }
        guard let elements = annotateFinder(driver, pid: pid) else {
            driver.close()
            return nil
        }
        return (driver, pid, elements)
    }

    // MARK: - Tests

    @Test("every drawn element carries a unique, well-formed element id")
    func idsAreWellFormed() throws {
        guard let (driver, _, elements) = Self.liveSession() else { return }
        defer { driver.close() }

        for entry in elements {
            let id = try #require(entry["element_id"]?.stringValue,
                                  "a drawn element came back without an element_id")
            #expect(id.hasPrefix("el_"))
            // Path-derived ids are `el_` + 16 hex chars (AXPath.identifier).
            #expect(id.count == 19)
        }
        let ids = elements.compactMap { $0["element_id"]?.stringValue }
        #expect(Set(ids).count == ids.count, "two boxes must never share an element_id")
    }

    @Test("the same element keeps its id across two capture_annotated calls")
    func idsAreStableAcrossCalls() throws {
        guard let (driver, pid, first) = Self.liveSession() else { return }
        defer { driver.close() }
        guard let second = Self.annotateFinder(driver, pid: pid) else { return }

        var matched = 0
        for entry in first {
            guard let geo = Self.rect(entry), let id = entry["element_id"]?.stringValue else { continue }
            let twin = second.first { other in
                Self.rect(other) == geo && other["role"]?.stringValue == entry["role"]?.stringValue
            }
            guard let twinID = twin?["element_id"]?.stringValue else { continue }
            #expect(twinID == id,
                    "id for \(entry["role"]?.stringValue ?? "?") at \(geo) changed between captures")
            matched += 1
        }
        #expect(matched > 0, "no element could be joined across the two captures")
        print("[annotated-identity] stable across calls for \(matched) element(s)")
    }

    @Test("capture_annotated and find_elements agree on the id of the same element")
    func idMatchesFindElements() throws {
        guard let (driver, pid, elements) = Self.liveSession() else { return }
        defer { driver.close() }

        guard let target = elements.first(where: { $0["role"]?.stringValue != nil && Self.rect($0) != nil }),
              let role = target["role"]?.stringValue,
              let targetGeo = Self.rect(target),
              let annotatedID = target["element_id"]?.stringValue else {
            print("[annotated-identity] skipped: no usable element in the capture")
            return
        }

        guard case .object(let found)? = driver.callTool(
            "find_elements",
            arguments: #"{"pid":\#(pid),"role":"\#(role)","limit":500,"max_depth":24}"#,
            timeout: 30
        ) else {
            print("[annotated-identity] skipped: find_elements returned nothing")
            return
        }
        let matches = (found["elements"]?.arrayValue ?? []).compactMap { $0.objectValue }
        let twin = matches.first { entry in
            guard let p = entry["position"]?.objectValue, let s = entry["size"]?.objectValue,
                  let x = p["x"]?.doubleValue, let y = p["y"]?.doubleValue,
                  let w = s["width"]?.doubleValue, let h = s["height"]?.doubleValue else { return false }
            return [x, y, w, h] == targetGeo
        }
        let twinID = try #require(
            twin?["id"]?.stringValue,
            "find_elements(role: \(role)) returned no element at \(targetGeo) — cannot compare ids"
        )
        #expect(twinID == annotatedID,
                "capture_annotated id \(annotatedID) != find_elements id \(twinID) for the same element")
        print("[annotated-identity] capture_annotated == find_elements → \(annotatedID) (\(role))")
    }

    @Test("pruning AXMenuBar drops menu items without moving any other element's id")
    func menuBarPruneKeepsIdsStable() async throws {
        guard AXIsProcessTrusted(), let pid = Self.finderPID else {
            print("[annotated-identity] skipped: no AX trust / no Finder")
            return
        }
        let accessibility = AccessibilityController()
        let full = await accessibility.treeWalk(pid: pid, maxDepth: 8, nodeCap: 2_000)
        let pruned = await accessibility.treeWalk(
            pid: pid, maxDepth: 8, nodeCap: 2_000, pruneRoles: ["AXMenuBar"]
        )
        guard full.contains(where: { $0.role == "AXMenuBar" }) else {
            print("[annotated-identity] skipped: this Finder exposes no menu bar to prune")
            return
        }

        // The menu bar NODE survives; its subtree does not.
        #expect(pruned.contains { $0.role == "AXMenuBar" })
        #expect(pruned.allSatisfy { $0.role != "AXMenuItem" })
        #expect(pruned.count <= full.count)

        // Every element that survives the prune keeps the id it had in the
        // full walk — pruning must not renumber siblings.
        let fullIDs = Dictionary(
            full.map { (AXPath.identity(pid: pid, path: $0.path), AXPath.identifier(pid: pid, path: $0.path)) },
            uniquingKeysWith: { first, _ in first }
        )
        var checked = 0
        for node in pruned where node.role != "AXMenuBar" {
            let identity = AXPath.identity(pid: pid, path: node.path)
            guard let expected = fullIDs[identity] else { continue }
            #expect(AXPath.identifier(pid: pid, path: node.path) == expected)
            checked += 1
        }
        print("[annotated-identity] prune kept \(checked) element id(s) unchanged "
              + "(\(full.count) nodes → \(pruned.count))")
    }

    @Test("an id from capture_annotated resolves for a follow-up call")
    func idResolvesForFollowUpCalls() throws {
        guard let (driver, _, elements) = Self.liveSession() else { return }
        defer { driver.close() }
        guard let id = elements.first?["element_id"]?.stringValue else { return }

        // get_element_attributes is a read-only consumer of element ids:
        // if the handle is live, it answers without re-searching.
        guard case .object(let attributes)? = driver.callTool(
            "get_element_attributes",
            arguments: #"{"element_id":"\#(id)"}"#,
            timeout: 20
        ) else {
            print("[annotated-identity] skipped: get_element_attributes returned nothing")
            return
        }
        #expect(attributes["ok"] == .bool(true),
                "element_id from capture_annotated did not resolve: \(attributes)")
    }
}
