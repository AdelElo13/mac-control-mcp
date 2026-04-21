import Foundation
import ApplicationServices
import CoreFoundation

/// Event-wait primitive backed by `AXObserver`.
///
/// Historically `wait_for_window`, `wait_for_app`, `wait_for_file_dialog` all
/// used `while Date() < deadline { check; sleep 250ms }` loops. Best-case
/// reaction latency was the poll interval (250 ms), worst-case was double
/// that under CPU load. `AXObserver` instead delivers the underlying events
/// (`AXWindowCreated`, `AXFocusedUIElementChanged`, `AXValueChanged`, …) *as
/// they happen* — typically within a single run-loop turn of the real event
/// (~1 frame). Net effect: wait calls feel instant to the agent and we stop
/// burning CPU on busy-wait polls.
///
/// This bridge owns a single dedicated `CFRunLoop` running on its own
/// `Thread`. Every `AXObserver` created by the bridge attaches its runloop
/// source here, which keeps the MCP's stdio dispatch loop untouched even
/// when a batch of concurrent wait calls is in flight.
public final class AXObserverBridge: @unchecked Sendable {
    public static let shared = AXObserverBridge()

    /// Allowlist of notifications we expose. Keeping the set small prevents
    /// callers from subscribing to obscure notifications that behave
    /// differently across apps (or trigger separate privacy prompts). Every
    /// entry here is a documented stable AX notification — see
    /// `<HIServices/AXNotificationConstants.h>`.
    public static let supportedNotifications: Set<String> = [
        // Application lifecycle
        "AXApplicationActivated",
        "AXApplicationDeactivated",
        "AXApplicationHidden",
        "AXApplicationShown",
        // Window lifecycle
        "AXWindowCreated",
        "AXWindowMoved",
        "AXWindowResized",
        "AXWindowMiniaturized",
        "AXWindowDeminiaturized",
        "AXMainWindowChanged",
        "AXFocusedWindowChanged",
        // Element lifecycle
        "AXUIElementDestroyed",
        "AXFocusedUIElementChanged",
        // Value / text
        "AXValueChanged",
        "AXTitleChanged",
        "AXSelectedTextChanged",
        "AXSelectedChildrenChanged",
        "AXSelectedRowsChanged",
        // Menu
        "AXMenuOpened",
        "AXMenuClosed",
        "AXMenuItemSelected",
        // Layout
        "AXRowCountChanged",
        "AXLayoutChanged"
    ]

    /// Machine-readable reasons returned from a wait. Callers can switch on
    /// these without string-matching human prose. Raw values are snake_case
    /// because they surface directly in the JSON `status` field of tool
    /// responses — that matches every other string field the MCP emits.
    public enum WaitStatus: String, Sendable {
        case fired       = "fired"           // notification arrived before timeout
        case timedOut    = "timed_out"       // deadline elapsed
        case setupFailed = "setup_failed"    // AXObserverCreate / AddNotification failed
        case unsupported = "unsupported"     // notification not in supportedNotifications
    }

    public struct WaitResult: Sendable {
        public let status: WaitStatus
        public let notification: String?
        public let elapsed: TimeInterval
        public let axError: Int32?    // AXError raw value when setupFailed
    }

    /// Dedicated runloop owned by the bridge. All AXObserver sources attach
    /// here, so the main MCP stdio loop stays responsive.
    private let runloop: CFRunLoop

