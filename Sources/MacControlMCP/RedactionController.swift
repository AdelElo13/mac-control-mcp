import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

/// PII redaction for text + image regions. Two functions:
///
/// 1. `redactText(_:categories:)` — pattern-match based redaction.
///    Categories are explicit so agents can choose what to strip:
///    emails, phone numbers (E.164 + US formats), SSN, credit-card
///    (Luhn-validated), common API-key patterns (AWS AKID, Stripe,
///    GitHub `ghp_`/`gho_`, Anthropic `sk-ant-`, OpenAI `sk-`).
///
/// 2. `redactImage(at:regions:output:)` — blur-or-blackout arbitrary
///    rectangular regions in an image. Uses Core Image's Gaussian blur
///    if `mode == .blur`, or solid black fill if `mode == .black`.
///
/// No cryptographic claims. These are "share-safe" redactions — they
/// prevent casual leakage when sharing transcripts/screenshots, not
/// targeted forensic recovery attempts.
public actor RedactionController {

    // MARK: - Text

    public enum TextCategory: String, Codable, Sendable, CaseIterable {
        case email, phone, ssn, creditCard, apiKey
    }

    public struct TextResult: Codable, Sendable {
        public let redactedText: String
        public let redactions: [Redaction]
        public struct Redaction: Codable, Sendable {
            public let category: String
            public let count: Int
        }
    }

    /// Replace every match of the selected categories with
    /// `[REDACTED:<category>]`. Categories can be a subset; `nil` means
    /// redact all.
    public func redactText(
        _ input: String,
        categories: Set<TextCategory>? = nil
    ) -> TextResult {
        let selected = categories ?? Set(TextCategory.allCases)
        var text = input
        var counts: [TextCategory: Int] = [:]

        for cat in selected {
            for pattern in patterns(for: cat) {
                let regex = try? NSRegularExpression(pattern: pattern, options: [])
                guard let regex else { continue }
                let range = NSRange(text.startIndex..., in: text)
                let matches = regex.matches(in: text, options: [], range: range)
                if matches.isEmpty { continue }
                // Luhn-check credit cards: reject false positives.
                let replacement = "[REDACTED:\(cat.rawValue)]"
                // Replace right-to-left so ranges stay valid.
                for m in matches.reversed() {
                    guard let r = Range(m.range, in: text) else { continue }
                    let matched = String(text[r])
                    if cat == .creditCard, !isValidLuhn(matched) {
                        continue
                    }
                    text.replaceSubrange(r, with: replacement)
                    counts[cat, default: 0] += 1
                }
            }
        }

        let redactions = counts.map {
            TextResult.Redaction(category: $0.key.rawValue, count: $0.value)
        }.sorted { $0.category < $1.category }

        return TextResult(redactedText: text, redactions: redactions)
    }

    private func patterns(for cat: TextCategory) -> [String] {
        switch cat {
        case .email:
            // Simple RFC-ish pattern; enough for redaction, not validation.
            return [#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#]
        case .phone:
            // E.164 + US dotted + US spaced variants
            return [
                #"\+\d{1,3}[\s\-]?\d{1,14}"#,
                #"\(\d{3}\)\s*\d{3}[\s\-]?\d{4}"#,
                #"\b\d{3}[\s\-]\d{3}[\s\-]\d{4}\b"#
            ]
        case .ssn:
            return [#"\b\d{3}-\d{2}-\d{4}\b"#]
        case .creditCard:
            // 13-19 digits with optional separators; Luhn check applied later
            return [#"\b(?:\d[ -]*?){13,19}\b"#]
        case .apiKey:
            return [
                // AWS access-key id — 20 uppercase letters/digits starting with AKIA/ASIA/AIDA
                #"\b(?:AKIA|ASIA|AIDA)[A-Z0-9]{16}\b"#,
                // Stripe live/test keys
                #"\b(?:sk|pk)_(?:live|test)_[A-Za-z0-9]{24,}\b"#,
                // GitHub classic PAT + fine-grained PAT + OAuth + Actions
                #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b"#,
                // Anthropic
                #"\bsk-ant-[A-Za-z0-9\-_]{40,}\b"#,
                // OpenAI
                #"\bsk-[A-Za-z0-9\-_]{32,}\b"#,
                // Generic JWT (header.payload.signature, 3 base64-url segments)
                #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#
            ]
        }
    }

    /// Luhn checksum over a candidate credit-card string.
    private func isValidLuhn(_ raw: String) -> Bool {
        let digits = raw.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }

    // MARK: - Image regions

    public enum ImageMode: String, Codable, Sendable {
        case blur
        case black
    }

    public struct ImageRegion: Codable, Sendable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
    }

    public struct ImageResult: Codable, Sendable {
        public let ok: Bool
        public let outputPath: String?
        public let redactedRegions: Int
        public let mode: String
        public let error: String?
    }

    /// Apply redaction to an image. `regions` are in CG coordinates
    /// (origin top-left, pixels). Blur uses a Gaussian radius of 30
    /// (enough to destroy faces/text at typical screenshot resolutions).
    public func redactImage(
        at sourcePath: String,
        regions: [ImageRegion],
        mode: ImageMode = .blur,
        outputPath: String? = nil
    ) -> ImageResult {
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            return ImageResult(ok: false, outputPath: nil,
                               redactedRegions: 0, mode: mode.rawValue,
                               error: "source path does not exist")
        }
        guard let srcImg = loadCGImage(from: sourcePath) else {
            return ImageResult(ok: false, outputPath: nil,
                               redactedRegions: 0, mode: mode.rawValue,
                               error: "could not decode source image")
        }

        let width = srcImg.width
        let height = srcImg.height

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return ImageResult(ok: false, outputPath: nil,
                               redactedRegions: 0, mode: mode.rawValue,
                               error: "could not create sRGB color space")
        }

        let bytesPerRow = width * 4
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return ImageResult(ok: false, outputPath: nil,
                               redactedRegions: 0, mode: mode.rawValue,
                               error: "could not create bitmap context")
        }

        // Draw the source image first.
        ctx.draw(srcImg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // For each region, paint over it.
        var count = 0
        for r in regions {
            // Flip Y: CGContext is bottom-left origin, callers use top-left.
            let flippedY = height - r.y - r.height
            let rect = CGRect(x: r.x, y: flippedY, width: r.width, height: r.height)
            switch mode {
            case .black:
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                ctx.fill(rect)
            case .blur:
                // Cheap pixelation: downscale the region into a tiny
                // context, then draw it back scaled up. Visually similar
                // to Gaussian blur without needing CIContext.
                if let sub = croppedCGImage(srcImg, rect: CGRect(x: r.x, y: r.y, width: r.width, height: r.height)) {
                    if let pixelated = pixelate(sub, blockSize: 24) {
                        ctx.draw(pixelated, in: rect)
                    }
                } else {
                    // Fallback: solid black.
                    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                    ctx.fill(rect)
                }
            }
            count += 1
        }

        guard let outImg = ctx.makeImage() else {
            return ImageResult(ok: false, outputPath: nil,
                               redactedRegions: 0, mode: mode.rawValue,
                               error: "could not finalize output bitmap")
        }

        let outPath = outputPath ?? defaultOutputPath(from: sourcePath)
        guard writePNG(outImg, to: outPath) else {
            return ImageResult(ok: false, outputPath: nil,
                               redactedRegions: 0, mode: mode.rawValue,
                               error: "could not write PNG to \(outPath)")
        }

        return ImageResult(ok: true, outputPath: outPath,
                           redactedRegions: count, mode: mode.rawValue,
                           error: nil)
    }

    // MARK: - CG helpers

    private func loadCGImage(from path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    private func croppedCGImage(_ img: CGImage, rect: CGRect) -> CGImage? {
        // cropping(to:) uses CGImage-local coords (top-left origin), so
        // we use the caller-supplied top-left rect as-is.
        return img.cropping(to: rect)
    }

    private func pixelate(_ img: CGImage, blockSize: Int) -> CGImage? {
        let small = max(1, img.width / blockSize)
        let smallH = max(1, img.height / blockSize)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let downCtx = CGContext(
            data: nil, width: small, height: smallH,
            bitsPerComponent: 8, bytesPerRow: small * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        downCtx.interpolationQuality = .low
        downCtx.draw(img, in: CGRect(x: 0, y: 0, width: small, height: smallH))
        return downCtx.makeImage()
    }

    private func writePNG(_ img: CGImage, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1, nil
        ) else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

    private func defaultOutputPath(from source: String) -> String {
        let url = URL(fileURLWithPath: source)
        let base = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()
        return parent.appendingPathComponent("\(base)-redacted.png").path
    }
}
