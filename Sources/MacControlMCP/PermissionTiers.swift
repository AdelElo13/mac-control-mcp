import Foundation

/// Per-app, time-bounded permission model inspired by Anthropic's computer-use
/// tiered access. An agent may be granted *view* (read-only AX queries +
/// screen capture), *click* (view + mouse/keyboard events), or *full* (click
/// + menus, file dialogs, system settings). Sessions expire after a TTL so
/// a forgotten grant doesn't permanently widen the attack surface.
///
/// This is the v0.3.0 "control plane" step: before every privileged tool
/// call the server asks `PermissionStore.check(bundleId:required:)`. Failing
/// that check returns a structured `{ok:false, reason:"permission_denied",
/// required: <tier>, granted: <tier>, hint: "call request_access"}` response
/// instead of silently performing the action.
///
/// The store is persisted to `~/.mac-control-mcp/permissions.json` so
/// grants survive server restarts within their TTL — agents don't have to
/// re-authorise on every launch — but a stale `permissions.json` from a
/// previous install still expires on its own clock.
public enum PermissionTier: String, Codable, Sendable, Comparable {
    /// Deny-list entry. Never grant anything for this bundle id.
    case denied = "denied"
    /// No grant. Every privileged call fails with permission_denied.
    case none = "none"
    /// Read-only: AX tree walks, focused_app, list_windows, capture_*, clipboard_read.
    case view = "view"
    /// view + click/type/scroll/drag.
    case click = "click"
    /// click + menus, file dialogs, set_element_attribute, set_volume, set_dark_mode.
    case full = "full"

    /// Ordered from least to most privileged. `denied` is a special case —
    /// it compares lower than `none` so any comparison against it fails.
    private var rank: Int {
        switch self {
        case .denied: return -1
        case .none: return 0
        case .view: return 1
        case .click: return 2
        case .full: return 3
        }
    }

    public static func < (lhs: PermissionTier, rhs: PermissionTier) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct PermissionGrant: Codable, Sendable {
    public let bundleId: String
    public let tier: PermissionTier
    /// ISO-8601 UTC. The store enforces expiry on every read.
    public let expiresAt: Date
    /// Optional human-readable note ("granted via /setup 2026-04-21").
    public let reason: String?

    public func isExpired(now: Date = Date()) -> Bool {
        expiresAt <= now
    }
}

/// Actor-isolated singleton store. Serialises disk I/O so two concurrent
/// tool calls never race against each other's JSON writes.
public actor PermissionStore {
    public static let shared = PermissionStore()

    private var grants: [String: PermissionGrant] = [:]
    private let storePath: URL
    private var loaded = false

    /// Default TTL when a caller doesn't specify one. 24h balances
    /// "agent doesn't re-prompt on every launch" against "grant doesn't
    /// outlive the session it was created for". Overridable via the
    /// `MAC_CONTROL_MCP_DEFAULT_TTL_SECONDS` env var.
    public static let defaultTTLSeconds: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["MAC_CONTROL_MCP_DEFAULT_TTL_SECONDS"],
           let n = TimeInterval(raw), n > 0 {
            return n
        }
        return 24 * 60 * 60
    }()

    private init() {
        // ~/.mac-control-mcp/permissions.json — user-scoped, never shared.
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.storePath = home
            .appendingPathComponent(".mac-control-mcp", isDirectory: true)
            .appendingPathComponent("permissions.json")
    }

