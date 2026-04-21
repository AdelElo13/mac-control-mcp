import Foundation
import CoreGraphics
import AppKit

/// Mission Control, Exposé, Spaces, Launchpad, Show Desktop.
///
/// macOS exposes these through "system events" hot-key equivalents rather
/// than a public API. We invoke them by posting the documented CGEvent
/// sequences, which matches what a user would do at the keyboard. The
/// advantage of CGEvent over `osascript "tell application System Events…"`
/// is that it works when Accessibility is granted but AppleScript
/// Automation isn't (common combination on new Macs).
actor MissionControlController {

    public enum Trigger: String, Sendable {
        case missionControl = "mission_control"  // F3 / Ctrl+Up
        case appExpose      = "app_expose"       // Ctrl+Down
        case launchpad      = "launchpad"        // F4
        case showDesktop    = "show_desktop"     // F11 / Fn+F11
    }

    public struct Result: Codable, Sendable {
        public let ok: Bool
        public let trigger: String
        public let method: String
        public let error: String?
    }

    func trigger(_ trig: Trigger) -> Result {
        // Virtual key codes for dedicated function keys:
        //   F3  = 160  (Mission Control on modern hardware)
        //   F4  = 131  (Launchpad)
        //   F11 = 103  (Show Desktop)
        //   Up Arrow = 126, Down Arrow = 125
        // Ctrl+Up Arrow = Mission Control fallback on older hardware.
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        switch trig {
        case .missionControl:
            keyCode = 126; flags = [.maskControl]
        case .appExpose:
            keyCode = 125; flags = [.maskControl]
        case .launchpad:
            keyCode = 131; flags = []
        case .showDesktop:
            // F11 is virtual key 103. The Fn-modifier flag uses the raw
            // kCGEventFlagMaskSecondaryFn bit (0x800000) — `maskSecondaryFn`
            // in Swift, but that constant isn't always imported cleanly
            // across SDKs, so we construct it with the raw bit.
            keyCode = 103
            flags = CGEventFlags(rawValue: 0x800000)
        }

        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            return Result(
                ok: false,
                trigger: trig.rawValue,
                method: "cgevent",
                error: "CGEventSource() returned nil"
            )
        }
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        return Result(
            ok: true,
            trigger: trig.rawValue,
            method: "cgevent",
            error: nil
        )
    }

    public struct SpaceSwitchResult: Codable, Sendable {
        public let ok: Bool
        public let targetIndex: Int
        public let method: String
        public let error: String?
    }

    /// Switch to Space N via Ctrl+Number. macOS only wires Ctrl+1…9 for the
    /// first 9 Spaces by default, and this keybinding must be enabled in
    /// System Settings → Keyboard → Shortcuts → Mission Control (it's off
    /// by default on fresh Macs). We return `error = "shortcut_disabled"`
    /// so the agent can instruct the user to enable it if the event is
    /// swallowed.
    func switchToSpace(index: Int) -> SpaceSwitchResult {
        guard index >= 1 && index <= 9 else {
            return SpaceSwitchResult(
                ok: false,
                targetIndex: index,
                method: "ctrl_number",
                error: "index must be 1-9 (macOS only wires Ctrl+1…9 by default)"
            )
        }
        // ANSI number keys: 1=18, 2=19, 3=20, 4=21, 5=23, 6=22, 7=26, 8=28, 9=25
        let keyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let code = keyCodes[index - 1]
        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            return SpaceSwitchResult(
                ok: false, targetIndex: index, method: "ctrl_number",
                error: "CGEventSource() returned nil"
            )
        }
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = .maskControl
        up?.flags = .maskControl
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return SpaceSwitchResult(
            ok: true,
            targetIndex: index,
            method: "ctrl_number",
            error: nil
        )
    }
}
