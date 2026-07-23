# Shaders for VFX (4.7) — writing gdshader code and wiring it with the CLI

Authoring `.gdshader` code and wiring it to nodes for game VFX. `game-patterns.md` holds the
**combat-VFX grammar** (the aesthetic recipe — lifetime curves, LUT recolor, erosion, polar remaps);
this file is the **machinery under it**: shader types, the wiring path agents get wrong, uniforms, a
tested 2D VFX kit, and how to *verify shader code compiles* (which `script validate` cannot). Every
snippet was compiled live on 4.7.1.rc via the orphan-`Shader` probe in the last section. `lighting-2d.md`
owns `texture_sdf`/emissive/glow; `environment-art.md` owns decals, fog, and trails.

## The shader types

`shader_type` on line 1 picks the pipeline and the built-ins available. `shader create --path
res://fx/x.gdshader --shader-type <type>` writes a stub for any of them (default `spatial`).

- **`canvas_item`** — 2D. Writes `COLOR` (rgba); reads `TEXTURE`/`UV`/`SCREEN_UV`/`TEXTURE_PIXEL_SIZE`.
  Every 2D sprite, UI, and particle.
- **`spatial`** — 3D. Writes `ALBEDO`/`ALPHA`/`EMISSION`/`NORMAL`… in `fragment()`, moves geometry in
  `vertex()`; reads `NORMAL`/`VIEW`/`VERTEX`/`UV`/`TIME`.
- **`particles`** — the GPU particle system when `ParticleProcessMaterial` runs out. `start()` seeds a
  particle, `process()` steps it; writes `TRANSFORM`/`VELOCITY`/`COLOR`, reads `DELTA`/`LIFETIME`/`INDEX`.
- **`sky`** / **`fog`** — a `Sky`'s shader (`sky()` writes `COLOR`) and a `FogVolume`'s density/color
  (`fog()` writes `DENSITY`/`ALBEDO`). Both niche — procedural skies, volumetric fog.

