# Social posts — ready to ship

Post these AFTER Show HN lands (so the HN thread can serve as the
proof link in replies). Wait ~30 min after Show HN to avoid the feeds
cannibalising each other.

---

## X / Twitter (attach the demo GIF)

Primary:

```
just shipped mac-control-mcp — native Swift MCP
server, 63 tools, one signed .app bundle.

claude can now drive your mac: AX tree, safari +
chrome, screen capture, OCR, spotlight, windows,
clipboard, menus. no python or node runtime.

one-click install via @AnthropicAI MCP Bundle spec.

github.com/AdelElo13/mac-control-mcp
```

Quote-RT variant if something from @AnthropicAI about MCP drops near
the same time:

```
built this around the MCP spec — 63 macOS tools in
one notarised Swift bundle. full AX + browser +
capture + OCR + spotlight. double-click the .mcpb
and claude desktop picks it up.

github.com/AdelElo13/mac-control-mcp
```

Follow-up reply (same thread) with a gifless deep link:

```
listed on the official MCP registry:
io.github.AdelElo13/mac-control-mcp

technical writeup of the spicy bits (CF pointer
recycling, Spotlight popover deadlock, TCC
resigning) in the README.
```

---

## r/ClaudeAI

Reddit favours longer context. Title:

```
mac-control-mcp — 63-tool native Swift MCP server for macOS (Developer ID signed + MCPB one-click install)
```

Body:

```
Built this over the last few weeks because every
Mac-automation MCP I tried was either a Python
wrapper fighting TCC, a Node/Electron thing that
leaked memory, or a pixel-based computer-use style
loop that was slow and wrong half the time.

**What you get**
- Accessibility tree walking (AXRole/Title find,
  click, type, attribute read/write)
- Safari + Chrome automation (tabs, navigation,
  do-JavaScript with a proper JSON envelope so
  locale coercion and CSP don't break it)
- ScreenCaptureKit window capture (works on
  cross-Space windows, the legacy CG* API doesn't)
- OCR over the screen
- Spotlight search via NSMetadataQuery +
  NSWorkspace.open (idempotent — the popover UI
  automation version was unfixable)
- Clipboard, windows, apps, menus, system settings,
  input injection (mouse/keys/drag/scroll)

**Install**
Claude Desktop users: download the .mcpb from the
release page, double-click, done. Developer-ID
signed + Apple-notarised, so no Gatekeeper drama
and TCC grants persist across updates.

Also on the official MCP registry as
io.github.AdelElo13/mac-control-mcp.

GitHub: https://github.com/AdelElo13/mac-control-mcp

Would love to hear which tools are missing — happy
to add if it's something common.
```

---

## r/LocalLLaMA (if you want a second Reddit bite)

This audience cares less about Claude Desktop specifically and more
about self-hosted tooling. Adjust body:

Title: `Native Swift MCP server for macOS — 63 tools, works with any MCP client`

Body — same as r/ClaudeAI but drop the "Claude Desktop users" line and
replace with:

```
Works with any MCP client that can spawn a stdio
binary — Claude Desktop, Claude Code, Cursor,
Continue, Zed, or your own orchestrator. Just
point the command at the .app's binary path.
```
