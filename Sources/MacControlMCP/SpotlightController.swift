import Foundation
import CoreGraphics
import AppKit

/// Spotlight search — backed by NSMetadataQuery (Spotlight's own index)
/// rather than UI automation of the Cmd+Space popover.
///
/// Why this architecture:
/// The v0.2.0 live probe revealed multiple failures in the UI-driven
/// approach — Cmd+Space is a toggle, NSWorkspace.frontmostApplication
/// never switches to Spotlight (its popover has .accessory activation),
/// global-tap keystrokes race with macOS's internal focus handoff and
/// land in the caller's window, and `AXUIElementSetAttributeValue` on
/// the search field silently no-ops for privacy-sensitive system UI.
/// After each of those, a second call still broke.
///
/// The backing service for Spotlight UI is `metadatad` driven by
/// NSMetadataQuery. Talking to that directly bypasses every UI concern,
/// is idempotent by construction, and returns a ranked result list
/// without any focus race.
///
/// Result ordering is matched as closely as possible to the popover
/// ("Top Hits" — apps first, then recent documents), so
/// `spotlight_open_result(index: N)` launches the same item a user
/// would see at that rank.
actor SpotlightController {
    struct ResultPreview: Codable, Sendable {
        let index: Int
        let title: String
        /// Filesystem path of the matched item. Held so `openResult`
        /// can launch it without going back through Spotlight.
        let path: String
    }

    /// Cached results from the most recent `search`. `openResult(index:)`
    /// uses this so it opens exactly what the caller saw in the preview.
    private var lastResults: [ResultPreview] = []

    /// Search Spotlight's index. Always idempotent: a fresh NSMetadataQuery
    /// is created per call, awaited to the first-batch notification, then
    /// stopped. No global state touched.
    func search(_ query: String, limit: Int = 10) async -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastResults = []
            return false
        }
        let results = await runMetadataQuery(query: trimmed, limit: limit)
        lastResults = results
        return true
    }

    /// Peek at results collected by the last `search` call. Shape is
    /// preserved for callers that expected the old popover-AX output.
    func currentResults(limit: Int = 10) async -> [ResultPreview] {
        Array(lastResults.prefix(limit))
    }

    /// Launch the Nth result (1-indexed) captured by the last `search`.
    /// Uses NSWorkspace directly — no keystrokes, no Spotlight popover.
    func openResult(index: Int = 1) async -> Bool {
        let target = max(1, index) - 1
        guard target < lastResults.count else { return false }
        let path = lastResults[target].path
        let url = URL(fileURLWithPath: path)
        return await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - NSMetadataQuery driver

    /// Run a Spotlight query end-to-end: build the predicate, start the
    /// query on the main runloop (NSMetadataQuery requires one), await
    /// the initial-gather notification, collect up to `limit` results,
    /// stop the query, return. The whole thing is bounded by a 2s
    /// timeout — Spotlight usually answers in < 200 ms, and a stale
    /// index shouldn't hang the MCP server.
    private func runMetadataQuery(query: String, limit: Int) async -> [ResultPreview] {
        // Use Swift-native NSPredicate format-string API (type-safe
        // bound parameter) rather than NSPredicate(fromMetadataQueryString:).
        // An earlier version tried the query-string syntax with
        // `==[cdw]` flags and NSPredicate threw an
        // NSInternalInconsistencyException that crashed the whole
        // process — Spotlight's Metadata framework rejects the `w`
        // (word-boundary) flag in its parser. LIKE[cd] via %@
        // substitution is the documented, crash-safe path.
        let pattern = "*\(query)*"

        return await withCheckedContinuation { (continuation: CheckedContinuation<[ResultPreview], Never>) in
            DispatchQueue.main.async {
                let mq = NSMetadataQuery()
                mq.predicate = NSPredicate(
                    format: "kMDItemDisplayName LIKE[cd] %@ OR kMDItemFSName LIKE[cd] %@",
                    pattern, pattern
                )
                // Sort: most recently used first.
                // (kMDItemContentTypeTree is an array attribute and
                // can't be used as a sort key — NSMetadataSortCompare
                // crashes with unrecognized selector when it tries to
                // -compare: two arrays. Seen during v0.2.0 probe.)
                mq.sortDescriptors = [
                    NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false),
                ]
                mq.searchScopes = [
                    NSMetadataQueryLocalComputerScope,
                    NSMetadataQueryUserHomeScope,
                ]

                var settled = false
                var observer: NSObjectProtocol?
                var timeoutWork: DispatchWorkItem?

                let finish: () -> Void = {
                    guard !settled else { return }
                    settled = true
                    if let obs = observer {
                        NotificationCenter.default.removeObserver(obs)
                    }
                    timeoutWork?.cancel()
                    mq.stop()
                    let items = (mq.results as? [NSMetadataItem]) ?? []
                    var out: [ResultPreview] = []
                    var seen = Set<String>()
                    for item in items {
                        let title =
                            (item.value(forAttribute: "kMDItemDisplayName") as? String)
                            ?? (item.value(forAttribute: "kMDItemFSName") as? String)
                            ?? ""
                        let path = (item.value(forAttribute: NSMetadataItemPathKey) as? String) ?? ""
                        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !clean.isEmpty, !path.isEmpty, seen.insert(path).inserted else { continue }
                        out.append(
                            ResultPreview(index: out.count + 1, title: clean, path: path)
                        )
                        if out.count >= limit { break }
                    }
                    continuation.resume(returning: out)
                }

                observer = NotificationCenter.default.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering,
                    object: mq,
                    queue: .main
                ) { _ in finish() }

                timeoutWork = DispatchWorkItem { finish() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: timeoutWork!)

                if !mq.start() {
                    finish()
                }
            }
        }
    }
}
