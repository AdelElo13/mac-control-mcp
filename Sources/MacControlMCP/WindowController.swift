import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

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

    /// PIDs for which we've already flipped the private Chromium/iWork AX
    /// unlock attributes. Duplicated from AccessibilityController (each
    /// actor keeps its own cache) because crossing actors just to set
    /// two idempotent CF attributes would cost more than one extra IPC
    /// call per first-touch.
    private var manualAccessibilityEnabled: Set<pid_t> = []

    /// Flip `AXManualAccessibility` + `AXEnhancedUserInterface` on the
    /// application element. Without this, Chromium/Electron (Chrome,
    /// Claude Desktop, VS Code, Slack, Discord, …) and iWork apps
    /// expose *no windows at all* over `kAXWindowsAttribute`. The call
    /// is idempotent — setting either attribute on a non-Electron app
    /// is a no-op at the AX layer.
    private func enableManualAccessibility(pid: pid_t) {
        guard !manualAccessibilityEnabled.contains(pid) else { return }
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(
            app, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
        )
        manualAccessibilityEnabled.insert(pid)
    }

    /// Resolve an app's window list through a three-step AX fallback
    /// chain: `kAXWindowsAttribute` → `kAXFocusedWindowAttribute` →
    /// `kAXMainWindowAttribute`. Chromium/Electron apps sometimes
    /// populate one but not the other, especially when the app has
    /// only just finished AX wiring.
    private func axWindows(pid: pid_t) -> [AXUIElement] {
        enableManualAccessibility(pid: pid)
        let app = AXUIElementCreateApplication(pid)

        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
           let array = ref as? [AXUIElement], !array.isEmpty {
            return array
        }

        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
           let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            return [unsafeDowncast(raw, to: AXUIElement.self)]
        }

        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &ref) == .success,
           let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            return [unsafeDowncast(raw, to: AXUIElement.self)]
        }

        return []
    }

    /// Window Server fallback — for apps whose windows are NEVER
    /// registered with Accessibility (Chrome's browser windows are
    /// the canonical example; all AX attributes return nothing).
    /// `CGWindowListCopyWindowInfo` lives one layer below AX and sees
    /// every window the window server draws, but the result is a
    /// dictionary — we lose the AXUIElement handle, so windows surfaced
    /// only via CG cannot be mutated (`move_window` / `resize_window`
    /// still need an AX handle). `list_windows` callers get honest
    /// bounds + title instead of the previous `count: 0`.
    private func cgWindows(pid: pid_t, appName: String) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        var out: [WindowInfo] = []
        for dict in info {
            guard
                let ownerPid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                ownerPid == pid,
                (dict[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                let bounds = dict[kCGWindowBounds as String] as? [String: Any]
            else { continue }
            let x = (bounds["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (bounds["Y"] as? NSNumber)?.doubleValue ?? 0
            let w = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            let h = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            // Exclude zero-sized overlays and the menubar stripes that
            // otherwise dominate Chrome's output (Chrome publishes
            // per-monitor 1800×39 @ y=0 entries for its menubar even
            // when no browser window is on that monitor).
            guard w > 1, h > 1 else { continue }
            if y < 1 && h < 60 { continue }
            let title = dict[kCGWindowName as String] as? String
            let onscreen = (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            out.append(WindowInfo(
                app: appName,
                pid: pid,
                title: title,
                x: x, y: y, width: w, height: h,
                minimized: !onscreen,
                main: out.isEmpty,  // treat first surfaced window as main
                index: out.count
            ))
        }
        return out
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
            // Try AX first (cheaper, gives us a mutable handle) …
            let axList = axWindows(pid: app.pid)
            if !axList.isEmpty {
                let appElement = AXUIElementCreateApplication(app.pid)
                var mainWindowRef: CFTypeRef?
                AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindowRef)
                let mainWindow = mainWindowRef.flatMap { raw -> AXUIElement? in
                    guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
                    return unsafeDowncast(raw, to: AXUIElement.self)
                }
                for (index, window) in axList.enumerated() {
                    let info = describe(
                        window: window, index: index,
                        appName: app.name, pid: app.pid,
                        mainWindow: mainWindow
                    )
                    // Some Electron apps report AX windows with
                    // `0×0` bounds — if that's all we got, fall
                    // through to the CG fallback for real numbers.
                    if info.width > 1 && info.height > 1 {
                        result.append(info)
                    }
                }
                if result.contains(where: { $0.pid == app.pid }) { continue }
            }
            // … otherwise (or if AX gave only zero-sized frames) fall
            // back to the Window Server list.
            result.append(contentsOf: cgWindows(pid: app.pid, appName: app.name))
        }

        return result
    }

    /// List windows for a single app by PID. Faster than `listWindows()`
    /// when the caller already knows which app they want.
    func listAppWindows(pid: pid_t) async -> [WindowInfo] {
        let name: String = await MainActor.run {
            NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown"
        }

        let axList = axWindows(pid: pid)
        if !axList.isEmpty {
            let appElement = AXUIElementCreateApplication(pid)
            var mainWindowRef: CFTypeRef?
            AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindowRef)
            let mainWindow = mainWindowRef.flatMap { raw -> AXUIElement? in
                guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
                return unsafeDowncast(raw, to: AXUIElement.self)
            }
            let described = axList.enumerated().map { index, window in
                describe(window: window, index: index, appName: name, pid: pid, mainWindow: mainWindow)
            }
            let real = described.filter { $0.width > 1 && $0.height > 1 }
            if !real.isEmpty { return real }
        }
        // Chrome / apps with no AX-exposed windows.
        return cgWindows(pid: pid, appName: name)
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

        let array = axWindows(pid: pid)
        guard index < array.count else { return false }

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
        let array = axWindows(pid: pid)
        guard index < array.count else { return nil }
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
