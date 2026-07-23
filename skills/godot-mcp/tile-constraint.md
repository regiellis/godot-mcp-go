# Constraint tile-assembly — the *other* procedural generation

There are **two families** of procedural generation, and they solve different problems. Reach for the right one:

| | **Point-scatter** (`pcg`, `scatter`) | **Constraint tile-assembly** (`wfc`, `gridmap`, `mesh`) |
|---|---|---|
| Question | "Put N things over a surface" | "Assemble handmade modules so neighbours fit" |
| Output | Instances (trees, rocks, debris) on terrain | A coherent built structure (towns, dungeons, terrain tiles) |
| Driver | Sample → filter → place | Neighbour constraints decide each cell's module + rotation |
| Examples | Foliage, set dressing, crowds | Townscaper, Bad North, dungeon layouts |

This file is the buildable playbook for the **second** family — the technique from Oscar Stålberg's "How One Guy FIXED Procedural Generation". The first family lives in `level-design.md`/`environment-art.md`.

Every recipe below was driven against the live 4.7 editor. Set up a GridMap first (`node add --type GridMap --parent . --name Grid`); paint with item ids, then assign a real MeshLibrary (`gridmap meshlibrary_from_scene` → `node set mesh_library`) once the logic works.

---

## 1. The dual-grid fix — type corners, not cells

The naive approach types whole cells (land or water), then each cell needs a mesh based on its 4 neighbours — 2⁸ = 256 cases, and shared corners between cells fight over whether they're convex or concave.

**The fix:** type the grid's **corners** instead. Each cell reads its own 4 corners (2⁴ = 16 configs), which collapse **under rotation** to just **6 distinct tiles**. Modeling corners *inside* a tile kills the convex/concave conflict for free.

Get the canonical table — author one mesh per tile in its `steps=0` orientation:

```
godot-mcp wfc case_table --states 2
# → 6 tiles: empty, outer_corner, edge, diagonal, inner_corner, full
#   + a mapping from every 4-corner config to {tile, rotation steps}
```

**Build a dual-grid island:** paint a per-corner type field (1 = land, 0 = water), then solve. Corners are addressed in corner space; a main cell at (cx,cz) owns corners (cx,cz),(cx+1,cz),(cx+1,cz+1),(cx,cz+1).

```
# water everywhere, then a land blob in the middle
godot-mcp wfc set-corner --node-path Grid --from "0,0" --to "8,8" --state 0
godot-mcp wfc set-corner --node-path Grid --from "2,2" --to "6,6" --state 1

# map each canonical tile -> a MeshLibrary item id (-1 = place nothing), then solve
godot-mcp wfc solve-dual --node-path Grid \
  --rules '{"0":-1,"1":11,"2":12,"3":13,"4":14,"5":15}'
# → sets each cell to the right tile + GridMap orientation (rotation handled for you)
```

Notes that save debugging:
- GridMap orientations are the 24 **proper** rotations — no reflections — which is *why* dual-grid canonicalization is rotation-only (and why binary gives exactly 6 tiles). Author meshes to the documented winding (SW,SE,NE,NW, CCW from above); if a tile faces the wrong way, add `--cw` to flip the rotation direction rather than re-modeling.
- `set_corner` stores the field as GridMap metadata, so you can paint incrementally (the click-to-toggle workflow) and re-solve. Or pass a whole field inline with `solve_dual --corners '{"x,z":state,…}'`.

## 2. Kill repetition with variant buckets

Author several mesh variants for a tile, hand them all to the solver, and identical-looking neighbours stop forming. The pick is a deterministic `(cell, seed)` hash, so re-runs converge.

```
# a tile id in the rules can be an ARRAY of variants:
godot-mcp wfc solve-dual --node-path Grid --seed 7 \
  --rules '{"0":-1,"1":11,"2":[20,21,22],"4":40,"5":[30,31]}'

# or paint a single cell from a candidate set directly:
godot-mcp gridmap set-cell-variant --node-path Grid --cell "Vector3i(4,0,4)" \
  --variants '[20,21,22]' --seed 7
```

## 3. Full-auto layouts — Wave Function Collapse

When you don't want to paint corners by hand, **learn** the rules from a small authored example and let WFC fill a region. This is the "simple tiled model": author a few cells showing what may touch what, then collapse.

**Build:** author an example (here a water│sand│grass gradient where water never touches grass), learn its adjacency, collapse a fresh region.

