import Foundation

/// Append-only audit log for destructive tool calls.  Lives at
/// `~/.mac-control-mcp/audit.jsonl`, one JSON line per event. No
/// in-place rewrites, no rotation-in-place — rotation happens via a
/// separate archive step (write a new `.1`, truncate). Agents and
/// humans can both read it; agents can also append custom events.
///
/// Why an actor: the file lives on disk and two concurrent tool calls
/// would race against each other's writes. The actor serialises.
actor AuditLogController {
    struct Entry: Codable, Sendable {
        let ts: String            // ISO-8601
        let session: String       // short session id (first 8 chars of a boot-time UUID)
        let event: String         // e.g. "tool_call_pre", "tool_call_post", "grant", "revoke", "custom"
        let tool: String?         // tool name if applicable
        let bundleId: String?
        let tier: String?
        let result: String?       // "ok" / "error" / "blocked"
        let metadata: [String: JSONValue]?
    }

    private let logPath: URL
    private let sessionID: String
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.logPath = home
            .appendingPathComponent(".mac-control-mcp", isDirectory: true)
            .appendingPathComponent("audit.jsonl")
        // A short session id so entries from this boot are groupable
        // without recording the full UUID.
        self.sessionID = String(UUID().uuidString.prefix(8)).lowercased()
    }

    /// Append a structured entry. Never throws to callers — a disk
    /// failure here should NOT kill the tool call, just lose the audit
    /// entry. Failures are emitted to stderr so ops notices.
    func append(
        event: String,
        tool: String? = nil,
        bundleId: String? = nil,
        tier: String? = nil,
        result: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) {
        let entry = Entry(
            ts: isoFormatter.string(from: Date()),
            session: sessionID,
            event: event,
            tool: tool,
            bundleId: bundleId,
            tier: tier,
            result: result,
            metadata: metadata
        )
        do {
            try ensureParentExists()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entry)
            // Append atomically: open for writing, seek to end, write + newline.
            let handle = try FileHandle(forWritingTo: openForAppend())
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
            try handle.close()
        } catch {
            FileHandle.standardError.write(
                Data("[audit] failed to append: \(error)\n".utf8)
            )
        }
    }

    /// Read entries. Lightweight filter — full JSONL query engines belong
    /// in downstream tooling, not the MCP.
    func read(
        since: Date? = nil,
        filterTool: String? = nil,
        filterEvent: String? = nil,
        limit: Int = 500
    ) -> [Entry] {
        guard FileManager.default.fileExists(atPath: logPath.path) else { return [] }
        guard let data = try? Data(contentsOf: logPath),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [Entry] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // Read newest first by reversing so the limit clips the tail.
        for raw in lines.reversed() {
            guard let lineData = String(raw).data(using: .utf8),
                  let entry = try? decoder.decode(Entry.self, from: lineData) else {
                continue
            }
            if let since, let entryDate = isoFormatter.date(from: entry.ts), entryDate < since {
                continue
            }
            if let filterTool, entry.tool != filterTool { continue }
            if let filterEvent, entry.event != filterEvent { continue }
            out.append(entry)
            if out.count >= limit { break }
        }
        return out.reversed() // caller gets chronological order
    }

    private func ensureParentExists() throws {
        let parent = logPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
    }

    private func openForAppend() throws -> URL {
        if !FileManager.default.fileExists(atPath: logPath.path) {
            FileManager.default.createFile(atPath: logPath.path, contents: nil)
        }
        return logPath
    }
}
