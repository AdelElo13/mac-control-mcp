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
///   1. Ask ScreenCaptureKit for the set of shareable windows.
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

    /// Capture a single CGImage of the given window ID. Runs on the current
    /// actor; the ScreenCaptureKit calls are inherently async and we await
    /// them.
    static func captureWindow(windowID: CGWindowID) async throws -> CGImage {
        guard ensureScreenRecordingPermission() else {
            throw BridgeError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        guard let target = content.windows.first(where: { $0.windowID == windowID }) else {
            throw BridgeError.windowNotFound(windowID)
        }

        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        // Match the window's real pixel dimensions at the display scale.
        // `frame` is in points; pixel scale matches the display's scale.
        let scale = CGFloat(1) // let SCK pick the right scale for us
        config.width = Int(target.frame.width * NSScreen.main!.backingScaleFactor * scale)
        config.height = Int(target.frame.height * NSScreen.main!.backingScaleFactor * scale)
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = false

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return image
        } catch {
            throw BridgeError.captureFailed(String(describing: error))
        }
    }
}
