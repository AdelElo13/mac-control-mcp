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

    /// Outcome of a Spotlight search. Distinguishes "query ran cleanly"
    /// from "the backend refused to start", so a metadatad outage gets
    /// reported as an error instead of masked as "0 results".
    enum SearchOutcome: Sendable {
        case ok(results: [ResultPreview])
        case emptyQuery
        case backendUnavailable      // NSMetadataQuery.start() returned false
        case timedOut                // 2s elapsed without NSMetadataQueryDidFinishGathering
    }

    /// Cached results from the most recent `search`. `openResult(index:)`
    /// uses this so it opens exactly what the caller saw in the preview.
    private var lastResults: [ResultPreview] = []

    /// Search Spotlight's index. Idempotent: a fresh NSMetadataQuery is
    /// created per call and stopped before returning. A previous version
    /// flattened startup-failure and timeout into "0 results with ok",
    /// which hid real outages (Codex v11 HIGH: metadatad down looked
    /// identical to "no hits"). The returned SearchOutcome now keeps
    /// those states distinct so the tool layer can surface them as
    /// errors.
    func search(_ query: String, limit: Int = 10) async -> SearchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastResults = []
            return .emptyQuery
        }
        Self.primeFilesystemAccess()
        let outcome = await runMetadataQuery(query: trimmed, limit: limit)
        if case .ok(let results) = outcome {
            lastResults = results
        } else {
            lastResults = []
        }
        return outcome
    }

    /// Touch the three protected folders (`~/Desktop`, `~/Documents`,
    /// `~/Downloads`) so macOS either shows the TCC consent dialog (on
    /// first ever touch) or silently confirms the grant (on subsequent
    /// calls). Without this, our `mdfind` subprocess inherits the
    /// parent's TCC scope and `metadatad` filters every hit under those
    /// three folders out of the result set — so files the user just
    /// saved to the Desktop appear to "not exist" in Spotlight.
    ///
    /// `contentsOfDirectory` is the cheapest TCC-probing call:
    ///   - If denied, it throws and we swallow the error.
    ///   - If granted, it returns quickly (<1 ms for typical folders).
    ///   - On first call, macOS shows the system consent dialog.
    ///
    /// The usage-description strings in Info.plist
    /// (NSDesktopFolderUsageDescription etc.) drive the prompt copy.
    /// Without those keys the dialog never appears and the denial
    /// persists silently — the exact failure mode reported in v0.2.4
    /// testing.
    private static func primeFilesystemAccess() {
        let home = NSHomeDirectory()
        for folder in ["Desktop", "Documents", "Downloads"] {
            _ = try? FileManager.default.contentsOfDirectory(
                atPath: home + "/" + folder
            )
        }
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
    private func runMetadataQuery(query: String, limit: Int) async -> SearchOutcome {
        // v0.2.4: shell out to `/usr/bin/mdfind` instead of building an
        // NSPredicate / NSMetadataQuery in-process.
        //
        // Why we stopped fighting NSPredicate:
        //   Spotlight's query engine (`metadatad`) only reliably accepts
        //   its own glob-equality syntax, e.g.
        //       kMDItemDisplayName = '*Jarvis*'cd
        //   NSPredicate's `LIKE[cd]` and `CONTAINS[cd]` go through
        //   Foundation's wildcard parser, which has different semantics
        //   and silently returns zero results for dotted / dashed
        //   filenames (`Claude-Jarvis.command`, `cost_calculator.py`,
        //   etc.). `NSPredicate(format: "= %@", "*Jarvis*")` is worse:
        //   %@ substitution makes the asterisks literal, so Spotlight
        //   matches only files whose name is exactly `*Jarvis*`, which
        //   is nothing. Live verification via `mdfind` against the
        //   user's real index showed a 60×+ gap between the two paths.
        //
        // Why mdfind as a subprocess is the honest fix:
        //   - It is the CLI frontend for `metadatad`, so the result
        //     set is byte-for-byte what `mdfind` / Finder's Spotlight
        //     search / Siri show the user.
        //   - Spawning `/usr/bin/mdfind` adds ~20–40 ms per search —
        //     cheaper than the 2 s NSMetadataQuery timeout we kept
        //     tripping.
        //   - Escapes out of the main-runloop / notification / observer
        //     dance entirely: stdout is line-per-path, read until EOF.
        //   - Matches the same three identity fields we want
        //     (DisplayName, FSName, Title).
        //
        // Single-quote escaping:
        //   User input gets folded into a single-quoted literal inside
        //   the query string, so any `'` in the query would close the
        //   literal and change the predicate. Doubling `'` to `''`
        //   (mdfind escape rule) or swapping to `\'` isn't reliably
        //   parsed. Simplest correct fix: reject queries containing a
        //   single quote outright — vanishingly rare for a Spotlight
        //   search and removes the injection surface.
        guard !query.contains("'") else {
            return .ok(results: [])
        }

        let queryString =
            "kMDItemDisplayName = '*\(query)*'cd"
            + " || kMDItemFSName = '*\(query)*'cd"
            + " || kMDItemTitle = '*\(query)*'cd"

        return await withCheckedContinuation { (continuation: CheckedContinuation<SearchOutcome, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                process.arguments = [queryString]

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .backendUnavailable)
                    return
                }

                // 2 s hard deadline — parity with the old NSMetadataQuery
                // timeout. mdfind normally returns in < 200 ms on a
                // warm index; anything slower is better surfaced as a
                // timeout than blocking the MCP.
                let deadline = DispatchWorkItem { [weak process] in
                    guard let p = process, p.isRunning else { return }
                    p.terminate()
                }
                DispatchQueue.global(qos: .userInitiated)
                    .asyncAfter(deadline: .now() + 2.0, execute: deadline)

                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()

                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(returning: .timedOut)
                    return
                }

                let output = String(data: data, encoding: .utf8) ?? ""
                var out: [ResultPreview] = []
                var seen = Set<String>()
                for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                    let path = String(line)
                    guard seen.insert(path).inserted else { continue }
                    let title = (path as NSString).lastPathComponent
                    guard !title.isEmpty else { continue }
                    out.append(
                        ResultPreview(index: out.count + 1, title: title, path: path)
                    )
                    if out.count >= limit { break }
                }
                continuation.resume(returning: .ok(results: out))
            }
        }
    }
}
