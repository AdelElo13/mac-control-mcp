import Foundation
import AppKit

/// Capture and restore the entire clipboard — all pasteboard items, every
/// type, not just plain text. Required because FileDialogController and
/// AccessibilityController's paste-fallback both need to clobber the
/// clipboard transiently and then put it back exactly the way it was.
///
/// Design notes:
/// - `NSPasteboardItem` is not itself Sendable, and we need to persist the
///   data across a pasteboard.clearContents() call, so we materialise each
///   item's type→data map into plain values (Data/String) up front.
/// - On restore we rebuild NSPasteboardItem objects from the captured data.
///   This preserves all types including image, file URLs, RTF, etc.
@MainActor
enum PasteboardSnapshot {
    struct Snapshot {
        let items: [[String: Data]]
    }

    static func capture() -> Snapshot {
        let pasteboard = NSPasteboard.general
        var captured: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entry: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type.rawValue] = data
                }
            }
            if !entry.isEmpty { captured.append(entry) }
        }
        return Snapshot(items: captured)
    }

    static func restore(_ snapshot: Snapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var rebuilt: [NSPasteboardItem] = []
        for entry in snapshot.items {
            let item = NSPasteboardItem()
            for (rawType, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            rebuilt.append(item)
        }
        if !rebuilt.isEmpty {
            pasteboard.writeObjects(rebuilt)
        }
    }
}
