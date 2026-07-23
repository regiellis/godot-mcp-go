# Menus & settings screens — structure and the meta-game the Godot way

How to build the screens *around* the game — title, pause, settings, remap, dialogs — with the CLI.
This doc owns **structure and the widget family**; `ui-polish-2d.md` owns the *look* (Design tokens,
drawn controls, juice, transitions) — build the skeleton here, polish there. Every widget, signal, and
enum below was verified against the live build. A menu only tells the truth when you **play it**
(`scene play` → `input click` / drive focus with a gamepad action → read back); ground anything
unfamiliar with `engine class-info --class OptionButton` before wiring it.

## The skeleton every menu shares

A menu is a `Control` scene laid out by **containers**, not absolute coordinates — containers re-flow
on any resolution, offsets don't. Three commands do it: `ui.add_container` (auto-arranging parent),
`ui.add_control` (a leaf widget), `ui.set_sizing` (how a child fills its slot). Anchor the outer
container `full_rect`; a `CenterContainer` then centers the button column at any window size.

**Build (a title screen):**
```sh
scene create --path res://ui/main_menu.tscn --root-type Control
scene open   --path res://ui/main_menu.tscn
ui add-container --type CenterContainer --name Center --parent-path .
node set-anchor --node-path Center --preset full_rect                 # track the window
ui add-container --type VBoxContainer --name Buttons --parent-path Center --separation 14
ui add-control --type Button --name PlayButton --parent-path Center/Buttons --text "Play"   # + Settings, Quit
ui set-sizing --node-path Center/Buttons/PlayButton --h fill --custom-min-size "Vector2(260,56)"
node connect --source-path Center/Buttons/PlayButton --signal-name pressed --target-path . --method-name _on_play
scene save
```
`grab_focus()` the first button on open (a controller/keyboard needs a focused control), then change scenes on Play:
```gdscript
func _on_play() -> void:
	get_tree().change_scene_to_file("res://scenes/level_01.tscn")   # returns an Error code
```
`change_scene_to_file` frees the current scene and loads the new one next frame;
`change_scene_to_packed(preloaded)` avoids the load hitch, `reload_current_scene()` restarts.

## Pause menu — an overlay that lives while the tree is frozen

Pause is two facts: `get_tree().paused = true` stops every node whose `process_mode` is the default
`PROCESS_MODE_INHERIT`/`PROCESS_MODE_PAUSABLE`, and the pause UI must keep running to un-pause. Put
the UI on its own `CanvasLayer` (draws above the world, ignores the game camera) set to
**`PROCESS_MODE_ALWAYS`** (`3`) so its buttons still receive input.

**Build:**
```sh
node add --type CanvasLayer --name PauseUI --parent-path .
node set --node-path PauseUI --properties '{"layer":10,"process_mode":3,"visible":false}'   # 3 = ALWAYS
ui add-container --type CenterContainer --name Center --parent-path PauseUI
node set-anchor --node-path PauseUI/Center --preset full_rect
```
```gdscript
func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_cancel"):              # Esc / gamepad Start
		var p := not get_tree().paused
		get_tree().paused = p
		$PauseUI.visible = p
		if p: $PauseUI/Center/Buttons/Resume.grab_focus()
```
Process-mode ladder: `INHERIT`(0) follows the parent, `PAUSABLE`(1) stops on pause, `WHEN_PAUSED`(2)
runs *only* while paused, `ALWAYS`(3) never stops, `DISABLED`(4) never runs. Gate Quit behind a
`ConfirmationDialog` (below) so a mis-click is recoverable.

## The settings screen — the full widget family

Group settings into `TabContainer` pages — its direct-child Controls **become the tabs** (title each
with `set_tab_title(idx, title)`); a bare `TabBar` is the strip alone when you page content yourself.
Each row pairs a `Label` with the right widget. The family, each with the signal you bind:

| Setting | Widget | Signal → read | Notes |
| --- | --- | --- | --- |
| Resolution / Quality | `OptionButton` | `item_selected(index)` → `get_item_id(index)` | `add_item(label, id)`, `select(idx)` |
| Bus volume | `HSlider` (`Range`) | `value_changed(value)` → `.value` | set `min_value`/`max_value`/`step` |
| VSync / Fullscreen | `CheckButton` | `toggled(on)` → `.button_pressed` | toggle button, label beside it |
| Numeric (FOV, …) | `SpinBox` (`Range`) | `value_changed(value)` → `.value` | `.suffix = "°"`, `.prefix` |
| Credits / web link | `LinkButton` | `pressed` | set `.uri` to auto-open on click |
| Extra actions | `MenuButton` / `MenuBar` | popup's `id_pressed(id)` | see below |

