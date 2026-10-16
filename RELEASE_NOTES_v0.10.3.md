# mac-control-mcp v0.10.3

Password fields are now off limits through every tool route. The server cannot read them, type into them or paste into them. This guard is enforced in code, not by an instruction to the model, so it holds for every client and every prompt, including text a web page injects.

## Why

A live probe of v0.10.2 against ControlZoo's `NSSecureTextField` found six routes that wrote into the field:

- `set_element_attribute` with `AXValue`
- `type_text` without an `element_id` (strategies `keys`, `ax` and `auto`)
- `press_key`
- `press_key_sequence`
- `key_down`

AppKit reports a password field as role `AXTextField` with subrole `AXSecureTextField`. The text-editing tools checked the role only, so they missed it too.

## What is refused now

A field counts as a password field when its role or its subrole is `AXSecureTextField`.

| Route | Behaviour |
|---|---|
| Reads: `get_ui_tree`, `find_elements`, `query_elements`, `read_value`, `get_element_attributes`, `text_get_value`, snapshots, grounding | The value and the character count are never returned |
| Element writes: `set_element_attribute` (content attributes), `text_*` edits, `type_text` with `element_id`, `act` with `type` or `set_value` | Refused |
| `type_text` without `element_id`, all strategies | Refused while a password field has keyboard focus. The check runs right before every event or Accessibility write, and before the clipboard is touched |
| `press_key`, `key_down`, every step of `press_key_sequence` | Text and editing keys and Cmd+V are refused while a password field has focus |
| Menu items: `click_menu_path`, `click` by title, element or coordinate, `double_click`, `right_click`, `mouse_event`, `perform_element_action` | Menu-bar and context-menu items are refused while a password field has focus. This blocks routes like clipboard then Edit ▸ Paste, Start Dictation and Emoji & Symbols |

**Still allowed:**

- Navigation keys: Tab, Shift+Tab, Return, Escape, arrows, Home/End and Page Up/Down. An agent can still move away or submit a form the user filled in.
- Pop-up button, menu button and combo box option menus. They pick an option and never insert text.
- `key_up`, always. A held key can always be released.
- `AXFocused` on the field. An agent can hand the field to the user.

**Tab, then type:** `press_key_sequence` used to check focus once, before the first step. A sequence like Tab, p, a, s could tab into the password field and keep typing. Focus is now checked before every text step, with a 150 ms settle after a navigation key. A refused sequence reports `steps_sent`.

**Every refusal has the same shape:** `ok: false`, `error_code: not_supported`, `reason: secure_field`, and a hint telling the agent to ask the user to type the value.

## Not covered

`browser_eval_js` runs arbitrary JavaScript in the page. It can read `input[type=password]` directly, and no Accessibility guard can see that.

## Tests

- **New unit tests:** `SecureFieldGuardTests` adds 14 tests. They inject the focus probe, so they post no real key events.
- **Live matrix:** the ControlZoo matrix asserts every route above, including tab-then-type and Edit ▸ Paste. It finds 13 issues against v0.10.2 and 0 against this build.
- **Context-menu probe:** right-click on the password field, then click Paste at its screen position. The click is refused and the field keeps its 7 characters.
- **Full suite:** 814 tests pass with exit 0, three runs in a row.
- **Independent review:** two review rounds. The findings that led to the per-step sequence check, the menu guard and the late focus probes are fixed.
