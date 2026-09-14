import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Security)
import Security
#endif

/// Who macOS attributes this server's TCC requests to, and why a request was
/// refused.
///
/// Permission state depends on the *responsible process*, not on this binary
/// alone: launched from a shell the terminal is responsible; launched by
/// Claude Desktop through `disclaimer` MacControlMCP.app itself is; launched
/// by ChatGPT.app's `codex app-server` ChatGPT.app is. Users must toggle THAT
/// app in System Settings, so every permission report and permission error
/// names it.
enum PermissionContext {

    struct ProcessDescriptor: Sendable, Equatable {
        let pid: pid_t
        let executablePath: String?

        var bundlePath: String? { PermissionContext.bundlePath(forExecutable: executablePath) }

        var bundleIdentifier: String? {
            bundlePath.flatMap { Bundle(path: $0)?.bundleIdentifier }
        }

        var name: String {
            if let bundlePath {
                return ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            if let executablePath {
                return (executablePath as NSString).lastPathComponent
            }
            return "pid \(pid)"
        }

        var json: JSONValue {
            .object([
                "pid": .number(Double(pid)),
                "name": .string(name),
                "bundle_id": bundleIdentifier.map(JSONValue.string) ?? .null,
                "path": (bundlePath ?? executablePath).map(JSONValue.string) ?? .null
            ])
        }
    }

    struct Snapshot: Sendable {
        let server: ProcessDescriptor
        /// nil when the private responsibility SPI is unavailable.
        let responsible: ProcessDescriptor?
        /// Parent chain, nearest first, excluding this process.
        let ancestry: [ProcessDescriptor]

        /// The app the user has to enable in System Settings.
        var permissionTarget: ProcessDescriptor { responsible ?? server }
        var responsibleIsSelf: Bool { responsible?.pid == server.pid }
    }

    /// Computed once: the responsible process of a running process is fixed
    /// at spawn time.
    static let current: Snapshot = {
        let pid = getpid()
        let server = ProcessDescriptor(pid: pid, executablePath: executablePath(of: pid))
        let responsible = responsiblePID(for: pid).map {
            ProcessDescriptor(pid: $0, executablePath: executablePath(of: $0))
        }
        return Snapshot(server: server, responsible: responsible, ancestry: ancestry(of: pid))
    }()

    // MARK: - Process introspection

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    static func ancestry(of pid: pid_t, maxDepth: Int = 12) -> [ProcessDescriptor] {
        var chain: [ProcessDescriptor] = []
        var current = pid
        while chain.count < maxDepth, let parent = parentPID(of: current), parent != current {
            chain.append(ProcessDescriptor(pid: parent, executablePath: executablePath(of: parent)))
            if parent == 1 { break }
            current = parent
        }
        return chain
    }

    /// `responsibility_get_pid_responsible_for_pid` is the SPI TCC itself
    /// uses to attribute requests. Looked up dynamically so a future OS that
    /// drops it degrades to "unknown" instead of failing to launch.
    static func responsiblePID(for pid: pid_t) -> pid_t? {
        typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return nil }
        let fn = unsafeBitCast(symbol, to: ResponsibleFn.self)
        let result = fn(pid)
        return result > 0 ? result : nil
    }

    /// Bundle that owns an executable: the innermost `X.app` whose
    /// `Contents/MacOS` holds it, else the outermost `.app` containing it
    /// (helpers such as `Claude.app/Contents/Helpers/disclaimer`).
    static func bundlePath(forExecutable path: String?) -> String? {
        guard let path else { return nil }
        if let range = path.range(of: ".app/Contents/MacOS/", options: .backwards) {
            return String(path[..<range.lowerBound]) + ".app"
        }
        if let range = path.range(of: ".app/") {
            return String(path[..<range.lowerBound]) + ".app"
        }
        return nil
    }

    // MARK: - Code-signing introspection

    /// Whether this process's signature carries `key` = true. nil when the
    /// signature can't be inspected.
    static func hasEntitlement(_ key: String) -> Bool? {
        #if canImport(Security)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return false }
        return (value as? Bool) ?? false
        #else
        return nil
        #endif
    }

    /// Hardened runtime is what makes missing resource entitlements fatal.
    static func isHardenedRuntime() -> Bool {
        #if canImport(Security)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value else { return false }
        return flags & SecCodeSignatureFlags.runtime.rawValue != 0
        #else
        return false
        #endif
    }

    // MARK: - Request outcome classification

    enum AuthOutcome: String, Sendable {
        case granted
        /// The user saw a prompt (now or earlier) and said no.
        case deniedByUser = "denied_by_user"
        /// Status is still not_determined after the request: macOS refused
        /// without asking (missing entitlement / responsible app can't prompt).
        case deniedWithoutPrompt = "denied_without_prompt"
        case restricted
        case promptTimeout = "prompt_timeout"
    }

