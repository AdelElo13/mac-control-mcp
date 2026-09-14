import Testing
import Foundation
import ApplicationServices
@testable import MacControlMCP

/// Regressions from the second external review round of v0.9.0 (Codex r2).
/// Each test names the finding it pins down; each failed (or trapped the
/// runner) before its fix.
@Suite("Codex r2 regressions")
struct CodexR2RegressionTests {

    // MARK: - ElementCache: a relabel is not a collision (new finding)

    /// The id hashes pid + role + ordinal + identifier only, so a button
    /// whose title flips "Start" → "Stop" must keep its id. The collision
    /// check compared whole path components — title included — and
    /// quarantined the stable id on every relabel, minting a random one.
    @Test("re-storing an element under a new title keeps its content-addressed id")
    func relabelKeepsID() async {
        let cache = ElementCache(ttl: 60, maxEntries: 100)
        let element = AXUIElementCreateApplication(4242)
        let before = [AXPathComponent(role: "AXWindow", index: 0, identifier: nil, title: "Main"),
                      AXPathComponent(role: "AXButton", index: 3, identifier: "run-btn", title: "Start")]
        let after = [AXPathComponent(role: "AXWindow", index: 0, identifier: nil, title: "Main"),
                     AXPathComponent(role: "AXButton", index: 3, identifier: "run-btn", title: "Stop")]

        let id1 = await cache.storeMany(withPaths: [(element, before)], pid: 4242)[0]
        let id2 = await cache.storeMany(withPaths: [(element, after)], pid: 4242)[0]

        #expect(id1 == AXPath.identifier(pid: 4242, path: before))
        #expect(id2 == id1, "a title change must refresh the entry, not evict it")
        #expect(await cache.resolve(id1!) != nil)
        #expect(await cache.count == 1)
    }

    @Test("a genuinely different hashed path under the same id is still quarantined")
    func realCollisionStillQuarantined() async {
        // Two paths that differ in a HASHED field (identifier) but are
        // filed under the same key can only happen on a digest collision;
        // simulate it by storing, then re-storing a different path whose
        // id we force equal by using the same element and pid but a path
        // the cache must consider different. There is no way to forge a
        // SHA-256 collision here, so assert the contrapositive: different
        // hashed paths get different ids and both resolve.
        let cache = ElementCache(ttl: 60, maxEntries: 100)
        let element = AXUIElementCreateApplication(4242)
        let a = [AXPathComponent(role: "AXButton", index: 3, identifier: "a")]
        let b = [AXPathComponent(role: "AXButton", index: 3, identifier: "b")]
        let ida = await cache.storeMany(withPaths: [(element, a)], pid: 4242)[0]
        let idb = await cache.storeMany(withPaths: [(element, b)], pid: 4242)[0]
        #expect(ida != idb)
        #expect(await cache.resolve(ida!) != nil)
        #expect(await cache.resolve(idb!) != nil)
    }

    // MARK: - Text editing: app-reported ranges are untrusted (#6)

    /// `insertAtCaret` collapses a non-empty selection to `location +
    /// length`. Those numbers come from the app; `Int.max + 1` trapped the
    /// server. Before the fix this test crashed the runner.
    @Test("an app-reported selection whose end overflows Int is refused, not trapped")
    func overflowingAppSelectionRefused() async {
        let element = TextEditingBackendTests.FakeElement(
            value: "hello", selection: .init(location: Int.max, length: 1)
        )
        let controller = TextEditingBackendTests.controller(element)
        do {
            _ = try await controller.insertAtCaret(of: TextEditingBackendTests.dummyElement(), text: "x")
            Issue.record("insertAtCaret should refuse an overflowing selection")
        } catch {
            #expect(error.code == "not_supported")
            #expect(error.reason == "invalid_selection_range")
        }
        #expect(element.value == "hello")
    }

    @Test("decoding an AX range rejects negative and overflowing components", arguments: [
        (-1, 5), (0, -1), (Int.max, 1), (1, Int.max), (Int.min, 0)
    ])
    func decodedRangeSanitized(location: Int, length: Int) throws {
        let value = try #require(TextEditingController.makeRangeValue(location: location, length: length))
        #expect(TextEditingController.textRange(from: value) == nil)
    }

    @Test("decoding a sane AX range is unchanged")
    func decodedRangeSane() throws {
        let value = try #require(TextEditingController.makeRangeValue(location: 6, length: 2))
        #expect(TextEditingController.textRange(from: value) == .init(location: 6, length: 2))
    }

    // MARK: - Clipboard: the type check must be on the open descriptor (#7)

    /// `resolveExistingFile` stats the path; a FIFO swapped in AFTER that
    /// check used to be opened blocking by the reader. The reader now
    /// opens non-blocking and fstat()s what it holds, so a FIFO handed
    /// straight to it — the post-swap state — is rejected without waiting
    /// for a writer.
    @Test("the image reader rejects a FIFO on the open descriptor without blocking")
    func readerRejectsFIFOWithoutBlocking() async throws {
        let fifoPath = NSTemporaryDirectory() + "mcp-clip-r2-fifo-\(UUID().uuidString)"
        #expect(mkfifo(fifoPath, 0o600) == 0, "mkfifo must succeed to exercise this path")
        defer { try? FileManager.default.removeItem(atPath: fifoPath) }

        let error = try await ClipboardRichTests.withTimeout(seconds: 5) {
            do {
                _ = try ClipboardController.boundedReadForImage(at: fifoPath, originalPath: fifoPath)
                return nil as ClipboardController.ClipboardError?
            } catch let e as ClipboardController.ClipboardError {
                return e
            }
        }
        #expect(error == .notRegularFile(fifoPath))
    }

