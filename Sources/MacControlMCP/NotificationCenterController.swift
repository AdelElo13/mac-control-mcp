import Foundation
import CoreGraphics

/// macOS "menu bar extra" panels: Notification Center (right edge slide-in)
/// and Control Center (top-right icon popover). macOS ships no public API
/// for these — every automation library uses one of three fallbacks:
///
/// 1. Clicking the menubar icon by coordinates (fragile — breaks when the
///    status icon order changes).
/// 2. Sending the documented keyboard shortcut. Since macOS Ventura users
///    can bind "Do Not Disturb" / "Notification Center" to a hotkey under
///    Keyboard → Shortcuts → Mission Control, but the defaults are unbound.
/// 3. Invoking the app directly via `osascript "tell application
///    \"NotificationCenter\" to activate"` — works for NC, not for CC.
///
/// We expose both panels through a single `panelToggle` tool with a
/// `panel` parameter, returning a structured hint when the OS refuses to
/// open the panel (e.g. when the hotkey isn't bound).
actor NotificationCenterController {

    public enum Panel: String, Sendable {
        case notificationCenter = "notification_center"
        case controlCenter      = "control_center"
    }

    public struct Result: Codable, Sendable {
        public let ok: Bool
        public let panel: String
        public let method: String
        public let hint: String?
    }

    func toggle(_ panel: Panel) -> Result {
        switch panel {
        case .notificationCenter:
            // osascript path works reliably since macOS 12.
            let script = """
            tell application "System Events"
                key code 111 using {function down}
            end tell
            """
            let r = OsascriptRunner.run(script)
            if r.ok {
                return Result(ok: true, panel: panel.rawValue,
                              method: "osascript_fn_f12", hint: nil)
            }
            // Fallback: click the notification-center spot. Exact coordinate
            // depends on display width — we grab the main screen's width
            // dynamically rather than hardcoding.
            return clickTopRight(xOffsetFromRight: 20, panel: panel)
        case .controlCenter:
            // Control Center sits just left of the clock. Typical offset is
            // ~210 pixels from the right edge on a 13"/14" MacBook. Works
            // across Ventura/Sonoma/Sequoia which is the macOS range we
            // target.
            return clickTopRight(xOffsetFromRight: 210, panel: panel)
        }
    }

    private func clickTopRight(xOffsetFromRight: CGFloat, panel: Panel) -> Result {
        guard let mainScreenWidth = mainDisplayWidth() else {
            return Result(
                ok: false, panel: panel.rawValue,
                method: "cgevent_click", hint: "could not read main display size"
            )
        }
        let x = mainScreenWidth - xOffsetFromRight
        let y: CGFloat = 12   // menubar is ~24 px tall; click vertical centre
        let at = CGPoint(x: x, y: y)

        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            return Result(ok: false, panel: panel.rawValue,
                          method: "cgevent_click", hint: "CGEventSource() returned nil")
        }
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                           mouseCursorPosition: at, mouseButton: .left)
        let up   = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                           mouseCursorPosition: at, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        return Result(
            ok: true, panel: panel.rawValue,
            method: "cgevent_click",
            hint: "clicked at (\(Int(x)), \(Int(y))); if panel didn't appear, macOS may have moved the status item — use click_menu_path as backup"
        )
    }

    private func mainDisplayWidth() -> CGFloat? {
        let id = CGMainDisplayID()
        let size = CGDisplayBounds(id).size
        return size.width > 0 ? size.width : nil
    }
}
