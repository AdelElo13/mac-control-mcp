import Testing
import Foundation
@testable import MacControlMCP

/// Keeps `docs/TOOLS.md`, and the tool-count claims in README.md /
/// server.json, honest against the single source of truth: the tool
/// definitions actually registered on `ToolRegistry.toolDefinitions`
/// (the same property `tools/list` serves at runtime — see main.swift).
///
/// Docs drift silently in this repo: README.md said "63 tools" while the
/// server registered 143 (verified via a live `tools/list` call), and
/// `server.json` / `release-artifacts/manifest.json` carry the count as a
/// hand-written string with no check tying them to reality.
///
/// Regenerate after adding/removing/renaming a tool:
///
///     UPDATE_TOOL_DOCS=1 swift test --filter ToolDocsDriftTests
///
/// then re-run `swift test --filter ToolDocsDriftTests` (no env var) to
/// confirm docs/TOOLS.md is current. Release metadata changes are separate;
/// UPDATE_RELEASE_TOOL_DOCS=1 additionally updates the README markers.
// .serialized: regeneration writes docs/TOOLS.md (and README.md only with
// UPDATE_RELEASE_TOOL_DOCS=1), while other tests read them back. Swift
// Testing runs tests within a suite in parallel by default, which raced
// the README-marker check against the in-flight rewrite the first time
// this was run — serialize so reads always see a finished write.
@Suite("Tool docs drift", .serialized)
struct ToolDocsDriftTests {

    // MARK: - Repo layout