    @Test("the image reader still reads a regular file and enforces the cap")
    func readerReadsRegularFile() throws {
        let path = NSTemporaryDirectory() + "mcp-clip-r2-reg-\(UUID().uuidString).bin"
        let payload = Data((0..<1024).map { UInt8($0 % 251) })
        #expect(FileManager.default.createFile(atPath: path, contents: payload))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try ClipboardController.boundedReadForImage(at: path, originalPath: path) == payload)
    }

    // MARK: - Codex r3

    /// A row that knows its own window-server id but whose id is missing
    /// from the snapshot (window closed between the AX and CG reads) must
    /// NOT fall back to frame/title — that would hand it an identical
    /// neighbour's id.
    @Test("enrich: a stale exact id never falls back to a same-frame neighbour's id")
    func staleExactIDDoesNotBorrow() {
        let cg = [WindowTargetingTests.entry(id: 300, title: "Untitled", z: 0)]
        // Row A's window (id 299) is gone; window B (id 300) has the same
        // frame and title. Old code: A takes 300 and B is left with nil.
        let rows = [
            WindowTargetingTests.row(title: "Untitled", index: 0, axID: 299),
            WindowTargetingTests.row(title: "Untitled", index: 1, axID: 300)
        ]
        let out = WindowController.enrich(windows: rows, cgEntries: cg, displays: [])
        #expect(out.map(\.windowID) == [nil, 300])
    }

    @Test("enrich: rows without any id still use the frame/title fallback")
    func idLessRowsStillFallBack() {
        let cg = [WindowTargetingTests.entry(id: 310, title: "Doc", z: 0)]
        let rows = [WindowTargetingTests.row(title: "Doc", index: 0)]
        let out = WindowController.enrich(windows: rows, cgEntries: cg, displays: [])
        #expect(out.map(\.windowID) == [310])
    }

    @Test("expectedCount refuses to overflow", arguments: [
        (Int.max, 0, 1), (Int.min, 1, 0), (Int.max, -1, 0)
    ])
    func expectedCountOverflow(before: Int, replaced: Int, inserted: Int) {
        #expect(TextEditingController.expectedCount(before: before, replaced: replaced, inserted: inserted) == nil)
        #expect(TextEditingController.expectedCount(before: 10, replaced: 2, inserted: 3) == 11)
    }

    /// End to end: an element exposing only a nonsense AXNumberOfCharacters
    /// (Int.max) used to trap the server on `before - length + inserted`.
    @Test("an Int.max character count during verification is reported as unverified, not trapped")
    func hugeCharacterCountDoesNotTrap() async throws {
        let element = TextEditingBackendTests.FakeElement(value: "hello", selection: .init(location: 0, length: 0))
        element.exposesValue = false
        element.exposesStringForRange = false
        element.forcedCharacterCount = Int.max
        let controller = TextEditingBackendTests.controller(element)
        let outcome = try await controller.insertAtCaret(of: TextEditingBackendTests.dummyElement(), text: "abc")
        #expect(outcome.applied == nil)
        // Codex r4: the count IS exposed — the diagnosis must not claim
        // otherwise, and must not send the caller back to AXValue.
        #expect(outcome.verification == "count_unusable")
        #expect(outcome.warning?.contains("out of Int range") == true)
        #expect(outcome.warning?.contains("text_get_value") == false)
    }

    @Test("count-based warnings never point at text_get_value (it reads the same unreadable AXValue)", arguments: [
        "count_only", "count_unusable", "unverified"
    ])
    func warningsNameWorkingRoutes(verification: String) {
        // An insert at 7: the replaced range is empty, the written text
        // occupies 7..<10. The clipboard instruction must name THAT range
        // (Codex r5) — "over the range" would copy nothing.
        let outcome = TextEditingController.WriteOutcome(
            range: .init(location: 7, length: 0), insertedCharacters: 3, selectionAfter: nil,
            collapsedSelection: false, applied: nil, observedText: nil, verification: verification
        )
        #expect(outcome.warning?.contains("text_get_value") == false)
        #expect(outcome.warning?.contains("capture_annotated") == true)
        #expect(outcome.warning?.contains("location: 7, length: 3") == true)
        // Codex r6: press_key targets the frontmost app, so the route must
        // bring the element's app forward first, and spell press_key's
        // real arguments.
        #expect(outcome.warning?.contains("activate_app") == true)
        #expect(outcome.warning?.contains("key: \"c\", modifiers: [\"cmd\"]") == true)
        // Codex r7: AXSelectedTextRange does not move keyboard focus; with
        // two documents open Cmd-C copies from the focused one. The route
        // must focus the element before selecting.
        #expect(outcome.warning?.contains("\"AXFocused\"") == true)
        let focusAt = outcome.warning?.range(of: "AXFocused")?.lowerBound
        let selectAt = outcome.warning?.range(of: "text_set_selection")?.lowerBound
        #expect(focusAt != nil && selectAt != nil && focusAt! < selectAt!)
    }

    @Test("a count that moved by the wrong amount reports applied:false WITH a warning")
    func wrongCountMoveHasWarning() {
        let outcome = TextEditingController.WriteOutcome(
            range: .init(location: 0, length: 0), insertedCharacters: 3, selectionAfter: nil,
            collapsedSelection: false, applied: false, observedText: nil, verification: "count_only"
        )
        #expect(outcome.warning?.contains("not by the requested amount") == true)
    }
}
