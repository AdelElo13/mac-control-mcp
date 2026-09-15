import Testing
import CoreGraphics
import Foundation
@testable import MacControlMCP

// v0.10 C1: test geometry without ever posting a CGEvent on the host desktop.
@Suite("Mouse visible targeting")
struct MouseControllerTests {
    @Test("center uses the part clipped to both window and display")
    func clipped() {
        #expect(MouseController.visibleCenter(frame: CGRect(x: -100, y: 10, width: 160, height: 40),
            window: CGRect(x: -20, y: 0, width: 200, height: 100),
            displays: [CGRect(x: 0, y: 0, width: 100, height: 100)]) == CGPoint(x: 30, y: 30))
    }
    @Test("offscreen elements and monitor gaps have no center")
    func invisible() {
        let displays = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 200, y: 0, width: 100, height: 100)]
        #expect(MouseController.visibleCenter(frame: CGRect(x: 110, y: 10, width: 20, height: 20),
            window: CGRect(x: 0, y: 0, width: 300, height: 100), displays: displays) == nil)
    }
    @Test("nonfinite window geometry cannot authorize a click")
    func invalidWindow() {
        #expect(MouseController.visibleCenter(frame: CGRect(x: 10, y: 10, width: 20, height: 20),
            window: CGRect(x: Double.nan, y: 0, width: 100, height: 100),
            displays: [CGRect(x: 0, y: 0, width: 100, height: 100)]) == nil)
    }
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(CGEventType, CGPoint, Int64)] = []
        func record(_ events: [MouseController.Event]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            recorded.append(contentsOf: events.map { ($0.type, $0.point ?? .zero, $0.clickCount) })
            return true
        }
        var values: [(CGEventType, CGPoint, Int64)] {
            lock.lock(); defer { lock.unlock() }; return recorded
        }
    }

    @Test("double click posts a complete gesture at the supplied visible point")
    func doubleClickTransport() async {
        let events = Events()
        let mouse = MouseController(postEvent: { events.record($0) })
        let posted = await mouse.doubleClick(at: CGPoint(x: 25, y: 40))
        #expect(posted)
        let values = events.values
        #expect(values.map { $0.0 } == [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        #expect(values.map { $0.2 } == [1, 1, 2, 2])
        #expect(values.allSatisfy { $0.1 == CGPoint(x: 25, y: 40) })
    }

    @Test("scroll and drag preserve their supplied element coordinates")
    func scrollAndDragTransport() async {
        let events = Events()
        let mouse = MouseController(postEvent: { events.record($0) })
        #expect(await mouse.scroll(deltaX: 0, deltaY: -25, at: CGPoint(x: 30, y: 50)))
        #expect(await mouse.drag(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 50, y: 60), steps: 1))
        let values = events.values
        #expect(values.first?.0 == .scrollWheel)
        #expect(values.first?.1 == CGPoint(x: 30, y: 50))
        #expect(values.last?.0 == .leftMouseUp)
        #expect(values.last?.1 == CGPoint(x: 50, y: 60))
    }

    @Test("failed mouse-up preparation emits no mouse-down")
    func preparationFailure() {
        var posted: [CGEventType] = []
        let events = [MouseController.Event(type: .leftMouseDown, point: .zero), MouseController.Event(type: .leftMouseUp, point: .zero)]
        let success = MouseController.prepareAndPost(events) { event in
            if event.type == .leftMouseUp { return nil }
            return { posted.append(event.type) }
        }
        #expect(!success)
        #expect(posted.isEmpty)
    }

}
