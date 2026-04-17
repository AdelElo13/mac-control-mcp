import Foundation
import ApplicationServices
import AppKit

/// Automation for standard macOS Open/Save dialogs.
///
/// Strategy: open dialogs use the "Go to folder" mechanism (Cmd+Shift+G)
/// to accept a typed path and a follow-up Return to commit. For in-list
/// selection we query the sheet's AXOutline/AXTable and match by title.
actor FileDialogController {
    struct Result: Codable, Sendable {
        let success: Bool
        let detail: String
    }

    /// Type a path into the frontmost save/open dialog. On success the
    /// dialog's text field has the path and the dialog is ready for a
    /// confirm call (or another selection).
    func setPath(_ path: String) async -> Result {
        // Cmd+Shift+G opens the "Go to folder" sheet on all macOS file dialogs.
        pressShortcut(key: 5 /* g */, flags: [.maskCommand, .maskShift])
        try? await Task.sleep(nanoseconds: 250_000_000)

        // Snapshot the full pasteboard state (all items, all types) so we
        // can restore it even if something goes wrong mid-flow. Previously
        // only plain text was captured and an early `return Result(...)`
        // on setString failure leaked the cleared clipboard.
        let snapshot = await MainActor.run { PasteboardSnapshot.capture() }
        defer {
            Task { @MainActor in PasteboardSnapshot.restore(snapshot) }
        }

        let setOK = await MainActor.run { () -> Bool in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(path, forType: .string)
        }
        guard setOK else {
            return Result(success: false, detail: "Pasteboard refused the path.")
        }

        pressShortcut(key: 9 /* v */, flags: [.maskCommand])
        try? await Task.sleep(nanoseconds: 200_000_000)
        // Confirm the "Go to folder" sheet
        pressShortcut(key: 36 /* return */, flags: [])
        try? await Task.sleep(nanoseconds: 250_000_000)

        return Result(success: true, detail: "Navigated to \(path).")
    }

    /// Confirm the dialog by pressing Return — equivalent to clicking the
    /// default button (Open/Save).
    func confirm() -> Result {
        pressShortcut(key: 36 /* return */, flags: [])
        return Result(success: true, detail: "Return pressed.")
    }

    /// Cancel the dialog by pressing Escape.
    func cancel() -> Result {
        pressShortcut(key: 53 /* escape */, flags: [])
        return Result(success: true, detail: "Escape pressed.")
    }

    /// Select a file or folder in the dialog's list by matching its title.
    /// Walks the focused window's AX tree looking for AXOutline/AXTable rows.
    func selectItem(named title: String) -> Result {
        guard let window = focusedWindow() else {
            return Result(success: false, detail: "No focused window.")
        }
        guard let row = findRow(in: window, titled: title) else {
            return Result(success: false, detail: "Row '\(title)' not found.")
        }
        let pressStatus = AXUIElementPerformAction(row, kAXPressAction as CFString)
        if pressStatus == .success {
            return Result(success: true, detail: "Row '\(title)' pressed.")
        }
        // Fallback: set AXSelected = true
        let selStatus = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        if selStatus == .success {
            return Result(success: true, detail: "Row '\(title)' selected.")
        }
        return Result(success: false, detail: "AX press+select both failed on row '\(title)'.")
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
        Thread.sleep(forTimeInterval: 0.015)
        up.post(tap: .cghidEventTap)
    }

    private func focusedWindow() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedWindowAttribute as CFString, &focused)
        guard status == .success, let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    private func findRow(in root: AXUIElement, titled title: String) -> AXUIElement? {
        var visited = Set<UInt>()
        return searchRow(element: root, target: title.lowercased(), visited: &visited, depth: 0)
    }

    private func searchRow(element: AXUIElement, target: String, visited: inout Set<UInt>, depth: Int) -> AXUIElement? {
        guard depth < 20 else { return nil }
        let key = UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque())
        guard visited.insert(key).inserted else { return nil }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        if role == "AXRow" || role == "AXStaticText" || role == "AXTextField" {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            let candidate = (titleRef as? String)?.lowercased()
                ?? (stringChild(element, attribute: kAXValueAttribute as CFString) ?? "").lowercased()
            if candidate == target || (candidate.contains(target) && !target.isEmpty) {
                return role == "AXRow" ? element : findAncestorRow(from: element)
            }
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        if let array = childrenRef as? [AXUIElement] {
            for child in array {
                if let hit = searchRow(element: child, target: target, visited: &visited, depth: depth + 1) {
                    return hit
                }
            }
        }
        return nil
    }

    private func findAncestorRow(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var steps = 0
        while let e = current, steps < 10 {
            var parentRef: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parentRef)
            guard let raw = parentRef, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            let parent = unsafeDowncast(raw, to: AXUIElement.self)

            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXRow" { return parent }
            current = parent
            steps += 1
        }
        return nil
    }

    private func stringChild(_ element: AXUIElement, attribute: CFString) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute, &ref)
        return ref as? String
    }
}
