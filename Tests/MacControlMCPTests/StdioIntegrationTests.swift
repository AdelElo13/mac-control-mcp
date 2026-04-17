import Testing
import Foundation
@testable import MacControlMCP

/// End-to-end stdio integration tests.
///
/// Regression guard for a bug discovered during Logic Pro functional
/// testing: `FileHandle.readData(ofLength: 4096)` blocked the server Task
/// until either 4096 bytes arrived OR stdin closed, which froze interactive
/// MCP clients that send small (~100 byte) JSON-RPC frames and expect a
/// reply before the next request. The fix switched to `availableData` plus
/// raw write(2)/fflush for the response path. These tests spawn the built
/// binary and drive it over a real pipe without closing stdin, so any
/// regression in the read or write path will be caught.
@Suite("Stdio integration — interactive MCP driver", .serialized)
struct StdioIntegrationTests {
    static func serverBinary() -> String {
        let dir = (#filePath as NSString).deletingLastPathComponent
        let root = URL(fileURLWithPath: dir).deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent(".build/debug/mac-control-mcp").path
    }

    static func frame(_ message: String) -> Data {
        let body = Data(message.utf8)
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }

    /// Counts occurrences of `needle` in `data` interpreted as UTF-8.
    static func countOccurrences(of needle: String, in data: Data) -> Int {
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }

    /// Sends `requests` to the server one at a time without closing stdin.
    /// Returns the concatenated stdout bytes once we've seen a response
    /// framed for every request (or timed out).
    static func driveInteractive(requests: [String], perCallTimeout: TimeInterval = 3) -> Data? {
        let binary = serverBinary()
        guard FileManager.default.fileExists(atPath: binary) else {
            Issue.record("Server binary missing at \(binary) — run swift build first")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do { try process.run() } catch {
            Issue.record("Failed to launch server: \(error)")
            return nil
        }

        var collected = Data()
        for (i, request) in requests.enumerated() {
            stdinPipe.fileHandleForWriting.write(frame(request))
            let deadline = Date().addingTimeInterval(perCallTimeout)
            while Date() < deadline {
                let chunk = stdoutPipe.fileHandleForReading.availableData
                if !chunk.isEmpty { collected.append(chunk) }
                // Stop once we have at least as many framed responses as
                // requests issued so far. Keeps the read loop tight without
                // breaking early on partial chunks.
                if countOccurrences(of: "Content-Length:", in: collected) > i { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return collected
    }

    @Test("server responds to a single request without stdin close")
    func singleRequestInteractive() throws {
        let init_ = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        guard let output = Self.driveInteractive(requests: [init_]) else { return }
        let text = String(data: output, encoding: .utf8) ?? ""
        #expect(text.contains("Content-Length:"))
        #expect(text.contains("\"id\":1"))
        #expect(text.contains("mac-control-mcp"))
    }

    @Test("server responds to a chain of three requests while stdin stays open")
    func chainedRequestsInteractive() throws {
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"permissions_status","arguments":{}}}"#
        ]
        guard let output = Self.driveInteractive(requests: requests) else { return }
        let text = String(data: output, encoding: .utf8) ?? ""
        #expect(text.contains("\"id\":1"))
        #expect(text.contains("\"id\":2"))
        #expect(text.contains("\"id\":3"))
        #expect(text.contains("accessibility"))
    }
}
