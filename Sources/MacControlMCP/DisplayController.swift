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
            // Pixel dimensions vs point dimensions — scale factor = px/pt
            let pixelWidth = Double(CGDisplayPixelsWide(id))
            let scale = pixelWidth / bounds.width
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

    /// Convert between coordinate spaces. `from`/`to` accept:
    /// - "global" (default Quartz/AX space, origin top-left of main display)
    /// - "display:<index>" (origin at that display's top-left in points)
    func convert(x: Double, y: Double, from: String, to: String) -> CGPoint? {
        let displays = list()
        guard let fromOrigin = originFor(space: from, displays: displays),
              let toOrigin = originFor(space: to, displays: displays)
        else { return nil }

        let globalX = fromOrigin.x + x
        let globalY = fromOrigin.y + y
        return CGPoint(x: globalX - toOrigin.x, y: globalY - toOrigin.y)
    }

    private func originFor(space: String, displays: [DisplayInfo]) -> CGPoint? {
        if space == "global" { return .zero }
        if space.hasPrefix("display:") {
            let idx = Int(space.dropFirst("display:".count))
            if let idx, idx >= 0, idx < displays.count {
                return CGPoint(x: displays[idx].x, y: displays[idx].y)
            }
        }
        return nil
    }
}