```
# author the example on a second GridMap
godot-mcp gridmap fill --node-path Example --from "0,0,0" --to "1,0,5" --item 1   # water
godot-mcp gridmap fill --node-path Example --from "2,0,0" --to "3,0,5" --item 2   # sand
godot-mcp gridmap fill --node-path Example --from "4,0,0" --to "5,0,5" --item 3   # grass

# learn adjacency + weights → a rules file
godot-mcp wfc rules-from-example --node-path Example --output-path res://rules.json

# collapse an 8×8 region (single layer); seed makes it reproducible
godot-mcp wfc collapse --node-path Grid --from "Vector3i(0,0,0)" --to "Vector3i(7,0,7)" \
  --rules-path res://rules.json --seed 5 --respect-existing=false
```

The payoff is **mixed constraints**: pre-paint anchor cells and collapse around them — the solver bridges them legally.

```
godot-mcp gridmap fill --node-path Grid --from "0,0,0" --to "0,0,5" --item 1   # water wall
godot-mcp gridmap fill --node-path Grid --from "6,0,0" --to "6,0,5" --item 3   # grass wall
godot-mcp wfc collapse --node-path Grid --from "Vector3i(0,0,0)" --to "Vector3i(6,0,5)" \
  --rules-path res://rules.json --seed 5
# → existing cells are pinned; the solver fills the gap with sand:  1 2 2 2 2 2 3
```

- `collapse` is single-layer (`from.y == to.y`) and **retries** on contradiction (`--max_retries`, default 12). A persistent contradiction means the example can't tile that region — loosen it or add tiles.
- `--respect-existing` (default true) and `--fixed '{"x,z":item}'` are how player/agent edits constrain the solve. Pass `--respect-existing=false` (and `gridmap clear` first) for a fresh unconstrained fill.

## 4. Special pieces — the Townscaper moment

A "special piece" is a multi-cell pattern that, when it appears, gets swapped for something bespoke (4 grass cells touching → a fountain). The match is rotation-aware, and matched cells are consumed so pieces never overlap.

```
# replace every 2×2 of item 5 with a special piece (10) at the origin, clearing the rest
godot-mcp wfc match-pattern --node-path Grid \
  --pattern '{"match":{"0,0":5,"1,0":5,"0,1":5,"1,1":5},"replace":{"0,0":10,"1,0":-1,"0,1":-1,"1,1":-1}}'
```

In `match`, item `-1` means "require empty"; in `replace`, `-1` clears the cell. `--rotate` (default on) tries all 4 orientations and orients the placed piece to match; `--limit` caps placements.

## 5. Organic, non-grid layouts

A square grid reads as a grid. For the Townscaper "irregular but tileable" look, generate an all-quad mesh from a jittered triangular lattice (random triangle-pair merge → subdivide-to-quads → relax).

```
godot-mcp wfc stalberg-grid --width 8 --depth 8 --seed 1 \
  --relax-iterations 12 --emit markers --name Town
# → quad corner lists (and Marker3D nodes at each quad centre to see the layout)
```

Tune with `--jitter` (off-grid push), `--relax-iterations` (smoothing; boundary stays fixed), `--spacing`. The relaxation primitive is also exposed standalone — `pcg relax --points … --edges …` — for de-clumping any point set.

**Conform a square module to an irregular cell.** The quads above aren't square, so warp each module to fit: store every vertex as a % of the module's AABB, rebuild from the cell's 8 displaced corners.

```
# handles = 8 AABB corners by bit (x=i&1, y=(i>>1)&1, z=(i>>2)&1);
# bottom face = 0,1,4,5  top = 2,3,6,7. Move corners to the target cell's corners.
godot-mcp mesh deform-lattice --node-path Module \
  --handles '["Vector3(-1,-0.5,-1)","Vector3(1,-0.5,-1)","Vector3(-0.5,0.5,-0.5)","Vector3(0.5,0.5,-0.5)","Vector3(-1,-0.5,1)","Vector3(1,-0.5,1)","Vector3(-0.5,0.5,0.5)","Vector3(0.5,0.5,0.5)"]'
# normals are recomputed from the deformed faces. --mesh-path saves a reusable .mesh.
```

---

## The shape of a build

Constraint tile-assembly composes, like the rest of the toolset — your command sequence **is** the generator:

1. **Kit** — author modules in the editor (or `csg` blockouts → `csg bake`), `gridmap meshlibrary_from_scene` → assign with `node set mesh_library`.
2. **Logic** — paint item ids and run `wfc solve_dual` / `collapse` until the topology is right (read it back with `gridmap get_used_cells`, not a screenshot).
3. **Variety** — variant buckets + `match_pattern` for special pieces.
4. **Organic** — `stalberg_grid` for the layout, `mesh deform_lattice` to fit modules to irregular cells.

Wrap risky runs in `authoring checkpoint --action capture` so a bad seed is one `restore` away.
