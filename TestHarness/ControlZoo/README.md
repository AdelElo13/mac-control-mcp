# ControlZoo

Deterministic AppKit test harness for `mac-control-mcp`.

This minimal Cocoa app places every control type we claim to support on
a single window with stable `accessibilityIdentifier` values. The compat
matrix (`/tmp/compat-zoo.py` — see below) drives it through MCP and
asserts every control's read/write/action works.

If this matrix ever regresses to < 100% PASS, the MCP has a real bug.

## Controls (11 total)

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

## Running

```bash
# One-off build
cd TestHarness/ControlZoo && swift build --disable-sandbox
./.build/debug/ControlZoo &

# Drive the compat matrix against the running harness
python3 /tmp/compat-zoo.py
```

Expected: `Total: 11  PASS=11`.

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
