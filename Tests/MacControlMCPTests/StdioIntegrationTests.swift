import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import MacControlMCP

/// End-to-end stdio integration tests.
///
/// Regression guard for the interactive I/O bug discovered during Logic
/// Pro functional testing: `FileHandle.readData(ofLength: 4096)` blocked
/// the server Task until 4096 bytes arrived or stdin closed, which froze
/// any MCP client that sends small frames and expects a reply before the
/// next request. The fix switched to `availableData` + raw write(2) with
/// EINTR handling.
///
/// Reading side design note: we explicitly use `fcntl(O_NONBLOCK)` on the
/// stdout pipe fd + `Darwin.read` rather than `FileHandle.availableData`,
/// because availableData itself blocks when no data is buffered — which
/// would let a regressed server hang the test runner forever instead of
/// failing with a clean timeout.
@Suite("Stdio integration — interactive MCP driver", .serialized, .timeLimit(.minutes(1)))
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

    static func countOccurrences(of needle: String, in data: Data) -> Int {
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }

    /// Flip fd to non-blocking so reads return -1/EAGAIN instead of blocking.
    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Drain up to `max` bytes from a non-blocking fd without waiting.
    static func drainNonBlocking(_ fd: Int32, max: Int = 65536) -> Data {
        var buf = [UInt8](repeating: 0, count: max)
        let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
            Darwin.read(fd, bp.baseAddress, bp.count)
        }
        guard n > 0 else { return Data() }
        return Data(buf.prefix(n))
    }

    /// Drives the server over real pipes without closing stdin. Stdout and
    /// stderr are set non-blocking; the loop bounded by `perCallTimeout` so
    /// a regressed server fails cleanly instead of hanging.
    static func driveInteractive(
        requests: [String],
        perCallTimeout: TimeInterval = 3,
        writeMode: WriteMode = .separateFrames
    ) -> (stdout: Data, stderr: Data)? {
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

        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor
        setNonBlocking(outFD)
        setNonBlocking(errFD)

        var stdoutBuf = Data()
        var stderrBuf = Data()

        func drainAll() {
            stdoutBuf.append(drainNonBlocking(outFD))
            stderrBuf.append(drainNonBlocking(errFD))
        }

        switch writeMode {
        case .separateFrames:
            for (i, request) in requests.enumerated() {
                stdinPipe.fileHandleForWriting.write(frame(request))
                let deadline = Date().addingTimeInterval(perCallTimeout)
                while Date() < deadline {
                    drainAll()
                    if countOccurrences(of: "\n", in: stdoutBuf) > i { break }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        case .singleBatch:
            // Send all frames in one write, then wait for all responses.
            var combined = Data()
            for r in requests { combined.append(frame(r)) }
            stdinPipe.fileHandleForWriting.write(combined)
            let deadline = Date().addingTimeInterval(perCallTimeout * Double(requests.count))
            while Date() < deadline {
                drainAll()
                if countOccurrences(of: "\n", in: stdoutBuf) >= requests.count { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        // Final drain after the server flushes on exit.
        drainAll()
        return (stdoutBuf, stderrBuf)
    }

    enum WriteMode {
        case separateFrames
        case singleBatch
    }

    @Test("server responds to a single request without stdin close")
    func singleRequestInteractive() throws {
        let init_ = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        guard let output = Self.driveInteractive(requests: [init_]) else { return }
        let text = String(data: output.stdout, encoding: .utf8) ?? ""
        // Per MCP spec 2025-06-18 transport/stdio, each message is a
        // single NDJSON line terminated by `\n`. Previously this test
        // asserted a `Content-Length:` prefix, which matched the
        // previous (incorrect) LSP-style framing and hid the real bug
        // — Claude Desktop refused to initialize because it expected
        // NDJSON. Now we check the actual spec: exactly one newline at
        // the end of a frame, body parses as JSON-RPC.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!trimmed.contains("\n"), "Framed NDJSON body must not contain embedded newlines.")
        #expect(text.hasSuffix("\n"), "NDJSON frame must end with `\\n`.")
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
        let text = String(data: output.stdout, encoding: .utf8) ?? ""
        #expect(text.contains("\"id\":1"))
        #expect(text.contains("\"id\":2"))
        #expect(text.contains("\"id\":3"))
        #expect(text.contains("accessibility"))
    }

    @Test("server reassembles a frame written byte-by-byte to stdin")
    func fragmentedFrameReassembly() throws {
        // Guards the read path against the original bug's inverse: when
        // the OS hands us ONE byte at a time instead of a batch, the
        // drainReadBuffer / availableData loop must keep polling until
        // the complete Content-Length header + body are in the buffer.
        let binary = Self.serverBinary()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        Self.setNonBlocking(stdoutPipe.fileHandleForReading.fileDescriptor)

        let request = #"{"jsonrpc":"2.0","id":42,"method":"initialize","params":{}}"#
        let framed = Self.frame(request)

        // Write one byte at a time with a small delay. This is the kind of
        // stdin pattern we'd see over a very slow IPC channel.
        for byte in framed {
            stdinPipe.fileHandleForWriting.write(Data([byte]))
            Thread.sleep(forTimeInterval: 0.002)
        }

        var stdoutBuf = Data()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            stdoutBuf.append(Self.drainNonBlocking(stdoutPipe.fileHandleForReading.fileDescriptor))
            if stdoutBuf.contains("\"id\":42".data(using: .utf8)!) { break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        stdoutBuf.append(Self.drainNonBlocking(stdoutPipe.fileHandleForReading.fileDescriptor))

        let text = String(data: stdoutBuf, encoding: .utf8) ?? ""
        #expect(text.contains("\"id\":42"))
        #expect(text.contains("mac-control-mcp"))
    }

    @Test("server handles three frames delivered in a single stdin chunk")
    func multiFrameSingleChunk() throws {
        // Guard the drainReadBuffer loop: when the OS happens to deliver
        // multiple framed requests in one availableData read, every frame
        // must still be processed, not just the first.
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"ping","params":{}}"#
        ]
        guard let output = Self.driveInteractive(requests: requests, writeMode: .singleBatch) else { return }
        let text = String(data: output.stdout, encoding: .utf8) ?? ""
        #expect(text.contains("\"id\":1"))
        #expect(text.contains("\"id\":2"))
        #expect(text.contains("\"id\":3"))
    }
}
