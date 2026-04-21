import Foundation

/// Read-only system telemetry: battery, CPU/RAM load, network, bluetooth,
/// disk usage.
///
/// v0.5.0 Codex hardening: every method now returns a `Result<Payload>`
/// envelope that propagates subprocess exit codes + stderr. v0.4.0 had a
/// silent-success bug — `battery_status` returned `ok:true` with all-nil
/// fields if `pmset` failed. Now a failing subprocess produces `ok:false`
/// with the stderr tail, so agents can distinguish "empty laptop battery"
/// from "pmset is broken".
///
/// All methods shell out to Apple-provided binaries (`pmset`, `top`,
/// `df`, `networksetup`, `system_profiler`) with timeouts so a stuck
/// subprocess can never wedge the MCP.
actor SystemInfoController {

    /// Uniform envelope — every public method returns one of these.
    /// `data` is populated when `ok == true`; `error` carries a stderr tail
    /// / parse-failure reason when `ok == false`. Callers can treat `ok`
    /// as the authoritative "did the subprocess and the parser both
    /// succeed" signal, instead of inspecting `data` for nil fields.
    public struct Result<T: Codable & Sendable>: Codable, Sendable {
        public let ok: Bool
        public let data: T?
        public let error: String?
        public let exitCode: Int32?
    }

    // MARK: - Battery

    public struct Battery: Codable, Sendable {
        public let percentage: Int?           // 0-100, nil on desktop Macs w/o battery
        public let charging: Bool?
        public let pluggedIn: Bool?
        public let timeRemainingMinutes: Int? // -1 = calculating, nil = n/a
        public let rawStatus: String
    }

    /// Parses `pmset -g batt` which looks like:
    ///   Now drawing from 'AC Power'
    ///    -InternalBattery-0 (id=0) 97%; charged; 0:00 remaining present: true
    func battery() -> Result<Battery> {
        let r = ProcessRunner.run("/usr/bin/pmset", ["-g", "batt"], timeout: 3)
        guard r.ok else {
            return Result(
                ok: false, data: nil,
                error: "pmset failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                exitCode: r.exitCode
            )
        }
        let out = r.stdout

        var percentage: Int?
        if let match = out.range(of: #"(\d{1,3})%"#, options: .regularExpression) {
            percentage = Int(out[match].replacingOccurrences(of: "%", with: ""))
        }
        let pluggedIn: Bool? = out.contains("AC Power") ? true :
            (out.contains("Battery Power") ? false : nil)
        let charging: Bool? = out.contains("; charging;") ? true :
            (out.contains("; discharging;") ? false :
             (out.contains("; charged;") ? false : nil))

        var timeRemaining: Int?
        if let match = out.range(of: #"(\d+):(\d{2}) remaining"#, options: .regularExpression) {
            let parts = out[match].split(separator: " ")[0].split(separator: ":")
            if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) {
                timeRemaining = h * 60 + m
            }
        } else if out.contains("(no estimate)") {
            timeRemaining = -1
        }

        let battery = Battery(
            percentage: percentage,
            charging: charging,
            pluggedIn: pluggedIn,
            timeRemainingMinutes: timeRemaining,
            rawStatus: out.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return Result(ok: true, data: battery, error: nil, exitCode: 0)
    }

    // MARK: - CPU + memory load

    public struct Load: Codable, Sendable {
        public let cpuUserPercent: Double?
        public let cpuSystemPercent: Double?
        public let cpuIdlePercent: Double?
        public let loadAverage1m: Double?
        public let loadAverage5m: Double?
        public let loadAverage15m: Double?
        public let memoryTotalMB: Int?
        public let memoryUsedMB: Int?
        public let memoryFreeMB: Int?
        public let memoryPressurePercent: Double?
    }

    /// Parse `top -l 1 -n 0` (snapshot, no processes). Faster + more portable
    /// than `vm_stat + sysctl` surfaces.
    func load() -> Result<Load> {
        let topRes = ProcessRunner.run("/usr/bin/top", ["-l", "1", "-n", "0"], timeout: 5)
        guard topRes.ok else {
            return Result(
                ok: false, data: nil,
                error: "top failed: \(topRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                exitCode: topRes.exitCode
            )
        }
        let lines = topRes.stdout.split(separator: "\n").map(String.init)

        var cpuUser: Double?, cpuSys: Double?, cpuIdle: Double?
        var load1: Double?, load5: Double?, load15: Double?
        var memTotal: Int?, memUsed: Int?, memFree: Int?, memPressure: Double?

        for line in lines {
            if line.hasPrefix("CPU usage:") {
                // CPU usage: 4.54% user, 3.03% sys, 92.42% idle
                let parts = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for p in parts {
                    let tokens = p.replacingOccurrences(of: "CPU usage:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                        .split(separator: " ")
                    guard tokens.count >= 2 else { continue }
                    let num = Double(tokens[0].dropLast()) // strip %
                    switch tokens[1] {
                    case "user":  cpuUser = num
                    case "sys":   cpuSys = num
                    case "idle":  cpuIdle = num
                    default: break
                    }
                }
            } else if line.hasPrefix("Load Avg:") {
                // Load Avg: 2.51, 2.34, 2.20
                let nums = line
                    .replacingOccurrences(of: "Load Avg:", with: "")
                    .split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if nums.count == 3 { load1 = nums[0]; load5 = nums[1]; load15 = nums[2] }
            } else if line.hasPrefix("PhysMem:") {
                if let usedMatch = line.range(of: #"(\d+[GMKB])\s+used"#, options: .regularExpression) {
                    memUsed = bytesToMB(String(line[usedMatch]).components(separatedBy: .whitespaces)[0])
                }
                if let freeMatch = line.range(of: #"(\d+[GMKB])\s+unused"#, options: .regularExpression) {
                    memFree = bytesToMB(String(line[freeMatch]).components(separatedBy: .whitespaces)[0])
                }
                if let u = memUsed, let f = memFree { memTotal = u + f }
            }
        }

        // Memory pressure — separate tool, more accurate.  If it fails we
        // just leave the field nil rather than flipping the whole result
        // to ok:false; the `top` numbers are still valid.
        let memP = ProcessRunner.run("/usr/bin/memory_pressure", [], timeout: 3)
        if memP.ok,
           let pressureMatch = memP.stdout.range(of: #"System-wide memory free percentage:\s*(\d+)%"#, options: .regularExpression) {
            let nums = memP.stdout[pressureMatch].compactMap { $0.isNumber ? String($0) : nil }.joined()
            if let free = Double(nums) {
                memPressure = 100.0 - free
            }
        }

        // If every field is nil the parser clearly broke — report it as a
        // parse failure rather than a success with an empty payload.
        let anyFieldPopulated = cpuUser != nil || cpuSys != nil || load1 != nil || memUsed != nil
        guard anyFieldPopulated else {
            return Result(
                ok: false, data: nil,
                error: "parser produced no data from top output (format drift?); first 200 chars: \(topRes.stdout.prefix(200))",
                exitCode: 0
            )
        }

        let load = Load(
            cpuUserPercent: cpuUser, cpuSystemPercent: cpuSys, cpuIdlePercent: cpuIdle,
            loadAverage1m: load1, loadAverage5m: load5, loadAverage15m: load15,
            memoryTotalMB: memTotal, memoryUsedMB: memUsed, memoryFreeMB: memFree,
            memoryPressurePercent: memPressure
        )
        return Result(ok: true, data: load, error: nil, exitCode: 0)
    }

    private func bytesToMB(_ token: String) -> Int? {
        guard let last = token.last else { return nil }
        let numPart = String(token.dropLast())
        guard let n = Double(numPart) else { return nil }
        switch last {
        case "G": return Int(n * 1024)
        case "M": return Int(n)
        case "K": return Int(n / 1024)
        case "B": return Int(n / 1024 / 1024)
        default:
            return Int(token)
        }
    }

    // MARK: - Network

    public struct Network: Codable, Sendable {
        public let wifiSSID: String?
        public let wifiInterface: String?
        public let interfaces: [Interface]
        public struct Interface: Codable, Sendable {
            public let name: String
            public let ip: String?
            public let mac: String?
            public let active: Bool
        }
    }

    func network() -> Result<Network> {
        var wifiSSID: String?, wifiIFace: String?

        let listRes = ProcessRunner.run("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 3)
        guard listRes.ok else {
            return Result(
                ok: false, data: nil,
                error: "networksetup failed: \(listRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                exitCode: listRes.exitCode
            )
        }
        for block in listRes.stdout.components(separatedBy: "\n\n") {
            guard block.contains("Wi-Fi") || block.contains("AirPort") else { continue }
            let devLine = block.split(separator: "\n").first(where: { $0.contains("Device:") })
            if let devLine, let iface = devLine.split(separator: " ").last {
                wifiIFace = String(iface)
                let airRes = ProcessRunner.run("/usr/sbin/networksetup", ["-getairportnetwork", String(iface)], timeout: 3)
                if airRes.ok, let colon = airRes.stdout.firstIndex(of: ":") {
                    let name = airRes.stdout[airRes.stdout.index(after: colon)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    wifiSSID = name.isEmpty ? nil : name
                }
            }
        }

        var interfaces: [Network.Interface] = []
        let ifRes = ProcessRunner.run("/sbin/ifconfig", ["-a"], timeout: 3)
        guard ifRes.ok else {
            return Result(
                ok: false, data: nil,
                error: "ifconfig failed: \(ifRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                exitCode: ifRes.exitCode
            )
        }
        var currentName: String?
        var currentMAC: String?
        var currentIP: String?
        var currentActive = false
        func flush() {
            if let name = currentName {
                interfaces.append(.init(name: name, ip: currentIP, mac: currentMAC, active: currentActive))
            }
            currentName = nil; currentMAC = nil; currentIP = nil; currentActive = false
        }
        for raw in ifRes.stdout.split(separator: "\n") {
            let line = String(raw)
            if !line.hasPrefix("\t") && line.contains(":") {
                flush()
                currentName = String(line.split(separator: ":")[0])
                currentActive = line.contains("UP")
            } else {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("ether ") {
                    currentMAC = String(t.dropFirst("ether ".count))
                } else if t.hasPrefix("inet ") {
                    currentIP = String(t.dropFirst("inet ".count).split(separator: " ")[0])
                }
            }
        }
        flush()

        let network = Network(
            wifiSSID: wifiSSID,
            wifiInterface: wifiIFace,
            interfaces: interfaces
        )
        return Result(ok: true, data: network, error: nil, exitCode: 0)
    }

    // MARK: - Bluetooth

    public struct BluetoothSummary: Codable, Sendable {
        public let enabled: Bool?
        public let devices: [Device]
        public struct Device: Codable, Sendable {
            public let name: String
            public let address: String
            public let connected: Bool
        }
    }

    func bluetoothSummary() -> Result<BluetoothSummary> {
        let r = ProcessRunner.run(
            "/usr/sbin/system_profiler",
            ["SPBluetoothDataType", "-json"],
            timeout: 6
        )
        guard r.ok else {
            return Result(
                ok: false, data: nil,
                error: "system_profiler failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                exitCode: r.exitCode
            )
        }
        guard let data = r.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["SPBluetoothDataType"] as? [[String: Any]],
              let root = arr.first
        else {
            return Result(
                ok: false, data: nil,
                error: "system_profiler produced unparseable JSON (length \(r.stdout.count))",
                exitCode: r.exitCode
            )
        }

        let enabled = (root["controller_properties"] as? [String: Any])?["controller_state"] as? String == "on_state"
        var devices: [BluetoothSummary.Device] = []

        func collect(from dict: [String: Any], connected: Bool) {
            for (name, v) in dict {
                guard let info = v as? [String: Any] else { continue }
                let addr = info["device_address"] as? String ?? ""
                devices.append(.init(name: name, address: addr, connected: connected))
            }
        }
        if let conn = root["device_connected"] as? [[String: Any]] {
            for entry in conn { collect(from: entry, connected: true) }
        }
        if let notConn = root["device_not_connected"] as? [[String: Any]] {
            for entry in notConn { collect(from: entry, connected: false) }
        }

        return Result(
            ok: true,
            data: BluetoothSummary(enabled: enabled, devices: devices),
            error: nil, exitCode: 0
        )
    }

    // MARK: - Disk usage

    public struct DiskUsage: Codable, Sendable {
        public let volumes: [Volume]
        public struct Volume: Codable, Sendable {
            public let name: String
            public let mountPoint: String
            public let totalGB: Double
            public let usedGB: Double
            public let availableGB: Double
            public let usedPercent: Double
        }
    }

    func diskUsage() -> Result<DiskUsage> {
        // `df -g -P` — POSIX output, GB blocks, single-line per volume even
        // for long mount names. The -P flag is critical: without it, mount
        // names with whitespace land on multi-line records that the old
        // whitespace-split parser broke on (Codex finding).
        let r = ProcessRunner.run("/bin/df", ["-g", "-P"], timeout: 3)
        guard r.ok else {
            return Result(
                ok: false, data: nil,
                error: "df failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                exitCode: r.exitCode
            )
        }
        var volumes: [DiskUsage.Volume] = []
        let lines = r.stdout.split(separator: "\n").dropFirst() // skip header
        for line in lines {
            // -P guarantees: fs SP total SP used SP avail SP capacity% SP mount...
            // Mount can contain spaces, so we split into MAX 6 fields and
            // treat the tail as the mount point.
            let cols = splitMaxFields(String(line), max: 6)
            guard cols.count >= 6 else { continue }
            let name = cols[0]
            let total = Double(cols[1]) ?? 0
            let used = Double(cols[2]) ?? 0
            let avail = Double(cols[3]) ?? 0
            let usedPct = Double(cols[4].replacingOccurrences(of: "%", with: "")) ?? 0
            let mount = cols[5]
            guard mount.hasPrefix("/") && !mount.hasPrefix("/System/Volumes/VM") &&
                  !["devfs", "map auto_home"].contains(name) else { continue }
            volumes.append(.init(
                name: name,
                mountPoint: mount,
                totalGB: total,
                usedGB: used,
                availableGB: avail,
                usedPercent: usedPct
            ))
        }
        return Result(
            ok: true,
            data: DiskUsage(volumes: volumes),
            error: nil, exitCode: 0
        )
    }

    /// Split `line` on whitespace, but collapse anything beyond the `max`-th
    /// field into the last returned element. Mirrors shell `read -r a b c rest`
    /// semantics. Needed because `df -P` mount points can contain spaces but
    /// the preceding 5 columns are whitespace-free.
    ///
    /// Implementation walks the string once, tracking byte-offsets rather
    /// than joining-and-re-offsetting (which was the bug that made the
    /// disk_usage test return 0 volumes: the joined-string offset didn't
    /// match the source position once fields contained more than one char).
    private func splitMaxFields(_ line: String, max: Int) -> [String] {
        var out: [String] = []
        var buf = ""
        var startIndex = line.startIndex
        var cursor = line.startIndex

        while cursor < line.endIndex {
            let ch = line[cursor]
            if ch == " " || ch == "\t" {
                if !buf.isEmpty {
                    out.append(buf)
                    buf = ""
                    if out.count == max - 1 {
                        // Take everything past the current cursor as the tail
                        // (the "rest" field that may contain whitespace).
                        let rest = line[cursor...].trimmingCharacters(in: .whitespaces)
                        if !rest.isEmpty { out.append(rest) }
                        return out
                    }
                }
                cursor = line.index(after: cursor)
                startIndex = cursor
            } else {
                buf.append(ch)
                cursor = line.index(after: cursor)
            }
        }
        if !buf.isEmpty { out.append(buf) }
        _ = startIndex // silence unused warning in tight builds
        return out
    }
}
