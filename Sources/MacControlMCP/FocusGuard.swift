import Foundation
import ApplicationServices
import AppKit

/// Guards synthetic input (CGEvent keyboard/mouse) against landing in the
/// wrong app when the frontmost app changes between an agent's check and
/// its keystroke/click.
///
/// Background: `press_key` / `type_text` / `click` (coordinate path) /
/// `mouse_event` / `scroll` / `drag_and_drop` all post `CGEvent`s that the
/// window server delivers to whatever app is frontmost *at delivery time*
/// — not whatever app the caller last observed. When two MCP clients (or
/// any two callers) drive this server concurrently, another app can steal
/// focus between the caller's `focused_app` check and its `press_key`
/// call, so a `cmd+a` / `cmd+v` lands in the wrong window. This was
/// measured with two concurrent MCP clients (Claude + ChatGPT) both
/// driving the server.
///
/// `FocusGuard.evaluate` is the pure, unit-testable matching function.
/// `FocusGuard.currentFocus()` is the thin AX/NSWorkspace wrapper that
/// gathers the "actual" side of the comparison. Tool handlers call
/// `ToolRegistry.checkFocusGuard` (see `Tools.swift`) right before
/// injecting synthetic input.
enum FocusGuard {
    /// Snapshot of what is actually focused right now.
    struct ActualFocus: Sendable, Equatable {
        let appName: String?
        let bundleIdentifier: String?
        let pid: pid_t?
        let windowTitle: String?
    }

    /// Outcome of comparing expected vs. actual focus.
    enum MatchResult: Sendable, Equatable {
        case match
        case mismatch(reason: String)
    }

    /// Pure matching logic — no AX/NSWorkspace calls, fully unit-testable.
    ///
    /// - `expectedApp` matches if it equals (case-insensitively) either the
    ///   actual bundle identifier OR the actual localized app name.
    /// - `expectedWindow` matches if the actual window title contains it as
    ///   a case-insensitive substring. A `nil` actual window title with a
    ///   non-empty `expectedWindow` is a mismatch (there is no window to
    ///   confirm against).
    /// - Omitting both (`nil`/empty) always matches — the guard is opt-in.
    static func evaluate(
        expectedApp: String?,
        expectedWindow: String?,
        actualAppName: String?,
        actualBundleIdentifier: String?,
        actualWindowTitle: String?
    ) -> MatchResult {
        if let expectedAppNormalized = normalized(expectedApp) {
            let bundleMatches = normalized(actualBundleIdentifier) == expectedAppNormalized
            let nameMatches = normalized(actualAppName) == expectedAppNormalized
            if !bundleMatches && !nameMatches {
                return .mismatch(
                    reason: "expected_app '\(expectedApp ?? "")' does not match the frontmost app "
                        + "(name: \(actualAppName ?? "unknown"), bundle: \(actualBundleIdentifier ?? "unknown"))."
                )
            }
        }

        if let expectedWindowNormalized = normalized(expectedWindow) {
            guard let actualWindowTitleNormalized = normalized(actualWindowTitle),
                  actualWindowTitleNormalized.contains(expectedWindowNormalized)
            else {
                return .mismatch(
                    reason: "expected_window '\(expectedWindow ?? "")' is not a substring of the "
                        + "focused window title (\(actualWindowTitle.map { "\"\($0)\"" } ?? "none"))."
                )
            }
        }

        return .match
    }

    /// Lowercased, trimmed, `nil`-if-empty normalization shared by both
    /// sides of the comparison so "" and nil behave identically.
    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    /// Thin wrapper: reads the real frontmost app (NSWorkspace) and its
    /// focused/main window title (AX). Kept separate from `evaluate` so
    /// the matching logic itself needs no AX/NSWorkspace access in tests.
    ///
    /// `NSWorkspace.shared.frontmostApplication` is main-actor-affine under
    /// strict concurrency (see `WindowController.listWindows()` and
    /// `callWaitForApp` in `Tools+V2Phase5.swift` for the same pattern) —
    /// snapshot the (name, bundle id, pid) triple on `MainActor` first,
    /// then do the AX window-title lookup off-main (AXUIElement is safe to
    /// call from any thread; see the `Sendable` note on `AXUIElement` in
    /// AccessibilityController.swift).
    static func currentFocus() async -> ActualFocus {
        struct AppSnapshot: Sendable {
            let name: String?
            let bundleIdentifier: String?
            let pid: pid_t
        }

        let snapshot: AppSnapshot? = await MainActor.run {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return AppSnapshot(
                name: app.localizedName,
                bundleIdentifier: app.bundleIdentifier,
                pid: app.processIdentifier
            )
        }

        guard let snapshot else {
            return ActualFocus(appName: nil, bundleIdentifier: nil, pid: nil, windowTitle: nil)
        }

        let pid = snapshot.pid
        let axApp = AXUIElementCreateApplication(pid)

        var windowTitle: String?
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
           let raw = windowRef, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            windowTitle = title(of: unsafeDowncast(raw, to: AXUIElement.self))
        }

        if windowTitle == nil {
            var mainRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainRef) == .success,
               let raw = mainRef, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                windowTitle = title(of: unsafeDowncast(raw, to: AXUIElement.self))
            }
        }

        return ActualFocus(
            appName: snapshot.name,
            bundleIdentifier: snapshot.bundleIdentifier,
            pid: pid,
            windowTitle: windowTitle
        )
    }

    private static func title(of window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success else {
            return nil
        }
        return titleRef as? String
    }
}
