import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// v0.7.0 A1 — image-size discipline.
///
/// Problem: agents that consume inline base64 screenshots can blow past
/// Claude's context-size limits (documented in claude-code issues
/// #13383, #45785). Solution: default screenshot tools to returning a
/// `content_ref` path + sha256 hash; let the agent opt-in to inline
/// base64 via `inline=true`.
///
/// Artifacts live under `~/.mac-control-mcp/artifacts/` with content-
/// addressed names (`<hash>.<ext>`). TTL is 1 hour; expired artifacts
/// are GC'd on every new write. Agents that need to retrieve bytes
/// can still `Read` the path directly.
actor ArtifactStore {

    struct StoredArtifact: Codable, Sendable {
        let contentRef: String        // absolute path
        let bytes: Int
        let sha256: String
        let mimeType: String
        let schema: String            // e.g. "mac-control-mcp.image.v1"
    }

    private let dir: URL
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 3600) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.dir = home
            .appendingPathComponent(".mac-control-mcp", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
        self.ttl = ttl
    }

    /// Copy `sourcePath` into the content-addressed store. Returns a
    /// stable ref. If `maxBytes` / `maxDimension` are set, the image is
    /// downscaled first (PNG only; other formats pass through).
    func storeImage(
        sourcePath: String,
        maxBytes: Int? = 4 * 1024 * 1024,   // 4 MB default
        maxDimension: Int? = 4000           // 4000 px default
    ) -> StoredArtifact? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        gcExpired()

        // Load to memory
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)),
              !data.isEmpty else { return nil }

        var outData = data
        var mime = "image/png"

        // Downscale if needed (PNG only; we don't re-encode JPEG/HEIF).
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
           let _ = props[kCGImagePropertyPixelWidth as String] as? Int {
            let maxDim = maxDimension ?? 10_000
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDim,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let scaled = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) {
                let mdata = NSMutableData()
                if let dest = CGImageDestinationCreateWithData(
                    mdata as CFMutableData,
                    UTType.png.identifier as CFString, 1, nil
                ) {
                    CGImageDestinationAddImage(dest, scaled, nil)
                    if CGImageDestinationFinalize(dest) {
                        outData = mdata as Data
                        mime = "image/png"
                    }
                }
            }
        }

        // Byte-size cap enforcement (after downscale). If still oversized,
        // return nil — the caller can request a smaller dimension or opt
        // into inline with a warning.
        if let maxBytes, outData.count > maxBytes {
            return nil
        }

        // Content-addressed write.
        let hash = Self.sha256Hex(outData)
        let ext = (sourcePath as NSString).pathExtension.isEmpty
            ? "png" : (sourcePath as NSString).pathExtension
        let outURL = dir.appendingPathComponent("\(hash).\(ext)")
        if !FileManager.default.fileExists(atPath: outURL.path) {
            try? outData.write(to: outURL, options: .atomic)
        }
        return StoredArtifact(
            contentRef: outURL.path,
            bytes: outData.count,
            sha256: hash,
            mimeType: mime,
            schema: "mac-control-mcp.image.v1"
        )
    }

    /// Delete expired artifacts.  Called on every write; also exposed as
    /// a tool so agents can force a sweep.
    func gcExpired() {
        let cutoff = Date().addingTimeInterval(-ttl)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in entries {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = attrs?[.modificationDate] as? Date ?? Date.distantPast
            if mtime < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - SHA256

    private static func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            CC_SHA256(base, UInt32(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// Bridge CommonCrypto without adding a separate import at module scope.
@_silgen_name("CC_SHA256")
private func CC_SHA256(_ data: UnsafeRawPointer?, _ len: UInt32,
                       _ md: UnsafeMutablePointer<UInt8>?) -> UnsafeMutablePointer<UInt8>?