    // MARK: - Lifecycle

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        do {
            let data = try Data(contentsOf: storePath)
            let records = try JSONDecoder().decode([PermissionGrant].self, from: data)
            for g in records where !g.isExpired() {
                grants[g.bundleId] = g
            }
        } catch {
            // Missing file or corrupt — start empty, don't block server.
            grants = [:]
        }
    }

    private func persist() {
        let dir = storePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let active = grants.values.filter { !$0.isExpired() }
        if let data = try? JSONEncoder().encode(Array(active)) {
            try? data.write(to: storePath, options: [.atomic])
        }
    }

    // MARK: - Public API

    /// Register or refresh a grant. Existing deny entries cannot be
    /// overwritten with a positive grant in one call — caller must `revoke`
    /// first, so a permission-escalation slip-up is harder.
    public func grant(
        bundleId: String,
        tier: PermissionTier,
        ttlSeconds: TimeInterval = defaultTTLSeconds,
        reason: String? = nil
    ) -> PermissionGrant? {
        loadIfNeeded()
        if let existing = grants[bundleId], existing.tier == .denied {
            return nil
        }
        let grant = PermissionGrant(
            bundleId: bundleId,
            tier: tier,
            expiresAt: Date().addingTimeInterval(ttlSeconds),
            reason: reason
        )
        grants[bundleId] = grant
        persist()
        return grant
    }

    /// Add (or refresh) a deny-list entry. Takes precedence over any grant.
    public func deny(bundleId: String, reason: String? = nil) {
        loadIfNeeded()
        grants[bundleId] = PermissionGrant(
            bundleId: bundleId,
            tier: .denied,
            // "denied" grants expire too — otherwise a one-time deny
            // would permanently block the app across years, which is
            // usually not what the user wants. 30 days is long enough
            // to be useful, short enough to self-heal.
            expiresAt: Date().addingTimeInterval(30 * 24 * 60 * 60),
            reason: reason
        )
        persist()
    }

    public func revoke(bundleId: String) {
        loadIfNeeded()
        grants.removeValue(forKey: bundleId)
        persist()
    }

    public func list() -> [PermissionGrant] {
        loadIfNeeded()
        // Expire on read — keeps `list` honest without requiring a
        // background sweeper.
        let now = Date()
        var live: [PermissionGrant] = []
        var dirty = false
        for (key, grant) in grants {
            if grant.isExpired(now: now) {
                grants.removeValue(forKey: key)
                dirty = true
            } else {
                live.append(grant)
            }
        }
        if dirty { persist() }
        return live.sorted { $0.bundleId < $1.bundleId }
    }

    public struct CheckResult: Sendable {
        public let allowed: Bool
        /// What the caller asked for.
        public let required: PermissionTier
        /// What the store currently has. `.none` when no grant exists.
        public let granted: PermissionTier
        /// Short machine-readable reason code.
        public let reason: String
        /// Human-oriented hint for the caller.
        public let hint: String
    }

    /// Central gate. Returns an allowed=true result when the installed grant
    /// is at least `required`. Returns allowed=false otherwise, with a
    /// stable reason code callers can switch on:
    ///   - "denied"            — bundle on deny-list
    ///   - "no_grant"          — no record for this bundle
    ///   - "insufficient_tier" — grant exists but below required
    ///   - "expired"           — had a grant, ttl elapsed (and we cleaned up)
    public func check(bundleId: String, required: PermissionTier) -> CheckResult {
        loadIfNeeded()
        guard let grant = grants[bundleId] else {
            return CheckResult(
                allowed: false,
                required: required,
                granted: .none,
                reason: "no_grant",
                hint: "call request_access bundle_id=\"\(bundleId)\" tier=\"\(required.rawValue)\" to authorise this app"
            )
        }
        if grant.isExpired() {
            grants.removeValue(forKey: bundleId)
            persist()
            return CheckResult(
                allowed: false,
                required: required,
                granted: .none,
                reason: "expired",
                hint: "grant expired — re-authorise with request_access"
            )
        }
        if grant.tier == .denied {
            return CheckResult(
                allowed: false,
                required: required,
                granted: .denied,
                reason: "denied",
                hint: "app is on the deny list — call revoke_access first if this is intentional"
            )
        }
        if grant.tier < required {
            return CheckResult(
                allowed: false,
                required: required,
                granted: grant.tier,
                reason: "insufficient_tier",
                hint: "current grant is \(grant.tier.rawValue); escalate to \(required.rawValue) via request_access"
            )
        }
        return CheckResult(
            allowed: true,
            required: required,
            granted: grant.tier,
            reason: "ok",
            hint: ""
        )
    }

    /// Test hook — allow the suite to reset state between tests without
    /// touching the real on-disk store path.
    public func _resetForTesting() {
        grants = [:]
        loaded = true
    }
}
