import Foundation
import AppKit

/// NSPasteboard calls are routed through `MainActor.run` for Swift 6 strict
/// concurrency compliance. In practice NSPasteboard is documented as
/// thread-safe, but the compiler does not know that and the main actor is
/// the canonical AppKit isolation.
actor ClipboardController {
    struct ReadResult: Codable, Sendable {
        let text: String?
        let types: [String]
    }

    /// Read the plain-text clipboard contents and the list of all available
    /// pasteboard types for the frontmost item.
    func read() async -> ReadResult {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            let types = pasteboard.types?.map { $0.rawValue } ?? []
            let text = pasteboard.string(forType: .string)
            return ReadResult(text: text, types: types)
        }
    }

    /// Replace the clipboard with the given text. Returns true on success.
    @discardableResult
    func write(text: String) async -> Bool {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
    }

    /// Clear the clipboard.
    func clear() async {
        await MainActor.run { NSPasteboard.general.clearContents() }
    }
}
