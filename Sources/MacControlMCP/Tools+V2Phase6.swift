import Foundation
import ApplicationServices
import AppKit

// MARK: - Tool definitions (v0.3.0 Phase 6: control plane + event waits)
//
// v0.3.0 introduces the "control plane" Codex flagged as the biggest gap in
// v0.2.6's SOTA audit: per-app tiered permissions with TTL, plus event-driven
// waits that replace polling. Both are scoped additively — no existing tool
// signature changes, and enforcement of the permission check is opt-in via
// `MAC_CONTROL_MCP_ENFORCE_TIERS=1`. That gates the rollout so existing
// Claude Desktop installs don't break on upgrade; v0.4.0 will flip the
// default once grants are seeded through `/setup`.

extension ToolRegistry {
    static let definitionsV2Phase6: [MCPToolDefinition] = [
        // MARK: Permission control plane

        MCPToolDefinition(
            name: "request_access",
            description: """
                Grant a per-app permission tier (view | click | full) to the given bundle id \
                for a bounded TTL. Writes to ~/.mac-control-mcp/permissions.json.
                """,
            inputSchema: schema(
                properties: [
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("Target app bundle id, e.g. 'com.apple.finder'.")
                    ]),
                    "tier": .object([
                        "type": .string("string"),
                        "description": .string("One of: view, click, full.")
                    ]),
                    "ttl_seconds": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Seconds until grant expires. Default 86400 (24h). Max 30 days.")
                    ]),
                    "reason": .object([
                        "type": .string("string"),
                        "description": .string("Optional human-readable note recorded alongside the grant.")
                    ])
                ],
                required: ["bundle_id", "tier"]
            )
        ),
        MCPToolDefinition(
            name: "list_granted_applications",
            description: """
                List every live permission grant (expired grants are filtered out). \
                Includes denied entries so callers can see the deny list too.
                """,
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "revoke_access",
            description: "Remove a grant (or deny entry) for bundle_id. Idempotent — missing entries are a no-op.",
            inputSchema: schema(
                properties: [
                    "bundle_id": .object(["type": .string("string")])
                ],
                required: ["bundle_id"]
            )
        ),
        MCPToolDefinition(
            name: "deny_access",
            description: """
                Add bundle_id to the deny list. Overrides any existing grant; \
                the check endpoint returns reason='denied' for this bundle. \
                Deny entries self-heal after 30 days.
                """,
            inputSchema: schema(
                properties: [
                    "bundle_id": .object(["type": .string("string")]),
                    "reason": .object(["type": .string("string")])
                ],
                required: ["bundle_id"]
            )
        ),

        // MARK: Event-driven waits (replace polling)

        MCPToolDefinition(
            name: "wait_for_ax_notification",
            description: """
                Block until an AX notification fires on the app root (or a cached element_id), \
                or timeout. Uses AXObserver so reaction latency is ~1 frame instead of the \
                250ms poll interval used by wait_for_window / wait_for_app.
                """,
            inputSchema: schema(
                properties: [
                    "pid": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Target pid. Required unless element_id is given.")
                    ]),
                    "element_id": .object([
                        "type": .string("string"),
                        "description": .string("Cached element id to observe instead of the app root.")
                    ]),
                    "notification": .object([
                        "type": .string("string"),
                        "description": .string("AX notification name, e.g. 'AXWindowCreated', 'AXValueChanged'. See supportedNotifications.")
                    ]),
                    "timeout_seconds": .object([
                        "type": .string("number"),
                        "description": .string("Deadline in seconds. Clamped 0.1..60. Default 5.")
                    ])
                ],
                required: ["notification"]
            )
        ),
        MCPToolDefinition(
            name: "wait_for_window_state_change",
            description: """
                Block until a window-related AX notification fires for the app \
                (AXWindowCreated, AXWindowMoved, AXWindowResized, AXFocusedWindowChanged).
                """,
            inputSchema: schema(
                properties: [
                    "pid": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Target pid.")
                    ]),
                    "change": .object([
                        "type": .string("string"),
                        "description": .string("One of: created, moved, resized, focused. Default 'created'.")
                    ]),
                    "timeout_seconds": .object([
                        "type": .string("number"),
                        "description": .string("Deadline in seconds. Clamped 0.1..60. Default 5.")
                    ])
                ],
                required: ["pid"]
            )
        )
    ]

    // MARK: - Tool handlers

    /// Lookup current tier for a bundle id. Convenience wrapper used by the
    /// opt-in enforcement path (see `enforceIfEnabled`).
    private static var enforceTiers: Bool {
        let raw = ProcessInfo.processInfo.environment["MAC_CONTROL_MCP_ENFORCE_TIERS"] ?? ""
        return ["1", "true", "yes", "on"].contains(raw.lowercased())
    }

    /// Public to the rest of the module — other phase files call this at
    /// the top of any sensitive tool once v0.4.0 flips the default. The
    /// helper short-circuits when enforcement is disabled, so adding the
    /// call in v0.3.0 is a no-op for today's callers.
    func enforceIfEnabled(
        bundleId: String?,
        required: PermissionTier
    ) async -> ToolCallResult? {
        guard Self.enforceTiers else { return nil }
        guard let bundleId, !bundleId.isEmpty else {
            return errorResult(
                "Cannot enforce tier — caller did not provide a bundle id.",
                [
                    "ok": .bool(false),
                    "reason": .string("no_bundle_id"),
                    "required": .string(required.rawValue)
                ]
            )
        }
        let result = await PermissionStore.shared.check(bundleId: bundleId, required: required)
        if result.allowed { return nil }
        return errorResult(
            "permission_denied: \(result.reason)",
            [
                "ok": .bool(false),
                "reason": .string(result.reason),
                "required": .string(result.required.rawValue),
                "granted": .string(result.granted.rawValue),
                "hint": .string(result.hint)
            ]
        )
    }

    func callRequestAccess(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let bundleId = arguments["bundle_id"]?.stringValue, !bundleId.isEmpty else {
            return invalidArgument("request_access requires bundle_id.")
        }
        guard
            let tierRaw = arguments["tier"]?.stringValue?.lowercased(),
            let tier = PermissionTier(rawValue: tierRaw),
            tier != .denied
        else {
            return invalidArgument("request_access requires tier = view | click | full.")
        }

        // Clamp TTL to [60 seconds, 30 days]. Agents that forget to set a
        // short TTL shouldn't accidentally hand out a year-long grant;
        // agents that pass 0 shouldn't leak a zero-TTL grant that never
        // matches.
        let requestedTTL = arguments["ttl_seconds"]?.doubleValue
            ?? PermissionStore.defaultTTLSeconds
        let ttl = max(60.0, min(requestedTTL, 30 * 24 * 60 * 60))
        let reason = arguments["reason"]?.stringValue

        guard let grant = await PermissionStore.shared.grant(
            bundleId: bundleId,
            tier: tier,
            ttlSeconds: ttl,
            reason: reason
        ) else {
            // The only failure mode is an existing deny-list entry.
            return errorResult(
                "Cannot grant — bundle is on the deny list. Call revoke_access first.",
                [
                    "ok": .bool(false),
                    "bundle_id": .string(bundleId),
                    "reason": .string("denied")
                ]
            )
        }

        return successResult(
            "Granted \(tier.rawValue) to \(bundleId) for \(Int(ttl))s.",
            [
                "ok": .bool(true),
                "bundle_id": .string(grant.bundleId),
                "tier": .string(grant.tier.rawValue),
                "expires_at": .string(ISO8601DateFormatter().string(from: grant.expiresAt)),
                "reason": grant.reason.map(JSONValue.string) ?? .null
            ]
        )
    }

    func callListGrantedApplications() async -> ToolCallResult {
        let grants = await PermissionStore.shared.list()
        let isoFormatter = ISO8601DateFormatter()
        let items: [JSONValue] = grants.map { g in
            .object([
                "bundle_id": .string(g.bundleId),
                "tier": .string(g.tier.rawValue),
                "expires_at": .string(isoFormatter.string(from: g.expiresAt)),
                "reason": g.reason.map(JSONValue.string) ?? .null
            ])
        }
        return successResult(
            "Found \(grants.count) live grant(s).",
            [
                "ok": .bool(true),
                "count": .number(Double(grants.count)),
                "grants": .array(items),
                "enforcement": .bool(Self.enforceTiers)
            ]
        )
    }

    func callRevokeAccess(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let bundleId = arguments["bundle_id"]?.stringValue, !bundleId.isEmpty else {
            return invalidArgument("revoke_access requires bundle_id.")
        }
        await PermissionStore.shared.revoke(bundleId: bundleId)
        return successResult(
            "Revoked \(bundleId).",
            [
                "ok": .bool(true),
                "bundle_id": .string(bundleId)
            ]
        )
    }

    func callDenyAccess(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let bundleId = arguments["bundle_id"]?.stringValue, !bundleId.isEmpty else {
            return invalidArgument("deny_access requires bundle_id.")
        }
        let reason = arguments["reason"]?.stringValue
        await PermissionStore.shared.deny(bundleId: bundleId, reason: reason)
        return successResult(
            "Denied \(bundleId).",
            [
                "ok": .bool(true),
                "bundle_id": .string(bundleId),
                "reason": reason.map(JSONValue.string) ?? .null
            ]
        )
    }

    // MARK: - Event waits

    func callWaitForAXNotification(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let notification = arguments["notification"]?.stringValue, !notification.isEmpty else {
            return invalidArgument("wait_for_ax_notification requires notification.")
        }
        guard AXObserverBridge.supportedNotifications.contains(notification) else {
            let supported = AXObserverBridge.supportedNotifications
                .sorted()
                .joined(separator: ", ")
            return invalidArgument(
                "Unsupported notification '\(notification)'. Supported: \(supported)."
            )
        }
        let timeout = min(max(arguments["timeout_seconds"]?.doubleValue ?? 5.0, 0.1), 60.0)

        // Resolve the target AXUIElement: cached element id wins if present,
        // otherwise the app root for pid.
        var pid: pid_t = 0
        var element: AXUIElement
        if let elementId = arguments["element_id"]?.stringValue, !elementId.isEmpty {
            guard let resolved = await elementCache.resolve(elementId) else {
                return errorResult(
                    "element_id '\(elementId)' not found or expired.",
                    ["ok": .bool(false), "reason": .string("element_not_found")]
                )
            }
            element = resolved
            pid = await elementCache.pid(for: elementId) ?? 0
        } else {
            guard let parsedPid = parsePID(arguments["pid"]) else {
                return invalidArgument("wait_for_ax_notification requires pid or element_id.")
            }
            pid = parsedPid
            element = AXUIElementCreateApplication(pid)
        }

        let result = await AXObserverBridge.shared.waitForNotification(
            pid: pid,
            element: element,
            notification: notification,
            timeout: timeout
        )

        switch result.status {
        case .fired:
            return successResult(
                "Notification fired: \(notification).",
                [
                    "ok": .bool(true),
                    "status": .string(result.status.rawValue),
                    "notification": .string(notification),
                    "elapsed_seconds": .number(result.elapsed)
                ]
            )
        case .timedOut:
            return errorResult(
                "Timed out after \(timeout)s waiting for \(notification).",
                [
                    "ok": .bool(false),
                    "status": .string(result.status.rawValue),
                    "notification": .string(notification),
                    "elapsed_seconds": .number(result.elapsed)
                ]
            )
        case .setupFailed:
            return errorResult(
                "AXObserver setup failed (AXError=\(result.axError ?? -1)).",
                [
                    "ok": .bool(false),
                    "status": .string(result.status.rawValue),
                    "ax_error": .number(Double(result.axError ?? -1)),
                    "hint": .string("check AX permissions for this process")
                ]
            )
        case .unsupported:
            // Already filtered above; defensive branch.
            return errorResult(
                "Unsupported notification.",
                ["ok": .bool(false), "status": .string(result.status.rawValue)]
            )
        }
    }

    func callWaitForWindowStateChange(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("wait_for_window_state_change requires a positive integer pid.")
        }
        let change = arguments["change"]?.stringValue?.lowercased() ?? "created"
        let notification: String
        switch change {
        case "created":
            notification = "AXWindowCreated"
        case "moved":
            notification = "AXWindowMoved"
        case "resized":
            notification = "AXWindowResized"
        case "focused":
            notification = "AXFocusedWindowChanged"
        default:
            return invalidArgument("change must be one of: created, moved, resized, focused.")
        }
        let timeout = min(max(arguments["timeout_seconds"]?.doubleValue ?? 5.0, 0.1), 60.0)

        let root = AXUIElementCreateApplication(pid)
        let result = await AXObserverBridge.shared.waitForNotification(
            pid: pid,
            element: root,
            notification: notification,
            timeout: timeout
        )
        switch result.status {
        case .fired:
            return successResult(
                "Window state change fired: \(change).",
                [
                    "ok": .bool(true),
                    "status": .string(result.status.rawValue),
                    "change": .string(change),
                    "notification": .string(notification),
                    "elapsed_seconds": .number(result.elapsed)
                ]
            )
        case .timedOut:
            return errorResult(
                "Timed out after \(timeout)s waiting for window \(change).",
                [
                    "ok": .bool(false),
                    "status": .string(result.status.rawValue),
                    "change": .string(change),
                    "elapsed_seconds": .number(result.elapsed)
                ]
            )
        case .setupFailed:
            return errorResult(
                "AXObserver setup failed (AXError=\(result.axError ?? -1)).",
                [
                    "ok": .bool(false),
                    "status": .string(result.status.rawValue),
                    "ax_error": .number(Double(result.axError ?? -1))
                ]
            )
        case .unsupported:
            return errorResult(
                "Unsupported notification.",
                ["ok": .bool(false), "status": .string(result.status.rawValue)]
            )
        }
    }
}
