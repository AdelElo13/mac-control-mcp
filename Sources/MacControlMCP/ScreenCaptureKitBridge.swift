import Foundation
import CoreGraphics
import AppKit
@preconcurrency import ScreenCaptureKit

/// ScreenCaptureKit-based window capture.
///
/// On macOS 15+ the legacy `CGWindowListCreateImage(_:.optionIncludingWindow:_:_:)`
/// silently returns nil for most per-window captures regardless of
/// Screen Recording permission. Apple's replacement is ScreenCaptureKit,
/// which also happens to be able to capture windows that live on a
/// different Space (something the legacy CG* APIs could never do).
///
/// The flow:
///   1. Ask ScreenCaptureKit for the set of shareable windows (cached
///      briefly — see `ShareableContentCache`).
///   2. Find the one whose `windowID` matches what we got from
///      CGWindowListCopyWindowInfo.
///   3. Build an SCContentFilter that isolates just that window.
///   4. Grab a single frame via `SCScreenshotManager.captureImage`
///      (macOS 14+) into a CGImage.
///
/// The caller must have Screen Recording permission; without it, the
/// shareable-content query returns an empty list.
enum ScreenCaptureKitBridge {
    enum BridgeError: Error, CustomStringConvertible {
        case windowNotFound(CGWindowID)
        case permissionDenied
        case captureFailed(String)

        var description: String {
            switch self {
            case .windowNotFound(let id):
                return "ScreenCaptureKit did not expose windowID=\(id). Window may be minimized, off-screen, or Screen Recording permission may be missing."
            case .permissionDenied:
                return "Screen Recording permission is not granted."
            case .captureFailed(let reason):
                return "ScreenCaptureKit capture failed: \(reason)"
            }
        }
    }

    private static func ensureScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        // First access should trigger the system consent flow when possible.
        // On some macOS versions this may return before the user finishes
        // toggling permission in System Settings, so we preflight again.
        _ = CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }

    static let contentCache = ShareableContentCache()

    /// Capture a single CGImage of the given window ID.
    ///
    /// - Parameter frame: the window's CURRENT bounds in global points
    ///   (from the caller's fresh CGWindowListCopyWindowInfo entry). Used
    ///   for sizing the capture so a briefly-cached `SCWindow` whose
    ///   `frame` predates a resize can never produce a wrongly-sized
    ///   image. nil → fall back to the SCWindow's own frame.
    static func captureWindow(windowID: CGWindowID, frame: CGRect? = nil) async throws -> CGImage {
        guard ensureScreenRecordingPermission() else {
            throw BridgeError.permissionDenied
        }

        // First attempt may use a cached shareable-content snapshot; if
        // that snapshot is stale (window gone / not yet listed / capture
        // rejects the old SCWindow) we retry exactly once with a fresh
        // fetch, so caching can add a round trip in the worst case but
        // can never change the outcome.
        let first = try await contentCache.window(id: windowID, allowCached: true)
        if let target = first.window {
            do {
                return try await capture(target: target, frame: frame)
            } catch where first.fromCache {
                // fall through to a fresh fetch
            }
        } else if !first.fromCache {
            throw BridgeError.windowNotFound(windowID)
        }

        let fresh = try await contentCache.window(id: windowID, allowCached: false)
        guard let target = fresh.window else {
            throw BridgeError.windowNotFound(windowID)
        }
        return try await capture(target: target, frame: frame)
    }

    private static func capture(target: SCWindow, frame: CGRect?) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        let bounds = (frame.map { $0.width > 0 && $0.height > 0 } ?? false) ? frame! : target.frame

        // Size derivation (Codex v10 HIGH): a previous version used
        //   config.width = Int(target.frame.width * NSScreen.main!.backingScaleFactor)
        // which
        //   (1) force-unwrapped NSScreen.main — crashes on headless /
        //       detached-display contexts,
        //   (2) assumed the target window lives on the main display's
        //       scale, which is wrong when the window is on a secondary
        //       display with a different backingScaleFactor.
        //
        // We now find the NSScreen that contains the window's frame and
        // use THAT screen's backing scale. If no screen contains the
        // frame (window off-screen / off-Space / headless), fall back to
        // 2× as a reasonable Retina default rather than crashing.
        let containingScreen = NSScreen.screens.first { screen in
            screen.frame.intersects(bounds)
        }
        let scale = containingScreen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        config.width = max(1, Int((bounds.width * scale).rounded()))
        config.height = max(1, Int((bounds.height * scale).rounded()))
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = false

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw BridgeError.captureFailed(String(describing: error))
        }
    }
}

/// Pure freshness rule for the shareable-content cache, split out so it
/// is unit-testable without ScreenCaptureKit.
struct TimedSnapshotPolicy: Sendable, Equatable {
    let ttl: TimeInterval

    func isFresh(fetchedAt: Date?, now: Date) -> Bool {
        guard let fetchedAt else { return false }
        let age = now.timeIntervalSince(fetchedAt)
        // A clock that went backwards is treated as stale, never fresh.
        return age >= 0 && age < ttl
    }
}

/// Short-lived cache of `SCShareableContent`.
///
/// PERF (v0.8.3): `SCShareableContent.excludingDesktopWindows` costs
/// ~53 ms per call on the benchmark machine (≈470 windows) — more than
/// the ~30 ms window capture itself — and capture_window fetched it on
/// every call. The cache is only ever used to look up an `SCWindow` by
/// ID for the content filter: sizing comes from the caller's fresh CG
/// bounds, a cache miss for the requested ID always refetches, and a
/// capture failure on a cached entry retries once with a fresh fetch
/// (see `ScreenCaptureKitBridge.captureWindow`). Fetch failures (e.g.
/// TCC denial) are never cached.
actor ShareableContentCache {
    static let defaultTTL: TimeInterval = 2

    private let policy: TimedSnapshotPolicy
    private var content: SCShareableContent?
    private var fetchedAt: Date?

    init(ttl: TimeInterval = ShareableContentCache.defaultTTL) {
        self.policy = TimedSnapshotPolicy(ttl: ttl)
    }

    struct Lookup: @unchecked Sendable {
        let window: SCWindow?
        let fromCache: Bool
    }

    func window(id: CGWindowID, allowCached: Bool) async throws -> Lookup {
        if allowCached, policy.isFresh(fetchedAt: fetchedAt, now: Date()), let content,
           let hit = content.windows.first(where: { $0.windowID == id }) {
            return Lookup(window: hit, fromCache: true)
        }
        let fresh = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        content = fresh
        fetchedAt = Date()
        return Lookup(window: fresh.windows.first(where: { $0.windowID == id }), fromCache: false)
    }

    func invalidate() {
        content = nil
        fetchedAt = nil
    }
}
