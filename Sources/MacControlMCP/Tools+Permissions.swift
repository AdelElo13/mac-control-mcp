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
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif

// v0.8.3 — permissions_status + request_permissions.
//
// Two measured v0.8.2 problems drive this file:
//   - Status depended on who launched the server (shell: accessibility
//     granted / screen not; Claude Desktop: the reverse) but the output never
//     said which app the grants belong to. Every report now names the
//     responsible app (PermissionContext).
//   - request_permissions hung past the client's timeout: it probed
//     ~/Desktop, ~/Documents, ~/Downloads synchronously, and a first-time
//     folder TCC prompt blocks the calling thread until answered — while the
//     stdio loop waited on it. Prompts are now fired off without waiting and
//     the current status comes back immediately.
extension ToolRegistry {

    struct PermissionStatusEntry: Sendable, Equatable {
        let name: String
        let status: String
    }

    /// Categories request_permissions can prompt for.
    static let requestablePermissionCategories = [
        "accessibility", "screen_recording", "calendar", "contacts", "microphone", "location", "folders"
    ]

    /// Hardened-runtime entitlement each TCC category needs when this app is
    /// the responsible process.
    static let entitlementByCategory: [String: String] = [
        "calendar": "com.apple.security.personal-information.calendars",
        "reminders": "com.apple.security.personal-information.calendars",
        "contacts": "com.apple.security.personal-information.addressbook",
        "microphone": "com.apple.security.device.audio-input",
        "location": "com.apple.security.personal-information.location"
    ]

    func currentPermissionStatuses() async -> [PermissionStatusEntry] {
        let ax = await accessibility.checkPermission()
        // v0.8.4 review fix: location is read on the main actor — see
        // locationPermissionStatusStringMainActor().
        let locationStatus = await Self.locationPermissionStatusStringMainActor()
        return [
            PermissionStatusEntry(name: "accessibility", status: ax ? "granted" : "not_granted"),
            PermissionStatusEntry(name: "screen_recording", status: Self.screenPermissionStatusString()),
            PermissionStatusEntry(name: "calendar", status: Self.calendarPermissionStatusString()),
            PermissionStatusEntry(name: "reminders", status: Self.remindersPermissionStatusString()),
            PermissionStatusEntry(name: "contacts", status: Self.contactsPermissionStatusString()),
            PermissionStatusEntry(name: "location", status: locationStatus),
            PermissionStatusEntry(name: "microphone", status: Self.microphonePermissionStatusString())
        ]
    }

    static func isGrantedPermissionStatus(_ status: String) -> Bool {
        // `write_only` is NOT granted: calendar_list_events needs full access,
        // so reporting it as ready contradicted the next call's failure.
        let granted: Set<String> = ["granted", "granted_when_in_use", "granted_always", "granted_legacy",
                                    "authorized_legacy", "limited"]
        // `location` can only report the system-wide services state.
        return granted.contains(status) || status.hasPrefix("granted")
    }

    /// Categories that will be refused WITHOUT a prompt: this app is the
    /// responsible process, runs under hardened runtime, the status is still
    /// not_determined, and the matching entitlement is absent.
    static func promptBlockedByMissingEntitlement(
        _ statuses: [PermissionStatusEntry],
        responsibleIsSelf: Bool = PermissionContext.current.responsibleIsSelf,
        hardenedRuntime: Bool = PermissionContext.isHardenedRuntime(),
        entitlementLookup: (String) -> Bool? = PermissionContext.hasEntitlement
    ) -> [String] {
        guard responsibleIsSelf, hardenedRuntime else { return [] }
        return statuses.compactMap { entry in
            guard entry.status == "not_determined",
                  let entitlement = entitlementByCategory[entry.name],
                  entitlementLookup(entitlement) == false else { return nil }
            return entry.name
        }
    }

    // MARK: - permissions_status

    func callPermissionsStatus() async -> ToolCallResult {
        let statuses = await currentPermissionStatuses()
        let missing = statuses.filter { !Self.isGrantedPermissionStatus($0.status) }.map(\.name)
        let blocked = Self.promptBlockedByMissingEntitlement(statuses)
        let target = PermissionContext.current.permissionTarget.name

        var payload: [String: JSONValue] = ["ok": .bool(true)]
        for entry in statuses {
            payload[entry.name] = .string(entry.status)
        }
        payload["missing"] = .array(missing.map(JSONValue.string))
        payload["prompt_blocked_by_missing_entitlement"] = .array(blocked.map(JSONValue.string))
        payload["hint"] = .string(missing.isEmpty
            ? "All monitored categories are ready to use."
            : "For each item in 'missing', call request_permissions (categories=[...]) to trigger the prompt, or open_permission_pane pane=<item> and enable '\(target)'. Grants belong to the responsible app '\(target)', not to mac-control-mcp alone — launching the server from another client changes which app needs them.")
        payload.merge(PermissionContext.contextPayload()) { current, _ in current }

        let summary = missing.isEmpty
            ? "All \(statuses.count) monitored permissions granted (responsible app: \(target))."
            : "Missing: \(missing.joined(separator: ", ")) — grant to '\(target)', the app macOS attributes mac-control-mcp's requests to."
        return successResult(summary, payload)
    }

    // MARK: - request_permissions

    enum PromptTrigger: Sendable, Equatable {
        case triggered
        case skipped(String)
    }

    func callRequestPermissions(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        await requestPermissions(arguments, folderProbe: Self.probeProtectedFolders)
    }

