# Environment art pass — greybox → final, driven from the editor

The pass *after* the level is proven. `level-design.md` says "beautify last" — this is the last:
you run it only once the blockout, game feel, and encounters hold up. It's the **Art Pass** in
`Greybox → Game-Feel → Vertical Slice → Art Pass`.

**Tool boundary.** The CLI doesn't model meshes or paint textures — author those in Blender /
Substance and import (`.glb`, PNG). The CLI **assembles, materials, lights, dresses, and
post-processes** the locked blockout. Everything below is scene/node/property ops. Verify APIs
against the live engine (`engine class-info`) — shapes are durable, signatures evolve.

**The rule that governs the whole pass: don't lose the read.** Re-run the **grayscale** and
**3-second screenshot** tests (`level-design.md`) on the art-passed scene. Final art must keep the
value hierarchy, keep interactables legible, and keep the gameplay lighting guiding the eye. If
beauty broke the read, the *art* is wrong, not the level. And it's **Big → Medium → Small** again:
lighting/atmosphere/materials that set the read → set dressing/decals/hero props → micro-detail.

## Handoff — greybox → art without breaking the layout

The blockout is locked. Change the **look**, keep the **function**: swap grey materials for real
ones in place, swap CSG for imported meshes while keeping the collision shape and `NavigationRegion`
intact, and instance art scenes onto the proven layout. Gameplay volumes (colliders, nav, triggers,
killzones) do **not** move. If the art pass tempts you to resize a room, that's a level decision —
go back to the greybox, don't fix it with art.

**Build — freeze a proven CSG blockout to static geometry.** Once a CSG layout is locked, bake it
to a single `MeshInstance3D` (CSG re-evaluates its whole boolean tree every frame — a static mesh
is far cheaper) with collision baked from the same shapes:
```
csg bake --node-path Level --collision true --mesh_path res://art/level_base.mesh --name LevelBaked
# verify the swap kept function, then drop the live CSG:
csg bake --node-path Level --collision true --replace
```
`--mesh_path` saves a shareable mesh resource; `--replace` removes the source CSG once you've
confirmed the bake. The baked `MeshInstance3D` carries the CSG's `material`, so a material applied
during greybox (`material apply`) survives the freeze. Collision becomes a nested
`StaticBody3D`/`CollisionShape3D` — the gameplay volume the blockout proved, unchanged.

## Materials — PBR the Godot way

`StandardMaterial3D` (its PBR props live on `BaseMaterial3D`): albedo + roughness + metallic +
normal. Most surfaces just need roughness/metallic tuned and albedo/normal textures.

