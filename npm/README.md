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
- The extracted bundle is re-verified with `codesign --verify --deep --strict`, `spctl --assess --type execute`, and a pinned Apple Team ID (`A3W973JZ49`). That last check is the real trust anchor: it is what a replaced release asset cannot forge.
- `MAC_CONTROL_MCP_SKIP_DOWNLOAD=1` skips the download (for CI and sandboxed builds).
- `HTTPS_PROXY` / `NO_PROXY` are honoured.

## License

MIT
