import Foundation
import CoreGraphics

/// Low-level mouse input via CGEvent. Positions are in the global Quartz
/// coordinate space (origin top-left, matches AX position attributes).
actor MouseController {
    enum Button: String, Sendable {
        case left, right, center

        var cgButton: CGMouseButton {
            switch self {
            case .left: return .left
            case .right: return .right
            case .center: return .center
            }
        }

        var downType: CGEventType {
            switch self {
            case .left: return .leftMouseDown
            case .right: return .rightMouseDown
            case .center: return .otherMouseDown
            }
        }

        var upType: CGEventType {
            switch self {
            case .left: return .leftMouseUp
            case .right: return .rightMouseUp
            case .center: return .otherMouseUp
            }
        }

        var dragType: CGEventType {
            switch self {
            case .left: return .leftMouseDragged
            case .right: return .rightMouseDragged
            case .center: return .otherMouseDragged
            }
        }
    }

    /// Move the cursor without clicking.
    func move(to point: CGPoint) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Single click at a point with a specific button.
    func click(at point: CGPoint, button: Button = .left) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: button.downType, mouseCursorPosition: point, mouseButton: button.cgButton),
              let up = CGEvent(mouseEventSource: source, mouseType: button.upType, mouseCursorPosition: point, mouseButton: button.cgButton)
        else { return false }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Double-click at a point. Uses the CGEvent click count mechanism so
    /// macOS recognises the pair as a genuine double-click.
    func doubleClick(at point: CGPoint, button: Button = .left) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        for count in 1...2 {
            guard let down = CGEvent(mouseEventSource: source, mouseType: button.downType, mouseCursorPosition: point, mouseButton: button.cgButton),
                  let up = CGEvent(mouseEventSource: source, mouseType: button.upType, mouseCursorPosition: point, mouseButton: button.cgButton)
            else { return false }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
        }
        return true
    }

    /// Click-and-drag from one point to another with the given button held.
    /// `steps` controls smoothness — more steps = slower, more natural drag.
    func drag(from start: CGPoint, to end: CGPoint, button: Button = .left, steps: Int = 20) -> Bool {
        let stepCount = max(1, steps)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: button.downType, mouseCursorPosition: start, mouseButton: button.cgButton)
        else { return false }

        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)

        for i in 1...stepCount {
            let t = Double(i) / Double(stepCount)
            let p = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            guard let moved = CGEvent(mouseEventSource: source, mouseType: button.dragType, mouseCursorPosition: p, mouseButton: button.cgButton)
            else { continue }
            moved.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.01)
        }

        guard let up = CGEvent(mouseEventSource: source, mouseType: button.upType, mouseCursorPosition: end, mouseButton: button.cgButton)
        else { return false }
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Scroll wheel event. Positive deltaY = scroll up, negative = down.
    /// deltaX moves sideways where the device supports it.
    func scroll(deltaX: Int, deltaY: Int, at point: CGPoint? = nil) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(deltaY),
                wheel2: Int32(deltaX),
                wheel3: 0
              )
        else { return false }

        if let point { event.location = point }
        event.post(tap: .cghidEventTap)
        return true
    }
}
