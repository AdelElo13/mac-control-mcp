import Foundation
import AppKit

/// Launch, activate, and quit applications via NSWorkspace.
actor AppLifecycleController {
    struct LaunchResult: Codable, Sendable {
        let pid: Int32?
        let name: String?
        let bundleIdentifier: String?
    }

    /// Launch an app by bundle ID, path, or name. Name-based lookup uses
    /// Spotlight/LaunchServices.
    func launch(identifier: String) async -> LaunchResult {
        // 1. Try bundle ID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
           let app = await openAndWait(url: url) {
            return describe(app: app)
        }

        // 2. Try file path
        if FileManager.default.fileExists(atPath: identifier) {
            let url = URL(fileURLWithPath: identifier)
            if let app = await openAndWait(url: url) {
                return describe(app: app)
            }
        }

        // 3. Try app name via LaunchServices search paths
        let candidatePaths = [
            "/Applications/\(identifier).app",
            "/System/Applications/\(identifier).app",
            "\(NSHomeDirectory())/Applications/\(identifier).app"
        ]
        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if let app = await openAndWait(url: url) {
                return describe(app: app)
            }
        }

        return LaunchResult(pid: nil, name: nil, bundleIdentifier: nil)
    }

    /// Bring an app to the front by PID or bundle ID.
    func activate(pid: pid_t? = nil, bundleIdentifier: String? = nil) -> Bool {
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

    /// Quit an app by PID or bundle ID. `force` uses forceTerminate.
    func quit(pid: pid_t? = nil, bundleIdentifier: String? = nil, force: Bool = false) -> Bool {
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

    // MARK: - Helpers

    private func openAndWait(url: URL) async -> NSRunningApplication? {
        await withCheckedContinuation { continuation in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
                continuation.resume(returning: app)
            }
        }
    }

    private func describe(app: NSRunningApplication) -> LaunchResult {
        LaunchResult(
            pid: app.processIdentifier,
            name: app.localizedName,
            bundleIdentifier: app.bundleIdentifier
        )
    }
}
