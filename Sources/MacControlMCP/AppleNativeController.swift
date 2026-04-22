import Foundation
#if canImport(Intents)
import Intents
#endif
#if canImport(AppIntents)
import AppIntents
#endif

/// Apple-native automation surfaces introduced 2025-2026:
///
///   - **Foundation Models** (macOS Tahoe 26+) — on-device LLM callable
///     by 3rd-party apps. We wrap with a `#if canImport(FoundationModels)`
///     and degrade to a structured "not available on this macOS" hint
///     when the framework isn't present.
///   - **App Intents** — lightweight enumeration of installed apps that
///     expose App Intents via Spotlight, and a generic `invoke` shim that
///     routes through the `shortcuts` CLI (the only sanctioned
///     third-party invocation path; direct AppIntent execution requires
///     the calling app to be bundled with the intent definition).
///
/// v0.7.0 ships a minimal surface — enough for agents to discover and
/// dispatch common app-level automations. v0.8.0 can deepen once Apple
/// stabilises the ThirdPartyAppIntents story.
actor AppleNativeController {

    public struct FoundationModelsResult: Codable, Sendable {
        public let ok: Bool
        public let text: String?
        public let model: String?        // "apple-intelligence" when we hit the real framework
        public let onDevice: Bool
        public let error: String?
        public let hint: String?
    }

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

    // MARK: - Foundation Models

    /// Call Apple's on-device Foundation Models framework to generate
    /// text from a prompt.  When the framework isn't available (older
    /// macOS, Intel Mac w/o Apple Intelligence), returns a structured
    /// hint so callers can fall back to a network model.
    ///
    /// Note on Swift compile-time availability: the FoundationModels
    /// framework ships with macOS Tahoe (26+). To let this file compile
    /// on older SDKs / CI runners, we guard with `#if canImport`. When
    /// the import succeeds at build time, the real call site is compiled;
    /// otherwise the stub path runs.
    func foundationModelsGenerate(
        prompt: String,
        system: String?
    ) async -> FoundationModelsResult {
        #if canImport(FoundationModels)
        // Real path. `LanguageModelSession` / `LanguageModel` are the
        // macOS Tahoe API surface. Kept name-flexible so we don't break
        // on minor API renames.
        do {
            let session = try await createFoundationSession(system: system)
            let response = try await session.respond(to: prompt)
            return FoundationModelsResult(
                ok: true,
                text: response,
                model: "apple-intelligence",
                onDevice: true,
                error: nil,
                hint: nil
            )
        } catch {
            return FoundationModelsResult(
                ok: false, text: nil,
                model: "apple-intelligence",
                onDevice: true,
                error: error.localizedDescription,
                hint: "Foundation Models returned an error — check that Apple Intelligence is enabled for this Mac"
            )
        }
        #else
        return FoundationModelsResult(
            ok: false,
            text: nil,
            model: nil,
            onDevice: false,
            error: nil,
            hint: "FoundationModels framework not available on this build (requires macOS 26 Tahoe+ and Apple Intelligence). Fall back to a network model."
        )
        #endif
    }

    #if canImport(FoundationModels)
    // Compile-isolated helper so the TYPE references only exist when the
    // framework is available.
    private func createFoundationSession(system: String?) async throws -> FoundationModelsStub {
        // The framework's public Swift API will likely look like
        // `LanguageModelSession(...).respond(to:)` by GA. We abstract
        // behind this stub so we can adapt without a rebuild chain.
        return FoundationModelsStub(system: system)
    }

    private struct FoundationModelsStub {
        let system: String?
        func respond(to prompt: String) async throws -> String {
            // Hard-fails so the real API lands before v0.7.0 depends on
            // generated text. We don't want to invent output the framework
            // didn't generate.
            throw NSError(domain: "mac-control-mcp.FoundationModels",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "FoundationModels integration pending — the framework is importable at build time but the public session API we need has not been wired yet. Use a Shortcut that invokes Apple Intelligence as a workaround."])
        }
    }
    #endif

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
                let plistPath = "\(root)/\(entry)/Contents/Info.plist"
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

                // Heuristic: any of these keys suggest the app ships Intents
                let hasIntents =
                    plist["NSAppShortcuts"] != nil ||
                    plist["INIntentsRestrictedWhileLocked"] != nil ||
                    plist["INSupportsMultipleAppSemantic"] != nil ||
                    plist["IntentsSupported"] != nil ||
                    (plist["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.intents-service"

                if hasIntents {
                    // We can't count intents without parsing Metadata.appintents;
                    // report 1+ as a discoverability signal.
                    apps.append(.init(bundleId: bundleID, appName: name, intentCount: 1))
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
        if let input, !input.isEmpty {
            args.append(contentsOf: ["--input", input])
        }
        let r = ProcessRunner.run("/usr/bin/shortcuts", args, timeout: 30)
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
