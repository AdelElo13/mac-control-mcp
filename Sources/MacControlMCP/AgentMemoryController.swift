import Foundation

/// Memory-as-tool surface, A-Mem pattern (Zhong et al. 2025).
///
/// v0.6.0 ships a simple substring + tag match recall. v0.7.0 will add
/// embedding-based semantic recall. The actor-isolated JSONL store at
/// `~/.mac-control-mcp/memory.jsonl` is append-only; updates rewrite
/// the whole file on a separate actor hop so concurrent tool calls
/// can't race each other.
actor AgentMemoryController {

    struct Entry: Codable, Sendable {
        let ts: String
        let session: String
        let key: String
        let value: String
        let tags: [String]
    }

    struct StoreResult: Codable, Sendable {
        let ok: Bool
        let key: String
        let stored: Bool
        let reason: String?
    }

    struct RecallResult: Codable, Sendable {
        let ok: Bool
        let query: String
        let count: Int
        let entries: [Entry]
    }

    private let storePath: URL
    private let sessionID: String
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // In-memory cache populated on first access. Everything flows through
    // this array; disk is the sink-of-truth but we don't re-read on every
    // call (that would cost 10s of ms on large stores).
    private var entries: [Entry] = []
    private var loaded = false

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.storePath = home
            .appendingPathComponent(".mac-control-mcp", isDirectory: true)
            .appendingPathComponent("memory.jsonl")
        self.sessionID = String(UUID().uuidString.prefix(8)).lowercased()
    }

    /// Store an entry. `key` is for human reference; uniqueness is NOT
    /// enforced — later entries with the same key coexist. Recall returns
    /// them in reverse-chronological order so the freshest wins naturally.
    func store(key: String, value: String, tags: [String] = []) -> StoreResult {
        loadIfNeeded()
        let entry = Entry(
            ts: isoFormatter.string(from: Date()),
            session: sessionID,
            key: key,
            value: value,
            tags: tags
        )
        entries.append(entry)
        do {
            try ensureParent()
            let encoder = JSONEncoder()
            let data = try encoder.encode(entry)
            let handle = try FileHandle(forWritingTo: openForAppend())
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
            try handle.close()
            return StoreResult(ok: true, key: key, stored: true, reason: nil)
        } catch {
            return StoreResult(ok: false, key: key, stored: false,
                               reason: "\(error)")
        }
    }

    /// Recall entries by substring match against key + value + tags.
    /// `limit` caps the result size. `tag` narrows to entries that have
    /// a specific tag (exact match).
    func recall(query: String, tag: String? = nil, limit: Int = 20) -> RecallResult {
        loadIfNeeded()
        let q = query.lowercased()
        let cap = max(1, min(limit, 200))
        let matches = entries.reversed().filter { entry in
            if let tag, !entry.tags.contains(tag) { return false }
            if q.isEmpty { return true }
            return entry.key.lowercased().contains(q)
                || entry.value.lowercased().contains(q)
                || entry.tags.contains(where: { $0.lowercased().contains(q) })
        }.prefix(cap)
        return RecallResult(
            ok: true,
            query: query,
            count: matches.count,
            entries: Array(matches)
        )
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: storePath.path) else { return }
        guard let data = try? Data(contentsOf: storePath),
              let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(Entry.self, from: lineData) else { continue }
            entries.append(entry)
        }
    }

    private func ensureParent() throws {
        try FileManager.default.createDirectory(
            at: storePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func openForAppend() throws -> URL {
        if !FileManager.default.fileExists(atPath: storePath.path) {
            FileManager.default.createFile(atPath: storePath.path, contents: nil)
        }
        return storePath
    }
}
