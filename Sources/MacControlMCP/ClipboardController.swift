import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// NSPasteboard calls are routed through `MainActor.run` for Swift 6 strict
/// concurrency compliance. In practice NSPasteboard is documented as
/// thread-safe, but the compiler does not know that and the main actor is
/// the canonical AppKit isolation.
///
/// v0.9 workstream G (gap C-10) — rich clipboard. Before this, a clipboard
/// holding 11 UTIs (`public.rtf`, `public.html`, `com.apple.webarchive`, …)
/// was flattened to plain text on read, and only plain text could be
/// written. Copy-an-image-and-paste-it and put-a-file-on-the-clipboard are
/// routine agent workflows; both are now first-class. The plain-text paths
/// (`read()` / `write(text:)`) are untouched so `clipboard_read` /
/// `clipboard_write` stay backward compatible when no `type` is given.
///
/// Everything that touches the filesystem (loading the image to write,
/// writing the PNG that a read produces) happens OFF the main actor; the
/// main-actor hop is kept to the NSPasteboard access itself.
actor ClipboardController {
    struct ReadResult: Codable, Sendable {
        let text: String?
        let types: [String]
    }

    /// Which pasteboard this controller talks to. `nil` (the default, and
    /// the only value production uses) means `NSPasteboard.general` — the
    /// user's real clipboard.
    ///
    /// Tests pass a private name instead. Two reasons: the general
    /// pasteboard is a single global resource, so clipboard tests running
    /// concurrently with ANY other suite that copies text (ToolRegistryV2's
    /// round-trip, the AX paste fallback, the file-dialog path) clobber
    /// each other — that flake was real and caught here — and a private
    /// board means `swift test` cannot disturb whatever the developer has
    /// on their clipboard at all.
    private let pasteboardName: NSPasteboard.Name?

    /// Test seam for the two-phase write. `NSPasteboard.writeObjects`
    /// returning false cannot be provoked from outside AppKit, so the
    /// only way to exercise the "restore the user's clipboard after a
    /// failed write" path is to inject the failure. Production never sets
    /// this (`.none`).
    enum WriteFailureSimulation: Sendable {
        case none
        /// Fail the private dry run — the real board must not be touched.
        case dryRun
        /// Fail the real write — the pre-write snapshot must be restored.
        case realWrite
    }

    private let writeFailureSimulation: WriteFailureSimulation

    init(
        pasteboardName: NSPasteboard.Name? = nil,
        writeFailureSimulation: WriteFailureSimulation = .none
    ) {
        self.pasteboardName = pasteboardName
        self.writeFailureSimulation = writeFailureSimulation
    }

    @MainActor
    private static func board(_ name: NSPasteboard.Name?) -> NSPasteboard {
        guard let name else { return .general }
        return NSPasteboard(name: name)
    }

    // MARK: - Rich types

    /// What `clipboard_read(type:)` should return.
    enum ReadKind: String, Sendable, CaseIterable {
        case text
        case rtf
        case html
        case image
        case files
        /// Every available UTI with its byte size, plus whatever flavours
        /// happen to be cheap to decode. The inventory call.
        case all

        static func parse(_ raw: String?) -> ReadKind? {
            guard let raw, !raw.isEmpty else { return .text }
            return ReadKind(rawValue: raw.lowercased())
        }

        static var allNames: String {
            allCases.map(\.rawValue).joined(separator: ", ")
        }
    }

    struct TypeInfo: Sendable, Equatable {
        let uti: String
        /// nil when the representation was deliberately NOT copied to be
        /// measured (see `isBulkType`) — `large` says so explicitly.
        let bytes: Int?
        /// Bulk payload: an image/video/audio/archive flavour, or a blob
        /// that turned out to be at least `bulkThresholdBytes`.
        let large: Bool

        init(uti: String, bytes: Int?, large: Bool) {
            self.uti = uti
            self.bytes = bytes
            self.large = large
        }
    }

    /// At or above this, a representation is reported as `large`.
    static let bulkThresholdBytes = 1_048_576

    /// Should `type=all` refuse to copy this representation just to
    /// measure it?
    ///
    /// NSPasteboard has no size API — `data(forType:)` is the only way to
    /// learn a length, and it copies the whole payload across. For an
    /// inventory call that is a terrible trade on image/video/archive
    /// flavours: copying 40 MB of TIFF to print a number stalls the tool
    /// and buys nothing. Those are reported as `{bytes: null, large: true}`
    /// and never materialised; ask for `type="image"` to actually get the
    /// bytes.
    ///
    /// Classification is by UTI conformance where the system knows the
    /// type, plus a small list of legacy AppKit pasteboard names (which
    /// are not registered UTIs at all, so `UTType` cannot see them).
    static func isBulkType(_ rawType: String) -> Bool {
        if legacyBulkTypeNames.contains(rawType) { return true }
        guard let type = UTType(rawType) else { return false }
        for bulk in [UTType.image, .movie, .audio, .archive, .pdf, .webArchive, .font]
        where type.conforms(to: bulk) {
            return true
        }
        return false
    }

    private static let legacyBulkTypeNames: Set<String> = [
        "Apple PNG pasteboard type",
        "Apple PDF pasteboard type",
        "NeXT TIFF v4.0 pasteboard type",
        "NeXT Encapsulated PostScript v1.2 pasteboard type",
        "com.apple.webarchive"
    ]

    struct ImagePayload: Sendable, Equatable {
        /// Absolute path of the PNG written for this read (nil only when
        /// the caller asked for inline bytes and no file was requested —
        /// today we always write the file, so this is always set).
        let path: String?
        let width: Int
        let height: Int
        let bytes: Int
        let base64: String?
    }

    struct RichReadResult: Sendable {
        let kind: String
        let types: [String]
        var text: String? = nil
        var rtf: String? = nil
        var html: String? = nil
        var image: ImagePayload? = nil
        var files: [String]? = nil
        /// Only populated for `.all`.
        var available: [TypeInfo]? = nil
    }

    /// One or more representations to put on the pasteboard in a single
    /// `clearContents()` transaction. Every field is optional; at least one
    /// must be set.
    struct WriteRequest: Sendable {
        var text: String?
        var html: String?
        var rtf: String?
        var imagePath: String?
        var files: [String]?

        init(
            text: String? = nil,
            html: String? = nil,
            rtf: String? = nil,
            imagePath: String? = nil,
            files: [String]? = nil
        ) {
            self.text = text
            self.html = html
            self.rtf = rtf
            self.imagePath = imagePath
            self.files = files
        }

        var isEmpty: Bool {
            text == nil && html == nil && rtf == nil && imagePath == nil && (files?.isEmpty ?? true)
        }
    }

    struct WriteResult: Sendable, Equatable {
        /// Representation names actually written ("text", "html", "rtf",
        /// "image", "files") — so the caller can see what landed rather
        /// than assuming.
        let wrote: [String]
        /// UTIs present on the pasteboard afterwards.
        let types: [String]
    }

    enum ClipboardError: Error, CustomStringConvertible, Equatable {
        case nothingToWrite
        case fileNotFound(String)
        case unreadableImage(String)
        case imageEncodeFailed
        case noData(String)
        case invalidPath(String)
        case pasteboardRejectedWrite

        var description: String {
            switch self {
            case .nothingToWrite:
                return "clipboard_write needs at least one of: text, html, rtf, image_path, files."
            case .fileNotFound(let p):
                return "No readable file at '\(p)'."
            case .unreadableImage(let p):
                return "'\(p)' is not a decodable image (expected PNG or JPEG)."
            case .imageEncodeFailed:
                return "Failed to encode the pasteboard image as PNG."
            case .noData(let kind):
                return "The clipboard holds no \(kind) representation. Call clipboard_read with type=\"all\" to see what is actually on it."
            case .invalidPath(let detail):
                return detail
            case .pasteboardRejectedWrite:
                return "NSPasteboard rejected the write."
            }
        }
    }

    // MARK: - Plain text (unchanged, v0.1 surface)

    /// Read the plain-text clipboard contents and the list of all available
    /// pasteboard types for the frontmost item.
    func read() async -> ReadResult {
        let name = pasteboardName
        return await MainActor.run {
            let pasteboard = Self.board(name)
            let types = pasteboard.types?.map { $0.rawValue } ?? []
            let text = pasteboard.string(forType: .string)
            return ReadResult(text: text, types: types)
        }
    }

    /// Replace the clipboard with the given text. Returns true on success.
    @discardableResult
    func write(text: String) async -> Bool {
        let name = pasteboardName
        return await MainActor.run {
            let pasteboard = Self.board(name)
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
    }

    /// Clear the clipboard.
    func clear() async {
        let name = pasteboardName
        await MainActor.run { Self.board(name).clearContents() }
    }

    // MARK: - Rich read

    /// Snapshot of the pasteboard data needed for one read, taken in a
    /// single main-actor hop. Only the flavours the requested `kind` needs
    /// are copied — a 40 MB TIFF is not pulled across for a text read.
    private struct RawSnapshot: Sendable {
        var types: [String] = []
        var sizes: [TypeInfo] = []
        var text: String?
        var rtf: Data?
        var html: Data?
        var png: Data?
        var tiff: Data?
        var files: [String] = []
    }

    func readRich(kind: ReadKind, inline: Bool, outputPath: String?) async throws -> RichReadResult {
        let name = pasteboardName
        let raw = await MainActor.run { Self.snapshot(for: kind, on: name) }

        switch kind {
        case .text:
            return RichReadResult(kind: kind.rawValue, types: raw.types, text: raw.text)

        case .rtf:
            guard let data = raw.rtf, let string = Self.decodeText(data) else {
                throw ClipboardError.noData("rtf")
            }
            return RichReadResult(kind: kind.rawValue, types: raw.types, rtf: string)

        case .html:
            guard let data = raw.html, let string = Self.decodeText(data) else {
                throw ClipboardError.noData("html")
            }
            return RichReadResult(kind: kind.rawValue, types: raw.types, html: string)

        case .files:
            guard !raw.files.isEmpty else { throw ClipboardError.noData("file URL") }
            return RichReadResult(kind: kind.rawValue, types: raw.types, files: raw.files)

        case .image:
            let png = try Self.pngData(png: raw.png, tiff: raw.tiff)
            let payload = try Self.writeImagePayload(png, inline: inline, outputPath: outputPath)
            return RichReadResult(kind: kind.rawValue, types: raw.types, image: payload)

        case .all:
            var result = RichReadResult(kind: kind.rawValue, types: raw.types)
            result.text = raw.text
            result.rtf = raw.rtf.flatMap(Self.decodeText)
            result.html = raw.html.flatMap(Self.decodeText)
            result.files = raw.files.isEmpty ? nil : raw.files
            result.available = raw.sizes
            // `all` is an inventory call: it reports that image bytes are
            // present and how big they are, but does not materialise a PNG
            // — ask for type="image" to get the file.
            return result
        }
    }

    @MainActor
    private static func snapshot(for kind: ReadKind, on name: NSPasteboard.Name?) -> RawSnapshot {
        let pasteboard = board(name)
        var raw = RawSnapshot()
        let types = pasteboard.types ?? []
        raw.types = types.map(\.rawValue)

        switch kind {
        case .text:
            raw.text = pasteboard.string(forType: .string)
        case .rtf:
            raw.rtf = pasteboard.data(forType: .rtf)
        case .html:
            raw.html = pasteboard.data(forType: .html)
        case .image:
            raw.png = pasteboard.data(forType: .png)
            if raw.png == nil { raw.tiff = pasteboard.data(forType: .tiff) }
        case .files:
            raw.files = Self.fileURLs(pasteboard)
        case .all:
            raw.text = pasteboard.string(forType: .string)
            raw.rtf = pasteboard.data(forType: .rtf)
            raw.html = pasteboard.data(forType: .html)
            raw.files = Self.fileURLs(pasteboard)
            raw.sizes = types.map { type in
                // Bulk flavours are named, not measured — see isBulkType.
                guard !isBulkType(type.rawValue) else {
                    return TypeInfo(uti: type.rawValue, bytes: nil, large: true)
                }
                let count = pasteboard.data(forType: type)?.count ?? 0
                return TypeInfo(uti: type.rawValue, bytes: count, large: count >= bulkThresholdBytes)
            }
        }
        return raw
    }

    @MainActor
    private static func fileURLs(_ pasteboard: NSPasteboard) -> [String] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return objects.filter(\.isFileURL).map(\.path)
    }

    /// RTF/HTML pasteboard payloads are byte blobs. RTF is 7-bit ASCII with
    /// escapes, HTML is normally UTF-8 — but some apps ship Latin-1 or
    /// UTF-16 HTML, so fall through rather than returning nil and claiming
    /// "no html on the clipboard" when there plainly is some.
    private static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    /// PNG bytes for the clipboard image: pass PNG through untouched,
    /// transcode TIFF (what most macOS apps actually put on the pasteboard
    /// when you copy an image), otherwise report honestly that there is no
    /// image rather than returning an empty file.
    private static func pngData(png: Data?, tiff: Data?) throws -> Data {
        if let png, !png.isEmpty { return png }
        guard let tiff, !tiff.isEmpty,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ClipboardError.noData("image")
        }
        guard let encoded = encodePNG(image) else { throw ClipboardError.imageEncodeFailed }
        return encoded
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Materialise the clipboard image for the caller.
    ///
    /// A file is written when the caller named an `output_path` (validated
    /// by `PathValidator`, same policy as every other client-named output)
    /// or when they did NOT ask for inline bytes — in which case the path
    /// is the only way to hand the image over, and it goes to the
    /// user-scoped temp dir. `inline` with no `output_path` writes nothing
    /// at all: the bytes are already in the response, and a temp file
    /// nobody asked for is just litter.
    private static func writeImagePayload(
        _ png: Data,
        inline: Bool,
        outputPath: String?
    ) throws -> ImagePayload {
        var path: String?
        if let outputPath, !outputPath.isEmpty {
            do {
                path = try PathValidator.validate(outputPath)
            } catch {
                throw ClipboardError.invalidPath(String(describing: error))
            }
        } else if !inline {
            path = NSTemporaryDirectory() + "mcp-clipboard-\(UUID().uuidString).png"
        }

        if let path {
            do {
                try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                throw ClipboardError.invalidPath("Could not write the clipboard image to '\(path)': \(error.localizedDescription)")
            }
        }

        var width = 0
        var height = 0
        if let source = CGImageSourceCreateWithData(png as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            width = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            height = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        }

        return ImagePayload(
            path: path,
            width: width,
            height: height,
            bytes: png.count,
            base64: inline ? png.base64EncodedString() : nil
        )
    }

    // MARK: - Rich write

    /// Replace the clipboard with any combination of text / html / rtf /
    /// image / file URLs, in ONE `clearContents()` transaction so the
    /// pasteboard is never observed half-written.
    ///
    /// Files become their own pasteboard items (that is what Finder and
    /// every file-drop target expect); text/html/rtf/image share a single
    /// multi-representation item, so a paste target picks the richest
    /// flavour it understands.
    @discardableResult
    func writeRich(_ request: WriteRequest) async throws -> WriteResult {
        guard !request.isEmpty else { throw ClipboardError.nothingToWrite }

        // All validation and file I/O happens BEFORE the pasteboard is
        // cleared: a bad path must not leave the user with an empty
        // clipboard.
        var imageRepresentations: [(NSPasteboard.PasteboardType, Data)] = []
        if let imagePath = request.imagePath {
            let resolved = try Self.resolveExistingFile(imagePath)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ClipboardError.unreadableImage(imagePath)
            }
            guard let png = Self.encodePNG(image) else { throw ClipboardError.imageEncodeFailed }
            imageRepresentations.append((.png, png))
            // Many long-lived AppKit apps only read `public.tiff` from the
            // pasteboard, so publish both flavours.
            if let tiff = Self.encodeTIFF(image) {
                imageRepresentations.append((.tiff, tiff))
            }
        }

        var fileURLs: [URL] = []
        for path in request.files ?? [] {
            fileURLs.append(URL(fileURLWithPath: try Self.resolveExistingFile(path)))
        }

        let text = request.text
        let html = request.html
        let rtf = request.rtf
        let images = imageRepresentations
        let urls = fileURLs

        let plan = WritePlan(text: text, html: html, rtf: rtf, images: images, urls: urls)
        let name = pasteboardName
        let simulation = writeFailureSimulation

        let outcome: Result<WriteResult, ClipboardError> = await MainActor.run {
            let pasteboard = Self.board(name)

            // PHASE 1 — dry run on a throwaway private pasteboard.
            //
            // The old code called clearContents() on the REAL board first
            // and only then discovered whether writeObjects succeeded: a
            // rejected write left the user with an EMPTY clipboard and
            // their previous contents gone for good. Proving the
            // representations are acceptable on a scratch board first
            // means the user's clipboard is never destroyed by a write
            // that was never going to land.
            let scratch = NSPasteboard(name: NSPasteboard.Name("com.mac-control-mcp.precheck.\(UUID().uuidString)"))
            defer { scratch.releaseGlobally() }
            let probe = plan.makeObjects()
            guard !probe.objects.isEmpty else { return .failure(.nothingToWrite) }
            scratch.clearContents()
            let probeAccepted = simulation == .dryRun ? false : scratch.writeObjects(probe.objects)
            guard probeAccepted else { return .failure(.pasteboardRejectedWrite) }

            // PHASE 2 — snapshot, then the real write.
            //
            // An NSPasteboardItem belongs to the pasteboard it was
            // written to, so phase 2 builds a FRESH set of objects from
            // the same bytes rather than re-writing the probe's.
            let snapshot = PasteboardSnapshot.capture(from: pasteboard)
            let real = plan.makeObjects()
            pasteboard.clearContents()
            let accepted = simulation == .realWrite ? false : pasteboard.writeObjects(real.objects)
            guard accepted else {
                // Put the user's clipboard back exactly as it was.
                PasteboardSnapshot.restore(snapshot, to: pasteboard)
                return .failure(.pasteboardRejectedWrite)
            }
            return .success(WriteResult(
                wrote: real.wrote,
                types: pasteboard.types?.map(\.rawValue) ?? []
            ))
        }

        switch outcome {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    /// The representations to publish, kept as plain data so a fresh set
    /// of `NSPasteboardItem`s can be minted per pasteboard (an item may
    /// only ever be written to one).
    private struct WritePlan: Sendable {
        let text: String?
        let html: String?
        let rtf: String?
        let images: [(NSPasteboard.PasteboardType, Data)]
        let urls: [URL]

        @MainActor
        func makeObjects() -> (objects: [NSPasteboardWriting], wrote: [String]) {
            var wrote: [String] = []
            var objects: [NSPasteboardWriting] = []

            let item = NSPasteboardItem()
            var itemHasContent = false
            if let text {
                item.setString(text, forType: .string)
                wrote.append("text")
                itemHasContent = true
            }
            if let html, let data = html.data(using: .utf8) {
                item.setData(data, forType: .html)
                wrote.append("html")
                itemHasContent = true
            }
            if let rtf, let data = rtf.data(using: .utf8) {
                item.setData(data, forType: .rtf)
                wrote.append("rtf")
                itemHasContent = true
            }
            for (type, data) in images {
                item.setData(data, forType: type)
                itemHasContent = true
            }
            if !images.isEmpty { wrote.append("image") }
            if itemHasContent { objects.append(item) }

            if !urls.isEmpty {
                objects.append(contentsOf: urls.map { $0 as NSURL })
                wrote.append("files")
            }
            return (objects, wrote)
        }
    }

    private static func encodeTIFF(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.tiff.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Input paths are READ, not written, so `PathValidator.validate`'s
    /// allowed-roots policy (which exists to stop the server overwriting
    /// arbitrary files) does not apply — confining it here would block the
    /// legitimate "put this repo file on the clipboard" case. What IS
    /// enforced: the path must resolve to an existing regular file, with
    /// symlinks and `..` normalised away first.
    private static func resolveExistingFile(_ path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ClipboardError.fileNotFound(path)
        }
        return resolved.path
    }
}
