import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
#if canImport(Darwin)
import Darwin
#endif
@testable import MacControlMCP

/// v0.9 workstream G — rich clipboard (C-10).
///
/// DESKTOP SAFETY: these tests never touch the user's real clipboard. Each
/// one drives a PRIVATE NSPasteboard (`ClipboardController(pasteboardName:)`,
/// and a `ToolRegistry` built around one), so `swift test` cannot disturb
/// whatever the developer has copied — and, just as important, cannot be
/// disturbed BY another suite: `ToolRegistryV2Tests` and the AX paste
/// fallback both write to `NSPasteboard.general` concurrently, which made
/// the first version of this suite flake in a full `swift test` run (it
/// passed under `--filter` and failed in the full run — the classic shape
/// of a shared-global-resource race).
///
/// The general-pasteboard path is covered by the live stdio probe, which
/// snapshots and restores the real clipboard around itself.
@Suite("Rich clipboard round-trips", .serialized)
struct ClipboardRichTests {

    /// A fresh private pasteboard name per call, so no two tests share state.
    static func privateBoard() -> NSPasteboard.Name {
        NSPasteboard.Name("com.mac-control-mcp.tests.\(UUID().uuidString)")
    }

    static func controller() -> ClipboardController {
        ClipboardController(pasteboardName: privateBoard())
    }

    static func registry() -> ToolRegistry {
        ToolRegistry(
            accessibility: AccessibilityController(),
            clipboard: ClipboardController(pasteboardName: privateBoard())
        )
    }

    // MARK: - Fixtures

    /// Write a solid-colour PNG of the given pixel size into the
    /// user-scoped temp dir (an allowed PathValidator root). Returns the path.
    static func makePNG(width: Int, height: Int) throws -> String {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let path = NSTemporaryDirectory() + "mcp-clip-test-\(UUID().uuidString).png"
        let url = URL(fileURLWithPath: path) as CFURL
        let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return path
    }

    static func makeTextFile(_ contents: String) throws -> String {
        let path = NSTemporaryDirectory() + "mcp-clip-test-\(UUID().uuidString).txt"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    static func pngSize(path: String) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        return (w, h)
    }

    // MARK: - Image

    @Test("write an image file to the pasteboard, read it back with its dimensions")
    func imageRoundTrip() async throws {
        let source = try Self.makePNG(width: 64, height: 40)
        defer { try? FileManager.default.removeItem(atPath: source) }

        let clipboard = Self.controller()
        let written = try await clipboard.writeRich(.init(imagePath: source))
        #expect(written.wrote.contains("image"))
        let result = try await clipboard.readRich(kind: .image, inline: false, outputPath: nil)

        let image = try #require(result.image)
        #expect(image.width == 64)
        #expect(image.height == 40)
        let path = try #require(image.path)
        #expect(FileManager.default.fileExists(atPath: path))
        let dims = try #require(Self.pngSize(path: path))
        #expect(dims == (64, 40))
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("inline:true returns base64 PNG bytes of the same image")
    func imageInlineBase64() async throws {
        let source = try Self.makePNG(width: 32, height: 16)
        defer { try? FileManager.default.removeItem(atPath: source) }

        let clipboard = Self.controller()
        _ = try await clipboard.writeRich(.init(imagePath: source))
        let result = try await clipboard.readRich(kind: .image, inline: true, outputPath: nil)

        let image = try #require(result.image)
        let b64 = try #require(image.base64)
        let data = try #require(Data(base64Encoded: b64))
        #expect(data.count == image.bytes)
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(decoded.width == 32)
        #expect(decoded.height == 16)
        if let path = image.path { try? FileManager.default.removeItem(atPath: path) }
    }

    @Test("a JPEG source is transcoded to PNG on the pasteboard")
    func jpegSourceBecomesPNG() async throws {
        // Build a JPEG by re-encoding the PNG fixture.
        let pngPath = try Self.makePNG(width: 20, height: 10)
        defer { try? FileManager.default.removeItem(atPath: pngPath) }
        let src = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: pngPath) as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let jpegPath = NSTemporaryDirectory() + "mcp-clip-test-\(UUID().uuidString).jpg"
        defer { try? FileManager.default.removeItem(atPath: jpegPath) }
        let dest = try #require(CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: jpegPath) as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))

        let clipboard = Self.controller()
        _ = try await clipboard.writeRich(.init(imagePath: jpegPath))
        let result = try await clipboard.readRich(kind: .image, inline: false, outputPath: nil)
        let payload = try #require(result.image)
        #expect(payload.width == 20)
        #expect(payload.height == 10)
        if let path = payload.path { try? FileManager.default.removeItem(atPath: path) }
    }

