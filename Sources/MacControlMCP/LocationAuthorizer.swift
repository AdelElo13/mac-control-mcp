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
/// `RunLoop.main.run()` for exactly this reason.
///
/// v0.8.4 review fix: whether CoreLocation even SHOWS the when-in-use
/// prompt for an LSUIElement MCP subprocess is unverified. Earlier this
/// type made callers wait up to 45s for the delegate to report a decided
/// status — if no prompt appears at all (plausible for a background
/// helper with no UI), every `wifi_scan` call would stall the full 45s,
/// regressing v0.8.2's instant scan. Callers are now expected to bound
/// their own wait externally (see `HardwareController.ensureLocationAuthorizationRequested`,
/// which wraps a call to this type in `AsyncTimeout.run` with a ~1s
/// timeout) and rely on `keepAlive` here only to keep the manager +
/// delegate alive in the BACKGROUND after that external wait gives up —
/// so a user who does eventually answer a still-visible prompt still
/// updates the per-app status for the *next* call, instead of that
/// answer being silently dropped because nothing held a strong reference
/// to the manager any more.
@MainActor
final class LocationAuthorizer: NSObject, CLLocationManagerDelegate {
    /// Self-retaining bag for fire-and-forget requests: once the caller
    /// that created a `LocationAuthorizer` moves on (its own bounding wait
    /// gave up), nothing else holds a strong reference to it. Keep it
    /// here until it resolves or `keepAlive` elapses, so the *class*, not
    /// each short-lived caller, is what keeps the request alive.
    private static var pending: [ObjectIdentifier: LocationAuthorizer] = [:]

    private var manager: CLLocationManager?
    private var onChange: (@Sendable (CLAuthorizationStatus) -> Void)?

    /// Fires `requestWhenInUseAuthorization` and suspends until the
    /// delegate reports a decided (non-`.notDetermined`) status, or until
    /// `keepAlive` elapses — whichever comes first. This call itself is
    /// NOT meant to bound a caller that can't wait for a human to answer a
    /// dialog; callers with that constraint should wrap this in
    /// `AsyncTimeout.run` with a short timeout instead (that helper
    /// discards rather than blocks on a slow operation, and this type's
    /// self-retention means the discarded call keeps running safely in
    /// the background).
    func requestAndWaitForChange(keepAlive: TimeInterval) async -> CLAuthorizationStatus? {
        let manager = CLLocationManager()
        self.manager = manager
        manager.delegate = self
        let id = ObjectIdentifier(self)
        Self.pending[id] = self
        let decided: CLAuthorizationStatus? = await PermissionContext.awaitCallback(timeout: keepAlive) { [weak self] done in
            self?.onChange = { status in
                guard status != .notDetermined else { return }
                done(status)
            }
            manager.requestWhenInUseAuthorization()
        }
        Self.pending.removeValue(forKey: id)
        return decided
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
