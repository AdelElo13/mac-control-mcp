# mac-control-mcp v0.2.1

Critical hotfix for v0.2.0. If you installed the v0.2.0 `.mcpb`, **please update** — v0.2.0 did not work inside Claude Desktop.

## The bug

v0.2.0 framed MCP stdio messages with LSP-style `Content-Length:` headers. The MCP transport spec requires **newline-delimited JSON** (one minified JSON message per line, terminated with `\n`). Claude Desktop rejected every message from the server with `SyntaxError: Unexpected token 'C', "Content-Length: 93" is not valid JSON`, timed out the initialize request, and closed the transport. The install succeeded (Gatekeeper + bundle registration worked), but no tool ever ran.

Full server log excerpt from `~/Library/Logs/Claude/mcp-server-mac-control-mcp.log`:

```
[error] Unexpected token 'C', "Content-Length: 93" is not valid JSON
[info] Message from client: {"jsonrpc":"2.0","method":"notifications/cancelled",
       "params":{"requestId":0,"reason":"McpError: MCP error -32001: Request timed out"}}
```

This is the "yellow warning, then connection drops" users reported.

## What's fixed

- **Outgoing messages** are now NDJSON: `<minified-json>\n`. One line per frame, no headers.
- **Incoming messages** still accept both NDJSON (primary, per spec) and `Content-Length:` framing (fallback, for older probes written against the previous server).
- `JSONEncoder.outputFormatting` has a defensive `.prettyPrinted` strip so nobody accidentally embeds newlines inside a frame and breaks framing silently.
- Three test drivers (stdio integration, ControlZoo, RealAppMatrix) that parsed responses via `Content-Length:` were rewritten to read NDJSON. One stdio assertion that required the old header has been replaced with an assertion on NDJSON shape — the embedded-newlines check would have caught the original regression.

No behaviour change to any of the 63 tools. This is purely a framing fix.

## Verification

- Swift test suite: 62/63 tests green (ControlZoo skipped — it needs clean AX state and a fresh spawn, not a framing issue).
- Live probe: `permissions_status`, `list_apps`, `spotlight_search`, `capture_screen`, `browser_eval_js` all roundtrip cleanly against the rebuilt binary.
- Developer ID signing + Apple notarization: accepted, ticket stapled, `spctl` reports `source=Notarized Developer ID`.
- Claude Desktop install flow: retested end-to-end with the new `.mcpb` — no more transport errors in the log.

## Upgrade

- **Claude Desktop**: remove the v0.2.0 extension from Settings → Extensions, then double-click the new v0.2.1 `.mcpb` from the release page.
- **Manual install**: download `MacControlMCP-v0.2.1-macos-universal.tar.gz`, replace `~/Applications/MacControlMCP.app`, restart your MCP client.
- **From source**: `git pull && ./scripts/build-bundle.sh` — same `NOTARIZE_PROFILE` env variable for signed builds.

Apologies for the bad ship. The live probes I used during development tolerated both framings so the regression passed my automated tests too — I've added the "NDJSON must not contain embedded newlines" assertion so this class of mistake is caught by CI going forward.
