# 2D lighting (Godot 4.7+) — darkness, lights, shadows, and the escape hatches

The complete 2D lighting stack: the darkness/light/shadow triad, what must be *exempted* from
it, normal-mapped sprites, glow, and the SDF layer. Every recipe driven live against 4.7.1.rc
with the `lighting` commands (screenshot-verified light pool, emissive, and CanvasTexture
shading). Day/night color cycling lives in `topdown-2d.md`; this file is the machinery.

## The triad: darkness → lights → shadows

**1. `CanvasModulate` is the darkness.** It *multiplies* every canvas item's color by its own
(channels are 0–1 fractions, so the product only ever darkens; pure white is identity, pure
black erases everything). One per canvas — `lighting canvas-modulate --color '#26264d'`
creates or updates it. Tint it for mood, not just night: a dusk orange or cave blue is the
same node. **What escapes it**: children of a `CanvasLayer` (HUD), and *nothing else* —
including `Parallax2D`, which IS affected in 4.x. To keep a parallax background out of the
darkness (the Tropical Freeze look), wrap it in a `CanvasLayer` with a negative `layer`.

**2. `PointLight2D` burns holes in it.** A point light renders **nothing without a texture** —
`lighting add-2d --type PointLight2D --range 256 --color '#ffd9a0' --shadows true` generates a
radial-gradient texture so the light shows immediately; swap in an authored texture for shaped
lights (window slats, flashlight cones). `--type DirectionalLight2D` is the 2D sun/moon — flat
directional shading, no texture needed, keep `energy` low as a fill.
**Use the cull masks deliberately**: `range_item_cull_mask` picks which items a light touches
(via each item's `light_mask`), so background lights never bleed onto gameplay sprites and vice
versa — that separation is *legibility*, helping players tell interactive from decorative. Set
masks with `--properties '{"range_item_cull_mask":2}'` / `node.set` on the sprites' `light_mask`.

**3. `LightOccluder2D` casts the shadows.** Darkness + light still gives no shadows until
occluders exist: `lighting occluder-2d --parent-path Wall --size 'Vector2(256,256)'` (or
`--polygon` for a traced shape). Discipline, all from shipped-game practice:
- Shadows are the expensive part. **Not every light needs them** (`--shadows` is per light),
  and `shadow_item_cull_mask` limits which occluders a light even tests. Keep polygons coarse —
  every vertex is math.
- Put occluders in the *prefab scenes* of walls/props so levels compose them for free; for a
  small level, one hand-drawn occluder over the whole layout beats dozens of pieces.
- **TileSet occluders seam**: per-tile occluders tend to leave hairline gaps between tiles that
  break shadow rendering. The pragmatic fix is exactly the previous point — draw one occluder
  polygon over the tile geometry at the level scene.

## Exempt what *emits*: unshaded + additive

Fire, sparks, lasers, muzzle flashes, bright particles must not be darkened — plan for it.
`lighting emissive-2d --node-path Flame --mode unshaded --additive` gives the node a
`CanvasItemMaterial` with `light_mode = UNSHADED` (ignores CanvasModulate and all lights) and
additive blending (brightens what's behind it — right for energy and heat). `--mode light_only`
is the inverse: visible *only* where light hits — the tool for glow-decal layers that a
flashlight reveals (pair with a dedicated light layer so only chosen sources trigger it).

## Normal-mapped sprites: lights get direction

Flat sprites light uniformly; a normal map makes a 2D light *rake* across them.
`lighting normal-map-2d --node-path Wall --normal res://art/wall_n.png [--diffuse ...]
[--specular ... --shininess 0.6]` wraps the sprite's texture in a **`CanvasTexture`**
(diffuse + normal + specular in one resource — any Texture2D slot accepts it). Author normal
maps in your paint tool or generate from height; feeding a non-normal texture shades wrong in
exactly the way you'd expect (verified live). Works on TileSets too via the atlas's texture.

## Glow: real bloom for 2D

The additive trick brightens, but real glow needs HDR: `lighting glow-2d --threshold 0.9
--intensity 1.2` flips `rendering/viewport/hdr_2d` on (persisted to project.godot; **needs an
editor/game restart to take effect**) and adds a `WorldEnvironment` with additive glow. After
that, pixels pushed past the threshold (additive overlaps, `color` values > 1 on lights, HDR
sprites) bloom for free. Without `hdr_2d`, 2D renders in LDR and the glow pass has nothing to
find — that's the gotcha that makes people think 2D glow is broken.

## The SDF layer (cheap fancy effects)

Every `LightOccluder2D` also renders into a global **2D signed distance field**
(`sdf_collision` on the occluder, on by default; our `occluder-2d` exposes `--sdf-collision`).
Any `canvas_item` shader can read it: `texture_sdf(uv)` returns the distance to the nearest
occluder — which is how you get soft contact shadows, cheap ambient occlusion against walls,
GPU particles colliding with level geometry (`GPUParticles2D` collision mode SDF), and
heat-haze that hugs surfaces, all without per-pixel raycasts. Tune the field's range in
project settings (`rendering/2d/sdf/*`) if effects clip.

## Composition rules (from shipped 2D games)

- Decide **per element** which of the three regimes it lives in: lit (default), unshaded
  (emitters, UI-ish overlays), light-only (revealed layers). Mixed regimes on one screen are
  the look.
- Lights direct attention: warm inviting pools along the intended path, red for danger, one
  animated light (flicker via a looping `AnimationPlayer` on `energy`) reads as *alive*.
- Less is more: real-time shadows only where they answer a gameplay or mood question; a busy
  scene with everything shadowed reads *worse*.
- Background and foreground get separate lights via cull masks; the player should never lose
  their character to a background light.

## Verify like an agent

`editor screenshot --save-path <png>` after composing (switch the main screen with
`editor run-script --code 'EditorInterface.set_main_screen_editor("2D")'` first if the 3D tab
is active), and check numerically with `node get` — a light that "does nothing" is usually a
missing texture, a mask mismatch, or `hdr_2d` still off.
