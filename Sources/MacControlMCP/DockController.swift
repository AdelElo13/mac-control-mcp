import Foundation
import ApplicationServices
import AppKit

/// Dock interaction: enumerate + click items.
///
/// The Dock exposes itself via AX under `com.apple.dock`. Its main element
/// is an `AXList` whose children are `AXDockItem`s — each one's title is
/// the app/folder/file name. We fetch that list by walking the Dock's AX
/// tree and expose click-by-name via `AXPress`.
///
/// Why not just `open -a <name>.app`? Because Dock can contain folders
/// (Downloads stack), documents, and "recent apps" items that aren't
/// bound to a .app. Clicking the dock item triggers the exact UX a user
/// would get, including stack-folder grid popovers.
actor DockController {

    public struct DockItem: Codable, Sendable {
        public let title: String
        public let role: String        // "AXDockItem" for most
        public let subrole: String?    // "AXApplicationDockItem", "AXFolderDockItem", etc.
        public let isRunning: Bool?
    }

    public struct ListResult: Codable, Sendable {
        public let ok: Bool
        public let items: [DockItem]
        public let error: String?
    }

    public struct ClickResult: Codable, Sendable {
        public let ok: Bool
        public let title: String
        public let method: String
        public let error: String?
    }

    func listItems() -> ListResult {
        let dockPID = pidForBundle("com.apple.dock")
        guard let pid = dockPID else {
            return ListResult(ok: false, items: [],
                              error: "Dock process not running (unusual) — cannot read dock items")
        }
        let dockApp = AXUIElementCreateApplication(pid)
        // Walk down to the AXList that actually contains the dock items.
        // Tree: AXApplication → AXList (contents) → AXDockItem children.
        guard let list = firstChild(of: dockApp, matching: "AXList") else {
            return ListResult(ok: false, items: [], error: "Dock has no AXList child")
        }
        var raw: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &raw)
        guard res == .success, let children = raw as? [AXUIElement] else {
            return ListResult(ok: false, items: [], error: "could not read Dock AXList children (AXError=\(res.rawValue))")
        }
        var items: [DockItem] = []
        for child in children {
            let title = axString(child, kAXTitleAttribute) ?? "(untitled)"
            let role = axString(child, kAXRoleAttribute) ?? "AXDockItem"
            let subrole = axString(child, kAXSubroleAttribute)
            let running = axBool(child, "AXIsApplicationRunning")
            items.append(.init(title: title, role: role, subrole: subrole, isRunning: running))
        }
        return ListResult(ok: true, items: items, error: nil)
    }

    /// Click the Dock item with the given title. Matching is
    /// case-insensitive substring — "safari" matches "Safari", "slack"
    /// matches "Slack Beta" etc. First match wins.
    func clickItem(title: String) -> ClickResult {
        let listResult = listItems()
        guard listResult.ok else {
            return ClickResult(ok: false, title: title, method: "ax_press",
                               error: listResult.error ?? "could not list dock items")
        }
        guard let pid = pidForBundle("com.apple.dock") else {
            return ClickResult(ok: false, title: title, method: "ax_press",
                               error: "Dock process not running")
        }
        let dockApp = AXUIElementCreateApplication(pid)
        guard let list = firstChild(of: dockApp, matching: "AXList") else {
            return ClickResult(ok: false, title: title, method: "ax_press",
                               error: "Dock AXList not found")
        }
        var raw: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &raw)
        guard let children = raw as? [AXUIElement] else {
            return ClickResult(ok: false, title: title, method: "ax_press",
                               error: "Dock children unreadable")
        }
        let query = title.lowercased()
        let matching = children.first(where: {
            (axString($0, kAXTitleAttribute) ?? "").lowercased().contains(query)
        })
        guard let target = matching else {
            return ClickResult(ok: false, title: title, method: "ax_press",
                               error: "no Dock item matches '\(title)'")
        }
        let actual = axString(target, kAXTitleAttribute) ?? title
        let pressResult = AXUIElementPerformAction(target, kAXPressAction as CFString)
        return ClickResult(
            ok: pressResult == .success,
            title: actual,
            method: "ax_press",
            error: pressResult == .success ? nil : "AXPress failed (AXError=\(pressResult.rawValue))"
        )
    }

    // MARK: - Helpers

    private func pidForBundle(_ bundleID: String) -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID })?.processIdentifier
    }

    private func firstChild(of element: AXUIElement, matching role: String) -> AXUIElement? {
        var raw: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        guard res == .success, let children = raw as? [AXUIElement] else { return nil }
        for c in children {
            if axString(c, kAXRoleAttribute) == role { return c }
        }
        return nil
    }

    private func axString(_ element: AXUIElement, _ attr: String) -> String? {
        var raw: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(element, attr as CFString, &raw)
        guard res == .success else { return nil }
        return raw as? String
    }

    private func axBool(_ element: AXUIElement, _ attr: String) -> Bool? {
        var raw: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(element, attr as CFString, &raw)
        guard res == .success else { return nil }
        return (raw as? NSNumber)?.boolValue
    }
}
