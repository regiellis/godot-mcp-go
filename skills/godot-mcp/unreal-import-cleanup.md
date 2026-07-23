# Cleaning up an Unreal → Godot scene export

When a scene comes across from Unreal via an exporter (e.g. **UnrealToGodot**), it renders — but it arrives with a layer of Unreal-isms that look wrong in Godot: a washed-out image, editor-only meshes scattered through the tree, light values in the wrong units, and import metadata that points at paths that no longer exist. The `cleanup` group fixes the four that matter, and this doc is the **order of operations** plus the reasoning, so you fix causes instead of chasing symptoms.

Every recipe below was driven against a real export (a Rail Bridge fishing scene) on the live 4.7 editor. The group is **exporter-agnostic and re-runnable** — run it again after a re-export and it converges.

> **Always checkpoint first.** A cleanup pass deletes nodes and rewrites resources. Wrap it:
> ```
> godot-mcp authoring checkpoint --action capture --label pre-cleanup
> # …run the cleanup commands…
> godot-mcp authoring checkpoint --action diff      # see exactly what moved
> ```
> And **`--dry-run` everything first** — every command that mutates supports it.

---

## The order: env → lights → junk → imports

Fix the things that make the scene *look* wrong before the things that make the tree *messy*, because the first screenshot you take after import is misleading until the environment and lights are sane.

1. **Environment** — the single biggest visual win; the exporter stamps one blown-out default everywhere.
2. **Lights** — the second; Unreal's physical light units come across as garbage magnitudes.
3. **Junk geometry** — editor-only meshes that clutter the tree and the viewport.
4. **Imports** — invisible until you try to reimport or move a file; do it last.

---

## 1. The washed-out look — `cleanup.unreal_env`

**Why it's washed out.** The exporter writes one default `WorldEnvironment` and reuses it across scenes. It carries: **Filmic** tonemap (Godot's old default, flatter than UE's look), a **blown `background_intensity`** (the real export had `9716` — and that sky feeds ambient when `ambient_light_source = sky`), every heavy effect on (**SDFGI + SSR + SSAO + glow**), and an **auto-exposure `CameraAttributes`** that adapts to the over-bright sky and crushes everything else. The wash-out is the *combination*, not any single value.

The Environment is a **sub-resource of the tiny `…WorldEnvironment.tscn`** the exporter emits — open *that* scene (not the big level) and fix it there:

```
godot-mcp scene open --path res://…/UnrealGodotWorldEnvironment.tscn
godot-mcp cleanup unreal-env --tonemap agx --background_intensity 2.0 \
    --ssr=false --ssao=false --sdfgi=false --clear_auto_exposure
godot-mcp scene save
```

- `--tonemap agx` — AgX matches UE5's modern filmic look far better than Filmic. (`linear|reinhard|filmic|aces|agx` → 0..4.)
- `--background_intensity` — drop the blown sky. Godot's *own* default is `30000`, so the exported `9716` isn't absurd in isolation; the problem is it driving ambient. Start low (1–5) and raise if the sky reads too dark.
- `--clear_auto_exposure` — removes the `CameraAttributes` that compounds everything. Re-add deliberate exposure later via `camera set_attributes` if you want it.
- Effect toggles are **only applied when you pass them** — omit `--glow` to leave glow as-is.

It reports `before`/`after` for every field it touched. Verify numerically, then take **one** screenshot — not before.

---

## 2. The lighting is too bright — `cleanup.unreal_lights`

**The trap (a real Godot API gotcha).** `light_intensity_lumens` and `light_intensity_lux` are **two inspector aliases for one stored intensity param** — the inspector shows "lux" on a `DirectionalLight3D`, "lumens" on omni/spot, but it's the same number underneath. So when the exporter dumps a UE intensity like `187500000` onto a directional's "lumens", Godot reads it **as lux** and the sun nukes the scene. It is *not* inert.

The magnitudes are garbage — there's no clean unit back-conversion. So don't try to recover them; **normalize**:

```
godot-mcp cleanup unreal-lights --dry-run     # see the plan: intensity_before/after, energy
godot-mcp cleanup unreal-lights               # apply
godot-mcp scene save
```

