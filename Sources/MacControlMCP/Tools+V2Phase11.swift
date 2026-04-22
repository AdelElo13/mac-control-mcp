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
            description: "Self-diagnostic: returns mac-control-mcp version, this process PID, binary path, uptime, and any OTHER mac-control-mcp processes running on this machine (Claude Desktop occasionally leaves zombie instances after extension reload — this surfaces them).",
            inputSchema: schema(properties: [:])
        )
    ]

    // MARK: - open_permission_pane

    func callOpenPermissionPane(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pane = arguments["pane"]?.stringValue else {
            return invalidArgument("open_permission_pane requires 'pane'.")
        }
        let mapping: [String: (url: String, status: String?)] = [
            "accessibility":     ("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",    Self.axPermissionStatusString()),
            "screen_recording":  ("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",    Self.screenPermissionStatusString()),
            "calendar":          ("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",        Self.calendarPermissionStatusString()),
            "reminders":         ("x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders",        Self.remindersPermissionStatusString()),
            "contacts":          ("x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts",         Self.contactsPermissionStatusString()),
            "location":          ("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices", Self.locationPermissionStatusString()),
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
        return successResult(
            "Opened System Settings → \(pane.replacingOccurrences(of: "_", with: " "))",
            [
                "ok": .bool(true),
                "pane": .string(pane),
                "url": .string(entry.url),
                "currentStatus": entry.status.map(JSONValue.string) ?? .null,
                "hint": .string("Toggle mac-control-mcp ON in the list. If the app isn't listed, click '+' and navigate to ~/Library/Application Support/Claude/Claude Extensions/local.mcpb.adil-el-ouariachi.mac-control-mcp/MacControlMCP.app — the path Claude Desktop actually runs.")
            ]
        )
        #else
        return errorResult("AppKit not available — cannot open Settings", ["ok": .bool(false)])
        #endif
    }

    // MARK: - mcp_server_info

    func callMcpServerInfo() async -> ToolCallResult {
        let pid = ProcessInfo.processInfo.processIdentifier
        let version = "0.8.0"
        let executablePath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? "unknown"
        let uptime = ProcessInfo.processInfo.systemUptime  // not process uptime, but close enough for diagnosis

        // Find other MacControlMCP processes via `pgrep -lf MacControlMCP`.
        // This is a one-shot diagnostic; nothing mutates.
        let others = Self.otherMcpProcesses(excluding: pid)

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
                    "start": .string(info.start)
                ])
            }),
            "other_instances_count": .number(Double(others.count))
        ]
        if !others.isEmpty {
            payload["hint"] = .string(
                "Claude Desktop left \(others.count) other mac-control-mcp process(es) running. These are harmless (new requests go to the current process, pid=\(pid)) but you can kill them manually with: `kill \(others.map { String($0.pid) }.joined(separator: " "))`"
            )
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

    static func locationPermissionStatusString() -> String {
        #if canImport(CoreLocation)
        // Don't construct CLLocationManager() — doing so from a binary
        // without NSLocationUsageDescription in its Info.plist raises
        // SIGABRT on macOS. The XCTest bundle has no Info.plist, so
        // tests exercising this path would crash the entire runner.
        //
        // Use the static `locationServicesEnabled()` instead which is
        // safe from any bundle and returns a system-wide bool. Per-app
        // authorization can still be inspected via
        // `open_permission_pane(pane: "location")`.
        if #available(macOS 11.0, *) {
            return CLLocationManager.locationServicesEnabled()
                ? "system_enabled (per-app grant visible via open_permission_pane)"
                : "system_disabled"
        } else {
            return "unknown"
        }
        #else
        return "unknown"
        #endif
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

    // MARK: - Zombie process detection

    struct OtherMcpProcessInfo: Sendable {
        let pid: Int
        let path: String
        let start: String
    }

    static func otherMcpProcesses(excluding self_pid: Int32) -> [OtherMcpProcessInfo] {
        let process = Process()
        process.launchPath = "/bin/ps"
        // Use args that we can parse deterministically: pid + lstart + command
        process.arguments = ["-eo", "pid,lstart,command"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var out: [OtherMcpProcessInfo] = []
        for line in text.split(separator: "\n") {
            guard line.contains("MacControlMCP.app/Contents/MacOS/MacControlMCP") else { continue }
            // Columns (from `ps -eo pid,lstart,command`):
            //   PID  LSTART(5-tokens:WDay Mon DD HH:MM:SS YYYY)  COMMAND...
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 7, let pid = Int(parts[0]) else { continue }
            if pid == Int(self_pid) { continue }
            let start = parts[1...5].joined(separator: " ")
            let path = parts[6...].joined(separator: " ")
            out.append(OtherMcpProcessInfo(pid: pid, path: path, start: start))
        }
        return out
    }
}
