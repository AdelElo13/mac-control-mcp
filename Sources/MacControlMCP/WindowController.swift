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
    func listWindows() async -> [WindowInfo] {
        // NSWorkspace.runningApplications is main-actor-affine under strict
        // concurrency — snapshot the (pid, name) pairs on MainActor, then
        // do the AX work (which is thread-safe) here on the actor thread.
        struct AppSnap: Sendable { let pid: pid_t; let name: String }
        let apps: [AppSnap] = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier > 0 }
                .map { AppSnap(pid: $0.processIdentifier, name: $0.localizedName ?? "Unknown") }
        }

        var result: [WindowInfo] = []
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.pid)
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
                let info = describe(window: window, index: index, appName: app.name, pid: app.pid, mainWindow: mainWindow)
                result.append(info)
            }
        }

        return result
    }

    /// List windows for a single app by PID. Faster than `listWindows()`
    /// when the caller already knows which app they want.
    func listAppWindows(pid: pid_t) async -> [WindowInfo] {
        let appElement = AXUIElementCreateApplication(pid)
        let name: String = await MainActor.run {
            NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown"
        }

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
    /// Returns true only when BOTH the raise and main-attribute assign
    /// succeed, so callers don't get a false-positive success when the AX
    /// tree rejects the request.
    func focusWindow(pid: pid_t, index: Int) async -> Bool {
        // NSRunningApplication activation is main-actor affine.
        let appActivated: Bool = await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            app.activate(options: [])
            return true
        }
        guard appActivated else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let array = windowsRef as? [AXUIElement], index < array.count else {
            return false
        }

        let window = array[index]
        let raise = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let setMain = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        return raise == .success && setMain == .success
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

    /// Apply a high-level state transition. Accepts multiple names per
    /// state because callers reach for different vocabulary
    /// (minimize / minimized; unminimize / restore; normal / default /
    /// show; main / raise; fullscreen; exit_fullscreen / windowed).
    ///
    /// "normal" is a composite — it guarantees the window is visible
    /// and frontmost by (a) unminimizing it if it was minimized and
    /// (b) raising + making it main. Handy when a caller just wants
    /// "please show this window" without knowing the prior state.
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
        case "normal", "default", "show":
            // Composite: unminimize → raise → make main. Previously all
            // but the final AX call were fire-and-forget (`_ = ...`), so
            // a failure in step 1 or 2 still reported success (Codex v11
            // HIGH: false-positive "state applied" when the window was
            // still minimized). Verify each step and only succeed if
            // either the call returned .success OR the state was
            // already correct going in (so e.g. an already-raised window
            // doesn't fail the raise step).
            let unminStatus = AXUIElementSetAttributeValue(
                window, kAXMinimizedAttribute as CFString, kCFBooleanFalse
            )
            // Verify not still minimized, regardless of whether the
            // write returned success (some apps report .noValue here
            // but the attribute is already false).
            var minRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef)
            let stillMinimized = (minRef as? Bool) ?? false
            guard unminStatus == .success || !stillMinimized else { return false }

            let raiseStatus = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            // Raise can legitimately return .noValue for already-front
            // windows; accept .success or .noValue, reject anything else.
            guard raiseStatus == .success || raiseStatus == .noValue else { return false }

            let mainStatus = AXUIElementSetAttributeValue(
                window, kAXMainAttribute as CFString, kCFBooleanTrue
            )
            return mainStatus == .success
        default:
            return false
        }
    }

    /// Documented list of accepted `state` values. Exposed so the tool
    /// layer can return an informative error listing valid options
    /// instead of a generic "unknown state".
    static let supportedStates: [String] = [
        "minimize", "minimized",
        "unminimize", "restore",
        "normal", "default", "show",
        "main", "raise",
        "fullscreen",
        "exit_fullscreen", "windowed"
    ]

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

        // Extract position/size; we check every step of the AX chain so
        // malformed AX responses produce documented zero-output rather than
        // silent misreporting. AXValueGetValue itself returns a bool that
        // must be honoured — if the conversion fails, the pointee is
        // undefined, not zero.
        var point = CGPoint.zero
        var positionRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
           let raw = positionRef,
           CFGetTypeID(raw) == AXValueGetTypeID() {
            let axValue = unsafeDowncast(raw, to: AXValue.self)
            var tmp = CGPoint.zero
            if AXValueGetType(axValue) == .cgPoint,
               AXValueGetValue(axValue, .cgPoint, &tmp) {
                point = tmp
            }
        }

        var size = CGSize.zero
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let raw = sizeRef,
           CFGetTypeID(raw) == AXValueGetTypeID() {
            let axValue = unsafeDowncast(raw, to: AXValue.self)
            var tmp = CGSize.zero
            if AXValueGetType(axValue) == .cgSize,
               AXValueGetValue(axValue, .cgSize, &tmp) {
                size = tmp
            }
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
