import Foundation
import ApplicationServices
import CoreGraphics
import AppKit

extension AXUIElement: @retroactive @unchecked Sendable {}

actor AccessibilityController {
    struct Point: Codable, Sendable {
        let x: Double
        let y: Double
    }

    struct Size: Codable, Sendable {
        let width: Double
        let height: Double
    }

    struct ElementInfo: Codable, Sendable {
        let role: String?
        let title: String?
        let value: String?
        let position: Point?
        let size: Size?
        let depth: Int?
    }

    struct TypeTextResult: Codable, Sendable {
        let success: Bool
        let strategy: String
    }

    struct AppInfo: Codable, Sendable {
        let pid: Int32
        let name: String
        let bundleIdentifier: String?
        let isActive: Bool
    }

    private let actionableRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXComboBox",
        "AXDisclosureTriangle",
        "AXLink",
        "AXMenuButton",
        "AXPopUpButton",
        "AXRadioButton",
        "AXSecureTextField",
        "AXSlider",
        "AXTextArea",
        "AXTextField"
    ]

    func checkPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func requestPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func listElements(pid: pid_t, maxDepth: Int = 8) -> [ElementInfo] {
        let root = AXUIElementCreateApplication(pid)
        var visited = Set<UInt>()
        var output: [ElementInfo] = []

        _ = walk(element: root, depth: 0, maxDepth: max(1, maxDepth), visited: &visited) { element, depth, role in
            guard self.actionableRoles.contains(role) else { return false }
            output.append(self.buildElementInfo(element: element, depth: depth, cachedRole: role))
            return false
        }

        return output
    }

    func findElement(pid: pid_t, role: String?, title: String?) -> AXUIElement? {
        let root = AXUIElementCreateApplication(pid)
        var visited = Set<UInt>()
        var match: AXUIElement?

        _ = walk(element: root, depth: 0, maxDepth: 20, visited: &visited) { element, _, currentRole in
            let roleMatches: Bool = {
                guard let role, !role.isEmpty else { return true }
                return currentRole.range(of: role, options: [.caseInsensitive]) != nil
            }()

            let titleMatches: Bool = {
                guard let title, !title.isEmpty else { return true }
                let candidate = self.title(for: element) ?? self.stringAttribute(of: element, attribute: kAXValueAttribute as CFString)
                return candidate?.range(of: title, options: [.caseInsensitive]) != nil
            }()

            if roleMatches && titleMatches {
                match = element
                return true
            }

            return false
        }

        return match
    }

    func clickElement(element: AXUIElement) -> Bool {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }

        guard
            let position = pointAttribute(of: element, attribute: kAXPositionAttribute as CFString),
            let size = sizeAttribute(of: element, attribute: kAXSizeAttribute as CFString)
        else {
            return false
        }

        let center = CGPoint(x: position.x + (size.width / 2.0), y: position.y + (size.height / 2.0))
        return click(at: center)
    }

    func click(at point: CGPoint) -> Bool {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
            ),
            let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            )
        else {
            return false
        }

        mouseDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)
        mouseUp.post(tap: .cghidEventTap)
        return true
    }

    func typeText(text: String) -> TypeTextResult {
        if setFocusedElementValue(text) {
            return TypeTextResult(success: true, strategy: "ax_set_value")
        }

        if typeWithUnicodeEvents(text) {
            return TypeTextResult(success: true, strategy: "cg_unicode")
        }

        if pasteTextViaClipboard(text) {
            return TypeTextResult(success: true, strategy: "clipboard_paste")
        }

        return TypeTextResult(success: false, strategy: "none")
    }

    func readValue(element: AXUIElement) -> String? {
        if let value = stringAttribute(of: element, attribute: kAXValueAttribute as CFString) {
            return value
        }

        guard let rawValue = attributeValue(of: element, attribute: kAXValueAttribute as CFString) else {
            return nil
        }

        return String(describing: rawValue)
    }

    func pressKey(keyCode: CGKeyCode, modifiers: [CGEventFlags] = []) -> Bool {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }

        let flags = modifiers.reduce(into: CGEventFlags()) { partialResult, modifier in
            partialResult.formUnion(modifier)
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    func getFocusedApp() -> AppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return AppInfo(
            pid: app.processIdentifier,
            name: app.localizedName ?? "Unknown",
            bundleIdentifier: app.bundleIdentifier,
            isActive: app.isActive
        )
    }

    func listApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular && app.processIdentifier > 0
            }
            .sorted { lhs, rhs in
                (lhs.localizedName ?? "") < (rhs.localizedName ?? "")
            }
            .map { app in
                AppInfo(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? "Unknown",
                    bundleIdentifier: app.bundleIdentifier,
                    isActive: app.isActive
                )
            }
    }

    func getElementInfo(element: AXUIElement) -> ElementInfo {
        buildElementInfo(element: element, depth: nil, cachedRole: nil)
    }

    private func buildElementInfo(element: AXUIElement, depth: Int?, cachedRole: String?) -> ElementInfo {
        let role = cachedRole ?? stringAttribute(of: element, attribute: kAXRoleAttribute as CFString)
        let title = title(for: element)
        let value = stringAttribute(of: element, attribute: kAXValueAttribute as CFString)

        let position = pointAttribute(of: element, attribute: kAXPositionAttribute as CFString).map { point in
            Point(x: Double(point.x), y: Double(point.y))
        }

        let size = sizeAttribute(of: element, attribute: kAXSizeAttribute as CFString).map { size in
            Size(width: Double(size.width), height: Double(size.height))
        }

        return ElementInfo(
            role: role,
            title: title,
            value: value,
            position: position,
            size: size,
            depth: depth
        )
    }

    @discardableResult
    private func walk(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        visited: inout Set<UInt>,
        visitor: (AXUIElement, Int, String) -> Bool
    ) -> Bool {
        guard depth <= maxDepth else { return false }

        let key = UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque())
        guard visited.insert(key).inserted else { return false }

        let role = stringAttribute(of: element, attribute: kAXRoleAttribute as CFString) ?? "AXUnknown"
        if visitor(element, depth, role) {
            return true
        }

        for child in childElements(of: element) {
            if walk(element: child, depth: depth + 1, maxDepth: maxDepth, visited: &visited, visitor: visitor) {
                return true
            }
        }

        return false
    }

    private func title(for element: AXUIElement) -> String? {
        stringAttribute(of: element, attribute: kAXTitleAttribute as CFString)
            ?? stringAttribute(of: element, attribute: kAXDescriptionAttribute as CFString)
            ?? stringAttribute(of: element, attribute: "AXIdentifier" as CFString)
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        guard let rawChildren = attributeValue(of: element, attribute: kAXChildrenAttribute as CFString) else {
            return []
        }

        if let children = rawChildren as? [AXUIElement] {
            return children
        }

        if let children = rawChildren as? NSArray {
            return children.compactMap { $0 as! AXUIElement }
        }

        return []
    }

    private func attributeValue(of element: AXUIElement, attribute: CFString) -> AnyObject? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else { return nil }
        return value
    }

    private func stringAttribute(of element: AXUIElement, attribute: CFString) -> String? {
        guard let value = attributeValue(of: element, attribute: attribute) else { return nil }

        if let string = value as? String {
            return string
        }

        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        return nil
    }

    private func pointAttribute(of element: AXUIElement, attribute: CFString) -> CGPoint? {
        guard let raw = attributeValue(of: element, attribute: attribute) else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(of element: AXUIElement, attribute: CFString) -> CGSize? {
        guard let raw = attributeValue(of: element, attribute: attribute) else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success else { return nil }
        return value as! AXUIElement
    }

    private func setFocusedElementValue(_ text: String) -> Bool {
        guard let focused = focusedElement() else { return false }
        let status = AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, text as CFTypeRef)
        return status == .success
    }

    private func typeWithUnicodeEvents(_ text: String) -> Bool {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            return false
        }

        let characters = Array(text.utf16)
        characters.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func pasteTextViaClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let previousText = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return false
        }

        let pasted = pressKey(keyCode: 9, modifiers: [.maskCommand])
        Thread.sleep(forTimeInterval: 0.05)

        pasteboard.clearContents()
        if let previousText {
            _ = pasteboard.setString(previousText, forType: .string)
        }

        return pasted
    }
}
