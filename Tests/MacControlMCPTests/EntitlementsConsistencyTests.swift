import Testing
import Foundation

/// Regression guard for the v0.8.2 TCC bug: the bundle declared
/// NSCalendars/NSContacts/NSMicrophone usage descriptions but was signed with
/// hardened runtime WITHOUT the matching resource-access entitlements, so TCC
/// denied calendar/contacts/microphone silently (no prompt) whenever
/// MacControlMCP.app was the responsible process (Claude Desktop).
///
/// Drives scripts/check-entitlements.sh — the same gate build-bundle.sh and CI
/// run — against the checked-in bundle sources and against real ad-hoc signed
/// bundles, so the codesign read path is exercised too.
@Suite("Entitlements ↔ Info.plist usage descriptions", .serialized, .timeLimit(.minutes(1)))
struct EntitlementsConsistencyTests {
    static let root: URL = {
        let dir = (#filePath as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: dir).deletingLastPathComponent().deletingLastPathComponent()
    }()
    static let checker = root.appendingPathComponent("scripts/check-entitlements.sh").path
    static let infoPlist = root.appendingPathComponent("scripts/bundle/Info.plist").path
    static let entitlements = root.appendingPathComponent("scripts/bundle/MacControlMCP.entitlements").path

    /// The exact entitlement set v0.8.2 shipped with.
    static let v082Entitlements = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>com.apple.security.automation.apple-events</key><true/>
    <key>com.apple.security.device.audio-input</key><false/>
    <key>com.apple.security.device.camera</key><false/>
    </dict></plist>
    """

    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "launch failed: \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Builds a minimal hardened-runtime, ad-hoc signed .app around /usr/bin/true
    /// carrying the real Info.plist and the given entitlements file.
    static func makeSignedBundle(entitlementsPath: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmcp-ent-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("MacControlMCP.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macos.appendingPathComponent("MacControlMCP").path)
        let plist = try String(contentsOfFile: infoPlist, encoding: .utf8)
            .replacingOccurrences(of: "__VERSION__", with: "0.0.0-test")
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let sign = run("/usr/bin/codesign", ["--force", "--options", "runtime", "--sign", "-",
                                             "--entitlements", entitlementsPath, app.path])
        #expect(sign.status == 0, "codesign failed: \(sign.output)")
        return app
    }

    @Test("checked-in Info.plist and entitlements are consistent (source mode)")
    func sourceFilesConsistent() {
        let r = Self.run("/bin/bash", [Self.checker, "--info-plist", Self.infoPlist, "--entitlements", Self.entitlements])
        #expect(r.status == 0, "checker output:\n\(r.output)")
        for ent in ["personal-information.calendars", "personal-information.addressbook", "device.audio-input"] {
            #expect(r.output.contains("com.apple.security.\(ent)"), "expected \(ent) to be checked")
        }
    }

    @Test("signed bundle with the shipped entitlements passes (codesign mode)")
    func signedBundlePasses() throws {
        let app = try Self.makeSignedBundle(entitlementsPath: Self.entitlements)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let r = Self.run("/bin/bash", [Self.checker, app.path])
        #expect(r.status == 0, "checker output:\n\(r.output)")
    }

    @Test("signed bundle with v0.8.2 entitlements fails on calendars, contacts and microphone")
    func v082EntitlementsRejected() throws {
        let entFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("v082-\(UUID().uuidString).entitlements")
        try Self.v082Entitlements.write(to: entFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: entFile) }
        let app = try Self.makeSignedBundle(entitlementsPath: entFile.path)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let r = Self.run("/bin/bash", [Self.checker, app.path])
        #expect(r.status == 1, "checker must fail, output:\n\(r.output)")
        #expect(r.output.contains("FAIL  NSCalendarsFullAccessUsageDescription"))
        #expect(r.output.contains("FAIL  NSContactsUsageDescription"))
        #expect(r.output.contains("FAIL  NSMicrophoneUsageDescription requires com.apple.security.device.audio-input=true (found: false)"))
    }

    @Test("unknown usage description keys fail the check instead of slipping through")
    func unknownUsageKeyRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macmcp-unk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appendingPathComponent("Info.plist")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>NSBluetoothAlwaysUsageDescription</key><string>x</string>
        </dict></plist>
        """.write(to: plist, atomically: true, encoding: .utf8)

        let r = Self.run("/bin/bash", [Self.checker, "--info-plist", plist.path, "--entitlements", Self.entitlements])
        #expect(r.status == 1, "checker output:\n\(r.output)")
        #expect(r.output.contains("unknown usage description"))
    }
}
