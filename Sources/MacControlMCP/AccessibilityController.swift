import Foundation
import ApplicationServices
import CoreGraphics
import AppKit

// `AXUIElement` is documented as safe to use from any thread — the
// Accessibility framework internally serialises AX requests. It has no
// Swift-visible mutable state; the handle is an opaque CF reference.
// Sendable conformance is therefore sound in practice; `@unchecked` is
// used only because Apple does not mark the type `Sendable` themselves.
extension AXUIElement: @retroactive @unchecked Sendable {}

/// A Hashable wrapper around AXUIElement for use as a Set element during
/// tree walks. Hashes via CFHash (logical identity, stable across CFRef
/// allocator churn) and compares via CFEqual (handles the theoretical
/// hash-collision case where two distinct elements share a hash). This
/// is the canonical Foundation pattern for CF types and gives Set its
/// expected semantics without any pointer-address heuristics.
struct AXKey: Hashable {
    let element: AXUIElement
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    static func == (lhs: AXKey, rhs: AXKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

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

    /// A node in a UI tree walk. `children` is only populated when the walk
    /// reached that depth; leaves have an empty array.
    struct TreeNode: Sendable {
        let element: AXUIElement
        let role: String?
        let title: String?
        let value: String?
        let position: Point?
        let size: Size?
        let depth: Int
        let childIndices: [Int]   // indices into the flat array returned by treeWalk
        /// Position in the app's AX tree, from the application root.
        /// Feeds the content-addressed element id (v0.9 C-5).
        let path: [AXPathComponent]
    }

    /// Where a tree walk / element search STARTS, when it should not start
    /// at the application element.
    ///
    /// v0.9.0 blocker fix (Codex r1 #2): window-scoped grounding and
    /// annotation used to walk the whole pid tree and filter by geometry,
    /// so with two overlapping windows of one app an element of the window
    /// BEHIND was a valid match. Rooting the walk at the resolved
    /// `AXWindow` element makes the other window's subtree unreachable
    /// rather than merely unlikely.
    ///
    /// `path` is the root's OWN AX path as seen from the application
    /// element, so every node's content-addressed element id (v0.9 C-5) is
    /// byte-identical to the one an app-rooted walk would produce — a
    /// window-scoped `capture_annotated` and a plain `find_elements` still
    /// agree about ids.
    ///
    /// Note that `maxDepth` is then measured FROM this root: depth 0 is the
    /// window itself, not the application.
    struct WalkRoot: Sendable {
        let element: AXUIElement
        let path: [AXPathComponent]

        init(element: AXUIElement, path: [AXPathComponent]) {
            self.element = element
            self.path = path
        }
    }

    /// A search hit: the live handle, its describable attributes, and the
    /// AX path that gives it a stable id (v0.9 C-5).
    struct Match: Sendable {
        let element: AXUIElement
        let info: ElementInfo
        let path: [AXPathComponent]
        var groundingMatch: GroundingPolicy.Match? = nil
    }

    /// Result of querying attributes. Missing attrs are omitted.
    struct AttributeValues: Codable, Sendable {
        let values: [String: String]
        let unavailable: [String]
    }

    // Codex v8 #9 — expanded to include controls previously missing from
    // this whitelist: AXSwitch, AXStepper, AXLevelIndicator,
    // AXIncrementor, AXDecrementor. Previously these were exposed via
    // get_ui_tree but filtered OUT by list_elements' whitelist.
    //
    // Codex v9 #2 — AXRow deliberately NOT in the whitelist. Adding it
    // floods list_elements on table-heavy apps (Finder list view, Mail,
    // Music). Users who want rows can use find_elements with an explicit
    // role filter; list_elements stays focused on actionable widgets.
    // v0.9: single source of truth lives in `AXPayload.interactiveRoles`
    // so `list_elements` and the new `interactive_only` budget filter can
    // never disagree about what "actionable" means.
    private var actionableRoles: Set<String> { AXPayload.interactiveRoles }

    func checkPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Frames of the app's AX windows, in global screen points. Used by
    /// the `viewport_only` payload filter (v0.9 C-9) as "the app's
    /// on-screen window bounds": a node whose frame intersects none of
    /// these is not visible in any of this app's windows.
    func windowFrames(pid: pid_t) -> [CGRect] {
        enableManualAccessibility(pid: pid)
        let app = AXUIElementCreateApplication(pid)
        return AXPath.copyElements(app, kAXWindowsAttribute as String).compactMap { window in
            // A minimized window still publishes a frame, but nothing in
            // it is on screen — counting it would let viewport_only keep
            // controls the user cannot see (review fix 4).
            if let minimized = AXPath.copyString(window, kAXMinimizedAttribute as String),
               minimized == "1" || minimized.lowercased() == "true" { return nil }
            let attrs = AXAttributeBatch.fetch(window, includeChildren: false)
            guard let origin = attrs.position, let size = attrs.size else { return nil }
            return CGRect(origin: origin, size: size)
        }
    }

    /// v0.9 (C-4) — AX hit-test. The inverse of `ground`: "what is under
    /// this coordinate?".
    ///
    /// `pid == nil` asks the system-wide element, which routes to
    /// whichever app owns that point; a pid restricts the hit-test to
    /// that application, which is what you want when a window is
    /// occluded by another app.
    func elementAtPoint(x: Double, y: Double, pid: pid_t?) -> AXUIElement? {
        if let pid { enableManualAccessibility(pid: pid) }
        let root = pid.map { AXUIElementCreateApplication($0) } ?? AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(root, Float(x), Float(y), &element)
        guard status == .success else { return nil }
        return element
    }

    /// v0.10 C2: SwiftUI/Finder can report a whole container for a precise
    /// point. Preserve overlay scope while allowing a sidebar hit to resolve its scrollbar.
    func refinedHit(element: AXUIElement, x: Double, y: Double) -> (element: AXUIElement, quality: String) {
        func frame(_ values: AXAttributeBatch.Values) -> CGRect? {
            guard let position = values.position, let size = values.size else { return nil }
            return CGRect(origin: position, size: size)
        }
        let lineage = ([element] + AXPath.ancestors(of: element, limit: 24)).map {
            (element: $0, role: AXPath.copyString($0, "AXRole"))
        }
        let window = lineage.first { $0.role == "AXWindow" }?.element
        // v0.10 C2 review: a direct cell hit still inherits its outline/table
        // context even though the bounded search starts below that ancestor.
        let localAncestors = lineage.prefix { !["AXSheet", "AXPopover", "AXDialog", "AXWindow"].contains($0.role) }
        let inCollection = localAncestors.contains { $0.role == "AXOutline" || $0.role == "AXTable" }
        // v0.10 C2 round 3: inconsistent direct hits can need a wider search,
        // but an enclosing overlay must still exclude background controls.
        let recoveryRoot = lineage.first { ["AXSheet", "AXPopover", "AXDialog", "AXWindow"].contains($0.role) }?.element
        // v0.10 C2 review: scrollbar siblings share this scroll area. Never
        // broaden the scroll scope through a sheet/popover boundary.
        let scrollContainer = localAncestors.first { $0.role == "AXScrollArea" }?.element
        let refined = GeometricHitTest.refine(hit: AXKey(element: element),
            window: window.map { AXKey(element: $0) }, point: CGPoint(x: x, y: y), inCollection: inCollection,
            scrollContainer: scrollContainer.map { AXKey(element: $0) },
            recoveryRoot: recoveryRoot.map { AXKey(element: $0) }) { key in
            let values = AXAttributeBatch.fetch(key.element, includeChildren: true)
            return .init(role: values.role, frame: frame(values), children: values.children.map { AXKey(element: $0) })
        }
        return (refined.element.element, refined.quality)
    }

    /// pid that owns an element handle.
    func ownerPID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    /// Describe an element plus the ancestor chain that contains it —
    /// the "what container did I hit?" half of `element_at_point`.
    struct HitTest: Sendable {
        let info: ElementInfo
        let enabled: Bool?
        let pid: pid_t
        let appName: String?
        let path: [AXPathComponent]?
        /// Nearest-first (role, title) pairs, capped by the caller.
        let ancestors: [(role: String?, title: String?)]
    }

    func describeHit(element: AXUIElement, ancestorLimit: Int = 8) -> HitTest? {
        guard let pid = ownerPID(of: element) else { return nil }
        let attrs = AXAttributeBatch.fetch(element, includeChildren: false)
        let enabled: Bool? = AXPath.copyString(element, "AXEnabled").map { $0 == "1" || $0.lowercased() == "true" }
        let ancestors = AXPath.ancestors(of: element, limit: ancestorLimit).map {
            (role: AXPath.copyString($0, "AXRole"),
             title: AXPath.copyString($0, "AXTitle") ?? AXPath.copyString($0, "AXDescription"))
        }
        return HitTest(
            info: Self.elementInfo(from: attrs, depth: nil),
            enabled: enabled,
            pid: pid,
            appName: NSRunningApplication(processIdentifier: pid)?.localizedName,
            path: AXPath.upwardPath(of: element),
            ancestors: ancestors
        )
    }

    func requestPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// PIDs for which we've already flipped AXManualAccessibility on.
    /// Used to avoid paying the IPC cost on every AX call.
    private var manualAccessibilityEnabled: Set<pid_t> = []

    /// For Chromium/Electron apps (VS Code, Slack, Discord, Cursor,
    /// 1Password, Obsidian, Postman, …) and iWork apps (Pages, Keynote,
    /// Numbers, MS Word via Office) the AX tree is NOT populated by
    /// default — you get a nearly-empty tree (just the window frame, no
    /// widgets). Flipping the private `AXManualAccessibility` attribute
    /// to true on the application element tells the renderer to expose
    /// the full DOM/widget tree over AX.
    ///
    /// This is a known, widely-used trick (Fazm, Scoot, Hyperkey,
    /// accessibility inspector, most serious macOS agents). Without it,
    /// mac-control-mcp's find/query/walk functions return useless
    /// results on any Electron app.
    ///
    /// Called automatically the first time any AX walk touches a given
    /// pid. Cached so subsequent calls are a free HashSet lookup.
    func enableManualAccessibility(pid: pid_t) {
        guard !manualAccessibilityEnabled.contains(pid) else { return }
        let app = AXUIElementCreateApplication(pid)
        // Attribute name is private — pass as CFString literal. Setting
        // CFBooleanTrue on a regular (non-Electron) app is a no-op, so
        // it's safe to always call.
        _ = AXUIElementSetAttributeValue(
            app,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        // Secondary attribute that some Chromium versions use instead.
        _ = AXUIElementSetAttributeValue(
            app,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
        manualAccessibilityEnabled.insert(pid)
    }

    func listElements(pid: pid_t, maxDepth: Int = AXDepth.default) -> [ElementInfo] {
        enableManualAccessibility(pid: pid)
        let root = AXUIElementCreateApplication(pid)
        var visited = Set<AXKey>()
        var output: [ElementInfo] = []
        let deadline = Date().addingTimeInterval(5.0)

        _ = walk(element: root, depth: 0, maxDepth: max(1, maxDepth), visited: &visited, deadline: deadline) { _, depth, attrs in
            guard self.actionableRoles.contains(attrs.role ?? "AXUnknown") else { return false }
            output.append(Self.elementInfo(from: attrs, depth: depth))
            return false
        }

        return output
    }

    /// First depth-first match.
    ///
    /// v0.9 (D-2): `maxDepth` is now a parameter defaulting to the
    /// project-wide `AXDepth.default` — it used to be hard-coded at 20,
    /// one of the seven different ceilings D-2 collapsed.
    ///
    /// v0.9 (A-9): `exact` switches role/title from case-insensitive
    /// SUBSTRING to case-insensitive EQUALITY. Substring matching on
    /// role is what made `role:"Button"` return an `AXRadioButton` (a
    /// Safari tab) — the default stays substring for compatibility, but
    /// callers that know the role should pass exact:true.
    func findElement(
        pid: pid_t,
        role: String?,
        title: String?,
        exact: Bool = false,
        maxDepth: Int = AXDepth.default
    ) -> AXUIElement? {
        findElementWithPath(pid: pid, role: role, title: title, exact: exact, maxDepth: maxDepth)?.element
    }

    /// Same search as `findElement`, but also returns the element's AX
    /// path so the caller can mint a stable, content-addressed id for it
    /// (C-5) without a second upward walk.
    func findElementWithPath(
        pid: pid_t,
        role: String?,
        title: String?,
        exact: Bool = false,
        maxDepth: Int = AXDepth.default
    ) -> (element: AXUIElement, path: [AXPathComponent])? {
        var match: (element: AXUIElement, path: [AXPathComponent])?
        let deadline = Date().addingTimeInterval(5.0)
        enableManualAccessibility(pid: pid)
        let root = AXUIElementCreateApplication(pid)
        var visited = Set<AXKey>()

        func recurse(element: AXUIElement, depth: Int, parentPath: [AXPathComponent], ordinal: Int) -> Bool {
            guard depth <= maxDepth else { return false }
            guard Date() < deadline else { return true }
            guard visited.insert(AXKey(element: element)).inserted else { return false }

            let attrs = AXAttributeBatch.fetch(element, includeChildren: true)
            // The application root itself is the empty path; every other
            // node appends its ordinal among its parent's children.
            let path = depth == 0
                ? parentPath
                : AXPath.appending(
                    parentPath, role: attrs.role, index: ordinal, identifier: attrs.identifier,
                    title: attrs.title, subrole: attrs.subrole
                )
            let currentRole = attrs.role ?? "AXUnknown"
            let roleMatches = Self.textMatches(filter: role, candidate: currentRole, exact: exact)
            let titleMatches: Bool = {
                guard let title, !title.isEmpty else { return true }
                if Self.textMatches(filter: title, candidate: attrs.title ?? "", exact: exact) { return true }
                // find_element (unlike find_elements) also falls back to
                // AXValue — documented behaviour, kept for compatibility.
                return Self.textMatches(filter: title, candidate: attrs.value ?? "", exact: exact)
            }()
            if roleMatches && titleMatches {
                match = (element, path)
                return true
            }
            for (ordinal, child) in attrs.children.enumerated() {
                if recurse(element: child, depth: depth + 1, parentPath: path, ordinal: ordinal) { return true }
            }
            return false
        }
        _ = recurse(element: root, depth: 0, parentPath: [], ordinal: 0)
        return match
    }

    /// Case-insensitive substring (default) or equality (`exact`) match.
    /// An empty/absent filter always matches.
    static func textMatches(filter: String?, candidate: String, exact: Bool) -> Bool {
        guard let filter, !filter.isEmpty else { return true }
        if exact { return candidate.compare(filter, options: .caseInsensitive) == .orderedSame }
        return candidate.range(of: filter, options: [.caseInsensitive]) != nil
    }

    /// Outcome of attempting to press an element via the AX-native
    /// `AXPress` action, WITHOUT ever falling back to a coordinate
    /// CGEvent click. Split out from the old single-`Bool` `clickElement`
    /// (input-focus-guard follow-up) so callers can apply the focus guard
    /// only to the coordinate-fallback path — `AXPress` acts on the
    /// element handle directly and does not depend on which app is
    /// frontmost, so it needs no guard.
    enum AXPressOutcome: Sendable, Equatable {
        /// AXPress succeeded — nothing else to do.
        case succeeded
        /// AXEnabled=false — short-circuited before ever attempting
        /// AXPress or a coordinate click (bug #3, see below).
        case disabled
        /// AXPress is unsupported/failed on this element. The caller may
        /// fall back to a coordinate click via `clickElementCoordinateFallback`.
        case unsupported
    }

    // BUG-FIX v0.2.6 #3 (AXEnabled): previously clickElement forwarded
    // the AXPress call even on disabled controls; AX reports .success
    // for the action but nothing happens, so the caller believes the
    // click landed. We now short-circuit when AXEnabled=false and let
    // callers see an explicit failure. The coord-click fallback is still
    // available for AX-press-unsupported controls (bug #5) but the
    // disabled check is evaluated first — a disabled control shouldn't
    // silently turn into a coord click either.
    func pressElementViaAX(element: AXUIElement) -> AXPressOutcome {
        if let enabled = stringAttribute(of: element, attribute: "AXEnabled" as CFString),
           enabled == "0" || enabled.lowercased() == "false" {
            return .disabled
        }
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return .succeeded
        }
        return .unsupported
    }

    /// Coordinate-click fallback for elements where `AXPress` is
    /// unsupported (bug #5). THIS is the synthetic-CGEvent path that
    /// depends on which app is frontmost — callers must apply the
    /// input-focus guard immediately before calling this, not before
    /// `pressElementViaAX`.
    func clickElementCoordinateFallback(element: AXUIElement) -> Bool {
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

    /// Strategy for `typeText`.
    ///
    /// BUG-FIX v0.2.6 #6: the previous implementation always tried
    /// `ax_set_value` first. On React / Angular / Material inputs the
    /// AX set_value "succeeds" — the field visually shows the text —
    /// but the framework's `onChange` handler never fires, leaving
    /// validators seeing an empty field, counters reading "0/100",
    /// submit buttons disabled. Google Cloud Console's Add-test-users
    /// dialog was the canonical repro.
    ///
    /// The default strategy is now `.auto` with the order
    /// clipboard → unicode → ax. Clipboard-paste fires native paste
    /// events and is the single most reliable path on modern SPAs;
    /// unicode events are a good fallback for AppKit-only UIs where
    /// clipboard is noisy; ax_set_value stays as a last resort so
    /// pre-AppKit / test-harness surfaces still work.
    ///
    /// Callers that know their target can force a specific path via
    /// `.clipboard`, `.keys`, or `.ax`.
    enum TypeStrategy: String, Sendable {
        case auto       // clipboard → keys → ax
        case clipboard  // paste events only
        case keys       // CGEvent unicode only
        case ax         // AX set_value only

        /// Strategy used when a caller omits `strategy`. `auto` tries
        /// clipboard → keys → ax for event fidelity on React/Angular SPAs.
        /// Single source of truth so the default can't drift silently.
        static let `default`: TypeStrategy = .auto

        /// Resolve a raw tool argument to a concrete strategy.
        /// - `nil`/empty (argument omitted) → `.default`.
        /// - a known name (case-insensitive) → that strategy.
        /// - an unknown non-empty string → `nil` (caller reports an error).
        static func resolve(argument raw: String?) -> TypeStrategy? {
            guard let raw, !raw.isEmpty else { return .default }
            return TypeStrategy(rawValue: raw.lowercased())
        }
    }

    func typeText(text: String, strategy: TypeStrategy = .default) async -> TypeTextResult {
        switch strategy {
        case .ax:
            return setFocusedElementValue(text)
                ? TypeTextResult(success: true, strategy: "ax_set_value")
                : TypeTextResult(success: false, strategy: "none")

        case .keys:
            return typeWithUnicodeEvents(text)
                ? TypeTextResult(success: true, strategy: "cg_unicode")
                : TypeTextResult(success: false, strategy: "none")

        case .clipboard:
            return await pasteTextViaClipboard(text)
                ? TypeTextResult(success: true, strategy: "clipboard_paste")
                : TypeTextResult(success: false, strategy: "none")

        case .auto:
            // Events-first ordering — triggers real paste/input events
            // so React / Angular state stays consistent with the DOM.
            if await pasteTextViaClipboard(text) {
                return TypeTextResult(success: true, strategy: "clipboard_paste")
            }
            if typeWithUnicodeEvents(text) {
                return TypeTextResult(success: true, strategy: "cg_unicode")
            }
            if setFocusedElementValue(text) {
                return TypeTextResult(success: true, strategy: "ax_set_value")
            }
            return TypeTextResult(success: false, strategy: "none")
        }
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

    /// Press and hold a key without releasing. Pair with `keyUp` to release.
    /// Useful for building custom modifier-held sequences.
    func keyDown(keyCode: CGKeyCode, modifiers: [CGEventFlags] = []) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        else { return false }
        event.flags = modifiers.reduce(into: CGEventFlags()) { $0.formUnion($1) }
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Release a previously held key.
    func keyUp(keyCode: CGKeyCode, modifiers: [CGEventFlags] = []) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        event.flags = modifiers.reduce(into: CGEventFlags()) { $0.formUnion($1) }
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Post a sequence of keys in order. Each step is an independent
    /// down+up pair with its own modifier set, separated by `delay` seconds.
    func pressKeySequence(_ steps: [(CGKeyCode, [CGEventFlags])], delay: TimeInterval = 0.03) -> Bool {
        for (code, modifiers) in steps {
            guard pressKey(keyCode: code, modifiers: modifiers) else { return false }
            Thread.sleep(forTimeInterval: delay)
        }
        return true
    }

    // `nonisolated` so @Sendable closures (notably the pasteTextViaClipboard
    // body passed to PasteboardSnapshot.withSnapshot) can post keystrokes
    // without crossing actor boundaries. CGEvent posting is stateless
    // relative to this actor.
    nonisolated func pressKey(keyCode: CGKeyCode, modifiers: [CGEventFlags] = []) -> Bool {
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

    // MARK: - v0.2.0 deep UI

    /// Walks the AX tree for an app and returns every node (including
    /// non-actionable containers) up to `maxDepth`. Each node's `childIndices`
    /// points into the returned array so the tree can be reconstructed.
    ///
    /// `pruneRoles` (v0.9 workstream F): roles whose SUBTREE is not worth
    /// walking. The node itself is still emitted — and, crucially, its
    /// ordinal among its siblings is unchanged, so every other node's AX
    /// path and therefore its content-addressed element id stay identical
    /// to an unpruned walk.
    ///
    /// `capture_annotated` prunes `AXMenuBar`: an app's closed menus are
    /// hundreds to thousands of `AXMenuItem` nodes (Safari: 1031, Chrome:
    /// 319) that are walked BEFORE the windows, cost one IPC round trip
    /// each, and can eat the whole 5 s deadline before the walk ever
    /// reaches the window whose screenshot is being annotated. They are
    /// also never drawable: a closed menu's items are parked off-screen at
    /// 0×0 (gap audit A-4). Default empty = every existing caller behaves
    /// exactly as before.
    ///
    /// `root` (v0.9.0, Codex r1 #2): start somewhere other than the
    /// application element — in practice the `AXWindow` a `window_id`
    /// resolved to, so a sibling window's subtree is never walked. Element
    /// ids are unchanged because the root carries its own AX path.
    func treeWalk(
        pid: pid_t,
        root axRoot: WalkRoot? = nil,
        maxDepth: Int,
        nodeCap: Int = 5000,
        pruneRoles: Set<String> = []
    ) -> [TreeNode] {
        enableManualAccessibility(pid: pid)
        let root = axRoot?.element ?? AXUIElementCreateApplication(pid)
        let rootPath = axRoot?.path ?? []
        var visited = Set<AXKey>()
        var nodes: [TreeNode] = []
        // Wall-clock deadline + node cap. Without these, large AX trees
        // (Mail preview pane, Finder list view, Logic Pro with depth>=20)
        // produce thousands of IPC round trips and the MCP client just
        // hangs until it disconnects. Matches the 5 s / 5000-node budget
        // used elsewhere in this controller.
        let deadline = Date().addingTimeInterval(5.0)

        func recurse(element: AXUIElement, depth: Int, parentPath: [AXPathComponent], ordinal: Int) -> Int {
            guard Date() < deadline, nodes.count < nodeCap else { return -1 }
            // AXKey wraps CFHash + CFEqual — see its definition for why
            // the pointer address is wrong here.
            let key = AXKey(element: element)
            guard visited.insert(key).inserted else { return -1 }

            let placeholderIndex = nodes.count
            // Leaves at max depth don't need their child lists — skip
            // copying them (a big container's AXChildren is not free).
            let descend = depth < max(1, maxDepth)
            let attrs = AXAttributeBatch.fetch(element, includeChildren: descend)
            let path = depth == 0
                ? parentPath
                : AXPath.appending(
                    parentPath, role: attrs.role, index: ordinal, identifier: attrs.identifier,
                    title: attrs.title, subrole: attrs.subrole
                )
            nodes.append(
                TreeNode(
                    element: element,
                    role: attrs.role,
                    title: attrs.title,
                    value: attrs.value,
                    position: attrs.position.map { Point(x: Double($0.x), y: Double($0.y)) },
                    size: attrs.size.map { Size(width: Double($0.width), height: Double($0.height)) },
                    depth: depth,
                    childIndices: [],
                    path: path
                )
            )

            guard descend else { return placeholderIndex }
            // Pruned subtree: the node stays (and keeps its ordinal), its
            // children are not walked.
            if let role = attrs.role, pruneRoles.contains(role) { return placeholderIndex }

            var childIndices: [Int] = []
            for (childOrdinal, child) in attrs.children.enumerated() {
                if Date() >= deadline || nodes.count >= nodeCap { break }
                let idx = recurse(element: child, depth: depth + 1, parentPath: path, ordinal: childOrdinal)
                if idx >= 0 { childIndices.append(idx) }
            }

            let node = nodes[placeholderIndex]
            nodes[placeholderIndex] = TreeNode(
                element: node.element,
                role: node.role,
                title: node.title,
                value: node.value,
                position: node.position,
                size: node.size,
                depth: node.depth,
                childIndices: childIndices,
                path: node.path
            )
            return placeholderIndex
        }

        _ = recurse(element: root, depth: 0, parentPath: rootPath, ordinal: 0)
        return nodes
    }

    /// The `WalkRoot` for one of an app's windows: the window element plus
    /// the AX path an app-rooted walk would have given it.
    ///
    /// `index` is the window's ordinal in `kAXWindowsAttribute` — the same
    /// ordinal the app-rooted walk uses — so ids match exactly.
    func windowWalkRoot(element: AXUIElement, index: Int) -> WalkRoot {
        let attrs = AXAttributeBatch.fetch(element, includeChildren: false)
        return WalkRoot(
            element: element,
            path: AXPath.appending(
                [], role: attrs.role ?? "AXWindow", index: index,
                identifier: attrs.identifier, title: attrs.title, subrole: attrs.subrole
            )
        )
    }

    /// Returns all elements matching the given filters. Unlike `findElement`
    /// which returns only the first match.
    ///
    /// `root` (v0.9.0, Codex r1 #2): search a single window's subtree
    /// instead of the whole app, so `ground(window_id:)` cannot return an
    /// element belonging to an overlapping window of the same app.
    func findElements(
        pid: pid_t,
        root axRoot: WalkRoot? = nil,
        role: String?,
        title: String?,
        value: String?,
        exact: Bool = false,
        maxDepth: Int = AXDepth.default,
        limit: Int = 100,
        groundingTarget: String? = nil
    ) -> [Match] {
        // Inline recurse (same structure as treeWalk) instead of going
        // through the private `walk(...)` helper. An earlier implementation
        // used `walk` with an `inout` visited set and a closure visitor; it
        // lost ~95% of the tree to spurious dedup hits on Logic Pro's AX
        // graph (43 nodes visited vs treeWalk's 936). The interaction of
        // actor isolation + inout parameters + capturing closures appears
        // to confuse the compiler's reference handling enough to break the
        // set's identity semantics in that code path.
        //
        // Wall-clock deadline (5 s) bounds the worst-case broad query
        // against apps with massive AX trees (Finder, Logic Pro). See
        // queryElements / findElement for the same pattern.
        let deadline = Date().addingTimeInterval(5.0)
        enableManualAccessibility(pid: pid)
        let root = axRoot?.element ?? AXUIElementCreateApplication(pid)
        let rootPath = axRoot?.path ?? []
        var visited = Set<AXKey>()
        var matches: [Match] = []
        let displays = groundingTarget == nil ? [] : WindowIdentity.displayBounds().map { $0.rect }

        func recurse(element: AXUIElement, depth: Int, parentPath: [AXPathComponent], ordinal: Int) {
            guard matches.count < limit, depth <= maxDepth else { return }
            guard Date() < deadline else { return }
            // AXKey wraps CFHash + CFEqual — see its definition.
            guard visited.insert(AXKey(element: element)).inserted else { return }

            let attrs = AXAttributeBatch.fetch(element, includeChildren: true)
            let path = depth == 0
                ? parentPath
                : AXPath.appending(
                    parentPath, role: attrs.role, index: ordinal, identifier: attrs.identifier,
                    title: attrs.title, subrole: attrs.subrole
                )
            // v0.10 A5: match all label fields in the same bounded walk; title-only
            // prefiltering discarded static text before grounding could score it.
            let groundingMatch = groundingTarget.flatMap { target in
                guard let position = attrs.position, let size = attrs.size else { return GroundingPolicy.Match?.none }
                return GroundingPolicy.match(.init(role: attrs.role, title: attrs.rawTitle,
                    value: attrs.value, description: attrs.description,
                    bounds: CGRect(origin: position, size: size)), target: target, displays: displays)
            }
            if groundingTarget != nil ? groundingMatch != nil
                : Self.matchesFilter(attrs: attrs, role: role, title: title, value: value, exact: exact) {
                matches.append(Match(element: element, info: Self.elementInfo(from: attrs, depth: depth),
                                     path: path, groundingMatch: groundingMatch))
                if matches.count >= limit { return }
            }

            for (childOrdinal, child) in attrs.children.enumerated() {
                recurse(element: child, depth: depth + 1, parentPath: path, ordinal: childOrdinal)
                if matches.count >= limit { return }
            }
        }

        recurse(element: root, depth: 0, parentPath: rootPath, ordinal: 0)
        return matches
    }

    /// v0.9 (A-13): which of `role_regex`/`title_regex`/`value_regex` was
    /// not a valid regex, and why. Non-empty when at least one pattern
    /// silently fell back to case-insensitive substring matching —
    /// previously that fallback was invisible, so a typo'd/unclosed
    /// pattern and a genuine no-match both came back as plain
    /// `{ok:true, count:0}`.
    struct InvalidPattern: Sendable {
        let field: String
        let pattern: String
        let error: String
    }

    private static func compileRegex(_ pattern: String?, field: String, invalid: inout [InvalidPattern]) -> NSRegularExpression? {
        guard let pattern, !pattern.isEmpty else { return nil }
        do {
            return try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        } catch {
            invalid.append(InvalidPattern(field: field, pattern: pattern, error: error.localizedDescription))
            return nil
        }
    }

    /// Regex-aware search. Matches on role/title/value with case-insensitive
    /// regex semantics. Invalid regex falls back to literal substring —
    /// `invalidPatterns` in the result says exactly when that happened.
    func queryElements(
        pid: pid_t,
        rolePattern: String?,
        titlePattern: String?,
        valuePattern: String?,
        maxDepth: Int = AXDepth.default,
        limit: Int = 200
    ) -> (matches: [Match], invalidPatterns: [InvalidPattern]) {
        var invalidPatterns: [InvalidPattern] = []
        let roleRegex = Self.compileRegex(rolePattern, field: "role_regex", invalid: &invalidPatterns)
        let titleRegex = Self.compileRegex(titlePattern, field: "title_regex", invalid: &invalidPatterns)
        let valueRegex = Self.compileRegex(valuePattern, field: "value_regex", invalid: &invalidPatterns)

        // Inline recurse for the same reason documented in findElements:
        // the private `walk(...)` helper's inout-visited-set + capturing-
        // visitor + actor-isolation interaction drops most of the tree on
        // real applications.
        //
        // Wall-clock deadline: 5 seconds. Broad patterns like
        // `AXMenuItem` across a whole app can touch thousands of AX
        // nodes; each lookup is an IPC round trip to the target process,
        // so without a cap the query just hangs until the client
        // disconnects. Reported in v0.2.1 testing.
        let deadline = Date().addingTimeInterval(5.0)
        enableManualAccessibility(pid: pid)
        let root = AXUIElementCreateApplication(pid)
        var visited = Set<AXKey>()
        var matches: [Match] = []

        func recurse(element: AXUIElement, depth: Int, parentPath: [AXPathComponent], ordinal: Int) {
            guard matches.count < limit, depth <= maxDepth else { return }
            guard Date() < deadline else { return }
            // AXKey wraps CFHash + CFEqual — see its definition for why
            // the pointer address is wrong here.
            let key = AXKey(element: element)
            guard visited.insert(key).inserted else { return }

            let attrs = AXAttributeBatch.fetch(element, includeChildren: true)
            let path = depth == 0
                ? parentPath
                : AXPath.appending(
                    parentPath, role: attrs.role, index: ordinal, identifier: attrs.identifier,
                    title: attrs.title, subrole: attrs.subrole
                )
            let currentRole = attrs.role ?? "AXUnknown"
            let roleOk = Self.matches(regex: roleRegex, literal: rolePattern, candidate: currentRole)
            let titleOk = Self.matches(regex: titleRegex, literal: titlePattern, candidate: attrs.title ?? "")
            let valueOk = Self.matches(regex: valueRegex, literal: valuePattern, candidate: attrs.value ?? "")
            if roleOk && titleOk && valueOk {
                matches.append(Match(element: element, info: Self.elementInfo(from: attrs, depth: depth), path: path))
                if matches.count >= limit { return }
            }

            for (childOrdinal, child) in attrs.children.enumerated() {
                recurse(element: child, depth: depth + 1, parentPath: path, ordinal: childOrdinal)
                if matches.count >= limit { return }
            }
        }

        recurse(element: root, depth: 0, parentPath: [], ordinal: 0)
        return (matches, invalidPatterns)
    }

    /// List every AX attribute name exposed by this element.
    func attributeNames(element: AXUIElement) -> [String] {
        var names: CFArray?
        let status = AXUIElementCopyAttributeNames(element, &names)
        guard status == .success, let names = names as? [String] else { return [] }
        return names
    }

    /// Distinguish "the AX tree is genuinely empty for this pid" from
    /// "the query didn't find anything". The native Telegram macOS app
    /// is the canonical repro: ru.keepcoder.Telegram uses its own
    /// TGModernGrowing toolkit instead of NSAccessibility, so find/
    /// query/list all return zero even when the window is clearly on
    /// screen. Previously the tool layer reported this as a normal
    /// empty result — indistinguishable from "no match for your
    /// filter" — and the agent would retry the same query forever.
    ///
    /// Heuristic: after enableManualAccessibility(), if the root app
    /// element has zero AXChildren AND zero AXWindows exposed via AX,
    /// the app is effectively headless to the accessibility API. We
    /// return a hint so callers can surface "try a web alternative /
    /// coord-based clicks / OCR" instead of spinning.
    ///
    /// BUG-FIX v0.2.6 #8.
    struct AXTreeHealth: Codable, Sendable {
        let pid: pid_t
        let hasAXTree: Bool
        let childCount: Int
        let windowCount: Int
        let hint: String?
    }

    func probeAXTree(pid: pid_t) -> AXTreeHealth {
        enableManualAccessibility(pid: pid)
        let app = AXUIElementCreateApplication(pid)
        let children = axElementArray(of: app, attribute: kAXChildrenAttribute as CFString)
        let windows = axElementArray(of: app, attribute: kAXWindowsAttribute as CFString)

        if children.isEmpty && windows.isEmpty {
            // Look up the bundle ID so we can surface an app-specific hint.
            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
            let hint: String
            switch bundle {
            case "ru.keepcoder.Telegram":
                hint = "Telegram's native macOS app uses TGModernGrowing (not NSAccessibility) and exposes no AX tree. Use web.telegram.org in Chrome/Safari instead — Chromium's AX tree is fully populated."
            default:
                hint = "This app (\(bundle)) exposes no AX children or windows even after enabling AXManualAccessibility / AXEnhancedUserInterface. It likely does not implement NSAccessibility. Options: (a) use coord-based clicks via the `click` tool with x/y, (b) use `ocr_screen` to locate targets visually, (c) try a web alternative if one exists."
            }
            return AXTreeHealth(
                pid: pid,
                hasAXTree: false,
                childCount: 0,
                windowCount: 0,
                hint: hint
            )
        }

        return AXTreeHealth(
            pid: pid,
            hasAXTree: true,
            childCount: children.count,
            windowCount: windows.count,
            hint: nil
        )
    }

    /// List every AX action name supported by this element (e.g. AXPress).
    func actionNames(element: AXUIElement) -> [String] {
        var names: CFArray?
        let status = AXUIElementCopyActionNames(element, &names)
        guard status == .success, let names = names as? [String] else { return [] }
        return names
    }

    /// Read multiple attributes at once. Returns their string representations
    /// plus a list of attributes that weren't available on this element.
    func getAttributes(element: AXUIElement, names: [String]) -> AttributeValues {
        var values: [String: String] = [:]
        var unavailable: [String] = []

        for name in names {
            guard let raw = attributeValue(of: element, attribute: name as CFString) else {
                unavailable.append(name)
                continue
            }
            values[name] = Self.describe(raw)
        }

        return AttributeValues(values: values, unavailable: unavailable)
    }

    /// Set an attribute value. Accepts String, Bool, or Number values.
    /// Returns the AXError rawValue; 0 (.success) means it worked.
    func setAttribute(element: AXUIElement, name: String, value: JSONValue) -> Int32 {
        let cfValue: CFTypeRef
        switch value {
        case .string(let s):
            cfValue = s as CFString
        case .bool(let b):
            cfValue = NSNumber(value: b)
        case .number(let n):
            cfValue = NSNumber(value: n)
        case .null:
            return AXError.illegalArgument.rawValue
        case .array, .object:
            return AXError.illegalArgument.rawValue
        }
        let status = AXUIElementSetAttributeValue(element, name as CFString, cfValue)
        return status.rawValue
    }

    /// Outcome of `performAction`. The old Int32-only signature returned
    /// 0 (success) even when AX silently no-op'd on a disabled element —
    /// callers had to re-read state to detect the failure, which almost
    /// nobody did. This structured return lets the tool surface the
    /// specific failure class and, when relevant, the fallback that
    /// kicked in.
    struct ActionResult: Codable, Sendable {
        let ok: Bool
        /// Raw AXError code. 0 = .success; -25202 = kAXErrorActionUnsupported;
        /// -25211 = kAXErrorCannotComplete; see AXError.h for the full list.
        let axStatus: Int32
        /// "ax" | "coord_fallback" | "rejected_disabled" | "rejected_unsupported"
        let strategy: String
        /// Machine-readable failure reason when ok=false. Stable across versions.
        let reason: String?
        /// Human-readable hint for operators when ok=false.
        let hint: String?
    }

    /// Perform an arbitrary AX action on an element (AXPress, AXShowMenu,
    /// AXIncrement, AXDecrement, AXCancel, etc).
    ///
    /// BUG-FIX v0.2.6 #3 (AXEnabled check): before the underlying
    /// `AXUIElementPerformAction` call, read `AXEnabled`. AX happily
    /// reports `.success` when the target is disabled (greyed out) —
    /// the framework delivers the action, nothing consumes it, nothing
    /// observable changes. That hid logic errors in agent code for
    /// months. We now refuse the call outright when the target is
    /// disabled and surface `rejected_disabled`.
    ///
    /// BUG-FIX v0.2.6 #5 (AXPress unsupported fallback): some Chromium-
    /// rendered "buttons" expose role=AXButton but don't register AXPress
    /// (e.g. the Enable button on Google Cloud API library pages). They
    /// return -25202 kAXErrorActionUnsupported. We used to forward that
    /// error untouched, which meant every caller had to hand-roll a
    /// coordinate-click fallback. `clickElement` already did this for
    /// the dedicated "click" tool; parity with `perform_element_action`
    /// was missing. We now transparently fall back to a synthesized
    /// click at the element's bounding-box center when the action is
    /// AXPress and AXPress is unsupported. Other AX actions (AXShowMenu,
    /// AXIncrement, …) don't have a natural coord-based equivalent, so
    /// they still surface the original error.
    func performAction(element: AXUIElement, action: String) -> ActionResult {
        // #3 — refuse actions on disabled controls.
        if let enabled = stringAttribute(of: element, attribute: "AXEnabled" as CFString),
           enabled == "0" || enabled.lowercased() == "false" {
            return ActionResult(
                ok: false,
                axStatus: AXError.cannotComplete.rawValue,
                strategy: "rejected_disabled",
                reason: "target_disabled",
                hint: "AXEnabled=false on this element. Check whether the surrounding form/selection makes the control actionable before retrying."
            )
        }

        let status = AXUIElementPerformAction(element, action as CFString)
        if status == .success {
            return ActionResult(
                ok: true,
                axStatus: status.rawValue,
                strategy: "ax",
                reason: nil,
                hint: nil
            )
        }

        // #5 — AXPress not supported → coord-click fallback.
        if action == (kAXPressAction as String),
           status == .actionUnsupported {
            if let pos = pointAttribute(of: element, attribute: kAXPositionAttribute as CFString),
               let size = sizeAttribute(of: element, attribute: kAXSizeAttribute as CFString) {
                let center = CGPoint(x: pos.x + size.width / 2.0, y: pos.y + size.height / 2.0)
                if click(at: center) {
                    return ActionResult(
                        ok: true,
                        axStatus: status.rawValue,
                        strategy: "coord_fallback",
                        reason: nil,
                        hint: "Target did not implement AXPress (−25202); fell back to a synthesized click at the element's bounding-box center."
                    )
                }
            }
            return ActionResult(
                ok: false,
                axStatus: status.rawValue,
                strategy: "rejected_unsupported",
                reason: "action_unsupported_no_geometry",
                hint: "AXPress is unsupported on this element and no AXPosition/AXSize attributes were available for a coord-click fallback."
            )
        }

        return ActionResult(
            ok: false,
            axStatus: status.rawValue,
            strategy: "ax",
            reason: axStatusReason(status),
            hint: "AX action \(action) returned \(status.rawValue). See AXError.h for the code meaning."
        )
    }

    /// Human-stable short strings for the AXError codes we surface most.
    /// Full mapping lives in AXError.h; we only translate the ones that
    /// actually ship through performAction.
    private func axStatusReason(_ status: AXError) -> String {
        switch status {
        case .success: return "ok"
        case .actionUnsupported: return "action_unsupported"
        case .attributeUnsupported: return "attribute_unsupported"
        case .cannotComplete: return "cannot_complete"
        case .invalidUIElement: return "invalid_ui_element"
        case .notImplemented: return "not_implemented"
        case .notificationUnsupported: return "notification_unsupported"
        default: return "ax_error_\(status.rawValue)"
        }
    }

    // MARK: - helpers for v0.2.0

    static func matchesFilter(
        attrs: AXAttributeBatch.Values,
        role: String?,
        title: String?,
        value: String?,
        exact: Bool = false
    ) -> Bool {
        guard textMatches(filter: role, candidate: attrs.role ?? "AXUnknown", exact: exact) else { return false }
        guard textMatches(filter: title, candidate: attrs.title ?? "", exact: exact) else { return false }
        guard textMatches(filter: value, candidate: attrs.value ?? "", exact: exact) else { return false }
        return true
    }

    static func elementInfo(from attrs: AXAttributeBatch.Values, depth: Int?) -> ElementInfo {
        ElementInfo(
            role: attrs.role,
            title: attrs.title,
            value: attrs.value,
            position: attrs.position.map { Point(x: Double($0.x), y: Double($0.y)) },
            size: attrs.size.map { Size(width: Double($0.width), height: Double($0.height)) },
            depth: depth
        )
    }

    private static func matches(regex: NSRegularExpression?, literal: String?, candidate: String) -> Bool {
        if let regex {
            let range = NSRange(candidate.startIndex..., in: candidate)
            return regex.firstMatch(in: candidate, range: range) != nil
        }
        guard let literal, !literal.isEmpty else { return true }
        return candidate.range(of: literal, options: [.caseInsensitive]) != nil
    }

    private static func describe(_ value: AnyObject) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let arr = value as? [AnyObject] { return "[\(arr.count) items]" }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return "<AXUIElement>" }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let axValue = unsafeDowncast(value, to: AXValue.self)
            switch AXValueGetType(axValue) {
            case .cgPoint:
                var p = CGPoint.zero
                if AXValueGetValue(axValue, .cgPoint, &p) { return "point(\(p.x),\(p.y))" }
            case .cgSize:
                var s = CGSize.zero
                if AXValueGetValue(axValue, .cgSize, &s) { return "size(\(s.width),\(s.height))" }
            case .cgRect:
                var r = CGRect.zero
                if AXValueGetValue(axValue, .cgRect, &r) {
                    return "rect(\(r.origin.x),\(r.origin.y),\(r.size.width),\(r.size.height))"
                }
            case .cfRange:
                var rng = CFRange(location: 0, length: 0)
                if AXValueGetValue(axValue, .cfRange, &rng) { return "range(\(rng.location),\(rng.length))" }
            default:
                break
            }
        }
        return String(describing: value)
    }

    private func buildElementInfo(element: AXUIElement, depth: Int?, cachedRole: String?) -> ElementInfo {
        let info = Self.elementInfo(
            from: AXAttributeBatch.fetch(element, includeChildren: false),
            depth: depth
        )
        guard let cachedRole else { return info }
        return ElementInfo(
            role: cachedRole, title: info.title, value: info.value,
            position: info.position, size: info.size, depth: info.depth
        )
    }

    @discardableResult
    // Legacy helper retained only for `listElements` (v0.1 code path).
    // Uses CFHash(element) for cycle detection — see findElements for the
    // detailed rationale. Core Foundation recycles freed CFRef pointers,
    // so a pointer-keyed visited set silently drops most of a real app's
    // AX tree once elements get released and their addresses reused.
    private func walk(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        visited: inout Set<AXKey>,
        deadline: Date,
        nodeCap: Int = 5000,
        visitor: (AXUIElement, Int, AXAttributeBatch.Values) -> Bool
    ) -> Bool {
        guard depth <= maxDepth else { return false }
        // Wall-clock + node-count budget. Each AX attribute read is an IPC
        // round trip; a wide tree (thousands of nodes) would otherwise let
        // list_elements hang the server until the client gives up. Returning
        // `true` unwinds the recursion. Matches treeWalk/findElements' budget.
        guard Date() < deadline, visited.count < nodeCap else { return true }

        guard visited.insert(AXKey(element: element)).inserted else { return false }

        let attrs = AXAttributeBatch.fetch(element, includeChildren: depth < maxDepth)
        if visitor(element, depth, attrs) {
            return true
        }

        for child in attrs.children {
            if walk(element: child, depth: depth + 1, maxDepth: maxDepth, visited: &visited, deadline: deadline, nodeCap: nodeCap, visitor: visitor) {
                return true
            }
        }

        return false
    }

    // BUG-FIX v0.2.6 #4: Modern web apps (React/Angular/Shadcn) label
    // buttons via `aria-label` → AXDescription, leaving AXTitle as the
    // empty string ("") rather than nil. The old `??` chain preferred
    // AXTitle even when empty, so `title_regex: "^Save$"` matched zero
    // elements on Google Cloud Console, Linear, Notion — every modern
    // SPA. The fallback now rejects empty / whitespace-only strings
    // before falling through, so an aria-labelled button's description
    // is reachable via the same `title` filter callers already use.
    //
    // Sources priority order (unchanged): AXTitle → AXDescription →
    // AXIdentifier. Only the "present but empty" handling changed.
    private func title(for element: AXUIElement) -> String? {
        func nonEmpty(_ attribute: CFString) -> String? {
            guard let s = stringAttribute(of: element, attribute: attribute),
                  !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return s
        }
        return nonEmpty(kAXTitleAttribute as CFString)
            ?? nonEmpty(kAXDescriptionAttribute as CFString)
            ?? nonEmpty("AXIdentifier" as CFString)
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        // Merge kAXChildrenAttribute with kAXSheetsAttribute. On macOS a
        // presented sheet is attached to its host window via kAXSheets and
        // is NOT always reflected in kAXChildren. Without this merge,
        // find_elements(role: "AXSheet") returns 0 even when a sheet is
        // visible (e.g. Mail's Add Attachments panel). Same for any
        // subtree that lives under the sheet. Dedup happens upstream via
        // AXKey visited-set, so listing a child here twice is safe.
        var result: [AXUIElement] = []
        result.append(contentsOf: axElementArray(of: element, attribute: kAXChildrenAttribute as CFString))
        // kAXSheetsAttribute is not exported as a Swift constant — use the
        // raw attribute name. Matches NSAccessibilitySheetsAttribute.
        let sheets = axElementArray(of: element, attribute: "AXSheets" as CFString)
        if !sheets.isEmpty { result.append(contentsOf: sheets) }
        return result
    }

    private func axElementArray(of element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        guard let raw = attributeValue(of: element, attribute: attribute) else { return [] }
        if let arr = raw as? [AXUIElement] { return arr }
        if let arr = raw as? NSArray {
            return arr.compactMap { child in
                guard CFGetTypeID(child as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
                return unsafeDowncast(child as AnyObject, to: AXUIElement.self)
            }
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
        // Every conversion step is guarded — Optional return signals
        // "no valid geometry" cleanly. AXValueGetValue returns false if
        // the stored type doesn't match the requested kind, in which case
        // the pointee is undefined (NOT zero), so we must honour the bool.
        guard let raw = attributeValue(of: element, attribute: attribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(of element: AXUIElement, attribute: CFString) -> CGSize? {
        guard let raw = attributeValue(of: element, attribute: attribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
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

    private func pasteTextViaClipboard(_ text: String) async -> Bool {
        // withSnapshot guarantees restore runs before we return (was a
        // detached Task in the previous version, which Codex flagged as a
        // race against the next pasteboard op).
        await PasteboardSnapshot.withSnapshot {
            let setOK = await MainActor.run { () -> Bool in
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
            }
            guard setOK else { return false }
            let pasted = pressKey(keyCode: 9, modifiers: [.maskCommand])
            try? await Task.sleep(nanoseconds: 50_000_000)
            return pasted
        }
    }
}
