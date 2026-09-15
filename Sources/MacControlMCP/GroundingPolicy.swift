import Foundation
import CoreGraphics

/// v0.10 A5: pure selection policy for AX and OCR candidates.
enum GroundingPolicy {
    struct Node {
        let role: String?
        let title: String?
        let value: String?
        let description: String?
        let bounds: CGRect
    }

    struct Match: Sendable {
        let field: String
        let label: String
        let confidence: Double
    }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "…", with: "...")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func match(_ node: Node, target: String, displays: [CGRect]) -> Match? {
        // v0.10 A5: a display bounding union includes invisible gaps between monitors.
        let frame = node.bounds
        guard !["AXWindow", "AXSheet", "AXApplication", "AXScrollArea"].contains(node.role),
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width >= 2, frame.height >= 2,
              displays.contains(where: { $0.intersects(frame) }) else { return nil }
        let needle = normalize(target)
        guard !needle.isEmpty else { return nil }
        var best: Match?
        for (field, label) in [("title", node.title), ("value", node.value), ("description", node.description)] {
            guard let label else { continue }
            let text = normalize(label)
            guard text.contains(needle) else { continue }
            let candidate = Match(field: field, label: label, confidence: text == needle ? 1 : 0.6)
            if candidate.confidence > (best?.confidence ?? 0) { best = candidate }
        }
        return best
    }

    static func ranked(_ candidates: [GroundingController.Candidate]) -> [GroundingController.Candidate] {
        let sorted = candidates.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            let left = $0.bounds.map { $0.width * $0.height } ?? .infinity
            let right = $1.bounds.map { $0.width * $0.height } ?? .infinity
            return left < right
        }
        // v0.10 B5: accurate and fast passes often see the same box; those
        // are one target, not independent alternatives.
        var unique: [GroundingController.Candidate] = []
        for candidate in sorted {
            let duplicate = candidate.source == "ocr" && unique.contains { prior in
                guard prior.source == "ocr", normalize(prior.title ?? "") == normalize(candidate.title ?? ""),
                      let a = prior.bounds, let b = candidate.bounds else { return false }
                let intersection = CGRect(x: a.x, y: a.y, width: a.width, height: a.height)
                    .intersection(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
                return !intersection.isNull && intersection.width * intersection.height
                    >= 0.5 * min(a.width * a.height, b.width * b.height)
            }
            if !duplicate { unique.append(candidate) }
        }
        return unique
    }

    static func ocrConfidence(text: String, target: String, recognition: Double, distance: Double?) -> Double {
        let exact = normalize(text) == normalize(target)
        let score = min(exact ? 0.9 : 0.6, max(0, recognition))
        // v0.10 A5: disagreement with a stronger spatial candidate is evidence
        // against an OCR substring, not another reason to call it certain.
        let penalty = distance.map { 1 / (1 + max(0, $0) / 150) } ?? 1
        return score * penalty
    }

    /// v0.10 B5 review: exact AX ties are already ranked by area. OCR
    /// cannot improve that winner and would add a complete capture/recognition pass.
    static func prefersAX(_ rankedCandidates: [GroundingController.Candidate]) -> Bool {
        guard let best = rankedCandidates.first else { return false }
        return best.confidence == 1 || rankedCandidates.count == 1
            || best.confidence > rankedCandidates[1].confidence
    }
}