**Build (a Video tab: dropdown, slider, toggle):**
```sh
ui add-container --type TabContainer --name Tabs --parent-path Center
ui add-container --type VBoxContainer --name Video --parent-path Center/Tabs
ui add-control --type OptionButton --name ResOption --parent-path Center/Tabs/Video
ui add-control --type HSlider --name MusicSlider --parent-path Center/Tabs/Video
node set --node-path Center/Tabs/Video/MusicSlider --properties '{"min_value":0.0,"max_value":1.0,"step":0.01,"value":1.0}'
ui add-control --type CheckButton --name VSyncToggle --parent-path Center/Tabs/Video --text "VSync"
node connect --source-path Center/Tabs/Video/MusicSlider --signal-name value_changed --target-path . --method-name _on_music
```
`add_item`/`select`/`item_selected` are runtime calls; populate and react in script:
```gdscript
func _ready() -> void:
	for r in ["1280x720", "1920x1080", "2560x1440"]:
		$Center/Tabs/Video/ResOption.add_item(r)
	$Center/Tabs/Video/ResOption.item_selected.connect(_on_res)

func _on_music(value: float) -> void:                 # HSlider (linear) → audio bus (dB)
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), linear_to_db(value))
```
`linear_to_db(0)` is `-inf` (silence), which is correct. Godot also has
`AudioServer.set_bus_volume_linear(idx, value)` to skip the conversion. Reach for `MenuBar` only for a
desktop-app top strip; each child `PopupMenu` is one menu, wired via `get_menu_popup(i).id_pressed`,
and a `MenuButton`'s dropdown is `get_popup().id_pressed`.

## Persist settings — ConfigFile + apply-on-boot

Save to `user://settings.cfg` with `ConfigFile` (INI-style, human-readable, no schema). One
**autoload** loads it and applies every value *before the first scene draws*, so the game starts in
the user's state. `save`/`load` return an `Error` (`OK == 0`).

```sh
project add-autoload --name Settings --path res://autoload/settings.gd
```
```gdscript
extends Node
const PATH := "user://settings.cfg"

func _ready() -> void:                                # apply-on-boot
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK: return                   # first run → defaults stand
	var m := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(m, linear_to_db(cfg.get_value("audio", "master", 1.0)))
	# …apply video/input the same way

func put(section: String, key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PATH)                                     # merge — don't clobber sibling keys
	cfg.set_value(section, key, value)
	cfg.save(PATH)
```
`get_value(section, key, default)` returns the default when absent — fresh installs and partial configs need no special-casing.

## Input remapping — rebind actions at runtime

Remapping edits the live `InputMap`: `action_erase_events(action)` clears an action's bindings,
`action_add_event(action, event)` adds the captured one. The UI enters a **listening** state, grabs
the next key, rebinds, persists. Serialize `InputEventKey.physical_keycode` (an int, layout-
independent), never the event object. The **edit-time default** bindings a project ships with come
from the `input_map` command group (`input_map set-action`); this is the *runtime* layer on top.

```gdscript
var listening := ""                                   # empty = not capturing

func begin_listen(action: String, prompt: Button) -> void:
	listening = action
	prompt.text = "Press a key…"

func _unhandled_input(e: InputEvent) -> void:
	var key := e as InputEventKey
	if listening == "" or key == null or not key.pressed: return
	InputMap.action_erase_events(listening)
	InputMap.action_add_event(listening, key)
	Settings.put("keys", listening, key.physical_keycode)   # persist the int
	listening = ""
```
On boot, rebuild each action from the saved int: `var ev := InputEventKey.new(); ev.physical_keycode
= scancode`, then `action_erase_events` + `action_add_event`. `key.as_text_physical_keycode()` gives
the label string ("Space", "A").

## Window & display

Runtime changes go through `DisplayServer`; layout-time scaling through project settings. Never write
`project.godot` by hand — use `project set-setting`.

