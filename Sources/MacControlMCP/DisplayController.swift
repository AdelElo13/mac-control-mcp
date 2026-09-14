import Foundation
import CoreGraphics
import AppKit

/// Multi-display enumeration and coordinate conversion.
actor DisplayController {
    struct DisplayInfo: Codable, Sendable {
        let id: UInt32
        let index: Int
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let scale: Double
        let main: Bool
    }

    func list() -> [DisplayInfo] {
        var activeCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &activeCount)
        guard activeCount > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(activeCount))
        var actual: UInt32 = 0
        CGGetActiveDisplayList(activeCount, &ids, &actual)

        let mainID = CGMainDisplayID()
        return ids.enumerated().map { index, id in
            let bounds = CGDisplayBounds(id)
            // Backing scale = real pixels / points. CGDisplayPixelsWide returns
            // POINTS in a HiDPI scaled mode, so px/pt collapsed to 1.0 on every
            // Retina display. The current mode's pixelWidth is the true backing
            // pixel count; divide by the point width for the real scale.
            let scale: Double = {
                guard let mode = CGDisplayCopyDisplayMode(id) else { return 1.0 }
                let pt = Double(mode.width)
                return pt > 0 ? Double(mode.pixelWidth) / pt : 1.0
            }()
            return DisplayInfo(
                id: UInt32(id),
                index: index,
                x: Double(bounds.origin.x),
                y: Double(bounds.origin.y),
                width: Double(bounds.width),
                height: Double(bounds.height),
                scale: scale,
                main: id == mainID
            )
        }
    }

    /// v0.9 (A-11): why a coordinate-space string didn't resolve, so the
    /// caller can report a real `error` + `error_code` + the valid range
    /// instead of a bare `{"ok":false}` (previously both a malformed
    /// space like "displayX" and a syntactically valid but out-of-range
    /// one like "display:5" on a single-display Mac hit the exact same
    /// silent failure).
    enum SpaceError: Error, Sendable, Equatable {
        /// Not "global" and not "display:<int>" at all.
        case malformed(field: String, value: String)
        /// "display:<int>" parsed, but no display has that index.
        case outOfRange(field: String, value: String, index: Int, displayCount: Int)
    }

    /// Convert between coordinate spaces. `from`/`to` accept:
    /// - "global" (default Quartz/AX space, origin top-left of main display)
    /// - "display:<index>" (origin at that display's top-left in points)
    func convert(x: Double, y: Double, from: String, to: String) -> Result<CGPoint, SpaceError> {
        let displays = list()
        switch originFor(space: from, field: "from", displays: displays) {
        case .failure(let e): return .failure(e)
        case .success(let fromOrigin):
            switch originFor(space: to, field: "to", displays: displays) {
            case .failure(let e): return .failure(e)
            case .success(let toOrigin):
                let globalX = fromOrigin.x + x
                let globalY = fromOrigin.y + y
                return .success(CGPoint(x: globalX - toOrigin.x, y: globalY - toOrigin.y))
            }
        }
    }

    private func originFor(space: String, field: String, displays: [DisplayInfo]) -> Result<CGPoint, SpaceError> {
        if space == "global" { return .success(.zero) }
        if space.hasPrefix("display:") {
            let raw = String(space.dropFirst("display:".count))
            if let idx = Int(raw) {
                if idx >= 0, idx < displays.count {
                    return .success(CGPoint(x: displays[idx].x, y: displays[idx].y))
                }
                return .failure(.outOfRange(field: field, value: space, index: idx, displayCount: displays.count))
            }
        }
        return .failure(.malformed(field: field, value: space))
    }
}
