import Foundation
#if canImport(Intents)
import Intents
#endif
#if canImport(AppIntents)
import AppIntents
#endif

/// Apple-native automation surfaces introduced 2025-2026:
///
///   - **App Intents** — lightweight enumeration of installed apps that
///     expose App Intents via Spotlight, and a generic `invoke` shim that
///     routes through the `shortcuts` CLI (the only sanctioned
///     third-party invocation path; direct AppIntent execution requires
///     the calling app to be bundled with the intent definition).
///
/// v0.7.0 ships a minimal surface — enough for agents to discover and
/// dispatch common app-level automations. v0.8.0 can deepen once Apple
/// stabilises the ThirdPartyAppIntents story.
///
/// Note: a `foundation_models_generate` tool (Apple's on-device LLM) was
/// removed in v0.9 (see A-5 in the gap audit) — the public
/// `LanguageModelSession` API could not be live-verified end to end
/// (this dev Mac reports `SystemLanguageModel.default.availability ==
/// .unavailable(.appleIntelligenceNotEnabled)`, and enabling Apple
/// Intelligence is a system-settings change outside this task's
/// read-only-desktop constraint), and the shipped stub always threw a
/// hard "integration pending" error — a tool that can never succeed
/// must not be listed per this project's own honest-failure rule.
actor AppleNativeController {

    public struct AppIntentSummary: Codable, Sendable {
        public let bundleId: String
        public let appName: String
        public let intentCount: Int      // best-effort; actual discovery is limited w/o CFBundleBuiltInPlugins walk
    }

    public struct AppIntentsListResult: Codable, Sendable {
        public let ok: Bool
        public let apps: [AppIntentSummary]
        public let hint: String?
    }

    public struct AppIntentInvokeResult: Codable, Sendable {
        public let ok: Bool
        public let bundleId: String
        public let intent: String
        public let method: String        // "shortcuts_run" | "url_scheme" | "applescript"
        public let stdout: String?
        public let stderr: String?
    }

    // MARK: - App Intents

    /// Enumerate installed apps that expose App Intents.  Proxy metric:
    /// we count apps that ship an `AppShortcuts` Info.plist entry OR an
    /// `Intents` or `IntentsRestrictedWhileLocked` keys.  Not perfect —
    /// there's no public "give me every App Intent" API — but it lets
    /// agents narrow which apps are automation-friendly.
    ///
    /// Performance: this walks /Applications bundle Info.plists.  Caches
    /// in-memory for the lifetime of the actor.
    private var cachedApps: [AppIntentSummary]?

    func listAppIntents() async -> AppIntentsListResult {
        if let c = cachedApps {
            return AppIntentsListResult(ok: true, apps: c, hint: nil)
        }
        var apps: [AppIntentSummary] = []
        let fm = FileManager.default
        let roots = [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications"
        ].filter { fm.fileExists(atPath: $0) }

        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let appPath = "\(root)/\(entry)"
                let plistPath = "\(appPath)/Contents/Info.plist"
                guard fm.fileExists(atPath: plistPath),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
                      let plist = try? PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil
                      ) as? [String: Any]
                else { continue }

                let bundleID = plist["CFBundleIdentifier"] as? String ?? entry
                let name = plist["CFBundleName"] as? String
                    ?? plist["CFBundleDisplayName"] as? String
                    ?? entry.replacingOccurrences(of: ".app", with: "")

                // v0.7.1 fix (BUG 2): Apple's first-party apps (Calendar,
                // Reminders, Notes, Messages, Safari etc) don't expose
                // Info.plist intent-keys but DO ship a compiled
                // `Contents/Resources/Metadata.appintents/` bundle. Check
                // for that directory first — it's the authoritative signal.
                let metadataAppintents = "\(appPath)/Contents/Resources/Metadata.appintents"
                let hasCompiledIntents = fm.fileExists(atPath: metadataAppintents)

                let hasInfoPlistHint =
                    plist["NSAppShortcuts"] != nil ||
                    plist["INIntentsRestrictedWhileLocked"] != nil ||
                    plist["INSupportsMultipleAppSemantic"] != nil ||
                    plist["IntentsSupported"] != nil ||
                    (plist["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.intents-service"

                if hasCompiledIntents || hasInfoPlistHint {
                    // If we have the compiled bundle, count the files under
                    // it as a rough upper bound on intent count.
                    var count = 1
                    if hasCompiledIntents,
                       let subEntries = try? fm.contentsOfDirectory(atPath: metadataAppintents) {
                        count = max(1, subEntries.count)
                    }
                    apps.append(.init(bundleId: bundleID, appName: name, intentCount: count))
                }
            }
        }

        cachedApps = apps
        return AppIntentsListResult(
            ok: true, apps: apps,
            hint: apps.isEmpty
                ? "No apps with App Intents metadata found — this is normal on fresh macOS installs without productivity apps"
                : nil
        )
    }

    /// Invoke an app intent.  Under the hood we always route through
    /// `shortcuts run "<intent>"` because direct AppIntent invocation
    /// from an unbundled process is not supported.  If the user has a
    /// Shortcut with the named intent name, it fires.  Otherwise we
    /// return a structured hint instructing the user to create one.
    func invokeAppIntent(bundleId: String, intent: String, input: String?) async -> AppIntentInvokeResult {
        var args = ["run", intent]
        // `shortcuts run` has no `--input <text>` flag (that made every call
        // with input fail); it reads input from a file via `--input-path`.
        // Stage the text in a temp file and clean it up afterwards.
        var tempInput: URL?
        if let input, !input.isEmpty {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mac-control-mcp-intent-\(UUID().uuidString).txt")
            if (try? input.write(to: url, atomically: true, encoding: .utf8)) != nil {
                args.append(contentsOf: ["--input-path", url.path])
                tempInput = url
            }
        }
        let r = ProcessRunner.run("/usr/bin/shortcuts", args, timeout: 30)
        if let tempInput { try? FileManager.default.removeItem(at: tempInput) }
        return AppIntentInvokeResult(
            ok: r.ok,
            bundleId: bundleId,
            intent: intent,
            method: "shortcuts_run",
            stdout: r.stdout.isEmpty ? nil : r.stdout,
            stderr: r.stderr.isEmpty ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
