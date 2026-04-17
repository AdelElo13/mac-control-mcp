# Show HN — draft

## Recommended timing
- **Target slot:** Tuesday–Thursday, 8:00 AM Pacific (17:00 Amsterdam).
  Weekdays outperform weekends by ~3x; that window hits both US morning
  and EU evening at the same time, which is when HN traffic peaks.
- Avoid Mondays (reset traffic) and US holidays.
- Post while you can babysit comments for ~2 hours — first replies set
  the tone and decide ranking.

## Title (80 chars max, punchy, no marketing fluff)

```
Show HN: mac-control-mcp – 63-tool native Swift MCP server for macOS
```

Alternatives to A/B in a thought:
- `Show HN: Give Claude full control of your Mac via one signed .app`
- `Show HN: Native Swift MCP server with 63 macOS tools (AX, capture, Spotlight)`

Pick one — title can't be edited after posting.

## Body (keep it short, HN readers skim)

```
After watching Claude Desktop struggle with every
"automate my Mac" hack I tried — Python AX wrappers,
Node/Electron wrappers, shelling out to osascript — I
built mac-control-mcp: a single notarised .app bundle
that exposes 63 tools over MCP stdio. Swift 6, no
Python or Node runtime.

What it covers:
  - Accessibility tree (find/click/type/read via AX)
  - Safari + Chrome automation (tabs, nav, JS eval)
  - ScreenCaptureKit window capture, full display, OCR
  - Clipboard, windows, apps, menus, Spotlight
  - Input injection (mouse, keys, drag, scroll)

Why this instead of computer-use-style pixel APIs:
MCP lets the model ask for the AX tree directly, so
it can click an element by role/title instead of
inferring from pixels. Much cheaper, much more
deterministic.

Install options:
  - Claude Desktop: double-click the .mcpb file
    (one-click install via MCP Bundle spec)
  - Any MCP client: download the notarised .app
    and point the stdio transport at it
  - From source: `./scripts/build-bundle.sh`

Repo: https://github.com/AdelElo13/mac-control-mcp
Registry: io.github.AdelElo13/mac-control-mcp

Demo GIF in the README shows Claude opening Safari,
typing a search, capturing the window, OCR'ing it,
and running a Spotlight query — end to end through
MCP stdio.

Hard parts along the way:
  - CF pointer recycling silently dropped 95% of the
    AX tree on large apps until I wrapped the dedup
    key in AXKey (CFHash + CFEqual).
  - Spotlight popover UI automation was unfixable —
    Cmd+Space toggles, popover doesn't take regular
    activation, AX writes get silently dropped by
    the privacy layer. Rewrote the whole thing to
    NSMetadataQuery + NSWorkspace.open for idempotent
    search.
  - Ad-hoc signing resets TCC grants every rebuild;
    moved to Developer ID + notarytool so grants
    persist.

MIT licensed. Happy to answer questions.
```

## First comment (post yourself, 30 sec after the submission goes live — HN convention for context and it gets upvoted early)

```
Author here. A few things I want to flag honestly
rather than have someone dig them up:

- Signed + notarised, but first tool call still
  triggers one round of TCC consent prompts — macOS
  requires that, there's no away around it.
- Intel slice compiles universal but I've only
  runtime-tested on Apple Silicon. If you're on an
  Intel Mac and something breaks, please file an
  issue with the error — I'll fix it fast.
- 43 of 63 tools were exercised end-to-end via a
  live MCP probe; the rest are covered by the Swift
  test suite (63/63 green on CI) but not touched in
  integration. Status table in the README has the
  full matrix.

Would love feedback on the server.json shape — this
is the first MCP Registry submission I've done and
I'm not 100% sure I've picked the right package
type.
```

## Checklist before posting

- [ ] Ensure the demo GIF loads on a cold page view
      (GitHub's image proxy sometimes lags; hit the
      raw GIF URL once from an incognito window).
- [ ] Star count visible. Consider asking 2-3 friends
      to star beforehand so the card doesn't look
      like 0 stars — social proof matters on HN.
- [ ] README badges all green (CI, License, Platform,
      Notarized, MCP Registry).
- [ ] Issues tab empty — easier to look credible when
      nothing's festering. Re-open yours after posting.
- [ ] Have a draft reply ready for the inevitable
      "why not use iohook/robotjs/pyautogui" question.
      Short answer: AX tree > pixel inspection for
      LLM determinism.

## What not to do

- Don't cross-post to HN from multiple accounts or
  ask a friend to vote. HN detects voting rings and
  will greylist your domain.
- Don't put "Show HN:" in uppercase or add emoji.
- Don't link-stuff the comments. One link per reply
  is fine; multiple gets flagged.
- Don't pitch monetisation. This is "neat thing I
  built" territory — the moment it sounds like a
  sales page the thread dies.
