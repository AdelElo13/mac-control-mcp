import Foundation
import AppKit

/// Launch, activate, and quit applications via NSWorkspace.
/// All NSWorkspace / NSRunningApplication calls are routed through
/// `MainActor.run` because AppKit is main-actor affine under Swift 6
/// strict concurrency.
actor AppLifecycleController {
    struct LaunchResult: Codable, Sendable {
        let pid: Int32?
        let name: String?
        let bundleIdentifier: String?
    }

    /// Launch an app by bundle ID, path, or name.
    func launch(identifier: String) async -> LaunchResult {
        // 1. Try bundle ID
        let bundleURL: URL? = await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        }
        if let url = bundleURL, let result = await openAndWait(url: url) {
            return result
        }

        // 2. Try file path
        if FileManager.default.fileExists(atPath: identifier) {
            let url = URL(fileURLWithPath: identifier)
            if let result = await openAndWait(url: url) { return result }
        }

        // 3. Try app name via LaunchServices search paths
        let candidatePaths = [
            "/Applications/\(identifier).app",
            "/System/Applications/\(identifier).app",
            "\(NSHomeDirectory())/Applications/\(identifier).app"
        ]
        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if let result = await openAndWait(url: url) { return result }
        }

        return LaunchResult(pid: nil, name: nil, bundleIdentifier: nil)
    }

    /// Bring an app to the front by PID or bundle ID.
    func activate(pid: pid_t? = nil, bundleIdentifier: String? = nil) async -> Bool {
        await MainActor.run {
            if let pid, let app = NSRunningApplication(processIdentifier: pid) {
                return app.activate(options: [])
            }
            if let bundleIdentifier {
                let apps = NSWorkspace.shared.runningApplications
                    .filter { $0.bundleIdentifier == bundleIdentifier }
                if let app = apps.first {
                    return app.activate(options: [])
                }
            }
            return false
        }
    }

    /// Quit an app by PID or bundle ID. `force` uses forceTerminate.
    func quit(pid: pid_t? = nil, bundleIdentifier: String? = nil, force: Bool = false) async -> Bool {
        await MainActor.run {
            let target: NSRunningApplication? = {
                if let pid { return NSRunningApplication(processIdentifier: pid) }
                if let bundleIdentifier {
                    return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier }
                }
                return nil
            }()
            guard let app = target else { return false }
            return force ? app.forceTerminate() : app.terminate()
        }
    }

    // MARK: - Helpers

    /// Opens the URL and extracts a Sendable LaunchResult on MainActor so
    /// we never leak a non-Sendable NSRunningApplication across actors.
    private func openAndWait(url: URL) async -> LaunchResult? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
                    guard let app else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let result = LaunchResult(
                        pid: app.processIdentifier,
                        name: app.localizedName,
                        bundleIdentifier: app.bundleIdentifier
                    )
                    continuation.resume(returning: result)
                }
            }
        }
    }
}