    private init() {
        let ready = DispatchSemaphore(value: 0)
        // `Thread`'s trailing closure closes over `capturedLoop`; we need a
        // reference box so both the thread and the enclosing init can see
        // the same value. A plain class with one property is the cheapest
        // way to do this in Swift 6 strict-concurrency mode.
        // `@unchecked Sendable` because thread-safety is enforced by the
        // DispatchSemaphore handshake: the enclosing init blocks on
        // `ready.wait()` until the spawned thread has written `box.loop`,
        // after which no other thread writes to it. Swift 6 strict
        // concurrency can't prove this, so we declare it manually.
        final class LoopBox: @unchecked Sendable { var loop: CFRunLoop? }
        let box = LoopBox()

        let thread = Thread {
            box.loop = CFRunLoopGetCurrent()
            // Anchor: a timer 100 years out ensures the runloop never exits
            // spontaneously when its last source is removed.
            var ctx = CFRunLoopTimerContext()
            let anchor = CFRunLoopTimerCreate(
                kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + 60 * 60 * 24 * 365 * 100,
                0, 0, 0,
                { _, _ in },
                &ctx
            )
            CFRunLoopAddTimer(box.loop, anchor, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "mac-control-mcp.AXObserver"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
        // `box.loop` is always non-nil by the time `ready.signal()` runs,
        // but guard against the degenerate case rather than force-unwrapping.
        self.runloop = box.loop ?? CFRunLoopGetMain()
    }

    /// Register for a single AX notification on `element` (which must belong
    /// to `pid`) and return when either the notification fires or `timeout`
    /// elapses. The observer is cleaned up before returning on every path,
    /// so callers never need a companion `removeObserver` call.
    public func waitForNotification(
        pid: pid_t,
        element: AXUIElement,
        notification: String,
        timeout: TimeInterval
    ) async -> WaitResult {
        let start = Date()

        guard Self.supportedNotifications.contains(notification) else {
            return WaitResult(
                status: .unsupported,
                notification: notification,
                elapsed: 0,
                axError: nil
            )
        }

        return await withCheckedContinuation { continuation in
            // Per-wait reference box: carries the continuation, the lock
            // that guards against double-resume, and the cleanup closure.
            // The AX callback and the DispatchQueue timeout both funnel
            // through `box.resume(_:)` which is at-most-once by design.
            let box = AXObserverWait(
                start: start,
                continuation: continuation,
                notification: notification
            )

            // 1. Create the observer.
            var rawObserver: AXObserver?
            let createErr = AXObserverCreate(pid, axObserverCallback, &rawObserver)
            guard createErr == .success, let observer = rawObserver else {
                box.resume(.init(
                    status: .setupFailed,
                    notification: notification,
                    elapsed: Date().timeIntervalSince(start),
                    axError: createErr.rawValue
                ))
                return
            }

            // 2. Retain the box for the refcon. The single matching release
            // lives inside the cleanup closure set up below, which runs on
            // the first (and only) `box.resume` call.
            let refcon = Unmanaged.passRetained(box).toOpaque()

            // 3. Register for the notification.
            let addErr = AXObserverAddNotification(
                observer,
                element,
                notification as CFString,
                refcon
            )
            guard addErr == .success else {
                Unmanaged<AXObserverWait>.fromOpaque(refcon).release()
                box.resume(.init(
                    status: .setupFailed,
                    notification: notification,
                    elapsed: Date().timeIntervalSince(start),
                    axError: addErr.rawValue
                ))
                return
            }

            // 4. Attach the observer's source to our dedicated runloop.
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopAddSource(self.runloop, source, .defaultMode)

            // 5. Stash cleanup. Whichever resolves first — callback or
            // timeout — runs this once and nils it out.
            box.cleanup = { [runloop = self.runloop] in
                CFRunLoopRemoveSource(runloop, source, .defaultMode)
                AXObserverRemoveNotification(observer, element, notification as CFString)
                Unmanaged<AXObserverWait>.fromOpaque(refcon).release()
            }

            // 6. Arm the timeout on a global queue independent of the AX
            // runloop. This is fire-and-forget; `box.resume` is idempotent.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.resume(.init(
                    status: .timedOut,
                    notification: notification,
                    elapsed: Date().timeIntervalSince(start),
                    axError: nil
                ))
            }
        }
    }
}

/// Reference box owning per-wait state.  `final class` (not a struct) because
/// we pass a pointer to it through AXObserver's `void *refcon`.
///
/// Thread-safety: the `NSLock` guards `fired`, `continuation`, and `cleanup`.
/// The AX callback (fires on the bridge's runloop thread) and the timeout
/// (fires on a global queue) race to resolve the continuation. Whichever
/// arrives first wins; the other becomes a no-op.  `@unchecked Sendable`
/// because the compiler cannot see through the NSLock invariant.
final class AXObserverWait: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<AXObserverBridge.WaitResult, Never>?
    let start: Date
    let notification: String
    /// Set exactly once after the observer is attached, nil-ed on the first
    /// resume.  `var` so the bridge can install it *after* the box is already
    /// visible to the AX callback via the refcon pointer.
    var cleanup: (() -> Void)?

    init(
        start: Date,
        continuation: CheckedContinuation<AXObserverBridge.WaitResult, Never>,
        notification: String
    ) {
        self.start = start
        self.continuation = continuation
        self.notification = notification
    }

    /// Elapsed time since the wait started. Read from both the callback and
    /// the timeout path.
    var elapsed: TimeInterval { Date().timeIntervalSince(start) }

    /// Resolve the continuation exactly once.  Subsequent calls are no-ops,
    /// which matters because the "callback fires and timeout fires" race is
    /// real when timeout is short and the app responds in the same frame.
    func resume(_ result: AXObserverBridge.WaitResult) {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        cleanup?()
        cleanup = nil
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: result)
        }
    }
}

/// Top-level C function pointer required by `AXObserverCreate`.  The refcon
/// carries an `AXObserverWait`; we unwrap, resolve, and let the box's own
/// cleanup closure unsubscribe the observer.  We must not `release()` the
/// refcon here — cleanup owns that.
private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let box = Unmanaged<AXObserverWait>.fromOpaque(refcon).takeUnretainedValue()
    let notif = notification as String
    box.resume(.init(
        status: .fired,
        notification: notif,
        elapsed: box.elapsed,
        axError: nil
    ))
}
