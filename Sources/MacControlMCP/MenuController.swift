import Foundation
import ApplicationServices

actor MenuController {
    struct Result: Codable, Sendable {
        let success: Bool
        let clickedPath: [String]
        let missingSegment: String?
    }

    /// Click a menu item specified as a path of titles. For example
    /// `clickPath(pid: pid, path: ["File", "Export", "PDF..."])` walks the
    /// menubar structure and invokes AXPress on each item in turn. Submenus
    /// are expanded via AXPress on their parent menu item.
    func clickPath(pid: pid_t, path: [String]) -> Result {
        guard !path.isEmpty else {
            return Result(success: false, clickedPath: [], missingSegment: "(empty path)")
        }

        let appElement = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
            let raw = menuBarRef,
            CFGetTypeID(raw) == AXUIElementGetTypeID()
        else {
            return Result(success: false, clickedPath: [], missingSegment: path.first)
        }
        var current = unsafeDowncast(raw, to: AXUIElement.self)

        var clicked: [String] = []
        for (i, segment) in path.enumerated() {
            guard let item = findChild(of: current, titled: segment) else {
                return Result(success: false, clickedPath: clicked, missingSegment: segment)
            }

            _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
            clicked.append(segment)

            // For all but the last segment, walk into the child menu container.
            if i < path.count - 1 {
                if let child = childMenu(of: item) {
                    current = child
                } else {
                    return Result(success: false, clickedPath: clicked, missingSegment: segment)
                }
            }
        }

        return Result(success: true, clickedPath: clicked, missingSegment: nil)
    }

    /// Enumerate top-level menubar titles for an app — useful for discovery
    /// before calling clickPath.
    func topLevelTitles(pid: pid_t) -> [String] {
        let appElement = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
            let raw = menuBarRef,
            CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return [] }

        let bar = unsafeDowncast(raw, to: AXUIElement.self)
        var childrenRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
            let array = childrenRef as? [AXUIElement]
        else { return [] }

        return array.compactMap { child in
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
            return titleRef as? String
        }
    }

    private func findChild(of parent: AXUIElement, titled title: String) -> AXUIElement? {
        var childrenRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &childrenRef) == .success,
            let array = childrenRef as? [AXUIElement]
        else { return nil }

        let target = title.lowercased()
        for child in array {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
            if let candidate = titleRef as? String, candidate.lowercased() == target {
                return child
            }
        }
        // Substring fallback — menus sometimes include trailing "…" or shortcuts
        for child in array {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
            if let candidate = titleRef as? String,
               candidate.lowercased().contains(target) {
                return child
            }
        }
        return nil
    }

    private func childMenu(of item: AXUIElement) -> AXUIElement? {
        var childrenRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &childrenRef) == .success,
            let array = childrenRef as? [AXUIElement]
        else { return nil }

        for child in array {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            if let role = roleRef as? String, role == "AXMenu" {
                return child
            }
        }
        return nil
    }
}
