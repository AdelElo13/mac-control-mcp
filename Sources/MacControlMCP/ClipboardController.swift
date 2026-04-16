import Foundation
import AppKit

actor ClipboardController {
    struct ReadResult: Codable, Sendable {
        let text: String?
        let types: [String]
    }

    /// Read the plain-text clipboard contents and the list of all available
    /// pasteboard types for the frontmost item.
    func read() -> ReadResult {
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types?.map { $0.rawValue } ?? []
        let text = pasteboard.string(forType: .string)
        return ReadResult(text: text, types: types)
    }

    /// Replace the clipboard with the given text. Returns true on success.
    @discardableResult
    func write(text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// Clear the clipboard.
    func clear() {
        NSPasteboard.general.clearContents()
    }
}
