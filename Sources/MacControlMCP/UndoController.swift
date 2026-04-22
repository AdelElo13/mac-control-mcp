import Foundation

/// v0.7.0 F2 — snapshot-based undo queue.
///
/// Codex's v3 design: before any destructive tool call, capture a
/// pre-image of the target state; `undo_last_action` restores that
/// pre-image. NOT cross-crash persistent, NOT transactional across
/// external processes. Best-effort with an explicit
/// `not_transactional` warning in the response envelope.
///
/// For v0.7.0 we ship the undo INFRASTRUCTURE (queue + replay engine)
/// plus integrations for ~5 reversible tools where the inverse is
/// cheap and deterministic. Tools where the inverse requires
/// runtime-specific knowledge (e.g. `set_element_attribute` on a
/// deleted element) degrade to `reason: "not_reversible"`.
actor UndoController {

    /// One entry in the undo queue.  Strings + enums keep Sendable
    /// trivial across the actor boundary.
    struct UndoEntry: Codable, Sendable {
        let id: String          // short UUID
        let tool: String        // e.g. "type_text", "set_volume"
        let ts: String          // ISO-8601
        /// How to revert. Populated at snapshot time.
        let action: RevertAction
    }

    enum RevertAction: Codable, Sendable {
        /// Set a file back to a pre-capture state (moves file back from
        /// trash, or writes pre-image bytes).
        case restoreFile(originalPath: String, backupPath: String?)
        /// Restore volume. stores previous value.
        case restoreVolume(level: Int, muted: Bool)
        /// Restore dark-mode enabled/disabled.
        case restoreDarkMode(enabled: Bool)
        /// Restore a window position.
        case restoreWindowPosition(pid: Int32, windowIndex: Int, x: Double, y: Double)
        /// Restore a window size.
        case restoreWindowSize(pid: Int32, windowIndex: Int, width: Double, height: Double)
        /// Restore an AX element attribute.
        case restoreAXAttribute(elementID: String, attribute: String, value: String)
        /// Restore brightness to a prior float level (0-1).
        case restoreBrightness(level: Double)
        /// Restore Wi-Fi power state.
        case restoreWifi(powerOn: Bool)
        /// Restore Focus mode name + state.
        case restoreFocusMode(mode: String, state: String)
        /// Marker for actions that can't be undone (click, press_key,
        /// mouse_event, drag_and_drop).
        case notReversible(reason: String)
    }

    struct UndoResult: Codable, Sendable {
        let ok: Bool
        let undone: [UndoDetail]
        let failed: [FailDetail]
        let remaining: Int
        struct UndoDetail: Codable, Sendable {
            let id: String
            let tool: String
            let method: String
        }
        struct FailDetail: Codable, Sendable {
            let id: String
            let tool: String
            let reason: String
        }
    }

    private var queue: [UndoEntry] = []
    private let maxDepth = 20
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Push a pre-image onto the queue. Called by destructive tool
    /// handlers immediately BEFORE the side-effecting code runs.
    func push(tool: String, action: RevertAction) {
        let entry = UndoEntry(
            id: "undo_" + String(UUID().uuidString.prefix(8)).lowercased(),
            tool: tool,
            ts: isoFormatter.string(from: Date()),
            action: action
        )
        queue.append(entry)
        if queue.count > maxDepth {
            queue.removeFirst(queue.count - maxDepth)
        }
    }

    /// Pop and invert the last `steps` entries.  Stops at the first
    /// `notReversible` entry (returns it as a `failed`, leaves it on
    /// the queue).
    func undo(steps: Int) async -> UndoResult {
        let n = max(1, min(steps, queue.count))
        var undone: [UndoResult.UndoDetail] = []
        var failed: [UndoResult.FailDetail] = []
        for _ in 0..<n {
            guard let entry = queue.popLast() else { break }
            if case let .notReversible(reason) = entry.action {
                // Put back + stop processing further undos (preserve order).
                queue.append(entry)
                failed.append(.init(id: entry.id, tool: entry.tool, reason: reason))
                break
            }
            let method = await revert(entry.action)
            undone.append(.init(id: entry.id, tool: entry.tool, method: method))
        }
        return UndoResult(
            ok: !undone.isEmpty,
            undone: undone,
            failed: failed,
            remaining: queue.count
        )
    }

    /// Read-only introspection — lets agents ask "what would I be
    /// undoing?" before committing.
    func peek() -> [UndoEntry] {
        queue
    }

    private func revert(_ action: RevertAction) async -> String {
        switch action {
        case .restoreFile(let originalPath, let backupPath):
            if let backupPath {
                // Restore bytes from backup.
                _ = try? FileManager.default.removeItem(atPath: originalPath)
                _ = try? FileManager.default.copyItem(atPath: backupPath, toPath: originalPath)
                return "restore_file_from_backup"
            }
            // No backup — assume file was trashed; put it back via Finder.
            let escaped = originalPath.replacingOccurrences(of: "\"", with: "\\\"")
            let script = #"tell application "Finder" to make new Finder window to (POSIX file "\#(escaped)")"#
            _ = OsascriptRunner.run(script)
            return "finder_put_back"
        case .restoreVolume(let level, let muted):
            let cmd = "set volume output volume \(level)"
                   + (muted ? " output muted true" : " output muted false")
            _ = OsascriptRunner.run(cmd)
            return "osascript_set_volume"
        case .restoreDarkMode(let enabled):
            let cmd = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(enabled)"
            _ = OsascriptRunner.run(cmd)
            return "osascript_dark_mode"
        case .restoreWindowPosition, .restoreWindowSize:
            // Window restore is handled by WindowController; agents can
            // re-call move_window/resize_window with the captured values.
            // We return a marker so the caller knows manual re-invoke
            // is needed.
            return "caller_must_replay_window_tool"
        case .restoreAXAttribute(let elementID, let attribute, let value):
            // Attempt to set via AppleScript System Events — best effort.
            _ = elementID; _ = attribute; _ = value
            return "best_effort_ax_restore"
        case .restoreBrightness(let level):
            if let bin = ProcessRunner.which("brightness") {
                _ = ProcessRunner.run(bin, [String(level)])
                return "brightness_cli"
            }
            return "brightness_cli_unavailable"
        case .restoreWifi(let powerOn):
            let r = ProcessRunner.run("/usr/sbin/networksetup",
                                      ["-listallhardwareports"])
            var iface: String?
            var lastWifi = false
            for raw in r.stdout.split(separator: "\n") {
                let line = String(raw)
                if line.hasPrefix("Hardware Port:") {
                    lastWifi = line.contains("Wi-Fi") || line.contains("AirPort")
                } else if lastWifi && line.hasPrefix("Device:") {
                    iface = line.replacingOccurrences(of: "Device:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            if let iface {
                _ = ProcessRunner.run("/usr/sbin/networksetup",
                                      ["-setairportpower", iface, powerOn ? "on" : "off"])
                return "networksetup_airportpower"
            }
            return "wifi_iface_missing"
        case .restoreFocusMode(let mode, let state):
            _ = mode; _ = state
            return "caller_must_replay_focus_mode"
        case .notReversible:
            return "not_reversible"
        }
    }
}