**Render modes worth knowing** (line 2, `render_mode a, b;` — verified compiling):
- `unshaded` — skip all lighting; the pixel is exactly what you write. Base for emitters, UI, flats.
- `blend_add` — additive (brightens what's behind). `render_mode unshaded, blend_add;` is the glow-ish
  sprite: muzzle flashes, lasers, energy. (2D real bloom needs `hdr_2d` — see `lighting-2d.md`.)
- `cull_disabled` (spatial) — draw back faces too, for flat/thin geometry (grass cards, capes).
  `blend_mix` (default), `blend_sub`, `blend_mul`, and `depth_prepass_alpha` (spatial) round out
  the common set (all compile-verified on 4.7).

## Wiring a shader with the CLI (the part agents get wrong)

A shader is code; a **`ShaderMaterial`** carries it; a node holds the material. Three steps:

```
shader create --path res://fx/hit_flash.gdshader --shader-type canvas_item --content '<code>'
shader assign-material --node-path Sprite --shader-path res://fx/hit_flash.gdshader
shader set-param --node-path Sprite --param flash_amount --value 0.5
```

- `shader assign-material` **builds a fresh `ShaderMaterial`** and picks the slot: `CanvasItem.material`,
  `MeshInstance3D.material_override`, else a `material` property. One per call, so each node gets its own.
- **Uniforms live on the material, not the node.** `shader set-param` calls
  `material.set_shader_parameter(name, value)`; the path is `shader_parameter/<name>` **on the
  `ShaderMaterial`** (verified round-trip on an orphan material). So `node set --property
  shader_parameter/amt` does **nothing** — the node has no such property. Drive the material in a
  script (below), or read back with `shader get-params`.
- After `shader edit`, the addon hot-reloads the cached shader — open materials update, no `editor reload`.

**The driver** — an animated uniform is what makes it VFX. Tween the material's property (the path is
the material's, so tween the material object) from a small script on the node:

```gdscript
func flash() -> void:
	var mat := material as ShaderMaterial
	mat.set_shader_parameter("flash_amount", 1.0)
	create_tween().tween_property(mat, "shader_parameter/flash_amount", 0.0, 0.15)
```

The `set_shader_parameter` *before* the tween is load-bearing, not style: a parameter that has
never been set reads back `null` (the shader's default doesn't count), and a tween whose start
value is `null` **dies silently** — nothing animates, no error. Verified live: tweening a fresh
material did nothing; the same tween after one explicit set ran perfectly. Always seed the
parameter, then tween.

## Uniforms, instance uniforms, and globals

- **`uniform`** — a per-material knob, set from CLI/code/inspector. Hints shape it: `uniform float x
  : hint_range(0.0, 1.0) = 0.2;` (a slider), `uniform vec4 c : source_color;` (a color picker — the
  4.x name for the old `hint_color`), `uniform sampler2D t : filter_nearest, repeat_enable;`. Always
  give a default — an unset uniform reads as zero.
- **`instance uniform`** — per-*node* variation on **one shared material**, no duplication. `instance
  uniform vec4 tint : source_color = vec4(1.0);`, then set it per node via the node's own method:
  `set_instance_shader_parameter("tint", …)` — a method on **both** `GeometryInstance3D` (3D) and
  `CanvasItem` (2D), so instance uniforms are *not* spatial-only in 4.7 (verified); unavailable in
  `particles`/`sky`/`fog`. Reach the setter with `editor run-script`; they don't enumerate in
  `get_shader_uniform_list`.
- **`global uniform`** — one value shared by every shader project-wide (wind, time-of-day, player
  position). **It will not compile until registered**: `global uniform world_wind;` on an
  unregistered global errors `Global uniform 'world_wind' does not exist. Create it in Project
  Settings.` (verified live). Register it *first*, never by hand-editing `project.godot`:

```
shader global-add --name world_wind --type vec4 --value "Color(1,0,0,0)"
shader global-set --name world_wind --value "Color(0,0,1,0)"     # live-updates open shaders
shader global-list
```

  `shader global-*` persists `shader_globals/<name>` into `project.godot` — clear throwaways with `shader global-remove`.

## The standard 2D VFX kit (tested)

Five `canvas_item` shaders that cover most 2D game feel. Each: the code, the attach, the driver.

**Hit-flash** — mix the sprite to white by a uniform (`modulate` only multiplies, so it can't whiten a
textured sprite). Drive `flash_amount` 1→0 with the tween above, fired from a `hurt`/`died` signal.

```glsl
shader_type canvas_item;
uniform vec4 flash_color : source_color = vec4(1.0);
uniform float flash_amount : hint_range(0.0, 1.0) = 0.0;
void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	COLOR = vec4(mix(tex.rgb, flash_color.rgb, flash_amount * tex.a), tex.a);
}
```

**Dissolve** — a noise texture + threshold burns the sprite away with a glowing edge; the threshold
*is* the driver (tween 0→1 to dissolve out).

```glsl
shader_type canvas_item;
uniform sampler2D noise_tex : repeat_enable;
uniform float threshold : hint_range(0.0, 1.0) = 0.0;
uniform float edge_width : hint_range(0.0, 0.2) = 0.05;
uniform vec4 edge_color : source_color = vec4(1.0, 0.6, 0.1, 1.0);
void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float n = texture(noise_tex, UV).r;
	if (n < threshold) { discard; }
	float edge = smoothstep(threshold, threshold + edge_width, n);
	COLOR = vec4(mix(edge_color.rgb, tex.rgb, edge), tex.a);
}
```
Feed the noise: `shader set-param --node-path X --param noise_tex --value res://fx/noise.tres` (a `NoiseTexture2D`).

**Outline** — sample the four neighbors, draw where the sprite is transparent but a neighbor opaque.
`TEXTURE_PIXEL_SIZE` is one texel in UV (no size uniform needed); the sprite region needs transparent
padding or the outline clips.

```glsl
shader_type canvas_item;
uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float thickness : hint_range(0.0, 8.0) = 1.0;
void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	vec2 px = TEXTURE_PIXEL_SIZE * thickness;
	float a = texture(TEXTURE, UV + vec2(px.x, 0.0)).a + texture(TEXTURE, UV - vec2(px.x, 0.0)).a
		+ texture(TEXTURE, UV + vec2(0.0, px.y)).a + texture(TEXTURE, UV - vec2(0.0, px.y)).a;
	float outline = min(a, 1.0) * (1.0 - tex.a);
	COLOR = mix(tex, outline_color, outline);
}
```
Leave static for a selection highlight, or pulse `thickness` with a looping tween.

**UV scroll** — offset UVs by `TIME` for conveyors, water, lava, scrolling backgrounds; `TIME` drives
it for free. The texture must import with **Repeat** on (or `repeat_enable` on a sampler variant).

```glsl
shader_type canvas_item;
uniform vec2 scroll_speed = vec2(0.1, 0.0);
void fragment() {
	vec2 uv = UV + TIME * scroll_speed;
	COLOR = texture(TEXTURE, uv);
}
```

**Palette swap (LUT)** — index a 1-D palette texture by the sprite's red channel; one grayscale sprite
recolors to any palette by swapping the LUT (the 2D cousin of `game-patterns.md`'s grayscale + LUT trick).

```glsl
shader_type canvas_item;
uniform sampler2D palette : filter_nearest;
void fragment() {
	float index = texture(TEXTURE, UV).r;
	vec4 lut = texture(palette, vec2(index, 0.5));
	COLOR = vec4(lut.rgb, texture(TEXTURE, UV).a);
}
```
Point `palette` at a different LUT to swap teams/rarities — no per-variant art.

## 3D quick hits

**Fresnel rim** — a glow at grazing angles (shields, selection, ghosts); `EMISSION` so it ignores lighting.

```glsl
shader_type spatial;
uniform vec4 rim_color : source_color = vec4(0.3, 0.6, 1.0, 1.0);
uniform float rim_power : hint_range(0.0, 8.0) = 3.0;
void fragment() {
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
	EMISSION = rim_color.rgb * fresnel;
}
```

**Vertex sway (wind)** — displace geometry in `vertex()`, masked by height so roots stay planted (grass, foliage, banners).

```glsl
shader_type spatial;
uniform float wind_strength : hint_range(0.0, 1.0) = 0.1;
uniform float wind_speed = 2.0;
void vertex() {
	float mask = 1.0 - UV.y;              // top of the texture sways, bottom is anchored
	VERTEX.x += sin(TIME * wind_speed + VERTEX.y) * wind_strength * mask;
}
```
Feed direction from a `global uniform` (register it first) so every plant sways as one.

**Triplanar** is *not* hand-written here — it is a `StandardMaterial3D` flag set via the
`material` group (`material set … --triplanar`), the supported way to skin greybox without UVs (see
`level-design.md` / `environment-art.md`). Write a `spatial` shader only when a `StandardMaterial3D`
can't express the math.

## Screen-space effects

Read the rendered frame with a **screen-texture sampler** — the 4.x replacement for the removed
`SCREEN_TEXTURE`. Hint a sampler `hint_screen_texture` and sample it at `SCREEN_UV` (verified in `canvas_item`):

```glsl
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float amount : hint_range(0.0, 0.02) = 0.005;
void fragment() {
	vec2 offset = vec2(sin(SCREEN_UV.y * 40.0 + TIME) * amount, 0.0);
	COLOR = texture(screen_tex, SCREEN_UV + offset);   // heat-haze / refraction
}
```
`hint_screen_texture` samplers are auto-bound and do **not** enumerate in `get_shader_uniform_list`
(verified) — don't treat their absence as a compile error.

- **Full-screen effect**: assign the shader to a `ColorRect` on a top `CanvasLayer` stretched to the
  viewport — it post-processes everything below (vignette / grade / chromatic aberration).
- **`BackBufferCopy`**: the screen sampler reads the frame *as of the last backbuffer copy*. To read
  what was drawn **below a node mid-frame** (frosted glass, refraction), put a `BackBufferCopy` above
  it in draw order to snapshot first — the node `game-patterns.md`'s screen-distortion recipe leans on.

## Particles + shaders

When `ParticleProcessMaterial`'s knobs run out (custom attractor fields, non-radial emission,
per-particle logic on `CUSTOM`), drop to a `particles` shader on the emitter's `process_material`:

```glsl
shader_type particles;
uniform float spread = 2.0;
void start() { VELOCITY = vec3(0.0, 4.0, 0.0); }
void process() { VELOCITY.y -= 9.8 * DELTA; }   // custom gravity
```
`INDEX`/`RESTART`/`LIFETIME`/`CUSTOM` give per-particle control; write `TRANSFORM`/`VELOCITY`/`COLOR`.
For authored trails, attractors, and collision, `environment-art.md` covers the node-level path first.

## VisualShader (artist handoff)

`shader create-visual --path res://fx/x.tres --mode canvas_item` writes an **empty `VisualShader`
resource** — a node-graph shader authored in the editor's visual graph, not text. Use it for an artist
who will own and tweak the effect without reading code. **For agents, code shaders are the default** —
they diff, review, and verify (below) cleanly, where a `VisualShader` is opaque; `create-visual` is for the handoff.

## Verify shader code compiles (script validate cannot)

`script validate` compiles **GDScript only** — nothing for `.gdshader`. But shader compile errors
*are* detectable: assigning code to an orphan `Shader` compiles it synchronously, and two signals
report the result (both established live). Run it before attaching — no scene, no file:

```
editor run-script --code 'var s := Shader.new(); s.code = "<SHADER CODE>";
emit(s.get_shader_uniform_list(false).size())'
editor errors
```

1. **`get_shader_uniform_list`** reflects the parsed shader — a shader that declares uniforms but
   fails to compile returns an **empty** list (parse aborts). Include a plain `uniform` canary; a
   count matching your declarations means it compiled, `0` means it failed.
2. **`editor errors`** carries the reason with a line, e.g. `:3 - Unknown identifier 'zzz'` then
   `Shader compilation failed.` — read the *tail*, because **`editor clear-output` does not reset it**
   (it accumulates), so a cleared-then-empty check won't work.

Caveats: `hint_screen_texture` samplers, `instance uniform`s, and `global uniform`s don't count toward
the list (canary on a plain `uniform`). Visual fallback — `assign-material` then `editor`/`runtime
screenshot`, since a shader that compiles but looks wrong only shows on screen.

## Common mistakes

- **Tweening a never-set parameter.** `tween_property(mat, "shader_parameter/x", …)` starts from
  the current value — which is `null` until the parameter has been explicitly set once, and a
  null-start tween dies silently. Seed with `set_shader_parameter` first (verified live).
- **Editing `project.godot` for global uniforms.** Use `shader global-add`/`global-set` — a `global
  uniform` won't compile until the global is registered (verified error above). Same for setting a
  uniform via `node set --property shader_parameter/x`: it's a *material* property, so use `shader set-param`.
- **`uniform` vs `varying`.** `uniform` = a knob set from outside (constant across the draw);
  `varying` = a value passed **vertex → fragment**, interpolated per pixel. Using a uniform to move
  data between stages is the classic mix-up.
- **Forgetting the screen sampler.** No `hint_screen_texture` sampler means no frame to read; `SCREEN_UV`
  alone is just coordinates.
- **Shared `.tres` material across instances.** A uniform set on a shared `ShaderMaterial` changes
  *every* node using it — `duplicate()` it or use an `instance uniform`. (`assign-material` already
  gives each node its own; this bites when you `load` one onto many.)
- **`COLOR` vs `ALBEDO`.** `canvas_item` writes `COLOR` (rgba); `spatial` writes `ALBEDO` (rgb) +
  `ALPHA`; `particles` writes `TRANSFORM`/`VELOCITY`/`COLOR`. Copying a snippet across types fails on
  the wrong output name — check `shader_type` first.
