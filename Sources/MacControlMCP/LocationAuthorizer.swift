import Foundation
#if canImport(CoreLocation)
import CoreLocation

/// Bridges CLLocationManager's delegate-based authorization flow into
/// async/await, the same shape as the completion-handler APIs used
/// elsewhere (EventKit's `requestFullAccessToEvents`, Contacts'
/// `requestAccess`) via `PermissionContext.awaitCallback`.
///
/// CoreLocation has no completion-handler request API: the answer to
/// `requestWhenInUseAuthorization()` arrives via the delegate method
/// `locationManagerDidChangeAuthorization`, and that delegate callback is
/// only delivered on a thread with an actively running run loop. This type
/// is pinned to the main actor, which the Swift runtime schedules onto the
/// main thread — `main.swift` keeps `RunLoop.main` spinning via
/// `RunLoop.main.run()` for exactly this reason. The `CLLocationManager`
/// itself is kept as a stored property so it isn't deallocated (and its
/// pending request dropped) before the delegate fires.
@MainActor
final class LocationAuthorizer: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var onChange: (@Sendable (CLAuthorizationStatus) -> Void)?

    /// Requests when-in-use authorization and waits, bounded by `timeout`,
    /// for the delegate to report a *decided* (non-`.notDetermined`)
    /// status. Returns nil on timeout — the prompt went unanswered, or
    /// nothing macOS-side ever showed it.
    ///
    /// Callers are expected to check the current status themselves before
    /// calling this (see `HardwareController.ensureLocationAuthorizationRequested`)
    /// — this method always fires the request regardless of current state.
    func requestAndAwaitChange(timeout: TimeInterval) async -> CLAuthorizationStatus? {
        let manager = CLLocationManager()
        self.manager = manager
        manager.delegate = self
        return await PermissionContext.awaitCallback(timeout: timeout) { [weak self] done in
            self?.onChange = { status in
                guard status != .notDetermined else { return }
                done(status)
            }
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Delivered by CoreLocation on the run loop the manager was created
    /// on. Declared `nonisolated` because the delegate protocol requirement
    /// itself carries no actor isolation; hop back to the main actor to
    /// touch `onChange`.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.onChange?(status)
        }
    }
}
#endif