    /// `folderProbe` is injectable so tests can prove the call does not wait
    /// for a (blocking) folder prompt.
    func requestPermissions(
        _ arguments: [String: JSONValue],
        folderProbe: @escaping @Sendable () -> Void
    ) async -> ToolCallResult {
        let requested: [String]
        if let raw = arguments["categories"] {
            guard let items = raw.arrayValue else {
                return invalidArgument("request_permissions 'categories' must be an array of strings.")
            }
            let names = items.compactMap(\.stringValue)
            let unknown = names.filter { !Self.requestablePermissionCategories.contains($0) }
            guard names.count == items.count, unknown.isEmpty else {
                return invalidArgument("request_permissions: unknown categories \(unknown). Valid: \(Self.requestablePermissionCategories.joined(separator: ", ")).")
            }
            requested = names
        } else {
            // v0.8.2 default: accessibility + protected folders.
            requested = ["accessibility", "folders"]
        }

        var triggered: [String] = []
        var skipped: [String: JSONValue] = [:]
        for category in requested {
            switch await triggerPermissionPrompt(category, folderProbe: folderProbe) {
            case .triggered: triggered.append(category)
            case .skipped(let reason): skipped[category] = .string(reason)
            }
        }

        let statuses = await currentPermissionStatuses()
        var statusObject: [String: JSONValue] = [:]
        for entry in statuses {
            statusObject[entry.name] = .string(entry.status)
        }
        let target = PermissionContext.current.permissionTarget.name
        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "requested": .array(requested.map(JSONValue.string)),
            "triggered": .array(triggered.map(JSONValue.string)),
            "skipped": .object(skipped),
            // Kept for v0.8.2 callers that read a bool.
            "accessibility": .bool(statuses.first { $0.name == "accessibility" }?.status == "granted"),
            "status": .object(statusObject),
            "hint": .string("Prompts are shown asynchronously and this call does not wait for answers. Answer the macOS dialogs (they may open behind other windows, attributed to '\(target)'), then call permissions_status.")
        ]
        payload.merge(PermissionContext.contextPayload()) { current, _ in current }

        let summary = triggered.isEmpty
            ? "No prompt triggered (already decided or skipped)."
            : "Triggered permission prompt(s) for \(triggered.joined(separator: ", ")); answer the dialogs, then call permissions_status."
        return successResult(summary, payload)
    }

    /// Fires one category's prompt without waiting for the user's answer.
    func triggerPermissionPrompt(
        _ category: String,
        folderProbe: @escaping @Sendable () -> Void
    ) async -> PromptTrigger {
        switch category {
        case "accessibility":
            if await accessibility.checkPermission() { return .skipped("already_granted") }
            _ = await accessibility.requestPermission()
            return .triggered

        case "screen_recording":
            #if canImport(CoreGraphics)
            if CGPreflightScreenCaptureAccess() { return .skipped("already_granted") }
            DispatchQueue.global(qos: .userInitiated).async { _ = CGRequestScreenCaptureAccess() }
            return .triggered
            #else
            return .skipped("unsupported")
            #endif

        case "calendar":
            let status = Self.calendarPermissionStatusString()
            guard status == "not_determined" else { return .skipped(status) }
            #if canImport(EventKit)
            let store = EKEventStore()
            let keeper = ObjectKeeper(store)
            store.requestFullAccessToEvents { _, _ in keeper.release() }
            return .triggered
            #else
            return .skipped("unsupported")
            #endif

        case "contacts":
            let status = Self.contactsPermissionStatusString()
            guard status == "not_determined" else { return .skipped(status) }
            #if canImport(Contacts)
            let store = CNContactStore()
            let keeper = ObjectKeeper(store)
            store.requestAccess(for: .contacts) { _, _ in keeper.release() }
            return .triggered
            #else
            return .skipped("unsupported")
            #endif

        case "microphone":
            let status = Self.microphonePermissionStatusString()
            guard status == "not_determined" else { return .skipped(status) }
            #if canImport(AVFoundation)
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return .triggered
            #else
            return .skipped("unsupported")
            #endif

        case "location":
            // locationPermissionStatusStringMainActor() already returns
            // "info_plist_missing" without ever touching CLLocationManager
            // when the Info.plist key is absent (the XCTest bundle case),
            // so this guard alone keeps that path crash-free.
            let status = await Self.locationPermissionStatusStringMainActor()
            guard status == "not_determined" else { return .skipped(status) }
            #if canImport(CoreLocation)
            // Fire-and-forget: don't hold up this call on a human answering
            // a dialog. LocationAuthorizer self-retains until the delegate
            // answers or its keep-alive elapses.
            Task { @MainActor in
                _ = await LocationAuthorizer().requestAndWaitForChange(keepAlive: HardwareController.locationPromptKeepAlive)
            }
            return .triggered
            #else
            return .skipped("unsupported")
            #endif

        case "folders":
            // A first-time folder prompt blocks the probing thread until the
            // user answers; run it on its own queue so nothing waits on it.
            DispatchQueue.global(qos: .utility).async(execute: folderProbe)
            return .triggered

        default:
            return .skipped("unknown_category")
        }
    }

    static let probeProtectedFolders: @Sendable () -> Void = {
        let home = NSHomeDirectory()
        for folder in ["Desktop", "Documents", "Downloads"] {
            _ = try? FileManager.default.contentsOfDirectory(atPath: home + "/" + folder)
        }
    }
}

/// Keeps a framework object (EKEventStore, CNContactStore) alive until its
/// asynchronous permission callback fires.
final class ObjectKeeper: @unchecked Sendable {
    private let lock = NSLock()
    private var object: AnyObject?

    init(_ object: AnyObject) {
        self.object = object
    }

    func release() {
        lock.lock()
        object = nil
        lock.unlock()
    }
}