    /// Resolved the same way `StdioIntegrationTests.serverBinary()` finds
    /// the built binary: walk up from this source file's own location
    /// rather than trusting the process's current working directory
    /// (which differs between `swift test` and Xcode/CI runners).
    static func repoRoot() -> URL {
        let dir = (#filePath as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: dir).deletingLastPathComponent().deletingLastPathComponent()
    }

    static var toolsDocPath: URL { repoRoot().appendingPathComponent("docs/TOOLS.md") }
    static var readmePath: URL { repoRoot().appendingPathComponent("README.md") }
    static var serverJSONPath: URL { repoRoot().appendingPathComponent("server.json") }
    static var manifestPath: URL {
        repoRoot().appendingPathComponent("release-artifacts/manifest.json")
    }

    // MARK: - Extracting the real tool count / schema

    /// The definitions the running server actually advertises — computed
    /// the exact same way `ToolRegistry.toolDefinitions` (used by
    /// `main.swift`'s `tools/list` handler) computes them, because this
    /// call *is* `toolDefinitions`.
    static func realDefinitions() -> [MCPToolDefinition] {
        ToolRegistry(accessibility: AccessibilityController()).toolDefinitions
    }

    /// Pulls `properties`/`required` out of an `inputSchema` JSONValue.
    /// Property iteration order over `[String: JSONValue]` is not stable,
    /// so callers MUST sort the returned property names themselves —
    /// this function does not do it for you, to keep it a pure accessor.
    static func schemaFields(_ schema: JSONValue) -> (properties: [String], required: Set<String>) {
        guard case .object(let root) = schema else { return ([], []) }

        var propertyNames: [String] = []
        if case .object(let props)? = root["properties"] {
            propertyNames = Array(props.keys)
        }

        var required: Set<String> = []
        if case .array(let reqArray)? = root["required"] {
            for entry in reqArray {
                if case .string(let name) = entry { required.insert(name) }
            }
        }

        return (propertyNames, required)
    }

    // MARK: - Deterministic rendering

    /// Renders `docs/TOOLS.md` from the live tool definitions. Sorted by
    /// tool name (not registration order, which is an implementation
    /// detail of how the Tools+V2Phase*.swift files got split) so the
    /// output — and therefore the drift check — is stable regardless of
    /// where in the source a tool definition physically lives.
    static func renderToolsDoc(_ definitions: [MCPToolDefinition]) -> String {
        let sorted = definitions.sorted { $0.name < $1.name }

        var lines: [String] = []
        lines.append("# Tool Reference")
        lines.append("")
        lines.append("Auto-generated from `ToolRegistry.toolDefinitions` — the exact list the")
        lines.append("running server returns from `tools/list`. **Do not hand-edit.** Regenerate with:")
        lines.append("")
        lines.append("```bash")
        lines.append("UPDATE_TOOL_DOCS=1 swift test --filter ToolDocsDriftTests")
        lines.append("```")
        lines.append("")
        lines.append("<!-- tool-count -->\(sorted.count)<!-- /tool-count --> tools total.")
        lines.append("")
        lines.append("| Tool | Description | Required params | Optional params |")
        lines.append("|---|---|---|---|")

        for tool in sorted {
            let (propertyNames, required) = schemaFields(tool.inputSchema)
            let sortedProps = propertyNames.sorted()
            let requiredNames = sortedProps.filter { required.contains($0) }
            let optionalNames = sortedProps.filter { !required.contains($0) }

            let requiredCell = requiredNames.isEmpty ? "—" : requiredNames.map { "`\($0)`" }.joined(separator: ", ")
            let optionalCell = optionalNames.isEmpty ? "—" : optionalNames.map { "`\($0)`" }.joined(separator: ", ")

            // Collapse newlines/pipes so multi-line descriptions (several
            // tool definitions use Swift multi-line string literals) don't
            // break the Markdown table.
            let flatDescription = tool.description
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)

            lines.append("| `\(tool.name)` | \(flatDescription) | \(requiredCell) | \(optionalCell) |")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - README marker handling

    struct MarkerError: Error, CustomStringConvertible {
        let description: String
    }

    static let markerPattern = "<!-- tool-count -->(\\d+)<!-- /tool-count -->"

    /// All tool-count marker values currently in README.md (there may be
    /// more than one — the count is stated in the intro sentence and in
    /// the "Tool surface" section).
    static func readmeMarkerValues(_ readme: String) throws -> [Int] {
        let regex = try NSRegularExpression(pattern: markerPattern)
        let range = NSRange(readme.startIndex..., in: readme)
        let matches = regex.matches(in: readme, range: range)
        return matches.compactMap { match -> Int? in
            guard let r = Range(match.range(at: 1), in: readme) else { return nil }
            return Int(readme[r])
        }
    }

    /// Rewrites every `<!-- tool-count -->N<!-- /tool-count -->` marker in
    /// README.md to the real count, in place.
    static func rewriteReadmeMarkers(_ readme: String, to count: Int) throws -> String {
        let regex = try NSRegularExpression(pattern: markerPattern)
        let range = NSRange(readme.startIndex..., in: readme)
        return regex.stringByReplacingMatches(
            in: readme,
            range: range,
            withTemplate: "<!-- tool-count -->\(count)<!-- /tool-count -->"
        )
    }

    /// Regenerates docs/TOOLS.md when `UPDATE_TOOL_DOCS=1` is set.
    /// v0.10 S4 keeps README mutation behind UPDATE_RELEASE_TOOL_DOCS=1. Idempotent and cheap, so every test
    /// below calls this itself rather than relying on some *other* test
    /// in the suite to have run first (or run before it) — Swift Testing
    /// gives no ordering guarantee between `@Test` funcs in a suite, only
    /// non-overlap when `.serialized`.
    static func regenerateIfRequested() throws {
        guard ProcessInfo.processInfo.environment["UPDATE_TOOL_DOCS"] == "1" else { return }

        let definitions = Self.realDefinitions()
        let rendered = Self.renderToolsDoc(definitions)
        try rendered.write(to: Self.toolsDocPath, atomically: true, encoding: .utf8)

        // v0.10 S4: release metadata is owned by the release workstream.
        // Regenerating tool schemas must not modify README.md implicitly.
        if ProcessInfo.processInfo.environment["UPDATE_RELEASE_TOOL_DOCS"] == "1" {
            let readme = try String(contentsOf: Self.readmePath, encoding: .utf8)
            let updatedReadme = try Self.rewriteReadmeMarkers(readme, to: definitions.count)
            try updatedReadme.write(to: Self.readmePath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Tests

    @Test("docs/TOOLS.md matches the live tool registry")
    func toolsDocMatchesRegistry() throws {
        try Self.regenerateIfRequested()

        let definitions = Self.realDefinitions()
        let rendered = Self.renderToolsDoc(definitions)

        if ProcessInfo.processInfo.environment["UPDATE_TOOL_DOCS"] == "1" {
            return
        }

        guard let onDisk = try? String(contentsOf: Self.toolsDocPath, encoding: .utf8) else {
            let message: String = "docs/TOOLS.md is missing — run "
                + "`UPDATE_TOOL_DOCS=1 swift test --filter ToolDocsDriftTests` to generate it."
            Issue.record(Comment(rawValue: message))
            return
        }

        let staleMessage: String = "docs/TOOLS.md is stale — run "
            + "`UPDATE_TOOL_DOCS=1 swift test --filter ToolDocsDriftTests` to regenerate it, "
            + "then re-run this test (no env var) to confirm it's green."
        #expect(onDisk == rendered, Comment(rawValue: staleMessage))
    }

    @Test("README.md tool-count markers match the real tool count")
    func readmeToolCountMatchesRegistry() throws {
        try Self.regenerateIfRequested()

        let realCount = Self.realDefinitions().count
        let readme = try String(contentsOf: Self.readmePath, encoding: .utf8)
        let markerValues = try Self.readmeMarkerValues(readme)

        #expect(
            !markerValues.isEmpty,
            "README.md has no <!-- tool-count --> markers — add them wherever the tool count is stated."
        )

        for value in markerValues {
            let message: String = "README.md claims \(value) tools between tool-count markers, "
                + "but ToolRegistry.toolDefinitions has \(realCount). "
                + "Run `UPDATE_TOOL_DOCS=1 swift test --filter ToolDocsDriftTests` to fix."
            #expect(value == realCount, Comment(rawValue: message))
        }
    }

    @Test("server.json description states the real tool count")
    func serverJSONMatchesRegistry() throws {
        let realCount = Self.realDefinitions().count
        let json = try String(contentsOf: Self.serverJSONPath, encoding: .utf8)

        let message: String = "server.json's description does not contain \"\(realCount) tools\" — "
            + "it has drifted from ToolRegistry.toolDefinitions (currently \(realCount) tools). "
            + "Update the description string in server.json."
        #expect(json.contains("\(realCount) tools"), Comment(rawValue: message))
    }

    @Test("release-artifacts/manifest.json (if tracked in git) states the real tool count")
    func manifestJSONMatchesRegistryIfTracked() throws {
        // manifest.json is a release build artifact, normally untracked
        // and regenerated by scripts/release.sh. Only enforce this check
        // if someone has committed one to source control.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["ls-files", "release-artifacts/manifest.json"]
        process.currentDirectoryURL = Self.repoRoot()
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !output.isEmpty else {
            // Not tracked — nothing to check.
            return
        }

        let realCount = Self.realDefinitions().count
        let json = try String(contentsOf: Self.manifestPath, encoding: .utf8)
        let message: String = "release-artifacts/manifest.json is tracked in git and does not contain "
            + "\"\(realCount) tools\" — it has drifted from ToolRegistry.toolDefinitions."
        #expect(json.contains("\(realCount) tools"), Comment(rawValue: message))
    }
}
