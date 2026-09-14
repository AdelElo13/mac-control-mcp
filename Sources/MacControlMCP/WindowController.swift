import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

actor WindowController {
    struct WindowInfo: Codable, Sendable {
        let app: String
        let pid: Int32
        /// v0.9 (C-2): ALWAYS present — "" for an untitled window. It used
        /// to be omitted from the JSON entirely when the window had no
        /// title, so a caller could not tell "no title" from "key missing".
        let title: String
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
        /// v0.9 (C-2) — the window server's own stable handle (CGWindowID).
        /// This is the preferred way to target a window in every other
        /// tool. nil only when no window-server entry could be matched to
        /// this AX window (rare: window closed between the two reads).
        var windowID: CGWindowID? = nil
        /// Index into `list_displays` of the display showing this window
        /// (by window center). nil when the window is off every display.
        var displayIndex: Int? = nil
        /// True for the frontmost on-screen window (`z_order == 0`) — the
        /// window that receives keystrokes. Not tied to the app's AX
        /// `main` flag, which can name a different window of the same app.
        var isFocused: Bool = false
        /// Front-to-back position among all normal application windows:
        /// 0 is the frontmost window on screen. nil when unmatched.
        var zOrder: Int? = nil
        /// v0.9.0 (Codex r2 #1) — the id the AX element itself reports via
        /// `AXWindowID.of`, read when the row is built from AX. `enrich`
        /// uses it to attach `window_id` EXACTLY instead of by frame.
        /// Internal only: NOT in `CodingKeys`, so `list_windows` output is
        /// unchanged (`window_id` is still the one public id). nil for
        /// CG-fallback rows and when the private symbol is unavailable.
        var axWindowID: CGWindowID? = nil

        enum CodingKeys: String, CodingKey {
            case app, pid, title, x, y, width, height, minimized, main, index
            case axTimeout = "ax_timeout"
            case windowID = "window_id"
            case displayIndex = "display_index"
            case isFocused = "is_focused"
            case zOrder = "z_order"
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
            let title = (dict[kCGWindowName as String] as? String) ?? ""
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

    // MARK: - v0.9 (C-2): window identity

    /// Attach the window-server identity (`window_id`, `z_order`) plus
    /// `display_index` and `is_focused` to an assembled window list.
    ///
    /// Matching rule, per window, in order (Codex r2 #1):
    ///   1. **Exact.** The row carries `axWindowID` (read from the AX
    ///      element via `AXWindowID.of`) → the window-server entry with
    ///      that id, full stop. No frame, no title, no order involved.
    ///   2. **Frame + title.** Rows without an exact id (CG-fallback rows,
    ///      or the private symbol is unavailable) take the first **unused**
    ///      entry of the same pid whose frame matches
    ///      (`WindowIdentity.frameTolerance`) AND whose normalized title
    ///      (trimmed; nil ≡ "") equals the row's.
    ///   3. **Frame only.** Last resort, first unused frame match — for
    ///      apps whose AX title and `kCGWindowName` disagree.
    ///
    /// Entries are consumed: an id attached exactly is marked used BEFORE
    /// any fallback row is considered, so a heuristic row can never steal
    /// an id that another row owns exactly, and two same-framed fallback
    /// rows still get distinct ids. A window with no matching entry keeps
    /// `window_id: null` rather than borrowing a neighbour's.
    ///
    /// Why not frame-only-first-unused, as v0.9.0-rc1 did: it assumed AX
    /// order == CG z-order. Same-frame windows A/B listed B,A by AX and A,B
    /// by CG gave row B the id of A — and `window_id` then acted on the
    /// wrong window (Codex r2 #1).
    ///
    /// Pure: no AX, no CG, no AppKit calls. `cgEntries` and `displays`
    /// are supplied by the caller.
    ///
    /// `is_focused` is the frontmost ON-SCREEN window (`z_order == 0`) —
    /// the window server's own answer to "what receives keystrokes",
    /// which costs no `NSWorkspace` MainActor hop. It deliberately does
    /// NOT require the AX `main` flag: a second window of an app can be
    /// frontmost while the app's AX main window is another one (observed
    /// live with two ControlZoo windows), and requiring `main` then left
    /// every window unfocused.
    static func enrich(
        windows: [WindowInfo],
        cgEntries: [WindowIdentity.Entry],
        displays: [WindowIdentity.DisplayBounds]
    ) -> [WindowInfo] {
        // Pass 1: exact ids. Reserved up front so no fallback row — even
        // one listed EARLIER — can consume an entry that a later row owns
        // exactly.
        let byID = Dictionary(cgEntries.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set<CGWindowID>()
        let exact: [WindowIdentity.Entry?] = windows.map { window in
            guard let id = window.axWindowID, let entry = byID[id], entry.pid == window.pid else { return nil }
            used.insert(id)
            return entry
        }

        // Pass 2: heuristics for the rest, consuming entries as they go.
        func normalized(_ title: String) -> String {
            title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return zip(windows, exact).map { window, exactEntry in
            var out = window
            let frame = CGRect(x: window.x, y: window.y, width: window.width, height: window.height)
            let match: WindowIdentity.Entry?
            if let exactEntry {
                match = exactEntry
            } else if window.axWindowID != nil {
                // Codex r3 #1: this row KNOWS its window-server id and the
                // snapshot does not carry it (the window closed between the
                // AX read and the CG read, or the id belongs to another
                // pid). Falling through to frame/title would hand it the id
                // of an identical-looking neighbour — exactly the retarget
                // the exact pass exists to prevent. A stale row reports
                // `window_id: null`; the next call sees the truth.
                match = nil
            } else {
                let sameFrame: (WindowIdentity.Entry) -> Bool = { entry in
                    entry.pid == window.pid
                        && !used.contains(entry.windowID)
                        && WindowIdentity.framesMatch(entry.bounds, frame)
                }
                let title = normalized(window.title)
                match = cgEntries.first(where: { sameFrame($0) && normalized($0.title) == title })
                    ?? cgEntries.first(where: sameFrame)
                if let match { used.insert(match.windowID) }
            }
            if let match {
                out.windowID = match.windowID
                out.zOrder = match.zOrder
            }
            out.displayIndex = WindowIdentity.displayIndex(containing: frame, displays: displays)
            out.isFocused = out.zOrder == 0
            return out
        }
    }

    /// A `window_id` resolved back to everything the AX-based window tools
    /// need. `index` is nil when the owning app exposes no AX window with
    /// this frame (Chrome's browser windows, some Electron apps): capture
    /// and OCR still work by id, but move/resize/focus cannot.
    struct ResolvedWindow: Sendable {
        let windowID: CGWindowID
        let pid: pid_t
        /// Owning application name, from `kCGWindowOwnerName`.
        let ownerName: String
        let title: String
        let bounds: CGRect
        let isOnscreen: Bool
        let index: Int?
        /// v0.9.0 blocker fix (Codex r1 #1): the CONCRETE AX window this id
        /// resolved to. Every mutating tool acts on THIS element, never on
        /// a re-read `axWindows(pid:)[index]`, so a window reorder between
        /// resolve and act cannot retarget.
        let element: AXUIElement?
        /// Non-nil when several AX windows are indistinguishable (same
        /// frame, same title, no usable z-order). The tool layer turns this
        /// into `error_code: ambiguous_window` with the candidates instead
        /// of acting on a guess.
        let ambiguousCandidates: [WindowTargeting.Candidate]?

        init(
            windowID: CGWindowID,
            pid: pid_t,
            ownerName: String,
            title: String,
            bounds: CGRect,
            isOnscreen: Bool,
            index: Int?,
            element: AXUIElement? = nil,
            ambiguousCandidates: [WindowTargeting.Candidate]? = nil
        ) {
            self.windowID = windowID
            self.pid = pid
            self.ownerName = ownerName
            self.title = title
            self.bounds = bounds
            self.isOnscreen = isOnscreen
            self.index = index
            self.element = element
            self.ambiguousCandidates = ambiguousCandidates
        }

        /// Identity echo for a tool response: enough for the caller to
        /// see WHICH window an id resolved to. CGWindowIDs are recycled
        /// by the window server after a window closes, so a stale id can
        /// resolve to a different window — this is how a caller notices.
        var payload: [String: JSONValue] {
            [
                "window_id": .number(Double(windowID)),
                "owner_pid": .number(Double(pid)),
                "owner_name": .string(ownerName),
                "title": .string(title)
            ]
        }

        /// Does this window satisfy the caller's `expect_pid` /
        /// `expect_title_contains` guards? Returns the failing field, or
        /// nil when everything matches (or nothing was asserted).
        func mismatch(expectPID: pid_t?, expectTitleContains: String?) -> (field: String, expected: String, actual: String)? {
            if let expectPID, expectPID != pid {
                return ("expect_pid", String(expectPID), String(pid))
            }
            if let expectTitleContains, !expectTitleContains.isEmpty,
               !title.localizedCaseInsensitiveContains(expectTitleContains) {
                return ("expect_title_contains", expectTitleContains, title)
            }
            return nil
        }
    }

    /// Exact id + frame + title of one AX window, in the shape
    /// `WindowTargeting` disambiguates over. The id (Codex r2 #1) is what
    /// makes resolution exact; frame and title only matter when the
    /// private symbol is unavailable.
    private static func snapshot(of element: AXUIElement, index: Int) -> WindowTargeting.AXWindow<AXUIElement> {
        WindowTargeting.AXWindow(
            handle: element,
            index: index,
            frame: axFrame(of: element),
            title: axTitle(of: element),
            windowID: AXWindowID.of(element)
        )
    }

    /// `AXPosition` + `AXSize` as one rect, or nil when either is missing
    /// or not an `AXValue`.
    static func axFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef,
              CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func axTitle(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    /// Resolve a `CGWindowID` to the CONCRETE AX window it names.
    /// Returns nil when no window-server entry carries that id.
    ///
    /// v0.9.0 blocker fix (Codex r1 #1): this used to be "the first AX
    /// window whose frame matches", which mapped two same-framed windows of
    /// one pid onto the same AX index. Codex r2 #1: the AX element now
    /// reports its own id (`AXWindowID.of`), so the match is exact;
    /// frame → title → refuse is the fallback for id-less elements only,
    /// in `WindowTargeting`, which is pure and unit-tested. The element is
    /// carried through to the action so no later re-indexing can retarget.
    func resolve(windowID: CGWindowID) -> ResolvedWindow? {
        let entries = WindowIdentity.copyEntries()
        guard let entry = WindowIdentity.entry(id: windowID, in: entries) else { return nil }
        let axCandidates = axWindows(pid: entry.pid).enumerated().map { index, element in
            Self.snapshot(of: element, index: index)
        }
        let outcome = WindowTargeting.resolve(
            entry: entry,
            siblings: entries.filter { $0.pid == entry.pid },
            axWindows: axCandidates
        )
        let index: Int?
        let element: AXUIElement?
        let ambiguous: [WindowTargeting.Candidate]?
        switch outcome {
        case .matched(let handle, let matchedIndex):
            index = matchedIndex
            element = handle
            ambiguous = nil
        case .noAXWindow:
            index = nil
            element = nil
            ambiguous = nil
        case .ambiguous(let candidates):
            index = nil
            element = nil
            ambiguous = candidates
        }
        return ResolvedWindow(
            windowID: entry.windowID,
            pid: entry.pid,
            ownerName: entry.ownerName,
            title: entry.title,
            bounds: entry.bounds,
            isOnscreen: entry.isOnscreen,
            index: index,
            element: element,
            ambiguousCandidates: ambiguous
        )
    }

    /// Post-action identity check (v0.9.0, Codex r1 #1): after mutating
    /// `element`, does it still describe the window `windowID` names?
    ///
    /// Compared against a FRESH window-server read, so `move_window` and
    /// `resize_window` — where the frame legitimately changed — verify
    /// too: entry and element moved together.
    func verify(element: AXUIElement, windowID: CGWindowID) -> WindowTargeting.Verification {
        let entry = WindowIdentity.entry(id: windowID, in: WindowIdentity.copyEntries())
        return WindowTargeting.verifyIdentity(
            entry: entry,
            axFrame: Self.axFrame(of: element),
            axTitle: Self.axTitle(of: element)
        )
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
    /// the call. Apps stay in `runningApplications` order.
    ///
    /// PERF (v0.9): window identity (window_id / z_order / display_index /
    /// is_focused) adds no round trips. The Window Server list is fetched
    /// EXACTLY ONCE per call and shared by the AX fallback and the
    /// identity pass; display geometry comes from CoreGraphics on this
    /// thread (no DisplayController actor hop) and the focused app from
    /// that same window-server snapshot (no NSWorkspace MainActor hop).
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

        // ONE window-server snapshot per call, shared by the AX fallback
        // (apps that expose no AX windows) and the identity pass.
        let snapshot = Self.copyWindowServerList()
        let assembled = Self.assemble(
            apps: apps.map { (pid: $0.pid, name: $0.name) },
            outcomes: outcomes,
            windowServerList: { snapshot }
        )
        return Self.enriched(assembled, windowServerList: snapshot)
    }

    /// Shared tail of both list calls: attach window_id / z_order /
    /// display_index / is_focused. Synchronous and hop-free — display
    /// geometry is read from CoreGraphics here, the focused app comes out
    /// of the snapshot itself.
    private static func enriched(_ windows: [WindowInfo], windowServerList: [[String: Any]]) -> [WindowInfo] {
        enrich(
            windows: windows,
            cgEntries: WindowIdentity.entries(from: windowServerList),
            displays: WindowIdentity.displayBounds()
        )
    }

    /// List windows for a single app by PID. Faster than `listWindows()`
    /// when the caller already knows which app they want.
    func listAppWindows(pid: pid_t) async -> [WindowInfo] {
        let name: String = await MainActor.run {
            NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown"
        }

        enableManualAccessibility(pid: pid)
        let snapshot = Self.copyWindowServerList()
        let real = Self.realAXWindowInfos(pid: pid, appName: name, messagingTimeout: nil)
        let list = real.isEmpty
            // Chrome / apps with no AX-exposed windows.
            ? Self.cgWindows(from: snapshot, pid: pid, appName: name)
            : real
        return Self.enriched(list, windowServerList: snapshot)
    }

    /// Bring a window to the front. Raises the app first, then the window.
    /// Returns true only when BOTH the raise and main-attribute assign
    /// succeed, so callers don't get a false-positive success when the AX
    /// tree rejects the request.
    func focusWindow(pid: pid_t, index: Int) async -> Bool {
        let array = axWindows(pid: pid)
        guard index < array.count else { return false }
        return await focusWindow(element: array[index], pid: pid)
    }

    /// Focus a window by its CONCRETE AX element (v0.9.0, Codex r1 #1).
    /// The `(pid, index)` overload resolves and delegates here, so there is
    /// exactly one implementation and no window-array re-read between
    /// resolution and the action.
    func focusWindow(element: AXUIElement, pid: pid_t) async -> Bool {
        // NSRunningApplication activation is main-actor affine.
        let appActivated: Bool = await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            app.activate(options: [])
            return true
        }
        guard appActivated else { return false }

        let raise = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        let setMain = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        return raise == .success && setMain == .success
    }

    /// Move the window to an absolute position in global coordinates.
    func moveWindow(pid: pid_t, index: Int, to point: CGPoint) -> Bool {
        guard let window = window(pid: pid, index: index) else { return false }
        return moveWindow(element: window, to: point)
    }

    func moveWindow(element: AXUIElement, to point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    /// Resize a window to the given width/height.
    func resizeWindow(pid: pid_t, index: Int, to size: CGSize) -> Bool {
        guard let window = window(pid: pid, index: index) else { return false }
        return resizeWindow(element: window, to: size)
    }

    func resizeWindow(element: AXUIElement, to size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
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
        return setState(element: window, state: state)
    }

    func setState(element window: AXUIElement, state: String) -> Bool {
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

        let title = (slots[0] as? String) ?? ""
        let point = AXAttributeBatch.point(slots[1]) ?? .zero
        let size = AXAttributeBatch.size(slots[2]) ?? .zero
        let minimized = (slots[3] as? NSNumber)?.boolValue ?? false

        let isMain: Bool = {
            guard let mainWindow else { return false }
            return CFEqual(mainWindow, window)
        }()

        // Codex r2 #1: ask the element which window-server entry it IS, so
        // `enrich` can attach `window_id` exactly instead of by frame.
        // One extra AX round trip per window; nil when unavailable.
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
            index: index,
            axWindowID: AXWindowID.of(window)
        )
    }
}
