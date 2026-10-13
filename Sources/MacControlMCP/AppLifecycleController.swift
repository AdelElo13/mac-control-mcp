import Foundation
import AppKit
import ApplicationServices

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

    /// Sendable snapshot of an NSRunningApplication.
    struct AppSnapshot: Sendable, Equatable {
        let pid: pid_t
        let name: String?
        let bundleIdentifier: String?
        let bundlePath: String?
        let isRegular: Bool
    }

    enum ActivationStatus: String, Sendable {
        case activated
        case notRunning = "not_running"
        case refused = "activation_refused"
    }

    struct ActivationResult: Sendable {
        let status: ActivationStatus
        let app: AppSnapshot?
        /// Which step made the app frontmost: activate, ax_frontmost or open_application.
        let method: String?
        let frontmost: AppSnapshot?
    }

    @MainActor
    static func snapshot(_ app: NSRunningApplication) -> AppSnapshot {
        AppSnapshot(
            pid: app.processIdentifier,
            name: app.localizedName,
            bundleIdentifier: app.bundleIdentifier,
            bundlePath: app.bundleURL?.path,
            isRegular: app.activationPolicy == .regular
        )
    }

    func runningApps() async -> [AppSnapshot] {
        await MainActor.run { NSWorkspace.shared.runningApplications.map(Self.snapshot) }
    }

    func frontmostApp() async -> AppSnapshot? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication.map(Self.snapshot) }
    }

    /// Pick the running app an agent means. `pid` wins; otherwise an exact
    /// bundle id, then a case-insensitive app name (localized name or the
    /// .app file name). Among several matches a regular (Dock) app beats
    /// helpers/agents sharing the bundle id.
    static func pickRunningApp(_ apps: [AppSnapshot], pid: pid_t?, bundleIdentifier: String?, name: String?) -> AppSnapshot? {
        // A pid that is no longer running falls back to bundle id / name
        // when given (v0.10.0 did the same for bundle_id).
        if let pid, let hit = apps.first(where: { $0.pid == pid }) { return hit }
        var matches: [AppSnapshot] = []
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            matches = apps.filter { $0.bundleIdentifier == bundleIdentifier }
        } else if let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty {
            let wanted = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
            matches = apps.filter { app in
                if app.name?.lowercased() == wanted { return true }
                guard let path = app.bundlePath else { return false }
                return ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() == wanted
            }
        }
        return matches.first(where: \.isRegular) ?? matches.first
    }

    /// Bring an app to the front and VERIFY it is frontmost.
    ///
    /// `NSRunningApplication.activate` is only a request: since macOS 14
    /// (cooperative activation) the system can ignore it when the caller
    /// is a background process, while still returning true. We therefore
    /// check `frontmostApplication` and fall back to the Accessibility
    /// `AXFrontmost` attribute and finally a LaunchServices open — each
    /// of which macOS treats as a user-intent activation.
    func activate(pid: pid_t? = nil, bundleIdentifier: String? = nil, name: String? = nil) async -> ActivationResult {
        let apps = await runningApps()
        guard let target = Self.pickRunningApp(apps, pid: pid, bundleIdentifier: bundleIdentifier, name: name) else {
            return ActivationResult(status: .notRunning, app: nil, method: nil, frontmost: await frontmostApp())
        }

        let requested: Bool = await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: target.pid) else { return false }
            if app.isHidden { app.unhide() }
            return app.activate(options: [])
        }
        if requested, await waitUntilFrontmost(target.pid, timeout: 1.0) {
            return ActivationResult(status: .activated, app: target, method: "activate", frontmost: target)
        }

        let axSet = AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(target.pid),
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        if axSet == .success, await waitUntilFrontmost(target.pid, timeout: 0.75) {
            return ActivationResult(status: .activated, app: target, method: "ax_frontmost", frontmost: target)
        }

        // Last resort, regular top-level apps only: a LaunchServices open of
        // a nested helper bundle (Foo.app/Contents/…/Helper.app) could start
        // something else. For some apps (Finder, Safari, Mail) this reopen
        // event also opens a new window — documented in the tool description.
        if target.isRegular, let path = target.bundlePath, !Self.isNestedBundle(path),
           await openExisting(path: path), await waitUntilFrontmost(target.pid, timeout: 1.0) {
            return ActivationResult(status: .activated, app: target, method: "open_application", frontmost: target)
        }

        return ActivationResult(status: .refused, app: target, method: nil, frontmost: await frontmostApp())
    }

    /// `/A/Foo.app/Contents/Frameworks/Helper.app` → true.
    static func isNestedBundle(_ path: String) -> Bool {
        (path as NSString).pathComponents.filter { $0.hasSuffix(".app") }.count > 1
    }

    private func waitUntilFrontmost(_ pid: pid_t, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if await frontmostApp()?.pid == pid { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        return await frontmostApp()?.pid == pid
    }

    /// LaunchServices re-open of an already running app (no new instance).
    private func openExisting(path: String) async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                config.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { app, _ in
                    continuation.resume(returning: app != nil)
                }
            }
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
