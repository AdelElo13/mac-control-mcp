import Foundation
import CoreGraphics

/// Hardware-adjacent controls: display brightness, Wi-Fi, Bluetooth,
/// Night Shift, AirPlay. macOS gates most of these behind system daemons
/// we can only reach through CLI tools (`networksetup`, `blueutil`) or
/// documented AppleScript surfaces. When a third-party CLI is missing we
/// return a structured hint instead of silently failing.
actor HardwareController {

    public struct ToggleResult: Codable, Sendable {
        public let ok: Bool
        public let target: String
        public let newState: String?  // "on" | "off" | nil when we can't verify
        public let method: String     // "networksetup" | "blueutil" | "osascript" | …
        public let hint: String?
    }

    // MARK: - Wi-Fi

    /// `state` ∈ {"on", "off", "toggle"}. Uses `networksetup -setairportpower <iface>`,
    /// which ships with macOS so no extra install needed.
    func wifiSet(state: String) -> ToggleResult {
        guard let iface = wifiInterface() else {
            return ToggleResult(
                ok: false, target: "wifi", newState: nil,
                method: "networksetup",
                hint: "no Wi-Fi interface found via networksetup -listallhardwareports"
            )
        }
        let desired: String
        switch state.lowercased() {
        case "on", "enable":
            desired = "on"
        case "off", "disable":
            desired = "off"
        case "toggle":
            let cur = ProcessRunner.run("/usr/sbin/networksetup", ["-getairportpower", iface])
            desired = cur.stdout.contains(": On") ? "off" : "on"
        default:
            return ToggleResult(
                ok: false, target: "wifi", newState: nil, method: "networksetup",
                hint: "state must be on|off|toggle"
            )
        }
        let r = ProcessRunner.run("/usr/sbin/networksetup", ["-setairportpower", iface, desired])
        return ToggleResult(
            ok: r.ok,
            target: "wifi",
            newState: r.ok ? desired : nil,
            method: "networksetup",
            hint: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func wifiInterface() -> String? {
        let r = ProcessRunner.run("/usr/sbin/networksetup", ["-listallhardwareports"])
        var lastWasWifi = false
        for raw in r.stdout.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("Hardware Port:") {
                lastWasWifi = line.contains("Wi-Fi") || line.contains("AirPort")
            } else if lastWasWifi && line.hasPrefix("Device:") {
                return String(line.replacingOccurrences(of: "Device:", with: "")
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    // MARK: - Bluetooth

    /// `blueutil` is a third-party but de-facto Homebrew standard. Without it,
    /// we fall back to toggling via the menubar-icon osascript which is slow
    /// and prone to UI drift across macOS versions.
    func bluetoothSet(state: String) -> ToggleResult {
        guard let bu = ProcessRunner.which("blueutil") else {
            return ToggleResult(
                ok: false, target: "bluetooth", newState: nil,
                method: "blueutil",
                hint: "install 'blueutil' (brew install blueutil) to toggle Bluetooth programmatically; macOS has no sanctioned CLI"
            )
        }
        let arg: String
        switch state.lowercased() {
        case "on", "enable":
            arg = "1"
        case "off", "disable":
            arg = "0"
        case "toggle":
            let cur = ProcessRunner.run(bu, ["-p"])
            arg = cur.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" ? "0" : "1"
        default:
            return ToggleResult(
                ok: false, target: "bluetooth", newState: nil,
                method: "blueutil", hint: "state must be on|off|toggle"
            )
        }
        let r = ProcessRunner.run(bu, ["-p", arg])
        return ToggleResult(
            ok: r.ok,
            target: "bluetooth",
            newState: r.ok ? (arg == "1" ? "on" : "off") : nil,
            method: "blueutil",
            hint: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Display brightness

    public struct BrightnessResult: Codable, Sendable {
        public let ok: Bool
        public let level: Double?  // 0.0 – 1.0
        public let method: String
        public let hint: String?
    }

    /// Brightness is set via the `brightness` Homebrew CLI or, when absent,
    /// by firing the F1/F2 brightness keys once. The key-firing fallback
    /// can't set an exact level — only step down/up — so we expose a
    /// `direction` mode specifically for that path.
    ///
    /// `level` ∈ 0.0…1.0 when `direction` is nil.
    /// `direction` ∈ {"up","down"} when `level` is nil — repeats 4×
    /// (~ one "step" on the brightness slider).
    func brightnessSet(level: Double?, direction: String?) -> BrightnessResult {
        if let level {
            guard (0.0...1.0).contains(level) else {
                return BrightnessResult(
                    ok: false, level: nil, method: "brightness",
                    hint: "level must be between 0.0 and 1.0"
                )
            }
            if let bin = ProcessRunner.which("brightness") {
                let r = ProcessRunner.run(bin, [String(level)])
                return BrightnessResult(
                    ok: r.ok,
                    level: r.ok ? level : nil,
                    method: "brightness",
                    hint: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return BrightnessResult(
                ok: false, level: nil, method: "brightness",
                hint: "install 'brightness' (brew install brightness) to set exact brightness levels"
            )
        }
        if let direction {
            let keyCode: CGKeyCode
            switch direction.lowercased() {
            case "up":   keyCode = 144  // F1/F2 mapped to brightness on most Macs — use private F-codes
            case "down": keyCode = 145
            default:
                return BrightnessResult(
                    ok: false, level: nil, method: "cgevent",
                    hint: "direction must be up|down"
                )
            }
            guard let src = CGEventSource(stateID: .combinedSessionState) else {
                return BrightnessResult(
                    ok: false, level: nil, method: "cgevent",
                    hint: "CGEventSource() returned nil"
                )
            }
            for _ in 0..<4 {
                let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
                let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.05)
            }
            return BrightnessResult(ok: true, level: nil, method: "cgevent", hint: nil)
        }
        return BrightnessResult(
            ok: false, level: nil, method: "none",
            hint: "pass either level=0..1 or direction=up|down"
        )
    }

    // MARK: - Night Shift

    /// Night Shift has no CLI. AppleScript via System Settings works but is
    /// slow (~1.5s). For the common "enable for now until morning" case we
    /// use the `nightlight` third-party CLI if installed. This is Codex-
    /// flagged as optional for v0.4.0; agents that need night shift today
    /// should install `nightlight` (brew install smudge/smudge/nightlight).
    func nightShiftSet(state: String) -> ToggleResult {
        guard let bin = ProcessRunner.which("nightlight") else {
            return ToggleResult(
                ok: false, target: "night_shift", newState: nil,
                method: "nightlight",
                hint: "install 'nightlight' (brew install smudge/smudge/nightlight) — macOS has no sanctioned Night Shift CLI"
            )
        }
        let arg: String
        switch state.lowercased() {
        case "on", "enable":
            arg = "on"
        case "off", "disable":
            arg = "off"
        case "toggle":
            let cur = ProcessRunner.run(bin, ["status"])
            arg = cur.stdout.contains("enabled") ? "off" : "on"
        default:
            return ToggleResult(
                ok: false, target: "night_shift", newState: nil,
                method: "nightlight", hint: "state must be on|off|toggle"
            )
        }
        let r = ProcessRunner.run(bin, [arg])
        return ToggleResult(
            ok: r.ok,
            target: "night_shift",
            newState: r.ok ? arg : nil,
            method: "nightlight",
            hint: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - AirPlay / Screen mirroring

    /// AirPlay mirroring has no sanctioned CLI. Best sanctioned surface is
    /// the Display preferences pane, which we open for the user rather than
    /// try to click through programmatically (that path broke 3× in recent
    /// macOS releases). Agents wanting "start mirroring to AppleTV" should
    /// either shell out to a user-owned script or use `click_menu_path`
    /// on the Control Center → Screen Mirroring item.
    func airplayOpenPreferences() -> ToggleResult {
        let r = ProcessRunner.run("/usr/bin/open", [
            "x-apple.systempreferences:com.apple.Displays-Settings.extension"
        ])
        return ToggleResult(
            ok: r.ok,
            target: "airplay_preferences",
            newState: nil,
            method: "systempreferences_url",
            hint: r.ok ? "Displays pane opened — toggle Screen Mirroring from there" :
                r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
