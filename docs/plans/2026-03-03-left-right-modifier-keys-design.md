# Left/Right Modifier Key Distinction for Push to Talk

## Problem

Push to Talk currently uses `NSEvent.modifierFlags` which cannot distinguish left vs right modifier keys. Users want to bind push-to-talk to a specific side (e.g., right Option) to avoid conflicts with normal modifier usage and eliminate the need for double-tap.

## Approach

Use `NSEvent.keyCode` from `flagsChanged` events to identify which physical key was pressed. The keyCode values are stable across macOS versions.

### Key Codes

| Key | Left keyCode | Right keyCode |
|-----|-------------|--------------|
| Shift | 56 | 60 |
| Control | 59 | 62 |
| Option | 58 | 61 |
| Command | 55 | 54 |
| Fn | 63 | (none) |

## Design

### 1. Extend `LongPressModifierKey` Enum

Expand from 5 cases to 13, adding left/right variants for Option, Command, Shift, Control. Fn stays as-is (no left/right). Each case exposes:

- `displayName`: e.g., "Right Option"
- `symbol`: e.g., "⌥"
- `modifierFlag`: the `NSEvent.ModifierFlags` value
- `keyCodes`: `Set<UInt16>` — one keyCode for side-specific, two for "any" variants
- `isSideSpecific`: `Bool` — true for left/right variants

### 2. Modify `ModifierKeyMonitor.handleFlagsChanged`

- On key-down: check both `modifierFlags` (for the modifier type) and `event.keyCode` (for the specific side)
- Store the last matched keyCode so `checkActivation` can verify without re-querying `NSEvent.modifierFlags`

### 3. Auto-disable Double-tap

- When user selects a side-specific modifier, automatically set `requireDoubleTap = false`
- Hide the double-tap toggle in the UI when a side-specific key is selected

### 4. Settings UI

Flat Picker listing all 13 options grouped visually:

```
⌥ Option (Any)
⌥ Left Option
⌥ Right Option
⌘ Command (Any)
⌘ Left Command
⌘ Right Command
⇧ Shift (Any)
⇧ Left Shift
⇧ Right Shift
⌃ Control (Any)
⌃ Left Control
⌃ Right Control
fn Fn
```

### 5. Backward Compatibility

Existing `LongPressConfig` JSON stores the enum raw value (e.g., `"shift"`). Old values decode correctly since the original cases are preserved.
