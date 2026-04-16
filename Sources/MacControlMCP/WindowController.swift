import Foundation
import ApplicationServices
import AppKit

actor WindowController {
    struct WindowInfo: Codable, Sendable {
        let app: String
        let pid: Int32
        let title: String?
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let minimized: Bool
        let main: Bool
        let index: Int
    }

    /// Enumerate all windows of all regular running apps. Windows are ordered
    /// per-app in the AX child order, which approximately matches z-order for
    /// the active app and is stable across calls for inactive apps.
    func listWindows() -> [WindowInfo] {
        var result: [WindowInfo] = []

        for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && app.processIdentifier > 0 {

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var mainWindowRef: CFTypeRef?
            AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindowRef)
            let mainWindow = mainWindowRef.flatMap { raw -> AXUIElement? in
                guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
                return unsafeDowncast(raw, to: AXUIElement.self)
            }

            var windowsRef: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            guard status == .success, let array = windowsRef as? [AXUIElement] else { continue }

            for (index, window) in array.enumerated() {
                let info = describe(
                    window: window,
                    index: index,
                    appName: app.localizedName ?? "Unknown",
                    pid: app.processIdentifier,
                    mainWindow: mainWindow
                )
                result.append(info)
            }
        }

        return result
    }

    /// List windows for a single app by PID. Faster than `listWindows()`
    /// when the caller already knows which app they want.
    func listAppWindows(pid: pid_t) -> [WindowInfo] {
        let appElement = AXUIElementCreateApplication(pid)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown"

        var mainWindowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindowRef)
        let mainWindow = mainWindowRef.flatMap { raw -> AXUIElement? in
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(raw, to: AXUIElement.self)
        }

        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let array = windowsRef as? [AXUIElement] else { return [] }

        return array.enumerated().map { index, window in
            describe(window: window, index: index, appName: name, pid: pid, mainWindow: mainWindow)
        }
    }

    /// Bring a window to the front. Raises the app first, then the window.
    func focusWindow(pid: pid_t, index: Int) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        app.activate(options: [])

        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let array = windowsRef as? [AXUIElement], index < array.count else {
            return false
        }

        let window = array[index]
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        return true
    }

    /// Move the window to an absolute position in global coordinates.
    func moveWindow(pid: pid_t, index: Int, to point: CGPoint) -> Bool {
        guard let window = window(pid: pid, index: index) else { return false }
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        let status = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        return status == .success
    }

    /// Resize a window to the given width/height.
    func resizeWindow(pid: pid_t, index: Int, to size: CGSize) -> Bool {
        guard let window = window(pid: pid, index: index) else { return false }
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        let status = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        return status == .success
    }

    /// Apply a high-level state transition: minimize, unminimize, fullscreen,
    /// exit_fullscreen, main (bring to main).
    func setState(pid: pid_t, index: Int, state: String) -> Bool {
        guard let window = window(pid: pid, index: index) else { return false }
        switch state.lowercased() {
        case "minimize", "minimized":
            return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        case "unminimize", "restore":
            return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
        case "fullscreen":
            return AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue) == .success
        case "exit_fullscreen", "windowed":
            return AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse) == .success
        case "main", "raise":
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue) == .success
        default:
            return false
        }
    }

    /// Return the window `(pid, index)` pointer or nil if out of bounds.
    func window(pid: pid_t, index: Int) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let array = windowsRef as? [AXUIElement], index < array.count else {
            return nil
        }
        return array[index]
    }

    private func describe(
        window: AXUIElement,
        index: Int,
        appName: String,
        pid: pid_t,
        mainWindow: AXUIElement?
    ) -> WindowInfo {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String

        var positionRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
        var point = CGPoint.zero
        if let raw = positionRef, CFGetTypeID(raw) == AXValueGetTypeID() {
            let axValue = unsafeDowncast(raw, to: AXValue.self)
            _ = AXValueGetValue(axValue, .cgPoint, &point)
        }

        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        var size = CGSize.zero
        if let raw = sizeRef, CFGetTypeID(raw) == AXValueGetTypeID() {
            let axValue = unsafeDowncast(raw, to: AXValue.self)
            _ = AXValueGetValue(axValue, .cgSize, &size)
        }

        var minimizedRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
        let minimized = (minimizedRef as? Bool) ?? false

        let isMain: Bool = {
            guard let mainWindow else { return false }
            return CFEqual(mainWindow, window)
        }()

        return WindowInfo(
            app: appName,
            pid: pid,
            title: title,
            x: Double(point.x),
            y: Double(point.y),
            width: Double(size.width),
            height: Double(size.height),
            minimized: minimized,
            main: isMain,
            index: index
        )
    }
}
