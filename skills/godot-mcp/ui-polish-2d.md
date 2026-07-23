# Comp-faithful 2D UI (Godot 4.7+) — tokens, drawn controls, juice, and screen builders

How to take a visual design (HTML/CSS comps, Figma frames) to a polished Godot UI that
actually matches it — and how to build those screens programmatically without the editor
fighting you. Distilled from a shipped-quality game built *with godot-mcp itself* against
pixel comps; every gotcha here was hit for real. Core kit validated headless against 4.7.

## Design tokens: one class, transcribed from the comps

Create a `Design` class (`@tool`, `RefCounted`, all `const`/`static`) as the **single source of
truth for the look** — never hard-code a color or size anywhere else. Discipline that pays:

- **Fix the ratio, scale the constant.** Author comps at one 16:9 size, run the game at another,
  and make every length `comp_px * SCALE`. With `stretch/aspect = keep`, common resolutions
  scale exactly; nothing re-lays-out.
- **Name colors by meaning**, not hue: `FELT`/`RIVAL_FELT`, `NEG_FACE` ("dark = subtracts"),
  `BTN_GHOST_HOVER`. A palette that encodes the rules teaches the player through color.
- **Solve constants, don't pick them** — and write the derivation in the comment: a scrim alpha
  is "the alpha that takes color A to the comp's measured B"; an optical nudge is "measured at
  1:1 over three font sizes." The comment is what stops the next session re-guessing.
- **Deterministic scruff**: hand-authored tilt lists cycled by index (`TILTS[i % n]`), never
  runtime `randf` — random re-rolls on every redraw and jitters.
- **BLEED overscan**: if a `Camera2D` leans or shakes, every full-screen rect must overhang the
  viewport on all sides by the max travel, or impacts expose the clear color at the edges.

Typography facts (all verified live, all silent failures otherwise):
- **`Label.label_settings` disables the theme for that label entirely** — `add_theme_*_override`
  calls on it are ignored without error. Write size/color *into* the settings resource.
- **`LabelSettings` with `shadow_size = 0` is the only crisp (unblurred) text drop shadow.**
- **Shared resources are shared**: a `LabelSettings`/`FontVariation` preloaded by N instances is
  one object — the last writer styles them all. `duplicate()` a private copy per instance,
  keeping the inner font shared (shallow copy) to preserve the glyph cache.
- **Letter-spacing** = a `FontVariation` with `set_spacing(TextServer.SPACING_GLYPH, em * size)`,
  cached per (em, size). Real metrics — not spaces stuffed between characters.
- **Variable fonts render at their axis defaults** (often too light) unless every
  `FontVariation` pins the axes: `{ts.name_to_tag("weight"): 700.0}` via
  `TextServerManager.get_primary_interface()`. A variation does *not* inherit axes from the theme.
- **A `Label` centers its line box, not its ink.** Descender-less text (digits, all-caps) sits
  visibly low. Fix with a measured nudge: shift `offset_top/bottom` by
  `font_size * -0.03 + line_spacing * 0.5` (measure your own font; center on the *face* rect only,
  never face + shadow).

## The drawn-control kit: one shape, one feel float

When comps use flat solids with hard shadows (`box-shadow: 0 Npx 0 c`), **draw the controls
yourself** — `StyleBoxFlat.shadow_size` grows on all four sides and can't express a directional
hard drop. The whole kit is one primitive: a rounded rect *face* over an identical rect offset
`depth` px straight down, drawn in `_draw()`:

```gdscript
var travel := clampf(sink, -depth, depth)
if depth - travel > 0.0:
    draw_style_box(style(drop_color, radius), Rect2(rect.position + Vector2(0, depth), rect.size))
draw_style_box(style(face_color, radius), rect.grow_side(SIDE_TOP, -travel).grow_side(SIDE_BOTTOM, travel))
```

- **`sink` is the entire button feel**: tween it to `depth` on press (face bottoms into the
  shadow), slightly negative on hover (lifts, shadow reads taller), back to 0 on release with
  `TRANS_BACK` so it overshoots. One float, one property tween.
- Cache `StyleBoxFlat`s by (color, radius) — allocation per redraw churns; the palette bounds
  the set.
- Extend **`BaseButton`, not `Button`** — `Button`'s own StyleBox/text machinery fights a drawn
  face. Put the label *on the face node* so press travel moves both with one tween.
