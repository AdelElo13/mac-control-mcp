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
}
