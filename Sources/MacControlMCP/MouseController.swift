import Foundation
import CoreGraphics

/// Low-level mouse input via CGEvent. Positions are in the global Quartz
/// coordinate space (origin top-left, matches AX position attributes).
actor MouseController {
    // v0.10 C1: clip each display separately so a monitor gap is never a click point.
    nonisolated static func visibleCenter(frame: CGRect, window: CGRect, displays: [CGRect]) -> CGPoint? {
        guard [frame.origin.x, frame.origin.y, frame.width, frame.height,
               window.origin.x, window.origin.y, window.width, window.height].allSatisfy(\.isFinite) else { return nil }
        let visible = displays.filter { rect in
            [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
        }.compactMap { ScreenAnnotator.visibleRect(of: frame, clippedTo: [window, $0]) }
            .max { $0.width * $0.height < $1.width * $1.height }
        return visible.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

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

    // v0.10 C1: transport takes plain event data so fakes never create
    // CGEventSource, which itself can block outside a desktop session.
    struct Event: Sendable {
        let type: CGEventType
        let point: CGPoint?
        var button: Button = .left
        var clickCount: Int64 = 0
        var deltaX: Int = 0
        var deltaY: Int = 0
        var delayAfter: Double = 0
    }

    private let postEvents: @Sendable ([Event]) -> Bool

    init(postEvent: @escaping @Sendable ([Event]) -> Bool = MouseController.postLive) {
        self.postEvents = postEvent
    }

    // v0.10 C1: prepare the whole gesture before its first down event so a
    // failure to construct mouseUp cannot leave the user's button held down.
    nonisolated static func prepareAndPost(_ events: [Event], prepare: (Event) -> (() -> Void)?) -> Bool {
        var prepared: [() -> Void] = []
        for event in events {
            guard let post = prepare(event) else { return false }
            prepared.append(post)
        }
        for (event, post) in zip(events, prepared) {
            post()
            if event.delayAfter > 0 { Thread.sleep(forTimeInterval: event.delayAfter) }
        }
        return true
    }

    nonisolated private static func postLive(_ events: [Event]) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        return prepareAndPost(events) { data in
            let event: CGEvent?
            if data.type == .scrollWheel {
                event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                wheel1: Int32(clamping: data.deltaY), wheel2: Int32(clamping: data.deltaX), wheel3: 0)
                if let point = data.point { event?.location = point }
            } else {
                guard let point = data.point else { return nil }
                event = CGEvent(mouseEventSource: source, mouseType: data.type, mouseCursorPosition: point, mouseButton: data.button.cgButton)
                if data.clickCount > 0 { event?.setIntegerValueField(.mouseEventClickState, value: data.clickCount) }
            }
            guard let event else { return nil }
            return { event.post(tap: .cghidEventTap) }
        }
    }

    /// Move the cursor without clicking.
    func move(to point: CGPoint) -> Bool {
        postEvents([Event(type: .mouseMoved, point: point)])
    }

    /// Single click at a point with a specific button.
    func click(at point: CGPoint, button: Button = .left) -> Bool {
        postEvents([
            Event(type: button.downType, point: point, button: button, delayAfter: 0.01),
            Event(type: button.upType, point: point, button: button)
        ])
    }

    /// The click-count field makes consecutive clicks a single gesture
    /// (v0.2.6 #10), rather than unrelated clicks in text surfaces.
    func multiClick(at point: CGPoint, count: Int, button: Button = .left) -> Bool {
        let events = (1...max(1, min(count, 5))).flatMap { count in [
            Event(type: button.downType, point: point, button: button, clickCount: Int64(count)),
            Event(type: button.upType, point: point, button: button, clickCount: Int64(count), delayAfter: 0.02)
        ] }
        return postEvents(events)
    }

    func doubleClick(at point: CGPoint, button: Button = .left) -> Bool {
        multiClick(at: point, count: 2, button: button)
    }

    func tripleClick(at point: CGPoint, button: Button = .left) -> Bool {
        multiClick(at: point, count: 3, button: button)
    }

    /// Prepare the drag and its button release together before posting.
    func drag(from start: CGPoint, to end: CGPoint, button: Button = .left, steps: Int = 20) -> Bool {
        let stepCount = max(1, steps)
        var events = [Event(type: button.downType, point: start, button: button, delayAfter: 0.02)]
        for i in 1...stepCount {
            let t = Double(i) / Double(stepCount)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            events.append(Event(type: button.dragType, point: point, button: button, delayAfter: 0.01))
        }
        events.append(Event(type: button.upType, point: end, button: button))
        return postEvents(events)
    }

    /// Positive deltaY scrolls up; the point is inside the element's visible frame.
    func scroll(deltaX: Int, deltaY: Int, at point: CGPoint? = nil) -> Bool {
        postEvents([Event(type: .scrollWheel, point: point, deltaX: deltaX, deltaY: deltaY)])
    }
}