- A ring/outline = a larger rounded rect drawn *behind* the face (`rect.grow(w)`, radius + w) —
  that's CSS `box-shadow: 0 0 0 4px` spread. Godot has no dashed border either: stroke the
  rounded-rect perimeter as a polyline and walk dashes along it — and **guard the walk's minimum
  step** (`maxf(step, 0.001)`): float phase math at a boundary can yield a step smaller than an
  ulp, and the loop hangs the editor at 100% CPU. `@export_range` clamps the inspector, not the value.
- **Layout-safe lift and tilt**: write `offset_transform_position/rotation` (visual-only), never
  `position`/`rotation` — a container undoes those on its next sort, while the offset transform
  keeps the layout rect intact so rows stay even. Treat the authored value as the rest pose and
  add your lift on top; overwriting it ratchets `@tool` scenes downward on reload.
- On `NOTIFICATION_RESIZED`, set `pivot_offset = size * 0.5` so pops/squashes punch from center.
- **Game pieces resolve their own colors.** A `Die`/card exposes rule state (`role`, `selected`,
  `zeroed`); a `face_colors()` ladder maps state → palette in priority order. Screens never tint
  pieces — per-screen tinting drifts. Bonus: a concealed piece checks *concealment first*, so a
  bluff can't leak through the fill.

## Juice grammar: which beat gets which effect

Scale feedback to the size of the moment (all fire-and-forget; see `game-patterns.md` for the
tween recipes): **entrances** grow-in staggered by index (`delay = i * 0.05`); **selection** a
small pop (1.18); **placement/impact** squash + small camera shake + tiny zoom punch;
**round/score beats** bigger pop (1.35) + stronger shake + harder zoom punch; **turn handoff**
a few px of camera `offset` lean toward the actor — felt, not seen. Two live-verified camera
caveats: `Camera2D.zoom` above 1.0 pushes IN — never below 1.0 if your board is drawn
viewport-sized (the void shows), and a second tween on the same property **cancels the one
already running** — so "punch then settle" must wait out the hit before issuing the settle, or
the pair collapses to a no-op.

## Programmatic screen builders (editor scripts that emit .tscn)

For comp-faithful screens, a builder script beats forty `node add`/`node set` round trips:
express the screen as a flat list of comp rects, run once via `editor.run_script`
(`--allow-unsafe-editor-io` since it writes the scene), commit the emitted `.tscn`, and the
builder has done its job. The traps — each one a silent failure, all hit live:

- **Stale editor caches**: a long-lived editor caches `PackedScene`s/`Script`s and a rescan does
  *not* evict them. A builder loading a just-edited component gets the OLD version — and a scene
  whose cached script is gone instances as a bare `Control` that swallows every property write.
  Load with `ResourceLoader.load(path, type, ResourceLoader.CACHE_MODE_REPLACE_DEEP)` and
  **assert `get_script() != null`** after instancing.
- **`owner` decides what `PackedScene.pack()` keeps.** Every node you add must get
  `node.owner = root` or it is silently dropped from the saved file.
- **Minimum-size caching outside the tree**: `get_combined_minimum_size()` refreshes on a
  deferred update that never runs for an out-of-tree builder — writing `size` clamps to whatever
  minimum the packed scene *saved*. Keep components' `custom_minimum_size` at zero in their own
  scenes; size instances in the builder (set `custom_minimum_size` + `size`, then verify).
- **Don't combine `PRESET_FULL_RECT` with an explicit `size`** — the anchors and the size
  compound into a rect 2× the board.
- After saving, `EditorInterface.reload_scene_from_path(path)` so the open editor shows the result.

## Checklist

- All colors/sizes live in `Design`; comments carry the derivation of every solved constant.
- `label_settings` set ⇒ theme overrides dead; shared font resources get private duplicates.
- Drawn controls: face + hard drop, `sink` tweened for press/hover/release, `BaseButton` base.
- Lift/tilt through `offset_transform_*`; pivot recentered on resize.
- Pieces own their colors via a priority ladder; concealment outranks everything.
- Juice scaled to the beat; same-property tweens never stacked.
- Builders: `CACHE_MODE_REPLACE_DEEP`, `owner` on every node, explicit sizing, script asserts.
