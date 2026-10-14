# mac-control-mcp v0.10.2

ControlZoo now covers ten more AppKit controls. Building that coverage turned up three cases where a tool reported success while nothing had happened. All three are fixed, and each fix is pinned by a test that fails on v0.10.1.

## Fixes

### Typed text that never arrived was reported as success

- **What happened:** `type_text` with an `element_id` reported `verified: true` while the field kept its old value. Verification counted a focus change as evidence, but that focus had been set by the tool itself a moment earlier.
- **Now:** targeted typing is judged on the element's value only.
  - A changed value gives `verified: true`.
  - An unchanged value gives `ok: false` with `error_code: no_effect` and a hint.
  - An unreadable value (secure fields) gives `verified: null`.
  - Key events are delivered asynchronously, so the value gets up to 500 ms to change before the verdict.

### `auto` typing silently lost text after a failed paste

Two bugs combined here:

1. **The paste was assumed to work.** The `auto` strategy pastes with Cmd+V first. In an app without an Edit ▸ Paste menu item, or a field that ignores paste, Cmd+V does nothing, yet `auto` reported `clipboard_paste`. Now, when the focused element's value is readable and stays unchanged for 400 ms after the paste, `auto` retypes with key events. The result carries `fallback_reason: clipboard_paste_no_effect`.
2. **The retyped keys arrived as Command shortcuts.** Unicode key events inherited the modifier state of the system event source. Right after a synthetic Cmd+V that state still held Command, so the text arrived as Cmd+key (`a` became Cmd+A, select all) and nothing was typed. Text events are now posted without modifiers. This also affected `type_text` right after any `press_key` that used modifiers.

### `set_element_attribute` reported ignored writes as success

- **What happened:** NSColorWell accepts an `AXValue` write with `ax_status 0` and keeps its colour. The tool returned `ok: true`.
- **Now:** the attribute is read back after the write, with up to 300 ms for the app to apply it.

| Read-back result | Tool response |
|---|---|
| Holds the requested value | `verified: true` |
| Unchanged, and not the requested value | `ok: false`, `error_code: no_effect`, `read_back`, and a hint to use `perform_element_action` |
| Changed to a different value (clamped or rounded, e.g. a slider written past its maximum) | `ok: true`, `verified: false`, `applied_value` |
| Unreadable | `verified: null` |

Secure fields are never read back.

The tool description now also states an AppKit fact that agents trip over: writing `AXValue` to a text field, combo box or search field changes its contents, but sends the app no text-change notification. Use `type_text` when the app has to react, for example search-as-you-type, validation or autocomplete.

## ControlZoo: 21 controls

A second column adds ten controls. Each control an agent can change updates a status label from its own action or delegate. The matrix asserts on that label, so a pass shows the app saw the change.

| Control | AX role | Driven by |
|---|---|---|
| Radio buttons | AXRadioButton | AXPress, exclusivity checked |
| Segmented control | AXRadioGroup → AXRadioButton/AXSegment | AXPress on a segment |
| Combo box | AXComboBox | AXValue write, read back |
| Search field | AXTextField/AXSearchField | `type_text auto`; the app is notified |
| Date picker | AXDateTimeArea | AXIncrement (AXValue is not writable) |
| Colour well | AXColorWell | AXValue write reports `no_effect`; AXPress opens the Colors panel |
| Disclosure triangle | AXDisclosureTriangle | AXPress toggles |
| Progress indicator | AXProgressIndicator | read |
| Tab view | AXTabGroup → AXRadioButton/AXTabButton | AXPress switches the visible content |
| Table | AXTable → AXRow | AXSelected; the app's selection follows |

`MAC_CONTROL_MCP_TEST_BINARY` lets the matrix run against a build other than the installed app.

## Tests

- The full suite (800 tests) passes with exit 0, run against the v0.10.2 debug build.
- The extended matrix run against the installed v0.10.1 fails on exactly the five issues above.
- Five new unit tests cover the write and typing verdicts.
- The npm launcher passes 93 of 93 tests.
- No osascript or AppleScript is used anywhere in these changes. Everything goes through Accessibility and CGEvent.
