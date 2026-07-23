# Mobile & touch input (Godot 4.7+) — building with godot-mcp

Touch, multitouch, gestures, on-screen controls, and safe areas the Godot way. Every class and
setting below was introspected against the live 4.7 build — **re-verify with `engine class-info`
/ `project settings`**; touch API and the built-in `VirtualJoystick` are newer than most
training data. General display/window settings live in `menus-settings.md`; this file owns the
*input* side and the mobile-specific display knobs.

## Touch events: index-based multitouch

Touch arrives as `InputEventScreenTouch` (down/up) and `InputEventScreenDrag` (move); each
carries an **`index`** (the finger's slot), so key a dictionary on it to track several fingers.
Verified: `ScreenTouch` has `index`, `position`, `pressed`, `canceled` (OS stole the touch —
treat as a lift), `double_tap`; `ScreenDrag` adds `relative` (delta since last event) and
`velocity`.

```gdscript
extends Node2D
var _touches: Dictionary = {}   # index -> Vector2 position

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventScreenTouch:
        if event.pressed:
            _touches[event.index] = event.position
        else:
            _touches.erase(event.index)       # finger lifted (or canceled)
    elif event is InputEventScreenDrag:
        _touches[event.index] = event.position
        if _touches.size() == 1:
            position += event.relative         # one-finger pan
```

`_touches.size()` is the live finger count — the basis for pinch/rotate math (two fingers,
compare their distance frame to frame).

## Mouse ↔ touch emulation (test on desktop; reuse mouse UI)

Two project settings bridge the two input worlds (defaults shown, both verified):

- `input_devices/pointing/emulate_mouse_from_touch` — **default `true`**: a touch also emits
  mouse events, so existing `Control` buttons and `_gui_input` mouse code work under touch
  with no changes.
- `input_devices/pointing/emulate_touch_from_mouse` — **default `false`**: the mouse also
  emits `InputEventScreenTouch`, so you can exercise touch handlers on desktop with the mouse.

```
project set-setting --setting input_devices/pointing/emulate_touch_from_mouse --value true
```

## On-screen controls: buttons vs a virtual stick

- **`TouchScreenButton`** — a 2D node (not a `Control`) that fires an InputMap **action** from a
  screen region and can multi-press alongside other touches; set
  `visibility_mode = TOUCHSCREEN_ONLY` so it vanishes on desktop. Covered in
  `game-patterns.md` (Input setup). Because it maps to an action, one gameplay code path
  serves touch and keyboard/pad.
- **`Control` buttons** (`Button`, `TextureButton`) work under touch via
  `emulate_mouse_from_touch`, but fire on **release** and don't multi-touch — fine for menus,
  wrong for twitch controls.
- **`VirtualJoystick`** — a `Control` node **in this 4.7 build's ClassDB** (engine-level, newer
  than most training data; builds can differ — confirm with
  `engine class-info --class VirtualJoystick`. If absent, roll a small Control stick: track one
  finger's `ScreenDrag` by `index` in `_gui_input`, as in the multitouch section above, and feed
  `Input.parse_input_event` with an `InputEventAction`). It drives four InputMap actions, so your
  existing `Input.get_vector(...)` movement code works unchanged — no glue. Verified members and
  defaults:
  - `action_left`/`action_right`/`action_up`/`action_down` (StringName, default
    `ui_left`…`ui_down`) — point at your own actions; `joystick_mode`/`visibility_mode` (int
    enums, default 0 — set the touchscreen-only value to hide on desktop); feel via
    `joystick_size` (100), `tip_size` (50), `deadzone_ratio` (0), `clampzone_ratio` (1).
  - Signals `pressed`, `tapped`, `released(input_vector)`, `flicked(input_vector)`,
    `flick_canceled` — `flicked` gives the analog vector for a dash gesture.

  ```
  node add --type VirtualJoystick --name Move --parent-path HUD
  node set --node-path HUD/Move --properties '{"action_left":"move_left","action_right":"move_right","action_up":"move_up","action_down":"move_down"}'
  ```
  Movement code then reads `Input.get_vector("move_left","move_right","move_up","move_down")`,
  never knowing a thumb drives it.

## Gestures: pinch-zoom & two-finger pan

Trackpads and touchscreens emit gesture events (both inherit `InputEventGesture`, verified):
`InputEventMagnifyGesture.factor` (float) is the pinch scale for this event
(`camera.zoom *= event.factor`); `InputEventPanGesture.delta` (Vector2) is the two-finger
scroll amount.

```gdscript
    elif event is InputEventMagnifyGesture:
        _zoom *= event.factor
    elif event is InputEventPanGesture:
        _pan += event.delta
```
On bare touchscreens with no OS gesture recognition, derive pinch from the two live `_touches`
distances instead.

## Safe areas: keep the HUD off the notch

`DisplayServer.get_display_safe_area()` returns a `Rect2i` (screen pixels) — the region clear of
notches, punch-holes, and rounded corners (verified; method exists). Inset a full-rect HUD from
it so nothing important lands under the hardware:

```gdscript
extends Control   # HUD root, anchors full-rect (0,0..1,1)
func _ready() -> void:
    _apply_safe_area()
    get_viewport().size_changed.connect(_apply_safe_area)

func _apply_safe_area() -> void:
    var safe := DisplayServer.get_display_safe_area()
    var win := DisplayServer.window_get_size()
    offset_left = safe.position.x
    offset_top = safe.position.y
    offset_right = safe.end.x - win.x       # <= 0: inset from the right edge
    offset_bottom = safe.end.y - win.y      # <= 0: inset from the bottom edge
```

Re-applying on `size_changed` matters — orientation flips move the safe rect.

## Synthesizing input from code

`InputEventAction` injects an action as if pressed — for cutscenes, tutorial ghosts, or replay
(verified: `action` StringName, `pressed` bool, `strength` float for analog):

```gdscript
var ev := InputEventAction.new()
ev.action = &"jump"
ev.pressed = true
Input.parse_input_event(ev)     # feed it into the input system
```

`InputEventShortcut` fires a bound `Shortcut` resource (menu accelerators, editor-style
keybinds); `InputEventMIDI` carries note/velocity/channel for MIDI controllers — reach for it
only in instrument/rhythm games (see `rhythm-games.md`).

## Mobile viewport & stretch (recap)

Scale across phone resolutions with `stretch/mode = canvas_items` (2D/UI scale with resolution)
and `stretch/aspect = expand` (show more world on wide screens vs letterbox);
`display/window/handheld/orientation` locks portrait/landscape. Full treatment in
`menus-settings.md`.

```
project set-setting --setting display/window/stretch/mode --value canvas_items
project set-setting --setting display/window/stretch/aspect --value expand
```

## Checklist

- Multitouch keyed on `event.index`; treat `canceled` like a lift.
- Test touch on desktop via `emulate_touch_from_mouse`; reuse mouse UI via `emulate_mouse_from_touch`.
- In-game controls are `TouchScreenButton` / `VirtualJoystick` (action-mapped), not `Control` buttons; gameplay reads `Input.get_vector`.
- Gestures via `InputEventMagnifyGesture.factor` / `InputEventPanGesture.delta`.
- HUD inset from `DisplayServer.get_display_safe_area()`, re-applied on `size_changed`; stretch `canvas_items` + `expand` for multi-resolution phones.
