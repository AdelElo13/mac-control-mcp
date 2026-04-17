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

    /// Capture → run async body → restore, with the restore guaranteed to
    /// complete synchronously before the caller sees the body's return
    /// value. Both success and thrown-error paths restore.
    ///
    /// Previously callers used `defer { Task { @MainActor in restore(...) } }`,
    /// which is fire-and-forget — Codex review v2 flagged that a caller could
    /// observe a cleared clipboard if the next pasteboard operation beat the
    /// detached Task to the main actor. Using this helper eliminates that race.
    ///
    /// `nonisolated` + `@Sendable` on the closure lets actor callers use it
    /// without tripping strict-concurrency sending-value errors; the capture/
    /// restore calls internally hop to MainActor via `MainActor.run`.
    ///
    /// NOTE: `@Sendable` only requires that captured values be Sendable. It
    /// does NOT prevent capturing actor references (actors are themselves
    /// Sendable). Callers must still avoid mutating per-actor state inside
    /// the closure through those references in ways that would not compose
    /// correctly with the surrounding actor's isolation. Today our two
    /// callers — AccessibilityController.pasteTextViaClipboard and
    /// FileDialogController.setPath — only invoke nonisolated methods on
    /// `self` inside the closure, so the call-site discipline is sound.
    nonisolated static func withSnapshot<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        let snapshot = await MainActor.run { capture() }
        do {
            let result = try await body()
            await MainActor.run { restore(snapshot) }
            return result
        } catch {
            await MainActor.run { restore(snapshot) }
            throw error
        }
    }
}
