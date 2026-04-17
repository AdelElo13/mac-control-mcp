import Foundation
import CoreGraphics
import AppKit

/// Spotlight automation — open the search bar with Cmd+Space and type a query.
actor SpotlightController {
    /// Search result as reported by Spotlight's own AX tree.
    struct ResultPreview: Codable, Sendable {
        let index: Int
        let title: String
    }

    /// Open Spotlight and type the query, then verify Spotlight is
    /// actually the frontmost receiver of keystrokes before reporting
    /// success.
    ///
    /// Codex v10 HIGH: a previous version always returned true as long
    /// as the key events were posted. That's a lie if the user has
    /// remapped Cmd+Space (e.g. to Alfred/Raycast) — we'd then type the
    /// query into whatever app was frontmost, and a later
    /// spotlight_open_result would send Down+Return into that same
    /// wrong app. Now we check Spotlight.app is running and its AX tree
    /// has a visible search/result element before returning success.
    func search(_ query: String) async -> Bool {
        pressShortcut(key: 49 /* space */, flags: [.maskCommand])
        // Spotlight needs a moment to appear. Poll its process +
        // shareable AX tree so we don't type into the wrong app.
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 60_000_000)
            if await spotlightProcessIsVisible() { break }
        }
        guard await spotlightProcessIsVisible() else { return false }
        typeString(query)
        // Result list needs a moment to populate.
        try? await Task.sleep(nanoseconds: 400_000_000)
        return true
    }

    /// True iff Spotlight.app is running AND has at least one visible
    /// AX window — i.e. the search popover is open and keystrokes will
    /// actually land there.
    ///
    /// NSWorkspace is main-actor-affine so we hop there for the
    /// runningApplications lookup (Codex v10 MEDIUM).
    private func spotlightProcessIsVisible() async -> Bool {
        let pid: pid_t = await MainActor.run {
            NSWorkspace.shared.runningApplications.first {
                ($0.bundleIdentifier ?? "").lowercased() == "com.apple.spotlight"
            }?.processIdentifier ?? 0
        }
        guard pid > 0 else { return false }
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }
        return !windows.isEmpty
    }

    /// Peek at Spotlight's current result titles via AX. Returns `[]` if
    /// Spotlight isn't open or AX can't read the list (e.g. permission
    /// missing). Lets a caller assert what 'index 1' will actually open
    /// instead of trusting Spotlight's ranking blindly.
    ///
    /// Spotlight runs inside `Spotlight` (pid from WindowServer list) with
    /// its result table exposed as AXTable → AXRow → AXStaticText.
    func currentResults(limit: Int = 10) async -> [ResultPreview] {
        // Spotlight.app has .accessory activation policy (hidden from
        // runningApplications' default regular-only filter). Iterate ALL
        // running apps and match by bundle ID. NSWorkspace is
        // main-actor-affine so we hop there for the lookup.
        let pid: pid_t = await MainActor.run {
            NSWorkspace.shared.runningApplications.first {
                ($0.bundleIdentifier ?? "").lowercased() == "com.apple.spotlight"
            }?.processIdentifier ?? 0
        }
        guard pid > 0 else { return [] }
        let root = AXUIElementCreateApplication(pid)
        var visited = Set<AXKey>()
        var rawTitles: [String] = []
        collectRowTitles(element: root, depth: 0, maxDepth: 16, visited: &visited, into: &rawTitles, limit: limit * 3)
        // Deduplicate + trim to limit
        var seen = Set<String>()
        var results: [ResultPreview] = []
        for t in rawTitles {
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
            results.append(ResultPreview(index: results.count + 1, title: clean))
            if results.count >= limit { break }
        }
        return results
    }

    private func collectRowTitles(element: AXUIElement, depth: Int, maxDepth: Int,
                                  visited: inout Set<AXKey>, into out: inout [String], limit: Int) {
        guard depth <= maxDepth, out.count < limit else { return }
        guard visited.insert(AXKey(element: element)).inserted else { return }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        // Spotlight's result list uses AXRow per result; each row's title
        // is exposed as the row's AXTitle or as a child AXStaticText.
        if role == "AXRow" {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            if let t = titleRef as? String, !t.isEmpty { out.append(t) }
        } else if role == "AXStaticText" {
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
            if let t = valueRef as? String { out.append(t) }
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        if let children = childrenRef as? [AXUIElement] {
            for child in children {
                collectRowTitles(element: child, depth: depth + 1, maxDepth: maxDepth, visited: &visited, into: &out, limit: limit)
                if out.count >= limit { return }
            }
        }
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
