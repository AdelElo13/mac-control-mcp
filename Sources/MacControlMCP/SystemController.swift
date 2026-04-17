import Foundation

/// System-level preferences (volume, appearance) via osascript.
actor SystemController {
    struct VolumeResult: Codable, Sendable {
        let volume: Int      // 0-100
        let muted: Bool
    }

    /// Set the system output volume 0-100. `muted=true` mutes output.
    func setVolume(_ volume: Int, muted: Bool? = nil) -> Bool {
        let clamped = max(0, min(100, volume))
        var parts = ["set volume output volume \(clamped)"]
        if let muted {
            parts.append("set volume \(muted ? "with" : "without") output muted")
        }
        let script = parts.joined(separator: "\n")
        return runOsascript(script) != nil
    }

    /// Read the current volume and mute state.
    func getVolume() -> VolumeResult? {
        let script = """
        set v to output volume of (get volume settings)
        set m to output muted of (get volume settings)
        return (v as string) & "|" & (m as string)
        """
        guard let out = runOsascript(script)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let parts = out.split(separator: "|").map(String.init)
        guard parts.count == 2, let v = Int(parts[0]) else { return nil }
        return VolumeResult(volume: v, muted: parts[1].lowercased() == "true")
    }

    /// Toggle or explicitly set system appearance (dark/light).
    /// Requires System Events access in Automation permissions.
    func setDarkMode(enabled: Bool) -> Bool {
        let flag = enabled ? "true" : "false"
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to \(flag)
            end tell
        end tell
        """
        return runOsascript(script) != nil
    }

    private(set) var lastError: String?

    private func runOsascript(_ script: String) -> String? {
        let result = OsascriptRunner.run(script)
        if result.ok {
            lastError = nil
            return result.stdout
        }
        lastError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return nil
    }
}