    /// `statusAfter` uses the strings produced by the *PermissionStatusString
    /// helpers ("not_determined", "denied", "restricted", "granted", …).
    static func classify(granted: Bool?, statusAfter: String) -> AuthOutcome {
        switch (granted, statusAfter) {
        case (true, _): return .granted
        case (nil, "not_determined"): return .promptTimeout
        case (_, "not_determined"): return .deniedWithoutPrompt
        case (_, "restricted"): return .restricted
        case (_, "granted"), (_, "authorized_legacy"), (_, "limited"): return .granted
        default: return .deniedByUser
        }
    }

    /// Structured error for a refused privacy service.
    static func permissionError(
        service: String,
        pane: String,
        entitlement: String,
        outcome: AuthOutcome,
        statusAfter: String,
        snapshot: Snapshot = current,
        entitlementLookup: (String) -> Bool? = PermissionContext.hasEntitlement
    ) -> (message: String, payload: [String: JSONValue]) {
        let target = snapshot.permissionTarget
        let entitlementPresent = entitlementLookup(entitlement)
        let code: String
        let message: String
        switch outcome {
        case .deniedWithoutPrompt:
            code = "permission_policy_denied"
            let cause: String
            if snapshot.responsibleIsSelf && entitlementPresent == false {
                cause = "This mac-control-mcp build lacks the \(entitlement) entitlement, so macOS denies without asking. Install a mac-control-mcp release that includes it."
            } else {
                cause = "macOS attributes the request to '\(target.name)', which cannot present the \(service) prompt (that app lacks the entitlement or runs in the background). Enable '\(target.name)' manually via open_permission_pane pane=\(pane)."
            }
            message = "macOS refused \(service) access without showing a prompt (status is still not_determined) — the user did not deny it. \(cause)"
        case .deniedByUser:
            code = "permission_missing"
            message = "\(service) access was denied for '\(target.name)'. Enable it via open_permission_pane pane=\(pane), then retry."
        case .restricted:
            code = "permission_policy_denied"
            message = "\(service) access is restricted by MDM or Screen Time policy for this user; an administrator must allow it."
        case .promptTimeout:
            code = "timeout"
            message = "A \(service) permission prompt is waiting for an answer. Answer the macOS dialog (it may be behind other windows), then retry."
        case .granted:
            code = "failed"
            message = "\(service) access is granted but the operation still failed."
        }
        return (message, [
            "ok": .bool(false),
            "error": .string(message),
            "error_code": .string(code),
            "reason": .string(outcome.rawValue),
            "service": .string(service),
            "status": .string(statusAfter),
            "pane": .string(pane),
            "entitlement": .string(entitlement),
            "entitlement_present": entitlementPresent.map(JSONValue.bool) ?? .null
        ])
    }

    // MARK: - Reporting helpers

    static func contextPayload(_ snapshot: Snapshot = current) -> [String: JSONValue] {
        [
            "responsible_app": snapshot.permissionTarget.json,
            "responsible_is_self": .bool(snapshot.responsibleIsSelf),
            "server": .object([
                "pid": .number(Double(snapshot.server.pid)),
                "bundle_path": .string(Bundle.main.bundlePath),
                "executable": snapshot.server.executablePath.map(JSONValue.string) ?? .null
            ]),
            "launched_by": .array(snapshot.ancestry.prefix(4).map { .string($0.name) })
        ]
    }

    /// Instruction naming the app to toggle. Never hard-codes an install path:
    /// the path offered for '+' is the real target app bundle.
    static func grantHint(paneTitle: String, snapshot: Snapshot = current) -> String {
        let target = snapshot.permissionTarget
        let path = target.bundlePath ?? (snapshot.responsibleIsSelf ? Bundle.main.bundlePath : target.executablePath) ?? Bundle.main.bundlePath
        return "In System Settings → Privacy & Security → \(paneTitle), enable '\(target.name)' — macOS attributes mac-control-mcp's requests to that app. If it isn't listed, click '+' and choose \(path). Restart the MCP client afterwards."
    }

    // MARK: - Callback bridging with timeout

    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
        func resume(_ value: T?) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    /// Bridges a completion-handler API that may never call back (a TCC prompt
    /// nobody answers) into async/await. Returns nil on timeout; a late
    /// callback is ignored.
    /// `isolation` keeps `start` in the caller's actor, so it may capture
    /// actor-owned framework objects such as an EKEventStore.
    static func awaitCallback<T: Sendable>(
        timeout: TimeInterval,
        isolation: isolated (any Actor)? = #isolation,
        _ start: (@escaping @Sendable (T) -> Void) -> Void
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
            start { value in once.resume(value) }
        }
    }
}

extension ToolCallResult {
    /// Adds responsible-app context to permission errors from any tool, so
    /// every `permission_*` error says WHICH app to enable.
    func withPermissionContext(_ snapshot: PermissionContext.Snapshot = PermissionContext.current) -> ToolCallResult {
        guard isError,
              case .object(var dict) = structuredContent,
              let code = dict["error_code"]?.stringValue,
              code.hasPrefix("permission_"),
              dict["responsible_app"] == nil else { return self }
        for (key, value) in PermissionContext.contextPayload(snapshot) where dict[key] == nil {
            dict[key] = value
        }
        return ToolCallResult(text: text, structuredContent: .object(dict), isError: isError)
    }
}
