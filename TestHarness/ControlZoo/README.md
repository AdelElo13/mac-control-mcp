# ControlZoo

Deterministic AppKit test harness for `mac-control-mcp`.

This minimal Cocoa app places every control type we claim to support on
a single window with stable `accessibilityIdentifier` values. The compat
matrix (`Tests/MacControlMCPTests/ControlZoo*Tests.swift`) drives it through MCP and
asserts every control's read/write/action works.

If this matrix ever regresses to < 100% PASS, the MCP has a real bug.

## Controls (first column, 11)

| Identifier       | AppKit class           | AX role            |
|------------------|------------------------|--------------------|
| `tf_single`      | NSTextField            | AXTextField        |
| `tf_secure`      | NSSecureTextField      | AXTextField + subrole |
| `ta_multi`       | NSTextView             | AXTextArea         |
| `cb_one`         | NSButton (checkbox)    | AXCheckBox         |
| `sw_one`         | NSSwitch               | AXSwitch           |
| `sl_one`         | NSSlider               | AXSlider           |
| `st_one`         | NSStepper              | AXStepper          |
| `pu_one`         | NSPopUpButton          | AXPopUpButton      |
| `li_meter`       | NSLevelIndicator       | AXLevelIndicator   |
| `btn_click`      | NSButton (bezeled)     | AXButton           |
| `outline_items`  | NSOutlineView          | AXOutline + AXRows |

## Extended controls (second column, 10 more)

Each control that an agent changes also updates a status label
(`<id>_label`) from its own target/action or delegate. The matrix
(`Tests/MacControlMCPTests/ControlZooExtendedTests.swift`) asserts on that
label, so a pass proves the app saw the change.

| Identifier        | AppKit class            | AX role                            | How the matrix drives it |
|-------------------|-------------------------|------------------------------------|--------------------------|
| `rb_a/b/c`        | NSButton (radio)        | AXRadioButton                      | AXPress, exclusivity checked |
| `seg_one`         | NSSegmentedControl      | AXRadioGroup → AXRadioButton/AXSegment | AXPress on a segment |
| `combo_one`       | NSComboBox              | AXComboBox (+ AXButton, same id!)  | AXValue write, read back `verified` |
| `sf_one`          | NSSearchField           | AXTextField / AXSearchField        | type_text `auto` (no Edit menu → key fallback), app notified |
| `dp_one`          | NSDatePicker            | AXDateTimeArea                     | AXIncrement (AXValue is not writable) |
| `cw_one`          | NSColorWell             | AXColorWell                        | AXValue write must report `no_effect`; AXPress opens Colors panel |
| `disc_one`        | NSButton (disclosure)   | AXDisclosureTriangle               | AXPress toggles |
| `prog_one`        | NSProgressIndicator     | AXProgressIndicator                | read (0.42) |
| `tab_one`         | NSTabView               | AXTabGroup → AXRadioButton/AXTabButton | AXPress switches visible content |
| `table_one`       | NSTableView             | AXTable → AXRow                    | AXSelected on a row, app selection follows |

`cw_close_panel` is a helper button that closes the shared Colors panel.

Notes learned while building this:

- Writing AXValue to a text field, combo box or search field changes its
  contents but AppKit sends the app no text-change notification. Use
  type_text when the app has to react.
- NSComboBox's drop-down button carries the combo's identifier; resolve by
  identifier and role.

## Running

```bash
# One-off build
cd TestHarness/ControlZoo && swift build --disable-sandbox
./.build/debug/ControlZoo &

# Run both matrices (installed MacControlMCP.app by default; point
# MAC_CONTROL_MCP_TEST_BINARY at another build to test it instead)
swift test --filter ControlZooMatrixTests
MAC_CONTROL_MCP_TEST_BINARY=$PWD/.build/debug/mac-control-mcp swift test --filter ControlZooMatrixTests
```

Keep the mouse and keyboard idle while it runs: the matrix activates the
harness and types into it.

## Matrix baseline (verified 2026-04-17)

```
PASS   AXTextField read/write         roundtrip verified
PASS   AXSecureTextField write        bullet-char count matches
PASS   AXTextArea read/write          roundtrip verified
PASS   AXCheckBox toggle              AXPress flips AXValue
PASS   AXSwitch toggle                AXPress flips AXValue
PASS   AXSlider read+write            numeric AXValue roundtrip
PASS   AXStepper increment            AXIncrement changes AXValue
PASS   AXPopUpButton menu nav         AXShowMenu + AXPress selects
PASS   AXLevelIndicator read+write    numeric AXValue roundtrip
PASS   AXButton AXPress               action succeeds ax_status=0
PASS   AXOutline row selection        AXSelected toggle works
```
