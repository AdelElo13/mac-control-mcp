import Foundation

/// Audio device selection + mic mute.  Uses the `SwitchAudioSource` CLI
/// when present (the de-facto Homebrew standard), falling back to a
/// structured install hint when not.  Choice to depend on this over
/// writing CoreAudio-direct Swift code: SwitchAudioSource is a 500-line
/// single-purpose tool that's been battle-tested for 10+ years, the
/// Apple APIs (AudioHardware, IOAudio) are notoriously version-brittle,
/// and every brew-user already has it.
///
/// Commands used:
///   SwitchAudioSource -a -t output   → list output devices
///   SwitchAudioSource -a -t input    → list input devices
///   SwitchAudioSource -c -t output   → current output
///   SwitchAudioSource -s "Name"      → set current output (or -t input)
///
/// Mic mute uses `osascript` to set the input volume to 0 (and restore
/// to previous on unmute), because SwitchAudioSource doesn't expose mute.
actor AudioController {

    public struct Device: Codable, Sendable {
        public let name: String
        public let kind: String     // "output" | "input"
        public let isCurrent: Bool
    }

    public struct DeviceListResult: Codable, Sendable {
        public let ok: Bool
        public let devices: [Device]
        public let hint: String?
    }

    public struct DeviceSetResult: Codable, Sendable {
        public let ok: Bool
        public let device: String
        public let kind: String
        public let hint: String?
    }

    public struct MuteResult: Codable, Sendable {
        public let ok: Bool
        public let muted: Bool
        public let method: String
        public let error: String?
    }

    /// Enumerate every audio device (output + input). Marks the currently
    /// selected one.
    func listDevices() -> DeviceListResult {
        guard let bin = ProcessRunner.which("SwitchAudioSource") else {
            return DeviceListResult(
                ok: false, devices: [],
                hint: "install 'switchaudio-osx' (brew install switchaudio-osx) to list/select audio devices"
            )
        }
        func fetch(kind: String) -> ([String], String?) {
            let listResult = ProcessRunner.run(bin, ["-a", "-t", kind])
            let currentResult = ProcessRunner.run(bin, ["-c", "-t", kind])
            let names = listResult.stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let current = currentResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return (names, current.isEmpty ? nil : current)
        }
        let (outNames, outCurrent) = fetch(kind: "output")
        let (inNames, inCurrent) = fetch(kind: "input")
        var devices: [Device] = []
        for n in outNames { devices.append(.init(name: n, kind: "output", isCurrent: n == outCurrent)) }
        for n in inNames  { devices.append(.init(name: n, kind: "input",  isCurrent: n == inCurrent)) }
        return DeviceListResult(ok: true, devices: devices, hint: nil)
    }

    /// Switch output device by name. Name must be one of the entries
    /// returned by `listDevices(kind:"output")`.
    func setOutputDevice(name: String) -> DeviceSetResult {
        guard let bin = ProcessRunner.which("SwitchAudioSource") else {
            return DeviceSetResult(
                ok: false, device: name, kind: "output",
                hint: "install 'switchaudio-osx' (brew install switchaudio-osx)"
            )
        }
        let r = ProcessRunner.run(bin, ["-s", name, "-t", "output"])
        return DeviceSetResult(
            ok: r.ok, device: name, kind: "output",
            hint: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Switch input device (microphone) by name.
    func setInputDevice(name: String) -> DeviceSetResult {
        guard let bin = ProcessRunner.which("SwitchAudioSource") else {
            return DeviceSetResult(
                ok: false, device: name, kind: "input",
                hint: "install 'switchaudio-osx' (brew install switchaudio-osx)"
            )
        }
        let r = ProcessRunner.run(bin, ["-s", name, "-t", "input"])
        return DeviceSetResult(
            ok: r.ok, device: name, kind: "input",
            hint: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Mute / unmute the current input device.  Sets the input volume to
    /// 0 when muting, and to 100 when unmuting (we don't have a way to
    /// round-trip the pre-mute level across separate tool calls without
    /// persistent state).  Agents that need the previous level should
    /// capture it from `system_load` / AppleScript before calling.
    func setMicMute(mute: Bool) -> MuteResult {
        let level = mute ? 0 : 100
        let script = "set volume input volume \(level)"
        let r = OsascriptRunner.run(script)
        return MuteResult(
            ok: r.ok, muted: mute, method: "osascript_set_input_volume",
            error: r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
