# mac-control-mcp — live bug log

Real-world findings from using mac-control-mcp for hackathon build. Each entry
lists the minimal repro + suggested fix for a future v0.2.4 release.

## #1 — `browser_list_tabs` / `browser_get_active_tab` false negative
**Trigger**: multiple Chrome processes active (main Chrome PID + Claude-in-Chrome
detached window). Both return `{count:0, tabs:[]}` while a window is clearly open.

**Root cause (probable)**: AppleScript call `tell application "Google Chrome" to get tabs`
matches only the first-launched Chrome instance, not all running processes of the
same bundle ID.

**Fix**: iterate over every PID with bundle `com.google.Chrome` and union the tabs.
Or: fall back to `list_windows` and read each window's title/URL from AX.

**Severity**: medium — blocks automation for anyone running multiple Chrome
windows (very common).

---

## #2 — `browser_eval_js` fails silently on default Chrome config
**Trigger**: fresh Chrome install without "Allow JavaScript from Apple Events"
enabled under View → Developer menu.

**Error returned**: "Executing JavaScript through AppleScript is turned off. …"

**Fix**: the error is already helpful. But the tool could (a) auto-detect and
enable the flag on first use (requires Accessibility permission), or (b) return
a structured `{ok:false, fixable:true, fix_hint:"..."}` so callers can prompt
the user programmatically.

**Severity**: low — one-time user action.

---

## #3 — `perform_element_action(AXPress)` silent success on disabled target
**Trigger**: call AXPress on an element whose `AXEnabled` is `"0"` (e.g. a Delete
button that's greyed out because the selection isn't valid for deletion).

**Observed**: returns `{ok:true, ax_status:0}` even though nothing happened.

**Fix**: before performing the action, read AXEnabled. If 0, return
`{ok:false, reason:"target not enabled"}`. This surfaces bugs in agent logic
that would otherwise hide as silent no-ops. Also consider surfacing
`unavailableActions` list in the return.

**Severity**: high — hides logic errors.

---

## #4 — `query_elements` title_regex matches only AXTitle
**Trigger**: modern web apps (Angular, Material, Shadcn, React with aria-label)
set button labels via `aria-label`, which maps to AXDescription, not AXTitle.
Buttons like "Save", "Next", "Enable API" have empty AXTitle but the label in
AXDescription.

**Observed**: queries like `title_regex: "^Save$"` return 0 elements even when
the Save button is visible and enabled.

**Fix**: add a `description_regex` parameter, or change title_regex to match
either AXTitle or AXDescription.

**Severity**: high — this is the single most common reason I had to fall back
to coordinate clicks during Google Cloud Console automation.

---

## #5 — AXPress returns `AXError=-25202` (kAXErrorActionUnsupported) on Chromium buttons
**Trigger**: some Chromium-rendered buttons expose themselves as AXButton but
don't register an AXPress action. Example: the "Enable" button on Google Cloud
API library pages.

**Fix**: in perform_element_action, if AXPress errors with -25202, transparently
fall back to a coordinate-based click at the element's bounding box center.
Document the fallback behaviour in the tool description.

**Severity**: medium — workaround is a separate `click` call with the element's
position.

---

## #6 — `type_text` silently degrades to `ax_set_value` on React/Angular inputs
**Trigger**: call type_text into a Material/React input. The tool returns
`{ok:true, strategy:"ax_set_value"}`. The input field visually shows the text,
but the framework's state (onChange handler) never fired. Submit buttons stay
disabled, validators see an empty field, forms refuse to advance.

**Repro**: Google Cloud Console "Add test users" dialog — typing an email via
type_text leaves the counter at "0/100". Same text pasted via Cmd+V produces
"1/100".

**Fix**: add a `strategy_hint` param (`"clipboard" | "keys" | "ax"`) so callers
can force an events-based path on SPAs. Or: verify success by re-reading AXValue
and an adjacent validator text ("0/100" → fail).

**Severity**: high — makes type_text unreliable for modern web forms, which
are the common case.

---

## #7 — `readLine` over stdin hangs on newline
**Scope**: not mac-control-mcp itself, but relevant to anything Adel builds on
top that reads stdin interactively. Our first `gmail-auth.ts` resolved only on
EOF, so pressing Enter after pasting did nothing; Ctrl+D triggered the resolve.

**Fix in our repo**: resolve on first "\n" in the data buffer. Fixed in commit
`34953cc` in the responder repo.