What it does, per light:
- Resets the intensity store to Godot's daylight/point default (**directional 100000, omni/spot 1000**) — sane in either unit mode.
- **Keeps `light_energy`** (the exporter usually leaves a sane `1.0`, which is a correct full-strength sun in non-physical mode). Override with `--energy N` or scale all lights with `--scale K`.
- **Turns off `use_physical_light_units`** (project setting) by default, so lights drive from `light_energy` like a native Godot project. Pass `--disable_physical_units=false` to keep physical mode and just clean the magnitudes.
- `--normalize_intensity=false` leaves the stored intensity alone (only touches energy / the project setting).

If after env + lights the scene is still off, tune **one** lever at a time (sun `--energy`, then env `--background_intensity`) and re-screenshot.

---

## 3. The junk geometry — `cleanup.strip_junk`

UE drags editor-only meshes into the export: **CineCamera / MatineeCamera bodies** (the literal camera mesh you saw in the viewport), **EnviroDome** sky domes, **WaterInfo** helper meshes, and anything instanced from an `/Engine/Editor…` path. None of it is game content.

```
godot-mcp scene open --path res://…/UnrealGodottestmap.tscn   # the level itself
godot-mcp cleanup strip-junk --dry-run        # list matches + the reason each matched
godot-mcp cleanup strip-junk                  # delete (undoable)
godot-mcp scene save
```

- Matches by node name, instance source basename, and the `engine/editor` source path; BFS from the root, and it **doesn't recurse into a matched subtree** (deleting a camera rig removes its children with it).
- **Decals are kept by default.** A real export can have *thousands* of decal references (this one had ~1760) and many are real surface detail — stripping them is a judgement call. Add `--include-decals` only when you've decided they're UI/debug junk.
- Tune the match set with `--patterns '["CineCam","EnviroDome",…]'` and protect specific nodes with `--keep '["HeroCamera"]'`.

Always `--dry-run` first and read the `reason` on each match before deleting.

---

## 4. Broken import paths — `cleanup.fix_imports`

**The symptom that isn't.** "Textures are wrong" usually *isn't* a color-space bug. On this export every material was a **ShaderMaterial** (zero `StandardMaterial3D`), normal maps imported correctly (`compress/normal_map=1`), and ORM/DIF shared import params because the **shader** decides sRGB-vs-linear, not the importer. The textures **resolve by uid** and render fine.

The real bug is **paths**: every `.import` says `source_file="res://RailBridge/…"` because the exporter assumes the export sits at the **project root** — but if you dropped it into a subfolder (`res://scenes/UnrealGodot…`) that source path no longer exists. Rendering still works (uid), but **reimport-from-source is broken**.

```
godot-mcp cleanup fix-imports --path res://scenes --dry-run   # list source_file mismatches
godot-mcp cleanup fix-imports --path res://scenes --reimport  # rewrite + reimport
```

- For each `*.import` it compares `source_file` to the actual sibling asset and rewrites the mismatched line (a **single-line text replace** — every other import param is preserved), but **only when the real sibling file exists** (the safe case; `actual_exists` in the report).
- **Godot auto-heals `source_file` only when it *reimports*** a file. A freshly-exported project with a valid import cache never reimports, so the wrong paths persist — that's exactly why the command is needed and why it's safe to run.
- The cleaner alternative, if you haven't unzipped yet: **place the export at the project root** the exporter expects (so `res://RailBridge/…` is correct on its own) instead of rewriting. `fix_imports` is the fix for when it's already in the wrong place.

---

## Putting it together

```
godot-mcp authoring checkpoint --action capture --label pre-cleanup

# 1. environment (in the WorldEnvironment sub-scene)
godot-mcp scene open --path res://scenes/UnrealGodotWorldEnvironment.tscn
godot-mcp cleanup unreal-env --tonemap agx --background_intensity 2.0 --ssr=false --sdfgi=false --clear_auto_exposure
godot-mcp scene save

# 2. lights + 3. junk (in the level)
godot-mcp scene open --path res://scenes/UnrealGodottestmap.tscn
godot-mcp cleanup unreal-lights
godot-mcp cleanup strip-junk
godot-mcp scene save

# 4. imports (project-wide)
godot-mcp cleanup fix-imports --path res://scenes --reimport

godot-mcp authoring checkpoint --action diff
```

Then take your screenshot. If the exporter itself is at fault for a value (hardcoded energy, a wrong cone angle, a dropped emission/temperature), that's worth a bug report to the vendor — `cleanup` patches the output, but the cause lives in the exporter.