- **Fullscreen / windowed:** `DisplayServer.window_set_mode(mode)` — `WINDOW_MODE_WINDOWED`,
  `WINDOW_MODE_FULLSCREEN` (borderless), `WINDOW_MODE_EXCLUSIVE_FULLSCREEN`.
- **VSync:** `DisplayServer.window_set_vsync_mode(mode)` — `VSYNC_ENABLED`, `VSYNC_DISABLED`,
  `VSYNC_ADAPTIVE`, `VSYNC_MAILBOX`.
- **Resolution:** `DisplayServer.window_set_size(Vector2i(w, h))` (windowed only).
- **Content scale** (UI crispness across resolutions): set the stretch policy once as project
  settings, then the engine scales the UI for you —
  ```sh
  project set-setting --name display/window/stretch/mode --value canvas_items
  project set-setting --name display/window/stretch/aspect --value keep
  ```
  A live per-user accessibility knob is `get_window().content_scale_factor`.

## Dialogs & popups

`AcceptDialog` is a `Window` with an OK button (signal `confirmed`); `ConfirmationDialog` adds Cancel
(signal `canceled`). Show either with **`popup_centered(Vector2i(w, h))`**, never `visible = true`
(which skips placement). `FileDialog` (a `ConfirmationDialog`) picks files: set `file_mode`
(`FILE_MODE_OPEN_FILE`, `FILE_MODE_SAVE_FILE`, …) and `access` (`ACCESS_RESOURCES` for `res://`,
`ACCESS_USERDATA` for `user://`, `ACCESS_FILESYSTEM` for the disk), add `*.ext` filters, read
`file_selected(path)`.
```gdscript
func confirm_quit(d: ConfirmationDialog) -> void:
	d.dialog_text = "Quit to desktop?"
	d.confirmed.connect(get_tree().quit)              # canceled just closes
	d.popup_centered(Vector2i(320, 140))              # a FileDialog: same popup_centered, + add_filter
```

## Gamepad & keyboard navigation — the couch-compat checklist

A mouse-only menu is broken on a controller. Exactly one Control holds focus; `ui_up`/`ui_down`/
`ui_left`/`ui_right`/`ui_accept`/`ui_cancel` (built-in actions) move and activate it. On every screen:

- **Grab focus on open** — `first_button.grab_focus()` when it shows; re-grab after a sub-dialog closes. No focus → a controller does nothing.
- **Every actionable Control is focusable** — Buttons default to `focus_mode = FOCUS_ALL`(2); custom Controls must set it (`FOCUS_NONE`=0, `FOCUS_CLICK`=1).
- **Fix auto-routing where it's wrong** — `focus_neighbor_top/bottom/left/right` (or `set_focus_neighbor(SIDE_BOTTOM, path)`) and `focus_next`/`focus_previous`.
- **Verify by driving** — `scene play`, then `input action --action ui_down` / `ui_accept`, and `runtime get` the focused path: reach *and trigger* mouse-free.
- **Touch builds** may want an on-screen stick — see *VirtualJoystick*.

## Skinning with 9-slice — NinePatchRect vs StyleBoxTexture

Both stretch a bordered texture without distorting corners; **their margin properties differ, and
mixing them up silently does nothing** (verified live):

- **`NinePatchRect`** — a *node*, a standalone stretchable image (a framed panel you place). Margins
  are **`patch_margin_left/top/right/bottom`** (`int`, px); `axis_stretch_horizontal/vertical` pick
  tile vs stretch on the edges.
- **`StyleBoxTexture`** — a *resource* fed to a Control's theme (a Button's `normal`/`hover`/
  `pressed`, a Panel's `panel`), so the widget draws itself skinned with correct content padding.
  Margins are **`texture_margin_left/…`** (`float`); `set_texture_margin_all(n)` sets all four.

Use `NinePatchRect` for a decorative frame; `StyleBoxTexture` to skin an interactive widget.
`theme.set_stylebox` only builds a flat `StyleBoxFlat`, so apply a textured one in script:
```gdscript
var sb := StyleBoxTexture.new()
sb.texture = load("res://ui/panel.png")
sb.set_texture_margin_all(12.0)                       # the 9-slice border, px
$Panel.add_theme_stylebox_override("panel", sb)       # or a Button's "normal"/"hover"/"pressed"
```