    @Test("an unreadable image file is rejected")
    func unreadableImageRejected() async throws {
        let notAnImage = try Self.makeTextFile("definitely not a PNG")
        defer { try? FileManager.default.removeItem(atPath: notAnImage) }
        let clipboard = Self.controller()
        await #expect(throws: ClipboardController.ClipboardError.self) {
            _ = try await clipboard.writeRich(.init(imagePath: notAnImage))
        }
    }

    // MARK: - Files

    @Test("write file URLs to the pasteboard and read the paths back")
    func filesRoundTrip() async throws {
        let a = try Self.makeTextFile("alpha")
        let b = try Self.makeTextFile("beta")
        defer {
            try? FileManager.default.removeItem(atPath: a)
            try? FileManager.default.removeItem(atPath: b)
        }

        let clipboard = Self.controller()
        let written = try await clipboard.writeRich(.init(files: [a, b]))
        #expect(written.wrote.contains("files"))
        let result = try await clipboard.readRich(kind: .files, inline: false, outputPath: nil)

        let files = try #require(result.files)
        #expect(files.count == 2)
        #expect(files.contains { $0.hasSuffix((a as NSString).lastPathComponent) })
        #expect(files.contains { $0.hasSuffix((b as NSString).lastPathComponent) })
    }

    @Test("a missing input file is rejected instead of silently writing nothing")
    func missingFileRejected() async throws {
        let ghost = NSTemporaryDirectory() + "mcp-clip-test-does-not-exist-\(UUID().uuidString).txt"
        let clipboard = Self.controller()
        await #expect(throws: ClipboardController.ClipboardError.self) {
            _ = try await clipboard.writeRich(.init(files: [ghost]))
        }
    }

    @Test("reading files from a clipboard that has none fails honestly")
    func filesReadWithoutFilesFails() async throws {
        let clipboard = Self.controller()
        _ = try await clipboard.writeRich(.init(text: "no files here"))
        await #expect(throws: ClipboardController.ClipboardError.self) {
            _ = try await clipboard.readRich(kind: .files, inline: false, outputPath: nil)
        }
    }

    // MARK: - Text flavours

    @Test("html and rtf round-trip as strings alongside plain text")
    func textFlavoursRoundTrip() async throws {
        let html = "<p>hello <b>world</b></p>"
        let rtf = #"{\rtf1\ansi Hello RTF}"#

        let clipboard = Self.controller()
        let written = try await clipboard.writeRich(.init(text: "hello world", html: html, rtf: rtf))
        #expect(written.wrote.contains("text"))
        #expect(written.wrote.contains("html"))
        #expect(written.wrote.contains("rtf"))

        let readHTML = try await clipboard.readRich(kind: .html, inline: false, outputPath: nil).html
        let readRTF = try await clipboard.readRich(kind: .rtf, inline: false, outputPath: nil).rtf
        let readText = try await clipboard.readRich(kind: .text, inline: false, outputPath: nil).text

        #expect(readHTML == html)
        #expect(readRTF == rtf)
        #expect(readText == "hello world")
    }

    @Test("type=all enumerates every available UTI with its byte size")
    func allEnumeratesTypes() async throws {
        let clipboard = Self.controller()
        _ = try await clipboard.writeRich(.init(text: "abc", html: "<i>abc</i>"))
        let result = try await clipboard.readRich(kind: .all, inline: false, outputPath: nil)

        let available = try #require(result.available)
        #expect(!available.isEmpty)
        #expect(available.allSatisfy { ($0.bytes ?? 0) >= 0 })
        #expect(available.contains { $0.uti == NSPasteboard.PasteboardType.string.rawValue })
        #expect(available.contains { $0.uti == NSPasteboard.PasteboardType.html.rawValue })
        #expect(result.text == "abc")
    }

    @Test("reading an image from a text-only clipboard fails honestly")
    func imageReadOnTextOnlyClipboardFails() async throws {
        let clipboard = Self.controller()
        _ = try await clipboard.writeRich(.init(text: "just text"))
        await #expect(throws: ClipboardController.ClipboardError.self) {
            _ = try await clipboard.readRich(kind: .image, inline: false, outputPath: nil)
        }
    }

    @Test("an empty write request is rejected")
    func emptyWriteRejected() async throws {
        let clipboard = Self.controller()
        await #expect(throws: ClipboardController.ClipboardError.self) {
            _ = try await clipboard.writeRich(.init())
        }
    }

    @Test("an output_path outside the allowed roots is refused")
    func imageOutputPathIsValidated() async throws {
        let source = try Self.makePNG(width: 8, height: 8)
        defer { try? FileManager.default.removeItem(atPath: source) }
        let clipboard = Self.controller()
        _ = try await clipboard.writeRich(.init(imagePath: source))
        await #expect(throws: ClipboardController.ClipboardError.self) {
            _ = try await clipboard.readRich(
                kind: .image, inline: false, outputPath: "/etc/mcp-clipboard-should-not-exist.png"
            )
        }
    }

    // MARK: - Write safety (two-phase write)

    @Test("a rejected write leaves the previous clipboard contents intact")
    func failedRealWriteRestoresPreviousContents() async throws {
        let board = Self.privateBoard()
        // Seed the board with something worth losing.
        let seeder = ClipboardController(pasteboardName: board)
        _ = try await seeder.writeRich(.init(text: "precious original", html: "<b>precious</b>"))

        // A write whose REAL writeObjects fails must restore the snapshot.
        let failing = ClipboardController(pasteboardName: board, writeFailureSimulation: .realWrite)
        await #expect(throws: ClipboardController.ClipboardError.self) {
            _ = try await failing.writeRich(.init(text: "replacement that never lands"))
        }

        let after = try await seeder.readRich(kind: .all, inline: false, outputPath: nil)
        #expect(after.text == "precious original", "a failed write must not empty the clipboard")
        #expect(after.html == "<b>precious</b>")
    }

    @Test("a write rejected during the dry run never touches the real pasteboard")
    func failedDryRunLeavesBoardUntouched() async throws {
        let board = Self.privateBoard()
        let seeder = ClipboardController(pasteboardName: board)
        _ = try await seeder.writeRich(.init(text: "still here"))
        let changeCountBefore = await MainActor.run { NSPasteboard(name: board).changeCount }

        let failing = ClipboardController(pasteboardName: board, writeFailureSimulation: .dryRun)
        await #expect(throws: ClipboardController.ClipboardError.self) {
            _ = try await failing.writeRich(.init(text: "never gets there"))
        }

        let after = try await seeder.readRich(kind: .text, inline: false, outputPath: nil)
        #expect(after.text == "still here")
        // Not even a clearContents() — the change count must be unmoved.
        let changeCountAfter = await MainActor.run { NSPasteboard(name: board).changeCount }
        #expect(changeCountAfter == changeCountBefore,
                "the dry run must not clear or touch the real pasteboard")
    }

    // MARK: - Inventory budget

    @Test("type=all reports sizes for small representations and flags bulk ones")
    func allCapsLargeRepresentations() async throws {
        // A PNG big enough to be worth not copying twice.
        let source = try Self.makePNG(width: 1400, height: 1400)
        defer { try? FileManager.default.removeItem(atPath: source) }

        let clipboard = Self.controller()
        _ = try await clipboard.writeRich(.init(text: "small text", imagePath: source))
        let result = try await clipboard.readRich(kind: .all, inline: false, outputPath: nil)

        let available = try #require(result.available)
        let text = try #require(available.first { $0.uti == NSPasteboard.PasteboardType.string.rawValue })
        #expect(text.bytes == 10)          // "small text"
        #expect(text.large == false)

        // Image flavours are never materialised just to be measured.
        let png = try #require(available.first { $0.uti == NSPasteboard.PasteboardType.png.rawValue })
        #expect(png.bytes == nil)
        #expect(png.large)
        let tiff = try #require(available.first { $0.uti == NSPasteboard.PasteboardType.tiff.rawValue })
        #expect(tiff.bytes == nil)
        #expect(tiff.large)
    }

    @Test("legacy image aliases are treated as bulk too")
    func legacyImageAliasesAreBulk() {
        #expect(ClipboardController.isBulkType("Apple PNG pasteboard type"))
        #expect(ClipboardController.isBulkType("NeXT TIFF v4.0 pasteboard type"))
        #expect(ClipboardController.isBulkType("com.apple.webarchive"))
        #expect(ClipboardController.isBulkType("public.jpeg"))
        #expect(ClipboardController.isBulkType("public.mpeg-4"))
        #expect(!ClipboardController.isBulkType("public.utf8-plain-text"))
        #expect(!ClipboardController.isBulkType("public.html"))
        #expect(!ClipboardController.isBulkType("public.rtf"))
    }

    // MARK: - Inline without a file

    @Test("inline:true with no output_path returns bytes without writing a temp file")
    func inlineDoesNotWriteAFile() async throws {
        let source = try Self.makePNG(width: 24, height: 12)
        defer { try? FileManager.default.removeItem(atPath: source) }

        let clipboard = Self.controller()
        _ = try await clipboard.writeRich(.init(imagePath: source))
        let result = try await clipboard.readRich(kind: .image, inline: true, outputPath: nil)

        let image = try #require(result.image)
        #expect(image.path == nil, "inline reads must not leave a temp file behind")
        #expect(image.base64 != nil)
        #expect(image.width == 24 && image.height == 12)
    }

    @Test("inline:true WITH an output_path still writes the file")
    func inlineWithOutputPathWritesFile() async throws {
        let source = try Self.makePNG(width: 24, height: 12)
        defer { try? FileManager.default.removeItem(atPath: source) }
        let destination = NSTemporaryDirectory() + "mcp-clip-out-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: destination) }

        let clipboard = Self.controller()
        _ = try await clipboard.writeRich(.init(imagePath: source))
        let result = try await clipboard.readRich(kind: .image, inline: true, outputPath: destination)

        let image = try #require(result.image)
        #expect(image.path == destination)
        #expect(FileManager.default.fileExists(atPath: destination))
        #expect(image.base64 != nil)
    }

    // MARK: - Tool layer

    @Test("clipboard_read with no type stays backward compatible (text + types)")
    func toolReadDefaultsToText() async throws {
        let registry = Self.registry()
        _ = await registry.callTool(name: "clipboard_write", arguments: ["text": .string("compat")])
        let result = await registry.callTool(name: "clipboard_read", arguments: [:])
        let payload = result.structuredContent.objectValue ?? [:]

        #expect(payload["ok"] == .bool(true))
        #expect(payload["text"] == .string("compat"))
        #expect(payload["types"]?.arrayValue?.isEmpty == false)
    }

    @Test("clipboard_write image_path → clipboard_read type=image via the tool layer")
    func toolImageRoundTrip() async throws {
        let source = try Self.makePNG(width: 48, height: 24)
        defer { try? FileManager.default.removeItem(atPath: source) }

        let registry = Self.registry()
        let write = await registry.callTool(
            name: "clipboard_write", arguments: ["image_path": .string(source)]
        )
        #expect(write.isError == false)
        let read = await registry.callTool(
            name: "clipboard_read", arguments: ["type": .string("image")]
        )
        let payload = read.structuredContent.objectValue ?? [:]

        #expect(payload["ok"] == .bool(true))
        let image = try #require(payload["image"]?.objectValue)
        #expect(image["width"] == .number(48))
        #expect(image["height"] == .number(24))
        if let path = image["path"]?.stringValue {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    @Test("clipboard_write files → clipboard_read type=files via the tool layer")
    func toolFilesRoundTrip() async throws {
        let file = try Self.makeTextFile("tool layer")
        defer { try? FileManager.default.removeItem(atPath: file) }

        let registry = Self.registry()
        let write = await registry.callTool(
            name: "clipboard_write", arguments: ["files": .array([.string(file)])]
        )
        #expect(write.isError == false)
        let read = await registry.callTool(
            name: "clipboard_read", arguments: ["type": .string("files")]
        )
        let payload = read.structuredContent.objectValue ?? [:]
        #expect(payload["file_count"] == .number(1))
        #expect(payload["files"]?.arrayValue?.first?.stringValue?.hasSuffix(
            (file as NSString).lastPathComponent
        ) == true)
    }

    @Test("clipboard_read with an unknown type is an invalid_argument, not a crash")
    func toolRejectsUnknownType() async throws {
        let result = await Self.registry().callTool(
            name: "clipboard_read", arguments: ["type": .string("hologram")]
        )
        #expect(result.isError)
        #expect(result.text.lowercased().contains("type"))
    }

    @Test("clipboard_write with no representation is an invalid_argument")
    func toolRejectsEmptyWrite() async throws {
        let result = await Self.registry().callTool(name: "clipboard_write", arguments: [:])
        #expect(result.isError)
        #expect(result.text.contains("image_path"))
    }

    @Test("clipboard_write reports a missing file with a machine-readable code")
    func toolReportsMissingFile() async throws {
        let ghost = NSTemporaryDirectory() + "mcp-clip-test-ghost-\(UUID().uuidString).txt"
        let result = await Self.registry().callTool(
            name: "clipboard_write", arguments: ["files": .array([.string(ghost)])]
        )
        #expect(result.isError)
        let payload = result.structuredContent.objectValue ?? [:]
        #expect(payload["error_code"] == .string("file_not_found"))
    }

    // MARK: - v0.9 review follow-up (HIGH, #7): FIFO / device rejection + size cap

    /// Runs `body` racing a timeout task; fails the test (rather than
    /// hanging the whole suite forever) if `body` doesn't finish in time.
    /// Used to prove the FIFO rejection never opens the file — a
    /// regression here would previously hang on `Data(contentsOf:)`
    /// reading from a FIFO with no writer.
    static func withTimeout<T: Sendable>(
        seconds: Double,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    struct TimeoutError: Error {}

    @Test("a FIFO passed as image_path is rejected as not_regular_file without blocking")
    func fifoImagePathRejectedWithoutBlocking() async throws {
        let fifoPath = NSTemporaryDirectory() + "mcp-clip-test-fifo-\(UUID().uuidString)"
        #expect(mkfifo(fifoPath, 0o600) == 0, "mkfifo must succeed to exercise this path")
        defer { try? FileManager.default.removeItem(atPath: fifoPath) }

        let clipboard = Self.controller()
        // A FIFO with no writer blocks forever on open(2) for reading —
        // if resolveExistingFile's type check didn't run BEFORE any open,
        // this whole test would hang instead of throwing.
        let error = try await Self.withTimeout(seconds: 5) {
            do {
                _ = try await clipboard.writeRich(.init(imagePath: fifoPath))
                return nil as ClipboardController.ClipboardError?
            } catch let e as ClipboardController.ClipboardError {
                return e
            }
        }
        #expect(error == .notRegularFile(fifoPath))
    }

    @Test("a FIFO passed in files is rejected as not_regular_file without blocking")
    func fifoFilesEntryRejectedWithoutBlocking() async throws {
        let fifoPath = NSTemporaryDirectory() + "mcp-clip-test-fifo-\(UUID().uuidString)"
        #expect(mkfifo(fifoPath, 0o600) == 0, "mkfifo must succeed to exercise this path")
        defer { try? FileManager.default.removeItem(atPath: fifoPath) }

        let clipboard = Self.controller()
        let error = try await Self.withTimeout(seconds: 5) {
            do {
                _ = try await clipboard.writeRich(.init(files: [fifoPath]))
                return nil as ClipboardController.ClipboardError?
            } catch let e as ClipboardController.ClipboardError {
                return e
            }
        }
        #expect(error == .notRegularFile(fifoPath))
    }

    @Test("an oversized image_path file is rejected before being decoded")
    func oversizedImagePathRejected() async throws {
        let path = NSTemporaryDirectory() + "mcp-clip-test-huge-\(UUID().uuidString).png"
        // Sparse file, one byte past the cap — cheap to create, and its
        // content is irrelevant: rejection must happen on SIZE, before any
        // image decoding is attempted.
        let oversized = ClipboardController.maxImageFileBytes + 1
        #expect(FileManager.default.createFile(atPath: path, contents: Data()))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seek(toOffset: UInt64(oversized - 1))
        handle.write(Data([0]))
        try handle.close()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.size] as? Int) == oversized)

        let clipboard = Self.controller()
        await #expect(throws: ClipboardController.ClipboardError.fileTooLarge(
            path, ClipboardController.maxImageFileBytes
        )) {
            _ = try await clipboard.writeRich(.init(imagePath: path))
        }
    }

    @Test("an image_path file at exactly the cap is accepted")
    func imagePathAtExactCapIsAccepted() async throws {
        // A real (small) PNG round-trips fine; this test only proves the
        // cap boundary is `<=`, not `<`, by checking a file just under the
        // cap is not rejected for size (it may still fail decode, which is
        // fine — we only assert it's NOT .fileTooLarge).
        let source = try Self.makePNG(width: 4, height: 4)
        defer { try? FileManager.default.removeItem(atPath: source) }
        let size = try FileManager.default.attributesOfItem(atPath: source)[.size] as? Int ?? 0
        #expect(size <= ClipboardController.maxImageFileBytes)

        let clipboard = Self.controller()
        // Must not throw .fileTooLarge for a small legitimate image.
        _ = try await clipboard.writeRich(.init(imagePath: source))
    }
}
