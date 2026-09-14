# mac-control-mcp

Native Swift MCP server for full macOS automation — 151 tools in one Developer ID signed, notarized `.app`. No Python, no Electron, no Node runtime in the hot path.

This npm package is a thin launcher: `npm install` downloads the notarized `MacControlMCP.app` for the matching release, verifies its published SHA-256, and `npx mac-control-mcp` execs the binary inside it as a stdio MCP server.

Full documentation, tool list and other install routes (`.mcpb` one-click, prebuilt tarball, build from source): <https://github.com/AdelElo13/mac-control-mcp>.

## Requirements

- macOS 14.0+ (Apple silicon or Intel — the bundle is universal)
- Node 18+

## Use it

```bash
npx -y mac-control-mcp --version
```

### Claude Desktop

`~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "mac-control-mcp": {
      "command": "npx",
      "args": ["-y", "mac-control-mcp"]
    }
  }
}
```

### Claude Code

```bash
claude mcp add mac-control-mcp -- npx -y mac-control-mcp
```

### Cursor

`~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "mac-control-mcp": {
      "command": "npx",
      "args": ["-y", "mac-control-mcp"]
    }
  }
}
```

## CLI

| Command | Effect |
|---|---|
| `mac-control-mcp` | start the MCP server on stdio |
| `mac-control-mcp --version` | print the bundled `MacControlMCP.app` version |
| `mac-control-mcp --app-path` | print the path to `MacControlMCP.app` |

`--app-path` is what you need when granting macOS permissions by hand.

## Permissions

macOS grants Accessibility, Screen Recording and Apple Events to the **application that launches the process**, not to this script. Run the `permissions_status` tool once from your MCP client to see exactly which grants are missing and which app they belong to.

## Install behaviour

- First install downloads ~3 MB from the GitHub release for this exact version.
- The tarball is checked against the release's `.sha256` asset before extraction; a mismatch aborts the install. Both assets come from the same release, so this proves the bytes arrived intact — not who built them.
- The archive's table of contents is validated before extraction: absolute paths, `..` entries and escaping symlinks are refused.
- The extracted bundle is verified in a staging directory — `codesign --verify --deep --strict`, a pinned Apple Team ID (`A3W973JZ49`), bundle identifier + version, then `spctl --assess --type execute` — and only then renamed into place. The Team ID check is the real trust anchor: it is what a replaced release asset cannot forge.
- On re-install / `npm rebuild`, an already-present bundle gets exactly the same checks before it is trusted. One that fails any of them is moved aside to `vendor/MacControlMCP.app.rejected-<timestamp>` (kept for inspection, never executed) and a fresh copy is downloaded.
- `MAC_CONTROL_MCP_SKIP_DOWNLOAD=1` skips the download (for CI and sandboxed builds).
- `MAC_CONTROL_MCP_RELEASE_BASE_URL=https://…` fetches the release assets from a mirror instead of GitHub Releases (test suites, enterprise re-hosts of the unmodified assets). It must be `https`; every verification step above still applies to whatever the mirror serves.
- `HTTPS_PROXY` / `NO_PROXY` are honoured.

## License

MIT