## Font pipeline

A `.ttf`/`.otf` dropped in the project **auto-imports as a `FontFile`** — reference its `res://` path
directly. Set it as a `Theme`'s `default_font` (+ `default_font_size`), or per control:
```gdscript
var f := load("res://ui/Inter.ttf")                   # FontFile
$Title.add_theme_font_override("font", f)             # one control
menu_theme.default_font = f                            # every Control under this Theme
menu_theme.default_font_size = 20
```
`SystemFont` pulls from the OS with a fallback chain (`font_names = ["Segoe UI", "Arial"]`,
`allow_system_fallback = true`) for glyphs a bundled font lacks. For weight/spacing/italic off one
base file, `FontVariation` — its axis-pinning and letter-spacing traps are in `ui-polish-2d.md`
("Typography facts"); don't re-solve them. Bulk theme sizing: `theme create --default-font-size 18` /
`theme set-font-size --node-path X --name font_size --size 24`.

## GraphEdit family (when a game needs a node editor)

`GraphEdit` + `GraphNode` build in-game/tool **node graphs** — a skill-tree builder, dialogue
debugger, visual crafting bench. Use it only when the game truly edits a graph; a static skill tree
is better as `TextureButton`s + `Line2D`s. `GraphEdit` doesn't connect wires itself — it emits
`connection_request(from, from_port, to, to_port)` and you decide, calling `connect_node(from,
from_port, to, to_port)` to accept the wire (`disconnection_request` is the tear-down half). Each
`GraphNode`'s ports come from **slots**: `set_slot(idx, enable_left, type_left, color_left,
enable_right, type_right, color_right)` turns a child row into an input (left) / output (right) port.

## VideoStreamPlayer — cutscenes & attract screens

`VideoStreamPlayer` is a `Control` that plays a `VideoStream`: set `stream`, call `play()`, react to
`finished`. The caveat: **Godot ships only the Theora codec** (`.ogv` → `VideoStreamTheora`) — no
MP4/H.264 out of the box, so transcode to `.ogv` (or add a GDExtension decoder).
```gdscript
$Intro.finished.connect(func(): get_tree().change_scene_to_file("res://ui/main_menu.tscn"))
$Intro.play()                                          # set autoplay + loop for an attract loop
```

## VirtualJoystick — on-screen touch stick

`VirtualJoystick` is a `Control` **in the running build's ClassDB** (it's engine-level, not a project
addon — verified: no plugin registers it here). It's newer than most training data and builds can
differ, so confirm with `engine class-info --class VirtualJoystick` before relying on it; if absent,
fall back to the Control-stick pattern in `mobile-touch.md`. It drives four InputMap actions, so
gameplay reads it as ordinary `Input.get_vector(...)`:
- Actions (`StringName`, point at your movement actions): `action_left/right/up/down`.
- Shape/feel: `joystick_mode`, `visibility_mode`, `joystick_size`, `tip_size`, `deadzone_ratio`, `clampzone_ratio`, `initial_offset_ratio`.
- Signals: `pressed`, `tapped`, `released(input_vector)`, `flicked(input_vector)`, `flick_canceled`.

## Checklist

- Layout by containers anchored `full_rect`, never offsets; `grab_focus()` a control on open.
- Pause = `get_tree().paused` + a `PROCESS_MODE_ALWAYS` `CanvasLayer` overlay; Quit behind a `ConfirmationDialog`.
- Right widget per setting, read off its signal; volumes through `linear_to_db`.
- Persist to `user://settings.cfg` via `ConfigFile`; one autoload applies on boot before first draw.
- Remaps edit `InputMap` at runtime and persist `physical_keycode` ints; `input_map` ships defaults.
- Display via `DisplayServer` (mode/vsync/size); content scale via `project set-setting display/window/stretch/*`.
- Couch test: reachable + triggerable by `ui_*` actions alone (verify via `input action` + `runtime get`).
- 9-slice: `NinePatchRect.patch_margin_*` (int) vs `StyleBoxTexture.texture_margin_*` (float) — don't cross them.
- Motion/transitions → `ui-polish-2d.md`; product-shell (boot/splash, settings-as-registration, a11y tab) → `narrative-game-patterns.md`.