**Lesson for mac-control-mcp docs**: when showing "interactive stdin" examples
(e.g. in README), recommend readline or a newline-triggered reader, not the
raw "end"-event pattern.

**Severity**: low — user-facing but easy to avoid with the right API.

---

## Workarounds that worked reliably

- **Form input on React/Angular**: `clipboard_write` → `press_key("a", cmd)` →
  `press_key("v", cmd)`. Triggers real paste events, framework state updates.
- **Disabled buttons**: `get_element_attributes` with `["AXEnabled"]` before
  every AXPress to fail loudly instead of silently.
- **Angular button without title**: `query_elements` without `title_regex`,
  then `get_element_attributes` with `["AXDescription"]` on candidates until
  match.
- **Multiple Chrome windows**: skip `browser_list_tabs`; use `list_windows`
  and filter by app=Google Chrome + title substring.

---

## #8 — Telegram macOS app exposes an empty AX tree
**Trigger**: focus the native Telegram macOS app (ru.keepcoder.Telegram),
call `list_elements(pid)` or `query_elements(pid, role_regex: ".+")`.

**Observed**: `{elements: [], count: 0}` — no AX nodes at all, not even the
window chrome. This is after v0.2.3's `AXManualAccessibility` + `AXEnhancedUserInterface`
auto-enable, so it's not a missed opt-in.

**Root cause (probable)**: Telegram's native app is built on their own TGModernGrowing
toolkit, not AppKit. It doesn't implement NSAccessibility protocols. Not a
mac-control-mcp bug per se — it's Telegram's accessibility story that's broken.

**Workaround for agents**: use Telegram Web (web.telegram.org) via Chrome —
Chromium's AX tree is fully populated with v0.2.3's fix.

**Mac-control-mcp could help** by: (a) detecting AX-empty apps and surfacing
`{ok:false, hint:"app exposes no AX tree, try coord-based clicks or a web
alternative"}` in find_element. (b) OCR-fallback auto-wiring.

**Severity**: high for workflows that NEED the native app. Medium overall since
web alternatives usually exist.

---

## #9 — OCR char confusion on monospace tokens (`l/1`, `O/0`)
**Trigger**: `ocr_screen` on monospace text containing `l` (lowercase L),
`1` (one), `O` (uppercase O), `0` (zero). Fonts like Telegram's monospace
distinguish these, but the OCR model conflates them.

**Repro**: Telegram bot token `8768274745:AAFIzGAOAsZBl0GBYscIYHhJIDLoaLjO2hk`
(ground truth from clipboard). OCR returned
`8768274745:AAFIzGAOAsZB10GBYscIYHhJIDLoaLj02hk` (Bl→B1, LjO→Lj0).

**Workaround that worked**: `mouse_event(double_click)` on the token in a
Telegram message + `press_key("c", ["cmd"])` + `clipboard_read`. Telegram's
code-block component selects the whole token on double-click. This gave the
exact ASCII — including a `TelegramTextPboardType` flavor in the pasteboard
so we could detect that the paste came from Telegram specifically.

**Fix suggestions**: (a) recommend clipboard-based extraction for
security-critical strings in the tool docs. (b) optional `ocr_screen` mode
that runs two different OCR passes and flags disagreements. (c) language
hint `["code"]` that uses a monospace-aware model. Low priority — the
workaround is reliable.

**Severity**: medium for agent workflows that extract tokens / hashes / IDs
from UIs.

---

## #10 — `mac-control-mcp` has no `triple_click` / range select primitive
**Trigger**: need to select an entire line of text in an app without an AX
tree (Telegram message body, monospace code blocks spanning >1 visual line).

**Observed**: `mouse_event` supports `move / click / double_click`. No
`triple_click`, no drag-select helper. `drag_and_drop` works for actual
drag gestures but isn't wired to "select text range".

**Fix**: add `triple_click` to the action enum (three rapid single clicks
within the system's multi-click threshold). Also consider a `select_range`
helper that does `mouseDown → drag → mouseUp` between two coords.

**Severity**: low — workaround in this case was double_click, which Telegram
treats as "select word" and fortunately the token is one word.

---

## Stats

- Sessions where findings came from: 1 (hackathon Day 0–Day 2).
- Apps exercised: Chrome (Google Cloud Console, Google OAuth), Terminal,
  Telegram (native).
- Findings total: 10 bugs + 5 reliable workarounds.
