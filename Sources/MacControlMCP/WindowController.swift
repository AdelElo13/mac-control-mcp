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
        /// true when the app did not answer its AX window query within
        /// `WindowController.axDeadline` and this entry comes from the
        /// Window Server list instead. Absent (nil) otherwise.
        var axTimeout: Bool? = nil

        enum CodingKeys: String, CodingKey {
            case app, pid, title, x, y, width, height, minimized, main, index
            case axTimeout = "ax_timeout"
        }
    }

    /// Per-app budget for the AX window query in `listWindows`. Applied
    /// both as the AX messaging timeout (so the blocking IPC itself
    /// returns) and as the BlockingWorkPool deadline (so the call never
    /// waits longer even if the timeout isn't honoured).
    static let axDeadline: TimeInterval = 1.5
    /// Max apps queried at once — keeps IPC fan-out and GCD threads bounded.
    static let maxConcurrentAXApps = 6

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
        Self.setManualAccessibility(pid: pid, messagingTimeout: nil)
        manualAccessibilityEnabled.insert(pid)
    }

    private static func setManualAccessibility(pid: pid_t, messagingTimeout: TimeInterval?) {
        let app = AXUIElementCreateApplication(pid)
        applyTimeout(app, messagingTimeout)
        _ = AXUIElementSetAttributeValue(
            app, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
        )
    }

    /// Client-side per-element AX timeout; nil keeps the system default.
    private static func applyTimeout(_ element: AXUIElement, _ timeout: TimeInterval?) {
        guard let timeout else { return }
        _ = AXUIElementSetMessagingTimeout(element, Float(timeout))
    }

    /// Resolve an app's window list through a three-step AX fallback
    /// chain: `kAXWindowsAttribute` → `kAXFocusedWindowAttribute` →
    /// `kAXMainWindowAttribute`. Chromium/Electron apps sometimes
    /// populate one but not the other, especially when the app has
    /// only just finished AX wiring.
    private func axWindows(pid: pid_t) -> [AXUIElement] {
        enableManualAccessibility(pid: pid)
        return Self.axWindowElements(pid: pid, messagingTimeout: nil)
    }

    /// Actor-independent half of `axWindows`, runnable on the
    /// BlockingWorkPool queue.
    private static func axWindowElements(pid: pid_t, messagingTimeout: TimeInterval?) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        applyTimeout(app, messagingTimeout)

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

    /// AX-described windows of one app with real (> 1×1) bounds, or `[]`
    /// when the app exposes none — the caller then falls back to the
    /// Window Server list.
    private static func realAXWindowInfos(
        pid: pid_t,
        appName: String,
        messagingTimeout: TimeInterval?
    ) -> [WindowInfo] {
        let axList = axWindowElements(pid: pid, messagingTimeout: messagingTimeout)
        guard !axList.isEmpty else { return [] }
        let appElement = AXUIElementCreateApplication(pid)
        applyTimeout(appElement, messagingTimeout)
        var mainWindowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindowRef)
        let mainWindow = mainWindowRef.flatMap { raw -> AXUIElement? in
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(raw, to: AXUIElement.self)
        }
        // Some Electron apps report AX windows with `0×0` bounds — drop
        // those so the CG fallback supplies real numbers instead.
        return axList.enumerated()
            .map { index, window in
                applyTimeout(window, messagingTimeout)
                return describe(window: window, index: index, appName: appName, pid: pid, mainWindow: mainWindow)
            }
            .filter { $0.width > 1 && $0.height > 1 }
    }

    private static func copyWindowServerList() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        return (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
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
    ///
    /// Pure over a pre-fetched window-server snapshot. PERF (v0.8.3):
    /// `listWindows` used to call `CGWindowListCopyWindowInfo` (~5 ms,
    /// ~470 entries) once PER app that needed the fallback — 10 of 22
    /// apps on the benchmark machine, ~45 ms of a ~110 ms call. It now
    /// fetches the snapshot once per call and filters it per pid here.
    static func cgWindows(
        from info: [[String: Any]],
        pid: pid_t,
        appName: String,
        axTimeout: Bool? = nil
    ) -> [WindowInfo] {
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
                index: out.count,
                axTimeout: axTimeout
            ))
        }
        return out
    }

    /// Pure merge of per-app AX outcomes (index-aligned with `apps`) into
    /// the final list, in `apps` order:
    ///   - AX answered with real windows → those.
    ///   - AX answered with none → Window Server entries.
    ///   - AX timed out → Window Server entries flagged `ax_timeout: true`.
    /// The Window Server list is fetched lazily, at most once.
    static func assemble(
        apps: [(pid: pid_t, name: String)],
        outcomes: [BlockingWorkPool.Outcome<[WindowInfo]>],
        windowServerList: () -> [[String: Any]]
    ) -> [WindowInfo] {
        var list: [[String: Any]]?
        func cgList() -> [[String: Any]] {
            if let list { return list }
            let fetched = windowServerList()
            list = fetched
            return fetched
        }
        var result: [WindowInfo] = []
        for (i, app) in apps.enumerated() {
            let outcome = i < outcomes.count ? outcomes[i] : .timedOut
            switch outcome {
            case .value(let infos) where !infos.isEmpty:
                result.append(contentsOf: infos)
            case .value:
                result.append(contentsOf: cgWindows(from: cgList(), pid: app.pid, appName: app.name))
            case .timedOut:
                result.append(contentsOf: cgWindows(from: cgList(), pid: app.pid, appName: app.name, axTimeout: true))
            }
        }
        return result
    }

    /// Enumerate all windows of all regular running apps. Windows are ordered
    /// per-app in the AX child order, which approximately matches z-order for
    /// the active app and is stable across calls for inactive apps.
    ///
    /// PERF (v0.8.3): per-app AX queries run concurrently on
    /// `BlockingWorkPool` — a dedicated GCD queue, NOT Swift's cooperative
    /// pool (blocking AX IPC there could starve every other tool call) —
    /// at most `maxConcurrentAXApps` at a time, each bounded by
    /// `axDeadline`. An app that doesn't answer in time is reported from
    /// the Window Server list with `ax_timeout: true` instead of blocking
    /// the call. The Window Server list is fetched at most once. Apps stay
    /// in `runningApplications` order.
    func listWindows() async -> [WindowInfo] {
        // NSWorkspace.runningApplications is main-actor-affine under strict
        // concurrency — snapshot the (pid, name) pairs on MainActor, then
        // do the AX work (which is thread-safe) off the main actor.
        struct AppSnap: Sendable { let pid: pid_t; let name: String }
        let apps: [AppSnap] = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier > 0 }
                .map { AppSnap(pid: $0.processIdentifier, name: $0.localizedName ?? "Unknown") }
        }

        let needsEnable = Set(apps.map(\.pid)).subtracting(manualAccessibilityEnabled)
        let deadline = Self.axDeadline
        let outcomes = await BlockingWorkPool.map(
            count: apps.count,
            maxConcurrent: Self.maxConcurrentAXApps,
            perItemTimeout: deadline
        ) { i in
            let app = apps[i]
            if needsEnable.contains(app.pid) {
                Self.setManualAccessibility(pid: app.pid, messagingTimeout: deadline)
            }
            return Self.realAXWindowInfos(pid: app.pid, appName: app.name, messagingTimeout: deadline)
        }
        // Only remember the unlock for apps that actually answered; a
        // timed-out app gets another attempt next call.
        for (i, outcome) in outcomes.enumerated() where needsEnable.contains(apps[i].pid) {
            if outcome.value != nil { manualAccessibilityEnabled.insert(apps[i].pid) }
        }

        return Self.assemble(
            apps: apps.map { (pid: $0.pid, name: $0.name) },
            outcomes: outcomes,
            windowServerList: Self.copyWindowServerList
        )
    }

    /// List windows for a single app by PID. Faster than `listWindows()`
    /// when the caller already knows which app they want.
    func listAppWindows(pid: pid_t) async -> [WindowInfo] {
        let name: String = await MainActor.run {
            NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown"
        }

        enableManualAccessibility(pid: pid)
        let real = Self.realAXWindowInfos(pid: pid, appName: name, messagingTimeout: nil)
        if !real.isEmpty { return real }
        // Chrome / apps with no AX-exposed windows.
        return Self.cgWindows(from: Self.copyWindowServerList(), pid: pid, appName: name)
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

    private static let describeAttributes: [String] = [
        kAXTitleAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
        kAXMinimizedAttribute as String
    ]

    /// Title / position / size / minimized in one batched AX round trip
    /// (was four). Decoding goes through the same type-checked helpers
    /// as tree walks: a missing attribute arrives as an `.axError`
    /// AXValue in its slot and decodes to the documented zero/nil output.
    private static func describe(
        window: AXUIElement,
        index: Int,
        appName: String,
        pid: pid_t,
        mainWindow: AXUIElement?
    ) -> WindowInfo {
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            window, describeAttributes as CFArray, [], &raw
        )
        let slots: [AnyObject]
        if status == .success, let array = raw as? [AnyObject], array.count == describeAttributes.count {
            slots = array
        } else {
            slots = describeAttributes.map { name in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, name as CFString, &value) == .success,
                      let value else { return kCFNull }
                return value
            }
        }

        let title = slots[0] as? String
        let point = AXAttributeBatch.point(slots[1]) ?? .zero
        let size = AXAttributeBatch.size(slots[2]) ?? .zero
        let minimized = (slots[3] as? NSNumber)?.boolValue ?? false

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
