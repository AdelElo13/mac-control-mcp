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
    // v0.10 A4/B7: isolate blocking AX reads from traversal policy so the
    // same walker can run on a worker queue and deterministic AX fixtures.
    nonisolated let readAttributes: @Sendable (AXUIElement, Bool) -> AXAttributeBatch.Values
    /// Same reader with the "inside an AXWebArea" flag the ranked search
    /// needs for web attributes (url / dom id). An injected fixture reader
    /// ignores the flag; the default asks AX for the web attributes.
    nonisolated let readAttributesInWeb: @Sendable (AXUIElement, Bool, Bool) -> AXAttributeBatch.Values
    private let prepareAccessibility: @Sendable (pid_t) -> Void
    private let readWindowFrames: (@Sendable (pid_t) -> [CGRect])?

    init(
        readAttributes: (@Sendable (AXUIElement, Bool) -> AXAttributeBatch.Values)? = nil,
        prepareAccessibility: @escaping @Sendable (pid_t) -> Void = AccessibilityController.prepareApplication,
        readWindowFrames: (@Sendable (pid_t) -> [CGRect])? = nil
    ) {
        if let readAttributes {
            self.readAttributes = readAttributes
            self.readAttributesInWeb = { element, children, _ in readAttributes(element, children) }
        } else {
            self.readAttributes = { AXAttributeBatch.fetch($0, includeChildren: $1) }
            self.readAttributesInWeb = { AXAttributeBatch.fetch($0, includeChildren: $1, insideWebArea: $2) }
        }
        self.prepareAccessibility = prepareAccessibility
        self.readWindowFrames = readWindowFrames
    }

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
        var web: [String: String] = [:]
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
        var childIndices: [Int]   // indices into the flat array returned by treeWalk
        /// Position in the app's AX tree, from the application root.
        /// Feeds the content-addressed element id (v0.9 C-5).
        let path: [AXPathComponent]
        var web: [String: String] = [:]
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
        var matchedField: String = "role"
        var match: String = "exact"
        var rankReason: String = ""
        /// v0.10 A5: set only by the grounding walk (`groundingTarget`).
        var groundingMatch: GroundingPolicy.Match? = nil
        /// v0.10 merge: the batched attributes the match was made from, so
        /// grounding can score title/value/description without a re-read.
        var attrs: AXAttributeBatch.Values? = nil
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

    func checkPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Frames of the app's AX windows, in global screen points. Used by
    /// the `viewport_only` payload filter (v0.9 C-9) as "the app's
    /// on-screen window bounds": a node whose frame intersects none of
    /// these is not visible in any of this app's windows.
    func windowFrames(pid: pid_t) async -> [CGRect] {
        let readWindows = readWindowFrames
        return await withWalkQueue(pid: pid) {
            if let readWindows { return readWindows(pid) }
            let app = AXUIElementCreateApplication(pid)
            return AXPath.copyElements(app, kAXWindowsAttribute as String).compactMap { window in
                // v0.10 B1: minimized windows cannot make descendants visible.
                if let minimized = AXPath.copyString(window, kAXMinimizedAttribute as String),
                   minimized == "1" || minimized.lowercased() == "true" { return nil }
                let attrs = AXAttributeBatch.fetch(window, includeChildren: false)
                guard let origin = attrs.position, let size = attrs.size else { return nil }
                return CGRect(origin: origin, size: size)
            }
        }
    }

    /// v0.9 (C-4) — AX hit-test. The inverse of `ground`: "what is under
    /// this coordinate?".
    ///
    /// `pid == nil` asks the system-wide element, which routes to
    /// whichever app owns that point; a pid restricts the hit-test to
    /// that application, which is what you want when a window is
    /// occluded by another app.
    func elementAtPoint(x: Double, y: Double, pid: pid_t?) async -> AXUIElement? {
        let read: @Sendable () -> AXUIElement? = {
            let root = pid.map { AXUIElementCreateApplication($0) } ?? AXUIElementCreateSystemWide()
            var element: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(root, Float(x), Float(y), &element)
            guard status == .success else { return nil }
            return element
        }
        // v0.10 B7: a pid-scoped hit test must wait for that pid's queued
        // preparation just like a tree walk; queued does not mean ready.
        if let pid { return await withWalkQueue(pid: pid, work: read) }
        return read()
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
        var identity: AXPath.Reconstruction? = nil
    }

    func describeHit(element: AXUIElement, ancestorLimit: Int = 8) -> HitTest? {
        guard let pid = ownerPID(of: element) else { return nil }
        let attrs = AXAttributeBatch.fetch(element, includeChildren: false)
        let enabled: Bool? = AXPath.copyString(element, "AXEnabled").map { $0 == "1" || $0.lowercased() == "true" }
        let ancestors = AXPath.ancestors(of: element, limit: ancestorLimit).map {
            (role: AXPath.copyString($0, "AXRole"),
             title: AXPath.copyString($0, "AXTitle") ?? AXPath.copyString($0, "AXDescription"))
        }
        let identity = AXPath.reconstruct(element: element)
        return HitTest(
            info: Self.elementInfo(from: attrs, depth: nil),
            enabled: enabled,
            pid: pid,
            appName: NSRunningApplication(processIdentifier: pid)?.localizedName,
            path: identity.path,
            ancestors: ancestors,
            identity: identity
        )
    }

    func requestPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// PIDs for which we've already flipped AXManualAccessibility on.
    /// Used to avoid paying the IPC cost on every AX call.
    private var preparationQueuedPIDs: Set<pid_t> = []

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
    private nonisolated static func prepareApplication(pid: pid_t) {
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
    }

    func listElements(pid: pid_t, maxDepth: Int = AXDepth.default) async -> [ElementInfo] {
        await search(pid: pid, maxDepth: maxDepth, interactiveOnly: true).matches.map(\.info)
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
        pid: pid_t, role: String?, title: String?, exact: Bool = false,
        maxDepth: Int = AXDepth.default
    ) async -> AXUIElement? {
        // v0.10 B3/B4: action helpers retain their existing full-DFS/menu
        // selection; the read tool opts into shallow-first search below.
        await findElementWithPath(pid: pid, role: role, title: title, exact: exact,
                                  maxDepth: maxDepth, includeMenus: true, shallowFirst: false)?.element
    }

    /// v0.10 B4: shallow-first uses one breadth-first pass, preserving
    /// original path ordinals without re-reading the first eight levels.
    func findElementWithPath(
        pid: pid_t, role: String?, title: String?, exact: Bool = false,
        maxDepth: Int = AXDepth.default, includeMenus: Bool = true,
        shallowFirst: Bool = false
    ) async -> (element: AXUIElement, path: [AXPathComponent])? {
        let result = await search(
            pid: pid, maxDepth: maxDepth, limit: 1, includeMenus: includeMenus,
            shallowFirst: shallowFirst,
            stopOnBest: shallowFirst ? Self.exactTitlePreference(title) : nil,
            predicate: { attrs in
                Self.textMatches(filter: role, candidate: attrs.role ?? "AXUnknown", exact: exact)
                    && (Self.textMatches(filter: title, candidate: attrs.title ?? "", exact: exact)
                        || Self.textMatches(filter: title, candidate: attrs.value ?? "", exact: exact))
            }
        )
        return result.matches.first.map { ($0.element, $0.path) }
    }

    /// v0.10 B4: partial labels remain fallbacks; an exact label is a
    /// best-quality hit and cannot improve by walking deeper. No extra IO.
    nonisolated static func exactTitlePreference(_ title: String?) -> (@Sendable (AXAttributeBatch.Values) -> Bool)? {
        guard let title, !title.isEmpty else { return nil }
        return { attrs in
            textMatches(filter: title, candidate: attrs.title ?? "", exact: true)
                || textMatches(filter: title, candidate: attrs.value ?? "", exact: true)
        }
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

    /// v0.10 B1/B3/B7: walk on a per-pid serial queue. Other apps can
    /// answer concurrently; no blocking AX IPC occupies this actor.
    /// Pruning never renumbers siblings, preserving path-derived ids.
    func treeWalk(
        pid: pid_t, root axRoot: WalkRoot? = nil, maxDepth: Int,
        nodeCap: Int = 5000, pruneRoles: Set<String> = [],
        includeMenus: Bool = true, clipRects: [CGRect] = []
    ) async -> [TreeNode] {
        await treeWalkResult(pid: pid, root: axRoot, maxDepth: maxDepth, nodeCap: nodeCap,
                             pruneRoles: pruneRoles, includeMenus: includeMenus, clipRects: clipRects).nodes
    }

    func treeWalkResult(
        pid: pid_t, root axRoot: WalkRoot? = nil, maxDepth: Int,
        nodeCap: Int = 5000, pruneRoles: Set<String> = [],
        includeMenus: Bool = true, clipRects: [CGRect] = [], timeBudget: TimeInterval = 5
    ) async -> WalkResult {
        await search(pid: pid, root: axRoot, maxDepth: maxDepth, nodeCap: nodeCap,
                     includeMenus: includeMenus, clipRects: clipRects,
                     pruneRoles: pruneRoles, collectNodes: true, timeBudget: timeBudget, predicate: { _ in false })
    }

    struct WalkResult: Sendable {
        var nodes: [TreeNode] = []
        var matches: [Match] = []
        var nodesVisited = 0
        var nodeCapReached = false
        var timedOut = false
        var timingsMS: [String: Double] = [:]
    }

    private var walkQueues: [pid_t: DispatchQueue] = [:]

    /// v0.10 A4: filtering is part of matching, before the match limit.
    /// v0.10 B7: the queue stays serial until IPC actually returns, even
    /// when the caller is cancelled; timed-out work must never overlap a
    /// subsequent walk of the same pid.
    func search(
        pid: pid_t, root axRoot: WalkRoot? = nil, maxDepth: Int = AXDepth.default,
        nodeCap: Int = .max, limit: Int = .max, includeMenus: Bool = false,
        clipRects: [CGRect] = [], viewportOnly: Bool = false, interactiveOnly: Bool = false,
        pruneRoles: Set<String> = [], collectNodes: Bool = false, shallowFirst: Bool = false,
        timeBudget: TimeInterval = 5,
        stopOnBest: (@Sendable (AXAttributeBatch.Values) -> Bool)? = nil,
        predicate: @escaping @Sendable (AXAttributeBatch.Values) -> Bool = { _ in true }
    ) async -> WalkResult {
        let root = axRoot ?? WalkRoot(element: AXUIElementCreateApplication(pid), path: [])
        let fetch = readAttributes
        return await withTimedWalkQueue(pid: pid) { queueMS, prepareMS in
            let started = ProcessInfo.processInfo.systemUptime
            var result = Self.walkTree(
                root: root, maxDepth: maxDepth, nodeCap: max(1, nodeCap), limit: max(1, limit),
                includeMenus: includeMenus, clipRects: clipRects, viewportOnly: viewportOnly,
                interactiveOnly: interactiveOnly, pruneRoles: pruneRoles,
                collectNodes: collectNodes, breadthFirst: shallowFirst,
                deadline: started + max(0, timeBudget), fetch: fetch,
                stopOnBest: stopOnBest, predicate: predicate
            )
            result.timingsMS["queue"] = queueMS
            result.timingsMS["prepare"] = prepareMS
            result.timingsMS["walk"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            return result
        }
    }

    private func withWalkQueue<Value: Sendable>(
        pid: pid_t, work: @escaping @Sendable () -> Value
    ) async -> Value {
        await withTimedWalkQueue(pid: pid) { _, _ in work() }
    }

    /// v0.10 B1/B7: drain per-request Objective-C temporaries BEFORE
    /// resuming the caller. Queue reuse retains no AX frames or results.
    /// Legacy entry point kept for the synchronous grounding / ranked walks
    /// (S3 / S5): same once-per-pid AXManualAccessibility preparation the
    /// queued walks do.
    private func enableManualAccessibility(pid: pid_t) {
        if preparationQueuedPIDs.insert(pid).inserted { prepareAccessibility(pid) }
    }

    private func withTimedWalkQueue<Value: Sendable>(
        pid: pid_t, work: @escaping @Sendable (Double, Double) -> Value
    ) async -> Value {
        let prepare = preparationQueuedPIDs.insert(pid).inserted ? prepareAccessibility : nil
        let queue: DispatchQueue
        if let existing = walkQueues[pid] {
            queue = existing
        } else {
            queue = DispatchQueue(label: "mac-control-mcp.ax-walk.\(pid)",
                                  qos: .userInitiated, target: BlockingWorkPool.sharedQueue)
            walkQueues[pid] = queue
        }
        let enqueued = ProcessInfo.processInfo.systemUptime
        return await withCheckedContinuation { continuation in
            queue.async {
                let value = autoreleasepool {
                    let started = ProcessInfo.processInfo.systemUptime
                    prepare?(pid)
                    let prepared = ProcessInfo.processInfo.systemUptime
                    return work((started - enqueued) * 1000, (prepared - started) * 1000)
                }
                continuation.resume(returning: value)
            }
        }
    }

    private struct PendingNode {
        let element: AXUIElement
        let depth: Int
        let parentPath: [AXPathComponent]
        let ordinal: Int
        let parentIndex: Int?
    }

    /// v0.10 B1/B4: a cursor borrows an AX child array instead of allocating
    /// one work item per child before the next budget/limit check.
    private struct PendingChildren {
        let elements: [AXUIElement]
        var ordinal = 0
        let depth: Int
        let parentPath: [AXPathComponent]
        let parentIndex: Int?
    }

    private nonisolated static func walkTree(
        root: WalkRoot, maxDepth: Int, nodeCap: Int, limit: Int,
        includeMenus: Bool, clipRects: [CGRect], viewportOnly: Bool, interactiveOnly: Bool,
        pruneRoles: Set<String>, collectNodes: Bool, breadthFirst: Bool, deadline: TimeInterval,
        fetch: @Sendable (AXUIElement, Bool) -> AXAttributeBatch.Values,
        stopOnBest: (@Sendable (AXAttributeBatch.Values) -> Bool)?,
        predicate: @Sendable (AXAttributeBatch.Values) -> Bool
    ) -> WalkResult {
        var visited = Set<AXKey>()
        var result = WalkResult()
        var pending: [PendingChildren?] = [.init(elements: [root.element], depth: 0,
                                               parentPath: root.path, parentIndex: nil)]
        var head = 0
        var fetchMS = 0.0
        var effectiveDeadline = deadline
        while breadthFirst ? head < pending.count : !pending.isEmpty {
            if result.matches.count >= limit && stopOnBest == nil { break }
            guard ProcessInfo.processInfo.systemUptime < effectiveDeadline else { result.timedOut = true; break }
            guard visited.count < nodeCap else { result.nodeCapReached = true; break }
            let offset = breadthFirst ? head : pending.count - 1
            let siblings = pending[offset]!
            let next = PendingNode(element: siblings.elements[siblings.ordinal], depth: siblings.depth,
                                   parentPath: siblings.parentPath, ordinal: siblings.ordinal,
                                   parentIndex: siblings.parentIndex)
            if siblings.ordinal + 1 < siblings.elements.count {
                pending[offset]!.ordinal += 1
            } else if breadthFirst {
                pending[offset] = nil
                head += 1
            } else {
                pending.removeLast()
            }
            guard visited.insert(AXKey(element: next.element)).inserted else { continue }
            let descend = next.depth < max(1, maxDepth)
            let fetched = ProcessInfo.processInfo.systemUptime
            // v0.10 B1/B7: AX batch decoding bridges autoreleased Foundation
            // values. A per-node pool prevents large walks accumulating them.
            let attrs = autoreleasepool { fetch(next.element, descend) }
            fetchMS += (ProcessInfo.processInfo.systemUptime - fetched) * 1000
            if !includeMenus && attrs.role == "AXMenuBar" { continue }
            let path = next.depth == 0 ? next.parentPath : AXPath.appending(
                next.parentPath, role: attrs.role, index: next.ordinal, identifier: attrs.identifier,
                title: attrs.title, subrole: attrs.subrole
            )
            let frame: CGRect? = attrs.position.flatMap { origin in attrs.size.map { CGRect(origin: origin, size: $0) } }
            let info = Self.elementInfo(from: attrs, depth: next.depth)
            if (!interactiveOnly || AXPayload.isInteractive(role: attrs.role))
                && (!viewportOnly || AXPayload.isInViewport(frame: frame, windows: clipRects))
                && predicate(attrs) {
                let match = Match(element: next.element, info: info, path: path, attrs: attrs)
                if stopOnBest?(attrs) == true {
                    result.matches = [match]
                    break
                }
                if result.matches.count < limit {
                    result.matches.append(match)
                    // v0.10 B4: once enough usable fallbacks are held, an
                    // absent exact label must not force another full-tree walk.
                    // Tighten once; later substring hits cannot renew the budget.
                    if stopOnBest != nil && result.matches.count == limit {
                        effectiveDeadline = min(effectiveDeadline, ProcessInfo.processInfo.systemUptime + 0.1)
                    }
                }
            }
            let index = result.nodes.count
            if collectNodes {
                result.nodes.append(TreeNode(element: next.element, role: attrs.role, title: attrs.title, value: attrs.value,
                                             position: info.position, size: info.size, depth: next.depth, childIndices: [], path: path))
                if let parent = next.parentIndex {
                    result.nodes[parent].childIndices.append(index)
                }
            }
            // v0.10 B1/B2: unknown/zero geometry still descends; original
            // child ordinals survive pruning and both traversal orders.
            if descend && !pruneRoles.contains(attrs.role ?? "")
                && !AXPayload.shouldPrune(frame: frame, clips: clipRects) {
                if !attrs.children.isEmpty {
                    pending.append(.init(elements: attrs.children, depth: next.depth + 1,
                                         parentPath: path, parentIndex: collectNodes ? index : nil))
                }
            }
        }
        result.nodesVisited = visited.count
        result.nodeCapReached = result.nodeCapReached || visited.count >= nodeCap
        result.timingsMS["ax_fetch"] = fetchMS
        return result
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
        semantic: String? = nil,
        groundingTarget: String? = nil,
        includeMenus: Bool = true, clipRects: [CGRect] = [],
        viewportOnly: Bool = false, interactiveOnly: Bool = false
    ) async -> [Match] {
        // v0.10 merge of S3 (grounding) and S5 (ranked search): a grounding
        // target scores every label field with GroundingPolicy inside one
        // bounded walk and must not go through the ranked-search filters;
        // every other query takes the ranked AXSearch path.
        if let groundingTarget {
            return groundingWalk(pid: pid, root: axRoot, maxDepth: maxDepth, limit: limit, target: groundingTarget).matches
        }
        return await findElementsWithStats(pid: pid, root: axRoot, role: role, title: title, value: value,
                              exact: exact, maxDepth: maxDepth, limit: limit, semantic: semantic,
                              interactiveOnly: interactiveOnly, viewportOnly: viewportOnly,
                              includeMenus: includeMenus).matches
    }

    /// v0.10 A5 (S3): grounding search — GroundingPolicy.match on role /
    /// title / value / description of every node in a bounded DFS.
    func groundingWalk(pid: pid_t, root axRoot: WalkRoot?, maxDepth: Int, limit: Int, target: String) -> (matches: [Match], nodesVisited: Int) {
        let deadline = Date().addingTimeInterval(5.0)
        enableManualAccessibility(pid: pid)
        let root = axRoot?.element ?? AXUIElementCreateApplication(pid)
        let rootPath = axRoot?.path ?? []
        var visited = Set<AXKey>()
        var matches: [Match] = []
        let displays = WindowIdentity.displayBounds().map { $0.rect }

        func recurse(element: AXUIElement, depth: Int, parentPath: [AXPathComponent], ordinal: Int) {
            guard matches.count < limit, depth <= maxDepth else { return }
            guard Date() < deadline else { return }
            guard visited.insert(AXKey(element: element)).inserted else { return }
            let attrs = AXAttributeBatch.fetch(element, includeChildren: true)
            let path = depth == 0
                ? parentPath
                : AXPath.appending(
                    parentPath, role: attrs.role, index: ordinal, identifier: attrs.identifier,
                    title: attrs.title, subrole: attrs.subrole
                )
            let groundingMatch: GroundingPolicy.Match? = {
                guard let position = attrs.position, let size = attrs.size else { return nil }
                return GroundingPolicy.match(.init(role: attrs.role, title: attrs.rawTitle ?? attrs.title,
                    value: attrs.value, description: attrs.description,
                    bounds: CGRect(origin: position, size: size)), target: target, displays: displays)
            }()
            if let groundingMatch {
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
        return (matches, visited.count)
    }

    struct SearchResult {
        let matches: [Match]
        let nodesVisited: Int
        let stoppedEarly: Bool
        let truncated: Bool
    }

    func findElementsWithStats(
        pid: pid_t, root: WalkRoot? = nil, role: String?, title: String?, value: String?,
        exact: Bool = false, maxDepth: Int = AXDepth.default, limit: Int = 100, semantic: String? = nil,
        interactiveOnly: Bool = false, viewportOnly: Bool = false, includeMenus: Bool = true
    ) async -> SearchResult {
        let windows = viewportOnly ? await windowFrames(pid: pid) : nil
        return searchSnapshot(pid: pid, root: root, maxDepth: maxDepth,
                       query: AXSearch.Query(role: role, title: title, value: value, exact: exact, semantic: semantic), limit: limit,
                       interactiveOnly: interactiveOnly, windows: windows, includeMenus: includeMenus)
    }

    // v0.10 C5: keep traversal and its read-count evidence on one code path.
    private func searchSnapshot(pid: pid_t, root axRoot: WalkRoot? = nil, maxDepth: Int,
                                query: AXSearch.Query, limit: Int, regex: Bool = false,
                                interactiveOnly: Bool = false, windows: [CGRect]? = nil,
                                includeMenus: Bool = true) -> SearchResult {
        let deadline = Date().addingTimeInterval(5)
        enableManualAccessibility(pid: pid)
        let read = readAttributesInWeb
        let result = AXSearch.walk(root: AXKey(element: axRoot?.element ?? AXUIElementCreateApplication(pid)),
                                   rootPath: axRoot?.path ?? [], maxDepth: maxDepth,
                                   deadline: deadline, query: query, limit: limit, regex: regex,
                                   includeMenus: includeMenus, eligible: { attrs in
            // v0.10 C5: payload-ineligible hits must not consume the limit
            // or stop the walk before their eligible descendants are read.
            guard !interactiveOnly || AXPayload.isInteractive(role: attrs.role) else { return false }
            guard let windows else { return true }
            let frame = attrs.position.flatMap { point in attrs.size.map { CGRect(origin: point, size: $0) } }
            return AXPayload.isInViewport(frame: frame, windows: windows)
        }) { key, children, web in
            let attrs = autoreleasepool { read(key.element, children, web) }
            return (attrs, attrs.children.map { AXKey(element: $0) })
        }
        let matches = result.hits.map { hit in
            let entry = result.entries[hit.index]
            return Match(element: entry.element.element, info: Self.elementInfo(from: entry.attrs, depth: entry.depth),
                         path: entry.path, matchedField: hit.field, match: hit.kind, rankReason: hit.reason)
        }
        return SearchResult(matches: matches, nodesVisited: result.entries.count,
                            stoppedEarly: result.stoppedEarly, truncated: result.truncated)
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
        pid: pid_t, rolePattern: String?, titlePattern: String?, valuePattern: String?,
        maxDepth: Int = AXDepth.default, limit: Int = 200, nodeCap: Int = 2000,
        includeMenus: Bool = false, clipRects: [CGRect] = [],
        viewportOnly: Bool = false, interactiveOnly: Bool = false, timeBudget: TimeInterval = 1
    ) async -> (matches: [Match], invalidPatterns: [InvalidPattern], walk: WalkResult) {
        var invalidPatterns: [InvalidPattern] = []
        let roleRegex = Self.compileRegex(rolePattern, field: "role_regex", invalid: &invalidPatterns)
        let titleRegex = Self.compileRegex(titlePattern, field: "title_regex", invalid: &invalidPatterns)
        let valueRegex = Self.compileRegex(valuePattern, field: "value_regex", invalid: &invalidPatterns)
        // v0.10 B3: anchored literal matches have equal best quality, so
        // BFS may stop at limit without exploring earlier deep subtrees.
        let patterns = [rolePattern, titlePattern, valuePattern].compactMap { $0 }.filter { !$0.isEmpty }
        let anchored = !patterns.isEmpty && patterns.allSatisfy(Self.isAnchoredLiteral)
        let walk = await search(
            pid: pid, maxDepth: maxDepth, nodeCap: nodeCap, limit: limit,
            includeMenus: includeMenus, clipRects: clipRects, viewportOnly: viewportOnly,
            interactiveOnly: interactiveOnly, shallowFirst: anchored, timeBudget: timeBudget, predicate: { attrs in
                Self.matches(regex: roleRegex, literal: rolePattern, candidate: attrs.role ?? "AXUnknown")
                    && Self.matches(regex: titleRegex, literal: titlePattern, candidate: attrs.title ?? "")
                    && Self.matches(regex: valueRegex, literal: valuePattern, candidate: attrs.value ?? "")
            }
        )
        return (walk.matches, invalidPatterns, walk)
    }

    nonisolated static func isAnchoredLiteral(_ pattern: String) -> Bool {
        guard pattern.hasPrefix("^"), pattern.hasSuffix("$"), pattern.count > 2 else { return false }
        // v0.10 B3: alternation, wildcards, escapes and lookarounds keep
        // their regex path; only unambiguous literal equality is fast-tracked.
        return !pattern.dropFirst().dropLast().contains { ".*+?[](){}|\\^$".contains($0) }
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
    /// Heuristic: after AX preparation, if the root app
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

    func probeAXTree(pid: pid_t) async -> AXTreeHealth {
        // v0.10 B7: health reads share the queue so they cannot observe
        // the app before its pending AX preparation has completed.
        await withWalkQueue(pid: pid) {
            let app = AXUIElementCreateApplication(pid)
            let children = AXPath.copyElements(app, kAXChildrenAttribute as String)
            let windows = AXPath.copyElements(app, kAXWindowsAttribute as String)

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
        !AXSearch.search([AXSearch.Node(attrs: attrs, parent: nil)], role: role, title: title, value: value, exact: exact).isEmpty
    }

    static func elementInfo(from attrs: AXAttributeBatch.Values, depth: Int?) -> ElementInfo {
        ElementInfo(
            role: attrs.role,
            title: attrs.title,
            value: attrs.value,
            position: attrs.position.map { Point(x: Double($0.x), y: Double($0.y)) },
            size: attrs.size.map { Size(width: Double($0.width), height: Double($0.height)) },
            depth: depth,
            web: attrs.web
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