Scalar props in one command:
```
node add-resource --node-path Floor --property material --resource-type StandardMaterial3D \
  --resource-properties '{"albedo_color":"Color(0.4,0.42,0.45,1)","roughness":0.85,"metallic":0.0}'
```
Texture props need loading (`node.set`/`add-resource` can't load a `res://` into a `Texture2D`), so
use `run-script`, reaching the scene via `EditorInterface.get_edited_scene_root()`:
```
editor run-script --code '
var m = StandardMaterial3D.new()
m.albedo_texture = load("res://art/floor_albedo.png")
m.normal_enabled = true
m.normal_texture = load("res://art/floor_normal.png")
m.roughness = 0.85
EditorInterface.get_edited_scene_root().get_node("Floor").material = m'
```
Then `scene save`. **Reuse** materials from a small `.tres` library — don't author a unique material
per node. Reach for a custom shader only when PBR genuinely can't express the surface.

## Lighting for real — realtime vs baked

Greybox lighting was *functional* (`level-design.md`). The art pass picks a global-illumination
strategy; keep the **gameplay read** (bright = go) living *under* the mood.

- **SDFGI** — dynamic, no bake, good for large/outdoor scenes: `Environment.sdfgi_enabled = true`.
- **LightmapGI** — baked, cheapest at runtime, for static scenes: add a `LightmapGI` node, set
  static lights to bake, bake in-editor.
- **VoxelGI** — dynamic-ish, mid cost, indoor.
- `ReflectionProbe` for local reflections; light groups / `light_energy` for control.

## WorldEnvironment & post — restraint

`Environment` post (all verified live): `tonemap_mode`, `glow_enabled`, `ssao_enabled`,
`ssil_enabled`, `ssr_enabled`, `fog_enabled`, `volumetric_fog_enabled`, `adjustment_*`.
```
node add-resource --node-path Env --property environment --resource-type Environment \
  --resource-properties '{"tonemap_mode":4,"glow_enabled":true,"ssao_enabled":true,"fog_enabled":true}'
```
(`tonemap_mode` 3 = ACES, 4 = AgX — confirm with `engine class-info --class Environment`.)
**Add effects one at a time and screenshot.** Post is seasoning, not a meal — bloom hides nothing,
it reveals over-bright mistakes. If a screenshot reads worse with an effect on, cut it.

## Atmosphere & VFX (cheap, high-impact)

`GPUParticles3D` for ambient motes/dust (`one_shot=false`, low rate). `Decal` for grime, signage,
projected AO, puddles — stamped onto existing geometry without new meshes. `FogVolume` for localized
fog/light shafts. A little of each sells the fantasy far past its cost.

**Particles interact with the world via dedicated nodes** (verified live): attractors
(`GPUParticlesAttractorSphere3D/Box/VectorField` — `strength` pulls, negative pushes) and
colliders (`GPUParticlesCollisionBox3D/Sphere/SDF/HeightField` — SDF bakes level geometry so
sparks bounce off walls). Two opt-ins bite silently: the `ParticleProcessMaterial` must set
`collision_mode` (and `attractor_interaction_enabled`) or the nodes do nothing. Godot also adds
**`AreaLight3D`** — a real rectangle emitter (`area_size`, optional `area_texture`) for soft
window/panel light where an OmniLight reads pointy.

**Particle trails** (verified live): set `trail_enabled` + `trail_lifetime` on the
`GPUParticles3D`, then make `draw_pass_1` a trail mesh — `RibbonTrailMesh` (flat streak:
`shape`, `size`, `sections`, `section_length`, `section_segments`) or `TubeTrailMesh`
(volumetric: `radius`, `radial_steps`, `sections`, `section_rings`, `cap_top/bottom`). Both
taper along a `curve` (width/radius profile — ease it to zero for comet tails). This is the
sword-slash / falling-star / tracer look in one node, no shader work.

**3D text as geometry**: `TextMesh` on a `MeshInstance3D` (`text`, `font_size`, `depth` for
extrusion, `pixel_size` for world scale, `curve_step` for outline smoothness) — real,
material-able, shadow-casting text for signage, monuments, logos. `Label3D` (already covered:
billboard flag) stays the pick for floating UI-ish labels; `TextMesh` is for text that belongs
to the *set*.

## Set dressing & kitbashing

A finished level is *composed*, not hand-modeled: instance prop scenes (`scene.instance`) onto the
blockout; build from a modular kit (walls/floors/trims) that snaps together. For repeated props
(grass, rocks, crates, crowds) use `MultiMeshInstance3D` — one draw call for thousands of instances
instead of N nodes.

**Build — procedural scatter (the `pcg` group, Godot's missing PCG).** Don't place set dressing by
hand or with a one-off script — `pcg` runs the whole sample → filter → emit pipeline, seeded so a
run is reproducible and tweakable. *Preview first* (`pcg.sample` mutates nothing, returns cull
stats), then *commit* (`pcg.scatter`):
```
# preview the distribution + see what each filter culls
pcg sample  --on Terrain --count 400 --max_slope 25 --min_height 2 --noise_threshold 0.55 --seed 7
# rocks on flat-ish ground above water, blue-noise spaced, conformed to the surface, as one draw call
pcg scatter --on Terrain --poisson --radius 1.5 --max_slope 25 --min_height 2 \
  --align_to_normal true --yaw_random true --scale_min 0.7 --scale_max 1.4 \
  --emit multimesh --mesh_from RockProto --seed 7 --name Rocks
# hero props that need real nodes (colliders/scripts) → scene instances instead, capped
pcg scatter --on Terrain --count 30 --noise_threshold 0.7 --emit scene --scene res://props/bush.tscn --seed 7
# fence posts evenly along a road spline
pcg scatter --along Road --spacing 3 --emit multimesh --mesh_from PostProto --seed 1
```
Filters: `--min_slope/--max_slope` (degrees from up — needs colliders so the down-ray reads a
normal), `--min_height/--max_height` (world Y band), `--noise_threshold` (a FastNoiseLite mask for
natural clumping/patches). `--emit multimesh` for thousands (one draw call, no node cost);
`--emit scene` when each instance needs to be a real node. Wrap a big generation in
`authoring checkpoint --action capture` first so you can `restore` if you don't like the seed.

## Ship-it — performance (env-art / tech-art, **not** level design)

This is the optimization layer. It's real and necessary, but it's environment/tech-art, not level
design (`level-design.md` draws that line) — do it last, once the look is locked.

- **Occlusion:** `OccluderInstance3D` (bake occluders) so geometry behind walls isn't drawn.
- **LOD / culling:** `GeometryInstance3D.visibility_range_begin`/`visibility_range_end` to fade or
  hide by distance; `lod_bias` for mesh LODs.
- **Instancing:** `MultiMeshInstance3D` for repeats; watch draw-call counts.

## 2D / 2.5D art pass

Replace `ColorRect`/`Polygon2D` blockouts with **tilesets + autotiling** (`tilemap.*`). Put real art
on the parallax layers (`Parallax2D` / `CanvasLayer`). Add 2D **normal maps** + `PointLight2D` /
`DirectionalLight2D` for lit sprites, and `CanvasModulate` for a global tint / time-of-day. The
value-hierarchy and grayscale rules from `level-design.md` apply unchanged.

**Parallax2D recipe** (one node per depth layer, sprites as children; APIs verified live):
`scroll_scale` is the depth — `(0.2, 1.0)` drifts slowly (far), `>1` moves faster than the
camera (foreground); `repeat_size` + `repeat_times` tile the art infinitely along an axis;
`autoscroll` drifts it with no camera motion (clouds, the shmup intro loop). It *is* affected
by `CanvasModulate` — wrap in a low-`layer` `CanvasLayer` to exempt it (see `lighting-2d.md`).

**2D instancing**: thousands of repeated sprites (grass blades, rubble, stars) in **one draw
call** via `MultiMeshInstance2D` — a `MultiMesh` with `transform_format = TRANSFORM_2D`,
`instance_count`, and `set_instance_transform_2d` per instance (seed the transforms from an
`editor run-script` loop; the 3D `scatter` group has no 2D twin). Individual nodes at that
count would drown the canvas renderer.

### Pixel-art projects: the setup that keeps them crisp

Four project settings decide whether pixel art reads sharp or smeared (keys verified live;
set via `project set-setting`):
- `rendering/textures/canvas_textures/default_texture_filter` → **Nearest** (0). Any linear
  filter softens every pixel edge project-wide.
- `display/window/size/viewport_width/height` → a low **native resolution**: 640×360 reads
  SNES/Genesis-density, 320×180 reads NES-chunky — a *style* choice, not just technical; both
  divide 1080p/4K exactly. `window_width/height_override` sizes the desktop window
  independently, so you author low-res but display big.
- `display/window/stretch/mode` = `canvas_items`, `aspect` = `keep`, and — the load-bearing
  one — `stretch/scale_mode` = **`integer`**: whole-number multiples only, which is what
  actually prevents blur and shimmer at arbitrary window sizes.

Authoring notes from working pixel devs: low-res is not low-effort — each pixel carries more
weight, and sloppy placement reads faster as bad art. The **tileset vs painted-scene**
tradeoff is real: tilesets (autotiling, reuse, `tilemap.*`) iterate faster and stay
consistent; painting a whole level strip as one layered image (sliced to parallax layers)
is more expressive for set-piece levels but forfeits reuse. Brush-painted art *over* a
low-res grid (pixel-snapping only the player/enemies) reads closer to CRT-era games than
hard nearest-neighbor everything.

### The paper-diorama technique (2D art staged in real 3D)

A shipped commercial Godot VN gets its signature look by putting flat 2D art on **textured quads
in true 3D space** and shooting it with a real `Camera3D` — parallax, DoF, and camera moves come
free from the perspective projection, while the art stays hand-drawn. Pattern (validated live):

- A `Paper3D` node (`MeshInstance3D` + `@tool`) builds a 4-vert `ArrayMesh` quad sized
  `texture_size * pixel_size`, with exports for centered/offset/flip/modulate/emission. Like
  `Sprite3D`, but with your own spatial shader — smooth filtering, emission maps, optional
  Y-billboarding — instead of `Sprite3D`'s fixed material. Transparent art uses a two-pass
  material (`transparent` pass with an opaque `next_pass`) so depth still writes.
- The animated variant drives the quad from `SpriteFrames` (plus parallel normal/emission frame
  sets), with per-animation offsets/flips, cross-node **sync groups** (background characters
  stepping in time), and **frame invokers** — callbacks bound to specific frames (footstep
  sounds land exactly on the contact frame).
- Layer the scene like a theatre set: background/mid/foreground paper planes at real depths;
  the camera dollies rather than the layers scrolling.
- **Camera-to-camera crossfades** without cutting: duplicate the target `Camera3D` into a
  one-shot `SubViewport` (`UPDATE_ONCE`), `await RenderingServer.frame_post_draw`, capture
  `viewport.get_texture().get_image()` to an `ImageTexture`, then shader-blend the two frames
  on a full-screen rect. While a captured frame covers the screen, set
  `get_viewport().disable_3d = true` — the 3D world stops rendering for free.

## Checklist

- Layout, collision, and nav **unchanged** from the locked greybox — only the *look* changed.
- Materials reused from a library (not unique-per-node); roughness/metallic tuned; normals where
  they matter.
- GI chosen deliberately (SDFGI dynamic / LightmapGI baked-static / VoxelGI indoor); gameplay read
  preserved under the mood.
- Post added sparingly, one effect at a time, each screenshot-checked; not masking errors.
- Repeated props via `MultiMeshInstance3D`; occlusion + LOD as the final perf pass.
- **Grayscale + 3-second tests still pass** — beauty didn't kill legibility.
