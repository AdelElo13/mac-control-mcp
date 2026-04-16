import Foundation
import CoreGraphics
import AppKit

/// Spotlight automation — open the search bar with Cmd+Space and type a query.
actor SpotlightController {
    /// Open Spotlight and type the query. Leaves the search popover open for
    /// follow-up `openTopResult()` or the user to act on.
    func search(_ query: String) -> Bool {
        // Cmd+Space opens Spotlight (default hotkey). Users who have remapped
        // this shortcut will need a different approach.
        pressShortcut(key: 49 /* space */, flags: [.maskCommand])
        Thread.sleep(forTimeInterval: 0.3)
        typeString(query)
        return true
    }

    /// Open the top result of an active Spotlight query by pressing Return.
    /// Pass `index` > 1 to press Down arrow (index-1) times first.
    func openResult(index: Int = 1) -> Bool {
        let steps = max(1, index) - 1
        for _ in 0..<steps {
            pressShortcut(key: 125 /* down */, flags: [])
            Thread.sleep(forTimeInterval: 0.05)
        }
        pressShortcut(key: 36 /* return */, flags: [])
        return true
    }

    // MARK: - Helpers

    private func pressShortcut(key: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)
        up.post(tap: .cghidEventTap)
    }

    private func typeString(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let chars = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }
        chars.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
