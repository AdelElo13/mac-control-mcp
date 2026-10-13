import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(Contacts)
import Contacts
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

// v0.8.0 — Phase 11: permission diagnostics + UX helpers
//
// Adel, 2026-04-22: "dit moet werken vriend wat is dit nou weer voor half werk".
// After v0.7.2 I still punted on the re-prompt UX to a "v0.8 roadmap" item.
// This phase lands the actual fix: tools that tell the agent WHICH permissions
// are missing, and tools that open the exact System Settings pane the user
// needs to grant them. No more vague "go to Privacy & Security" hints.
//
// Three tools ship here:
//   - open_permission_pane   — deep-links to one specific Settings pane
//   - mcp_server_info        — self-diagnostic (version, pid, other instances)
//   - (permissions_status is upgraded in-place inside Tools+V2.swift:
//      now reports accessibility, screen, calendar, reminders, contacts,
//      location, microphone — not just accessibility).
extension ToolRegistry {

    static let definitionsV2Phase11: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "open_permission_pane",
            description: "Open a specific System Settings → Privacy & Security pane so the user can grant (or revoke) access for mac-control-mcp. Returns the URL opened and the current authorization status if known.",
            inputSchema: schema(
                properties: [
                    "pane": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("accessibility"),
                            .string("screen_recording"),
                            .string("calendar"),
                            .string("reminders"),
                            .string("contacts"),
                            .string("location"),
                            .string("microphone"),
                            .string("automation"),
                            .string("full_disk_access")
                        ])
                    ])
                ],
                required: ["pane"]
            )
        ),
        MCPToolDefinition(
            name: "mcp_server_info",
            description: "Self-diagnostic: returns mac-control-mcp version, this process PID, binary path, uptime, and any OTHER mac-control-mcp processes running on this machine each classified as connected (its client is alive), outdated (alive but running another or replaced build), orphaned (client gone — the only ones the hint offers to kill) or unknown.",
            inputSchema: schema(properties: [:])
        )
    ]

    // MARK: - open_permission_pane

    func callOpenPermissionPane(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pane = arguments["pane"]?.stringValue else {
            return invalidArgument("open_permission_pane requires 'pane'.")
        }
        // v0.8.4: routed through the main-actor variant — see
        // locationPermissionStatusStringMainActor().
        let locationStatus = await Self.locationPermissionStatusStringMainActor()
        let mapping: [String: (url: String, status: String?)] = [
            "accessibility":     ("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",    Self.axPermissionStatusString()),
            "screen_recording":  ("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",    Self.screenPermissionStatusString()),
            "calendar":          ("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",        Self.calendarPermissionStatusString()),
            "reminders":         ("x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders",        Self.remindersPermissionStatusString()),
            "contacts":          ("x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts",         Self.contactsPermissionStatusString()),
            "location":          ("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices", locationStatus),
            "microphone":        ("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",       Self.microphonePermissionStatusString()),
            "automation":        ("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",       nil),
            "full_disk_access":  ("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",         nil)
        ]
        guard let entry = mapping[pane] else {
            return invalidArgument("unknown pane '\(pane)'. Valid: \(mapping.keys.sorted().joined(separator: ", "))")
        }
        #if canImport(AppKit)
        guard let url = URL(string: entry.url) else {
            return errorResult("Could not build Settings URL for \(pane).",
                               ["ok": .bool(false), "pane": .string(pane)])
        }
        // `open(_:)` returns Bool (success); the dispatch is async to AppKit
        // but we don't need to wait — the Settings app shows asynchronously.
        NSWorkspace.shared.open(url)
        let paneTitle = pane.replacingOccurrences(of: "_", with: " ")
        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "pane": .string(pane),
            "url": .string(entry.url),
            "currentStatus": entry.status.map(JSONValue.string) ?? .null,
            // v0.8.3: the '+' path is the app macOS actually attributes our
            // requests to — not a hard-coded Claude Extensions path, which was
            // wrong for tarball installs and other MCP clients.
            "hint": .string(PermissionContext.grantHint(paneTitle: paneTitle))
        ]
        payload.merge(PermissionContext.contextPayload()) { current, _ in current }
        return successResult("Opened System Settings → \(paneTitle)", payload)
        #else
        return errorResult("AppKit not available — cannot open Settings", ["ok": .bool(false)])
        #endif
    }

    // MARK: - mcp_server_info

    func callMcpServerInfo() async -> ToolCallResult {
        let pid = ProcessInfo.processInfo.processIdentifier
        let version = ServerVersion.current
        let executablePath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? "unknown"
        let uptime = ProcessInfo.processInfo.systemUptime  // not process uptime, but close enough for diagnosis

        // Find other MacControlMCP processes via `ps`. One-shot diagnostic;
        // nothing mutates.
        let others = Self.otherMcpProcesses(excluding: pid, selfVersion: version)

        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "version": .string(version),
            "pid": .number(Double(pid)),
            "executable_path": .string(executablePath),
            "system_uptime_seconds": .number(uptime),
            "other_instances": .array(others.map { info in
                .object([
                    "pid": .number(Double(info.pid)),
                    "path": .string(info.path),
                    "start": .string(info.start),
                    "parent_pid": .number(Double(info.parentPid)),
                    "client": info.client.map(JSONValue.string) ?? .null,
                    "client_pid": info.clientPid.map { .number(Double($0)) } ?? .null,
                    "version": info.version.map(JSONValue.string) ?? .null,
                    "status": .string(info.status.rawValue)
                ])
            }),
            "other_instances_count": .number(Double(others.count))
        ]
        if let hint = Self.otherInstancesHint(others, selfPid: pid, selfVersion: version) {
            payload["hint"] = .string(hint)
        }
        return successResult("mac-control-mcp v\(version) running as pid \(pid)", payload)
    }

    // MARK: - Per-category status helpers

    static func axPermissionStatusString() -> String {
        #if canImport(AppKit)
        return AXIsProcessTrusted() ? "granted" : "not_granted"
        #else
        return "unknown"
        #endif
    }

    static func screenPermissionStatusString() -> String {
        #if canImport(CoreGraphics)
        // CGPreflightScreenCaptureAccess is a non-prompting check (unlike
        // CGRequestScreenCaptureAccess which can trigger the prompt).
        return CGPreflightScreenCaptureAccess() ? "granted" : "not_granted"
        #else
        return "unknown"
        #endif
    }

    /// v0.8.0: guard-check that Bundle.main has the required usage-description
    /// key before calling the underlying framework API. Without this, the
    /// XCTest bundle (which has no NSCalendarsUsageDescription /
    /// NSContactsUsageDescription / NSMicrophoneUsageDescription keys in its
    /// Info.plist) raises SIGABRT the moment we touch those frameworks,
    /// taking the whole test runner down.
    static func hasInfoPlistKey(_ key: String) -> Bool {
        return Bundle.main.infoDictionary?[key] != nil
    }

    static func calendarPermissionStatusString() -> String {
        #if canImport(EventKit)
        guard hasInfoPlistKey("NSCalendarsUsageDescription") else {
            return "info_plist_missing"
        }
        let s = EKEventStore.authorizationStatus(for: .event)
        switch s {
        case .notDetermined: return "not_determined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized_legacy"
        case .writeOnly:     return "write_only"
        case .fullAccess:    return "granted"
        @unknown default:    return "unknown"
        }
        #else
        return "unknown"
        #endif
    }

    static func remindersPermissionStatusString() -> String {
        #if canImport(EventKit)
        guard hasInfoPlistKey("NSRemindersUsageDescription") else {
            return "info_plist_missing"
        }
        let s = EKEventStore.authorizationStatus(for: .reminder)
        switch s {
        case .notDetermined: return "not_determined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized_legacy"
        case .writeOnly:     return "write_only"
        case .fullAccess:    return "granted"
        @unknown default:    return "unknown"
        }
        #else
        return "unknown"
        #endif
    }

    static func contactsPermissionStatusString() -> String {
        #if canImport(Contacts)
        guard hasInfoPlistKey("NSContactsUsageDescription") else {
            return "info_plist_missing"
        }
        let s = CNContactStore.authorizationStatus(for: .contacts)
        switch s {
        case .notDetermined: return "not_determined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "granted"
        case .limited:       return "limited"
        @unknown default:    return "unknown"
        }
        #else
        return "unknown"
        #endif
    }

    /// v0.8.4: previously reported only the system-wide `locationServicesEnabled()`
    /// flag ("system_enabled (…)" / "system_disabled"), never the per-app
    /// authorization — so a caller had no way to tell "not asked yet" from
    /// "denied" from "granted" for THIS responsible process, and wifi_scan
    /// had nothing reliable to check before deciding whether SSIDs would be
    /// visible. `CLLocationManager().authorizationStatus` (the macOS 11+
    /// instance property) gives the real per-app answer; guarded by
    /// `hasInfoPlistKey`, same as calendar/reminders/contacts/microphone,
    /// because constructing CLLocationManager() from a binary without
    /// NSLocationWhenInUseUsageDescription in its Info.plist raises SIGABRT
    /// — the XCTest bundle has no such key, so tests exercising this path
    /// must stop here rather than take down the runner.
    static func locationPermissionStatusString() -> String {
        #if canImport(CoreLocation)
        guard hasInfoPlistKey("NSLocationWhenInUseUsageDescription") else {
            return "info_plist_missing"
        }
        guard CLLocationManager.locationServicesEnabled() else {
            return "system_disabled"
        }
        switch CLLocationManager().authorizationStatus {
        case .notDetermined:                            return "not_determined"
        case .restricted:                                return "restricted"
        case .denied:                                    return "denied"
        case .authorizedAlways, .authorizedWhenInUse:    return "granted"
        @unknown default:                                return "unknown"
        }
        #else
        return "unknown"
        #endif
    }

    /// Same status as `locationPermissionStatusString()`, but performed on
    /// the main actor.
    ///
    /// v0.8.4 review fix: CoreLocation's documented thread contract is
    /// really about delegate callbacks needing a run-looped thread, but to
    /// avoid depending on whichever actor/thread happens to call in for
    /// reading `CLLocationManager().authorizationStatus` too, route the
    /// read through the one thread `main.swift` guarantees keeps an active
    /// run loop (`RunLoop.main.run()`). Prefer this from async call sites
    /// (`wifi_scan`, `permissions_status`, `open_permission_pane`); the
    /// synchronous `locationPermissionStatusString()` stays available for
    /// callers that can't await, with the same Info.plist-key guard.
    static func locationPermissionStatusStringMainActor() async -> String {
        await MainActor.run { locationPermissionStatusString() }
    }

    static func microphonePermissionStatusString() -> String {
        #if canImport(AVFoundation)
        guard hasInfoPlistKey("NSMicrophoneUsageDescription") else {
            return "info_plist_missing"
        }
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        switch s {
        case .notDetermined: return "not_determined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "granted"
        @unknown default:    return "unknown"
        }
        #else
        return "unknown"
        #endif
    }

    // MARK: - Other-instance detection

    /// Every MCP client spawns its own server, so several instances are
    /// normal. v0.10.1: classify each one instead of suggesting `kill` for
    /// all of them — the old hint listed instances of still-connected
    /// clients (and Claude Desktop's `disclaimer` wrappers), so following
    /// it broke mac-control in every other open session.
    enum OtherInstanceStatus: String, Sendable {
        /// Parent (the MCP client) is alive; killing it breaks that client.
        case connected
        /// Same as connected, but running a different build than this one.
        case outdated
        /// Parent gone (re-parented to launchd) — safe to stop.
        case orphaned
        /// The parent could not be identified from the process table. Never
        /// offered for kill: an unidentified parent is not a dead one.
        case unknown
    }

    struct OtherMcpProcessInfo: Sendable {
        let pid: Int
        let path: String
        let start: String
        let parentPid: Int
        let client: String?
        let clientPid: Int?
        let version: String?
        let status: OtherInstanceStatus
        /// Wrapper processes (Claude Desktop's `disclaimer`) that only exist
        /// for this instance; stopped together with an orphan.
        let wrapperPids: [Int]
    }

    struct PsRow: Sendable, Equatable {
        let pid: Int
        let ppid: Int
        let start: String
        let command: String
    }

    static let serverExecutableMarker = "MacControlMCP.app/Contents/MacOS/MacControlMCP"

    /// Parse `ps -axo pid=,ppid=,lstart=,command=` output. lstart is five
    /// tokens (`Wed Oct 14 00:28:52 2026`); the command keeps its spacing.
    static func parsePsRows(_ text: String) -> [PsRow] {
        var rows: [PsRow] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard parts.count == 8, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            rows.append(PsRow(
                pid: pid,
                ppid: ppid,
                start: parts[2...6].joined(separator: " "),
                // maxSplits keeps the separator run before the last field.
                command: String(parts[7]).trimmingCharacters(in: .whitespaces)
            ))
        }
        return rows
    }

    /// The server binary path when `command` IS a mac-control-mcp server
    /// (argv[0] is the binary) — nil for wrappers such as
    /// `disclaimer --pgroup -- /…/MacControlMCP`, which merely mention it.
    static func serverExecutable(of command: String) -> String? {
        guard let range = command.range(of: serverExecutableMarker) else { return nil }
        let prefix = command[..<range.lowerBound]
        // An argument separator before the marker means the binary is an
        // argument of some other program, not argv[0].
        guard !prefix.contains(" -") else { return nil }
        let after = command[range.upperBound...]
        guard after.isEmpty || after.hasPrefix(" ") else { return nil }
        return String(command[..<range.upperBound])
    }

    /// argv[0] basename of a command line (`/A/Claude.app/Contents/MacOS/Claude --x` → `Claude`).
    static func programName(of command: String) -> String {
        // argv[0] may contain spaces ("Application Support"), so take
        // everything before the first option separator. A path appearing
        // later as an ARGUMENT (disclaimer -- /…/X.app/…) must not win.
        let head = command.range(of: " -").map { String(command[..<$0.lowerBound]) } ?? command
        if let r = head.range(of: ".app/Contents/MacOS/", options: .backwards) {
            let tail = head[r.upperBound...]
            return String(tail.split(separator: " ", maxSplits: 1).first ?? Substring(tail))
        }
        let argv0 = head.split(separator: " ", maxSplits: 1).first.map(String.init) ?? head
        return (argv0 as NSString).lastPathComponent
    }

    /// Processes that only exist to start the server: Claude Desktop's
    /// `disclaimer` helper and the npm launcher (`node …/mac-control-mcp.js`).
    /// The real client is their parent.
    static func isLauncherWrapper(_ command: String) -> Bool {
        let program = programName(of: command)
        if program == "disclaimer" { return true }
        return program == "node" && command.contains("mac-control-mcp")
    }

    /// Readable names for the MCP clients seen in practice; anything else
    /// keeps its program name.
    static func clientDisplayName(_ program: String) -> String {
        switch program {
        case "Claude": return "Claude Desktop"
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        default: return program
        }
    }

    static func bundleVersion(forExecutable path: String) -> String? {
        // …/X.app/Contents/MacOS/X → …/X.app/Contents/Info.plist
        let plist = URL(fileURLWithPath: path)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    /// `ps` lstart in the C locale, e.g. `Wed Oct 14 00:28:52 2026`.
    static func parseLstart(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.date(from: text.split(separator: " ").joined(separator: " "))
    }

    /// True when the binary on disk was replaced after the process started:
    /// an in-place upgrade keeps the path (and the new Info.plist version),
    /// but the running process still executes the old build.
    static func binaryChangedSinceStart(_ exe: String, _ start: String) -> Bool {
        guard let started = parseLstart(start),
              let attrs = try? FileManager.default.attributesOfItem(atPath: exe),
              let modified = attrs[.modificationDate] as? Date else { return false }
        // lstart has 1 s resolution.
        return modified.timeIntervalSince(started) > 1
    }

    static func classifyInstances(
        rows: [PsRow],
        excluding selfPid: Int,
        selfVersion: String,
        versionLookup: (String) -> String?,
        isStaleBinary: (String, String) -> Bool = { _, _ in false }
    ) -> [OtherMcpProcessInfo] {
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [OtherMcpProcessInfo] = []
        for row in rows where row.pid != selfPid {
            guard let exe = serverExecutable(of: row.command) else { continue }
            var wrappers: [Int] = []
            // Orphaned ONLY when the chain demonstrably ends at launchd
            // (ppid <= 1). A parent row that is merely missing from the
            // snapshot (exited between rows, unparseable line) is `unknown`.
            var parentPid = row.ppid
            var reachedLaunchd = parentPid <= 1
            var client: PsRow? = reachedLaunchd ? nil : byPid[parentPid]
            // Claude Desktop launches extensions through a `disclaimer`
            // wrapper; the real client is the wrapper's parent.
            if let wrapper = client, isLauncherWrapper(wrapper.command) {
                wrappers.append(wrapper.pid)
                parentPid = wrapper.ppid
                reachedLaunchd = parentPid <= 1
                client = reachedLaunchd ? nil : byPid[parentPid]
            }
            let version = versionLookup(exe)
            let status: OtherInstanceStatus
            if client == nil {
                status = reachedLaunchd ? .orphaned : .unknown
            } else if (version.map { $0 != selfVersion } ?? false) || isStaleBinary(exe, row.start) {
                status = .outdated
            } else {
                status = .connected
            }
            out.append(OtherMcpProcessInfo(
                pid: row.pid,
                path: exe,
                start: row.start,
                parentPid: row.ppid,
                client: client.map { clientDisplayName(programName(of: $0.command)) },
                clientPid: client?.pid,
                version: version,
                status: status,
                wrapperPids: status == .orphaned ? wrappers : []
            ))
        }
        return out
    }

    static func otherInstancesHint(_ others: [OtherMcpProcessInfo], selfPid: Int32, selfVersion: String) -> String? {
        guard !others.isEmpty else { return nil }
        let connected = others.filter { $0.status == .connected }
        let outdated = others.filter { $0.status == .outdated }
        let orphaned = others.filter { $0.status == .orphaned }
        let unknown = others.filter { $0.status == .unknown }
        var parts: [String] = [
            "\(others.count) other mac-control-mcp process(es): \(connected.count) connected, "
                + "\(outdated.count) outdated, \(orphaned.count) orphaned"
                + (unknown.isEmpty ? "" : ", \(unknown.count) with an unidentified parent")
                + ". Each MCP client runs its own instance and they don't affect this one (pid=\(selfPid))."
        ]
        if !connected.isEmpty || !outdated.isEmpty || !unknown.isEmpty {
            parts.append("Do NOT kill connected, outdated or unidentified instances — that can break mac-control in the client that owns them.")
        }
        if !outdated.isEmpty {
            let clients = Set(outdated.compactMap(\.client)).sorted().joined(separator: ", ")
            parts.append("Outdated instances run a different build than v\(selfVersion); restart their client"
                + (clients.isEmpty ? "" : " (\(clients))") + " to load the current one.")
        }
        if !orphaned.isEmpty {
            let pids = orphaned.flatMap { [$0.pid] + $0.wrapperPids }.map(String.init).joined(separator: " ")
            parts.append("Orphaned instances have no client left and can be stopped with: `kill \(pids)`")
        }
        return parts.joined(separator: " ")
    }

    static func otherMcpProcesses(excluding self_pid: Int32, selfVersion: String = ServerVersion.current) -> [OtherMcpProcessInfo] {
        let process = Process()
        process.launchPath = "/bin/ps"
        // `=` suppresses headers; lstart is five tokens, command comes last.
        process.arguments = ["-axo", "pid=,ppid=,lstart=,command="]
        // lstart is locale-formatted (ja_JP prints 4 tokens instead of 5),
        // which would shift every column. Pin the C locale.
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        process.environment = env
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return []
        }
        // v0.8.1 fix: read BEFORE waitUntilExit. The previous order
        // deadlocked when `ps` output exceeded the default 16KB pipe
        // buffer — ps blocked on write, we blocked on waitUntilExit, and
        // nothing moved. On a busy machine `ps` can easily produce 30-50KB.
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return classifyInstances(
            rows: parsePsRows(text),
            excluding: Int(self_pid),
            selfVersion: selfVersion,
            versionLookup: bundleVersion(forExecutable:),
            isStaleBinary: binaryChangedSinceStart
        )
    }
}
