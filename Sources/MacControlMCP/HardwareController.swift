import Foundation
import CoreGraphics
#if canImport(CoreWLAN)
import CoreWLAN
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif

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
            // Brightness is a system-defined ("aux") key, NOT a regular
            // keyboard virtualKey. The old code posted CGKeyCodes 144/145,
            // which aren't the brightness keys and changed nothing while
            // still reporting ok:true. Post NX_KEYTYPE_BRIGHTNESS_UP/DOWN as
            // NSSystemDefined events, the documented way to drive the keys.
            #if canImport(AppKit)
            let auxKey: Int32
            switch direction.lowercased() {
            case "up":   auxKey = 2   // NX_KEYTYPE_BRIGHTNESS_UP
            case "down": auxKey = 3   // NX_KEYTYPE_BRIGHTNESS_DOWN
            default:
                return BrightnessResult(
                    ok: false, level: nil, method: "nsevent",
                    hint: "direction must be up|down"
                )
            }
            func postAux(_ key: Int32, keyDown: Bool) -> Bool {
                let state = keyDown ? 0xA : 0xB
                let data1 = (Int(key) << 16) | (state << 8)
                guard let ev = NSEvent.otherEvent(
                    with: .systemDefined,
                    location: .zero,
                    modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0,
                    context: nil,
                    subtype: 8,
                    data1: data1,
                    data2: -1
                ), let cg = ev.cgEvent else { return false }
                cg.post(tap: .cghidEventTap)
                return true
            }
            var posted = false
            for _ in 0..<4 {
                let d = postAux(auxKey, keyDown: true)
                let u = postAux(auxKey, keyDown: false)
                posted = posted || (d && u)
                Thread.sleep(forTimeInterval: 0.05)
            }
            return posted
                ? BrightnessResult(ok: true, level: nil, method: "nsevent", hint: nil)
                : BrightnessResult(ok: false, level: nil, method: "nsevent",
                                   hint: "failed to construct NSSystemDefined brightness event")
            #else
            return BrightnessResult(
                ok: false, level: nil, method: "none",
                hint: "brightness direction keys require AppKit (macOS)"
            )
            #endif
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
            // `nightlight status` prints "on"/"off"; it never prints "enabled",
            // so the old check always fell through to "on" (toggle could never
            // turn Night Shift off). Detect the real off-state instead.
            let cur = ProcessRunner.run(bin, ["status"])
            let status = cur.stdout.lowercased()
            let currentlyOn = status.contains("on") && !status.contains("off")
            arg = currentlyOn ? "off" : "on"
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

    // MARK: - Wi-Fi scan + join (extended v0.5.0)

    public struct WifiScanResult: Codable, Sendable {
        public let ok: Bool
        public let networks: [Network]
        public let hint: String?
        /// True when SSIDs were withheld because Location isn't granted to
        /// the responsible process — distinct from a network that is
        /// genuinely hidden (see `Network.hidden`).
        public let ssidsRedacted: Bool
        /// The per-app Location authorization status at scan time (same
        /// strings as `locationPermissionStatusString()`).
        public let locationStatus: String

        private enum CodingKeys: String, CodingKey {
            case ok, networks, hint
            case ssidsRedacted = "ssids_redacted"
            case locationStatus = "location_status"
        }

        public struct Network: Codable, Sendable {
            /// nil when redacted (Location not granted — CoreWLAN's nil is
            /// ambiguous) OR when the network is genuinely hidden (Location
            /// IS granted and CoreWLAN still reported no name). Distinguish
            /// the two via `hidden`.
            public let ssid: String?
            public let rssi: Int?       // signal strength in dBm, nil when unavailable
            public let channel: Int?
            public let security: String?
            /// True only when Location is granted and CoreWLAN reported no
            /// SSID for this network — i.e. a real hidden network, not a
            /// redaction artifact.
            public let hidden: Bool

            private enum CodingKeys: String, CodingKey { case ssid, rssi, channel, security, hidden }

            // Manual encode so `ssid: nil` serializes as JSON `null` rather
            // than being omitted — callers need to tell "redacted/hidden"
            // (key present, null) apart from a field that was never there.
            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(ssid, forKey: .ssid)
                try container.encode(rssi, forKey: .rssi)
                try container.encode(channel, forKey: .channel)
                try container.encode(security, forKey: .security)
                try container.encode(hidden, forKey: .hidden)
            }
        }
    }

    /// Pure decision, given the current Location authorization and the raw
    /// SSID CoreWLAN returned, of what to expose and whether the network is
    /// a genuinely hidden one. Kept pure (no framework calls) so it's
    /// directly testable without touching CoreWLAN/CoreLocation.
    static func classifyNetworkSSID(granted: Bool, rawSSID: String?) -> (ssid: String?, hidden: Bool) {
        guard granted else {
            // Location not granted: CoreWLAN's nil is ambiguous (could be a
            // real hidden network OR just withheld), so we can't claim
            // "hidden" — redact instead of guessing.
            return (nil, false)
        }
        if let rawSSID {
            return (rawSSID, false)
        }
        return (nil, true)
    }

    /// Upper bound for waiting on the Location TCC prompt's answer, same
    /// budget AppleAppsController uses for Calendar/Contacts.
    static let locationPromptTimeout: TimeInterval = 45

    /// If Location authorization is still undecided, request it and wait
    /// (bounded) for the user's answer; otherwise return the current status
    /// immediately without touching CoreLocation again. The request itself
    /// runs on the main actor (see `LocationAuthorizer`).
    private static func ensureLocationAuthorizationRequested() async -> String {
        let status = ToolRegistry.locationPermissionStatusString()
        guard status == "not_determined" else { return status }
        #if canImport(CoreLocation)
        _ = await LocationAuthorizer().requestAndAwaitChange(timeout: locationPromptTimeout)
        return ToolRegistry.locationPermissionStatusString()
        #else
        return status
        #endif
    }

    /// Scan for visible Wi-Fi networks. v0.6.0 A5: switched from the
    /// private `airport` utility (removed in Sonoma 14.4) to the
    /// CoreWLAN framework's `CWWiFiClient.scanForNetworks` API.
    ///
    /// CoreWLAN works on macOS 10.6+, no private entitlement needed for
    /// basic scan. Some managed-fleet devices have scan blocked; in
    /// that case CoreWLAN returns an empty set and we surface a hint.
    ///
    /// v0.8.4: macOS 14+ returns `ssid == nil` for EVERY network unless
    /// Location Services authorization is granted to the responsible
    /// process — CoreWLAN never surfaces this as an error. The old code
    /// mapped nil straight to "(hidden)", making every network
    /// indistinguishable from a genuinely hidden one. We now request
    /// Location (bounded, only if undecided) before scanning and use the
    /// *actual* per-app status — not a network-count heuristic — to decide
    /// whether a nil SSID means "redacted" or "hidden".
    func wifiScan() async -> WifiScanResult {
        #if canImport(CoreWLAN)
        guard let client = CWWiFiClient.shared().interface() else {
            return WifiScanResult(
                ok: false, networks: [],
                hint: "no Wi-Fi interface available via CoreWLAN (adapter disabled?)",
                ssidsRedacted: false,
                locationStatus: ToolRegistry.locationPermissionStatusString()
            )
        }

        let locationStatus = await Self.ensureLocationAuthorizationRequested()
        let granted = ToolRegistry.isGrantedPermissionStatus(locationStatus)

        do {
            let scan = try client.scanForNetworks(withName: nil)
            let nets = scan.map { network -> WifiScanResult.Network in
                // Note: CWNetwork.rssiValue returns 0 when the device didn't
                // capture a signal strength for that entry. We preserve nil
                // semantics by treating 0 as "unknown", since real Wi-Fi
                // RSSI is always negative (-30..-90 dBm range).
                let rssi = network.rssiValue != 0 ? network.rssiValue : nil
                let channel = network.wlanChannel?.channelNumber
                let security: String?
                if #available(macOS 10.15, *) {
                    security = network.supportsSecurity(.wpa3Personal) ? "WPA3"
                        : network.supportsSecurity(.wpa2Personal) ? "WPA2"
                        : network.supportsSecurity(.wpaPersonal) ? "WPA"
                        : network.supportsSecurity(.WEP) ? "WEP"
                        : network.supportsSecurity(.none) ? "Open"
                        : nil
                } else {
                    security = nil
                }
                let (ssid, hidden) = Self.classifyNetworkSSID(granted: granted, rawSSID: network.ssid)
                return WifiScanResult.Network(
                    ssid: ssid,
                    rssi: rssi,
                    channel: channel,
                    security: security,
                    hidden: hidden
                )
            }
            if nets.isEmpty {
                return WifiScanResult(
                    ok: false, networks: [],
                    hint: "CoreWLAN scan returned empty — adapter may be blocked by MDM policy, or no networks visible",
                    ssidsRedacted: !granted,
                    locationStatus: locationStatus
                )
            }
            let hint: String? = granted ? nil : PermissionContext.grantHint(paneTitle: "Location Services")
            return WifiScanResult(ok: true, networks: nets, hint: hint, ssidsRedacted: !granted, locationStatus: locationStatus)
        } catch {
            return WifiScanResult(
                ok: false, networks: [],
                hint: "CoreWLAN scan failed: \(error.localizedDescription)",
                ssidsRedacted: !granted,
                locationStatus: locationStatus
            )
        }
        #else
        return WifiScanResult(
            ok: false, networks: [],
            hint: "CoreWLAN not available on this platform build",
            ssidsRedacted: false,
            locationStatus: "unknown"
        )
        #endif
    }

    /// Join a Wi-Fi network by SSID (+ optional password). macOS stores
    /// the password in Keychain on success, so subsequent joins don't need
    /// the password again.
    func wifiJoin(ssid: String, password: String?) -> ToggleResult {
        guard let iface = wifiInterface() else {
            return ToggleResult(
                ok: false, target: "wifi_join", newState: nil,
                method: "networksetup",
                hint: "no Wi-Fi interface found"
            )
        }
        var args = ["-setairportnetwork", iface, ssid]
        if let pw = password, !pw.isEmpty { args.append(pw) }
        let r = ProcessRunner.run("/usr/sbin/networksetup", args, timeout: 15)
        return ToggleResult(
            ok: r.ok,
            target: "wifi_join",
            newState: r.ok ? "joined:\(ssid)" : nil,
            method: "networksetup",
            hint: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Focus Mode / Do Not Disturb

    /// Toggle Do Not Disturb via shortcuts. macOS 13+ doesn't expose DND
    /// via osascript in a reliable way; we invoke the user's named Shortcut
    /// if they have one. If they don't, we return a hint with the URL to
    /// install a Gallery shortcut.
    func setFocusMode(mode: String, state: String) -> ToggleResult {
        let cmd: String
        switch mode.lowercased() {
        case "dnd", "do_not_disturb", "do-not-disturb":
            cmd = state.lowercased() == "on" ? "Turn Do Not Disturb On" : "Turn Do Not Disturb Off"
        case "work":
            cmd = state.lowercased() == "on" ? "Turn Work Focus On" : "Turn Work Focus Off"
        case "personal":
            cmd = state.lowercased() == "on" ? "Turn Personal Focus On" : "Turn Personal Focus Off"
        case "sleep":
            cmd = state.lowercased() == "on" ? "Turn Sleep Focus On" : "Turn Sleep Focus Off"
        default:
            // Was `state == "on"` (case-sensitive) while every named case
            // lowercased first, so "On"/"ON" flipped a custom mode to Off.
            cmd = "Turn \(mode) Focus \(state.lowercased() == "on" ? "On" : "Off")"
        }
        let r = ProcessRunner.run("/usr/bin/shortcuts", ["run", cmd], timeout: 8)
        if r.ok {
            return ToggleResult(
                ok: true, target: "focus:\(mode)", newState: state,
                method: "shortcuts_run",
                hint: "user-seeded shortcut '\(cmd)' invoked"
            )
        }
        return ToggleResult(
            ok: false, target: "focus:\(mode)", newState: nil,
            method: "shortcuts_run",
            hint: "no shortcut named '\(cmd)' — install one from the Gallery or create it in Shortcuts.app. stderr: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
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
