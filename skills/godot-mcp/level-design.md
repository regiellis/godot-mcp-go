# Level design & spatial communication (4.7) — building blockouts with godot-mcp

How to lay out a *space* that teaches the player what to do without a word of text — and how
to **build it** as a playable blockout with the CLI. Distilled from level-design talks aimed at
**solo / small-team** devs (you do both the design and the art, so do them in that order). The
other craft files cover entities and systems; this one covers **the space between them**.

These are **patterns to draw from, not a checklist to run end-to-end** — pick the ones that serve
the experience you're after. Each pairs an idea with a **Build:** recipe (real `node`/`scene`
commands); treat the commands as a starting point and adapt them. Verify APIs against the live
engine (`engine class-info --class CSGBox3D`) — shapes are stable, signatures evolve. A level only
tells the truth when you **play it**: build rough geometry → `scene play` → walk it → adjust.

## A level is four things at once

Design for all four — most weak levels are "a place with some art in it" and nothing else:

- **A place** — a coherent space the player reads as somewhere real-enough.
- **An experience** — an *emotional sequence* you pace: encounter → quiet → encounter → puzzle.
  Structure the player's activities; don't scatter them.
- **A goal** — the player knows what they're trying to do. Make it obvious, then **hide and
  re-reveal** it (see Tension and release).
- **A language** — consistent with itself and with conventions players know. Break the pattern
  carelessly and the level becomes illegible.

There are **no universal rules**, only truths of **human psychology**. "Players flow like water"
(they probe every nook for fear of missing a secret, turning in smooth curves not 90° angles)
only holds *if the game rewards exploring* — teach players the corners are empty and they stop.
So **make your own rules** and tie each to a **player-experience goal** (achievement,
legibility, surprise, world-building). Abstract genres (sci-fi, dungeon) are *practical* because
they relax real-world plausibility — fewer language constraints to satisfy.

## Process & strategy — graybox first, plan the whole, finish level one last

Level design is **functionality and gameplay**; environmental art is coherence and looks;
optimization (culling, streaming) is neither. Keep them in separate stages so you don't make
work for yourself:

- **Keep iteration cycles short — the prime directive.** Anything that slows down changing the
  level before you *know* it's good is the enemy. Beautify before playtesting and every later
  change fights a pile of art. In practice: **build blockouts from CSG primitives colored only
  by the greybox color language** (flat albedo, no textures), and don't `scene.instance`
  finished art until the layout is proven.
- **Experiment to find the requirements first.** Prototype the core mechanic, learn what a level
  must *support* (jump height, sightline distances, encounter size), then design levels.
- **Plan all levels up front** as a content grid — for each level note: art/environment variant
  (so it isn't monotonous), dominant theme, where it sits on the **difficulty curve**, and which
  mechanic it introduces. Keep the grid as a doc/comment before you build scenes; it gives you
  the whole game's flow and pacing at a glance.
- **Build the middle first; finish the first level last** (Romero; Mario's World 1) — you can't
  design onboarding until you know what you're onboarding *into*. So build `blockout_03` before
  `blockout_01`.
- **Beautiful corner.** To nail art style + asset pipeline without polishing everything, fully
  art-up **one tiny slice** (one room) as a target; the rest stays graybox.
- **Budget motivation.** Solo work needs rewarding tasks to sustain it — but keep ~2–3
  game-needs per 1 done-for-fun, and if the fun thing is premature polish that slows iteration,
  do something else for fun. A game needs **both** messy experimentation and a structured plan.

## Big → Medium → Small — solve the expensive problems first

A **risk-reduction workflow**, not just an art-composition principle: build in three passes, and at
each stage ask **"what's the biggest thing that could still invalidate this work?"** Only invest in
a pass once the larger decisions above it are stable. Don't model the coffee cup while cover
placement might still move; don't place the desk while the room might resize; don't build the
hospital while the layout might change. The cup is never the problem — the layout is.

- **Big (macro) — answer the gameplay questions.** Room sizes, combat spaces, choke points, cover,
  sight lines, routes, spawns, the critical path. The level is literally cube-room / cube-hallway /
  cube-cover. Question: *"is it fun?"* — not *"does it look like a hospital?"*
- **Medium (structure) — define the space.** What makes it read as the place: doors, windows,
  stairs, elevators, desks, major machinery, bridges. Question: *"does this feel like a hospital?"* —
  while still validating gameplay.
- **Small (detail) — only after the level works.** Clutter, props, signage, decals, monitors,
  particles. Question: *"is it believable?"*

This is the shape behind every staged process in this doc:
- **2.5D layout:** Big = platforms/terrain/routes → Medium = doors/bridges/trees/interactables →
  Small = signs/lamps/wires/debris/particles.
- **Lighting** (functional → gameplay → mood) and **presentation** (readability → feedback →
  cinematic lighting → atmosphere) are Big→Medium→Small for their domains.
- **Game feel** tiers too (see `game-patterns.md`): Big feel (movement/jump/camera) before Medium
  (landing/shake/recoil) before Small (dust/sparks/UI flourish) — if movement feels bad, nobody
  cares about the shell-casing effect.

Most indie projects stall by **jumping straight to Small** — detailing a space (or a juice effect)
whose larger decisions aren't locked, then rebuilding when a playtest moves a wall.

## Greybox the AI too (Big → Medium → Small)

Don't pair a proven level with a dumb walk-at-player enemy and discover months later it breaks under
real AI. Greybox the AI alongside the level. The guiding idea: **greybox AI tests the level, it
doesn't win the game** — if it can reliably break your pathing / cover / sight lines / encounter
flow, it's doing its job; if it stands around, you're testing half the game.

- **Big AI — archetypes as questions.** Each is a coloured capsule (`CharacterBody2D/3D` +
  `NavigationAgent`, one material per type), not a finished enemy: **Rusher** (combat space big
  enough? cover meaningful?), **Flanker** (enough routes? too linear?), **Sniper** (are sight lines
  interesting?), **Defender** (does objective play work?). Build the navmesh with the `navigation`
  group; drive the pawn with a `NavigationAgent`.
- **Medium AI — tactical.** Cover use, retreat, grouping, search/patrol. Tests "does this space
  support *intelligent* behaviour?" — a room that works against Rushers often fails the moment
  enemies use cover.
- **Small AI — personality.** Voice, animation, gestures, abilities. Immersion, not gameplay proof — last.

**Reusable AI test pawn:** one capsule with an `@export` mode enum (Rush / Flee / Patrol / Defend /
Flank / Wander) switchable in the inspector, and **loud debug visuals** (target, nav path, aggro
radius, vision cone, chosen cover). Greybox AI should be *extremely* visible. For stakeholder demos,
build **fake-smart** AI, not smart AI — an enemy that visibly takes cover, peeks, and reacts reads
as smarter than a sophisticated AI you can't observe. Genre shorthand: puzzle — Big: reach the goal?
Medium: avoid obstacles? Small: look smart? Narrative — Big: move through scenes? Medium: react to
state? Small: facial/idle micro-behaviour.

## Presentation stages — designer vs stakeholder greybox

There are **two greyboxes**, answering different questions:

- **Designer greybox** — internal, ugly, proves the *mechanics* ("does the jump work?"). Everything
  else in this doc serves this one.
- **Stakeholder greybox** — shown to a publisher/investor/non-designer to answer "is this *fun*?".
  They evaluate what they see (most people can't picture the finished game from grey cubes), so it
  has to *feel* alive — a mechanically perfect prototype looks dead if nothing responds to the player.

This **refines "beautify last," it doesn't contradict it.** The mistake isn't adding juice; it's
adding **art-specific** juice too early. **Game feel is its own pass, before art** — and it's cheap
and reversible (it works on cubes), so unlike art it *doesn't* slow iteration:
```
Greybox  ->  Game-Feel Pass  ->  Vertical Slice  ->  Art Pass
```
(The **Art Pass** — PBR materials, real lighting, post, set dressing — is its own craft: see
`environment-art.md`. It must preserve the read you built here: re-run the grayscale + 3-second
tests on the finished scene, and never move locked geometry to fix a look.)

Add presentation in four layers, in order — each is worth doing only once the prior holds:

1. **Readability (required)** — clear playable surfaces, layer separation, visible character &
   objectives. Without it nothing else matters (the color language + 2.5D value work below).
2. **Feedback / juice (required for stakeholders)** — *something happens immediately* on move / jump
   / land / hit / collect / interact: dust puff, squash-&-stretch, landing impact, button depress,
   collect pop + particle + sound. None of it needs final art — cubes feel good long before they look good.
3. **Cinematic lighting (limited)** — light the *actor, not the environment* (theatre stage): bright
   gameplay plane, dark background, subtle rim on the player. This is Stage 2 of Greybox lighting
   below — **not** the full mood pass.
4. **Atmosphere (optional)** — just enough to sell the fantasy: a few floating particles + soft
   vignette + ambient loop (puzzle); impact flashes + screen shake + trails (action); light fog +
   depth haze + ambient audio (narrative). Cheap, effective, last.

**Reusable prototype stack** — build once (a `Juice` autoload + a few component scenes) and every
greybox inherits "feels polished on grey cubes": camera damping + screen shake + hitstop; tween
helpers (squash/stretch, scale punch, glow pulse); a screen-flash and a floating-text node;
placeholder SFX + an ambient loop; the key/fill/rim light rig. Build the mechanics the Godot way —
see `game-patterns.md` **"Game feel vs juice"** for the verified recipes (squash/stretch, hit-stop,
screen shake, coyote time/jump buffer) and `gdscript-architecture.md` for the `Juice` autoload-service
pattern. Note the distinction: **game feel** is the control itself (movement code); **juice** is the
fired-on-event feedback — build feel first, juice second.

## Greybox color language — color as information, not art

In a blockout, **color is an information layer**, not decoration: one color = one rule, used
consistently so anyone (you, a playtester, a screenshot) instantly reads what a piece *does*
before any art exists. The exact hues don't matter; the **consistency does**. A workable default
palette (close to common AAA blockout conventions, so it reads to other designers):

| Color | Meaning |
| --- | --- |
| Grey | Static environment (walls, floors — neutral) |
| Blue | Player-accessible / player-controlled |
| Green | Goals, exits, objectives, interactables |
| Yellow / Orange | Traversal: climbable, cover, routes |
| Red | Hazard / danger / failure / enemy |
| Purple | Scripted event / special mechanic |

**Establish this table once at the start of the project** (a `greybox-palette` note) and **never
remap a color mid-project** — if red means "danger" for 50 levels then becomes "collectible,"
players (and you) fight the instinct. Tune the palette to your genre: a puzzle game might use
blue=movable, green=goal, orange=switch, red=invalid-placement. For clean, readable puzzle styles
(Hitman GO, etc.), keep the environment neutral grey and let only the **gameplay pieces** carry
strong color.

**Color a piece (verified recipes):**
```
# 2D — set the node's color directly (ColorRect / Polygon2D):
node set --node-path Hazard --properties '{"color":"Color(1, 0, 0, 1)"}'

# 3D — make a reusable material once, then apply it to any box (CSG, MeshInstance3D, …):
material create --path res://mat/hazard.tres --albedo_color "#ff0000" --roughness 0.9
material apply --node-path Hazard --material_path res://mat/hazard.tres
```
(`material apply` resolves the right slot automatically — CSG shapes get their `material`
property, other `GeometryInstance3D` get `material_override`; force it with `--slot
material|override`. Apply the *same* `.tres` to many boxes to share one material. For a quick
one-off you can still inline a material with `node add-resource --resource-type
StandardMaterial3D`, but `material create`/`apply` is the supported path — and the only one
that can wire **texture maps** and **triplanar**, which `node.set`/`add-resource` can't.)

**Prototype textures (the recommended skin).** Flat albedo reads function but hides *scale and
surface alignment*. A **grid/checker prototype texture** fixes that — the cells let you judge
distances and spot stretched/misaligned faces at a glance (this is why Romero changed texture
when floor height changed). [Kenney's **Prototype Textures**](https://kenney.nl/assets/prototype-textures)
(CC0) are the standard pick and **ship with this tool** — install them into the project once:
```
godot-mcp install-assets --pack kenney_prototype_textures   # -> res://assets/vendor/kenney_prototype_textures/
# --dest <path> to install elsewhere; --list to see bundled packs
```
The pack is **per-color folders** (`PNG/Dark/`, `PNG/Light/` greys, `PNG/Green/`, `PNG/Orange/`,
`PNG/Purple/`, `PNG/Red/`, each `texture_01…13.png`), so the *folder color* carries the function
code and the *grid* carries scale. Map to the palette: Light/Dark→environment, Green→goals,
Orange→traversal, Red→hazard, Purple→special (no blue variant — use Light for standard floors or
tint via `albedo_color`). Keep the bundled `License.txt` alongside it (CC0 requires attribution).

Apply one with **triplanar** tiling so the grid stays square at a fixed world scale even on a
stretched box. `world_triplanar` tiles by world units (so scaling the box doesn't stretch the
grid) and `uv1_scale` sets cell density — two `material` commands, no `run-script` needed:
```
material create --path res://mat/proto_floor.tres \
  --albedo_texture res://assets/vendor/kenney_prototype_textures/PNG/Orange/texture_13.png \
  --triplanar true --world_triplanar true --uv1_scale "Vector3(0.5,0.5,0.5)" \
  --texture_filter nearest          # crisp grid lines; tune uv1_scale = cells per world unit
material apply --node-path Floor --material_path res://mat/proto_floor.tres
```
(`material set --path … --uv1_scale …` re-tunes density on the saved `.tres` without rebuilding
it; `material info --node-path Floor` reads the applied material back to verify.) Then `scene save`.

## Place by anchor, not by parallel constants (read back · raycast · verify)

You can't perceive 3D from one screenshot and you're bad at absolute-coordinate math, so the way
you *place* the blocks below matters as much as which ones. The failure mode: computing every part
of a composite from the same constants (`board_x`, `rim_x = board_x - 1.2`, `net_x = board_x - 1.2`)
— nothing is anchored to what actually landed, so one error floats a piece or sinks it into the
floor, and a single camera angle calls it done. The fix is the same "let the engine tell you" reflex
the `SKILL.md` golden rule preaches, applied to space:

Use the **`spatial` group** — it does the math (3D, meters, global space; returns `"Vector3(…)"` you
feed straight back into `node set --property global_position`):

- **Build composites by chaining off realized bounds.** Place the anchor, `spatial bounds` it, derive
  the next piece from *those* numbers, `bounds` that, and so on (post → board → rim → net):
  ```
  spatial bounds --node-path Post            # -> center/size/min/max of what ACTUALLY landed
  # …compute the board off Post's measured top, place it, then:
  spatial relate --node-path Board --other Post   # center_delta, centered{x,y,z}, gap, overlaps
  ```
  `node set --property position` is **local to the parent** — `spatial align`/`place_on`/`distribute`
  write `global_position` for you. (Under the hood `bounds` is `VisualInstance3D.get_aabb()` ×
  `global_transform`; reach it via `editor run-script` for any shape `spatial` doesn't cover.)
- **Seat props on uneven greybox terrain** (the "Build on uneven terrain" section below) instead of
  hand-computing `y`. Three tiers, cheapest first — climb only when the cheaper one is too coarse:
  ```
  # Tier 1 — flat ground, no colliders needed (mesh-AABB; one height under the footprint):
  spatial place_on --node-path Lamp --surface-from Floor
  # Tier 2 — uneven ground / overhang risk: a footprint bundle of parallel down-rays.
  #   Seats on the HIGHEST contact (never clips), and tells you if it's stable:
  spatial place_on --node-path Crate --samples 3 --conform
  #   -> hits/misses (misses>0 ⇒ part hangs off an edge), unevenness (0=flat), avg_normal;
  #      --conform also tilts the prop to match the slope's normal. Needs use_collision.
  # Tier 3 — exact corner/edge alignment (the scriptable 4.7 vertex-snap analog; no collider):
  spatial snap --node-path Bolt --to Beam --mode vertex   # mover's anchor -> nearest real vertex
  spatial snap --node-path Decal --to Wall --mode face --axes yz   # nearest point on nearest face
  # one-off exact ray hit + normal (orient a prop to a ramp), when you don't want to move it:
  spatial raycast --from "Vector3(4,30,-6)" --to "Vector3(4,-30,-6)"
  ```
  Greybox CSG with `use_collision:true` **registers collision in the editor's physics space, so the
  edit-time Tier-2 bundle and `raycast` work** (verified — not just at runtime). Picking a tier:
  `place_on` (no samples) when the ground is flat; `--samples N` when it's sloped/stepped or a piece
  might overhang (let `misses`/`unevenness` flag a bad seat before a screenshot does); `snap` when you
  need a prop *aligned to actual geometry* (a bolt on a beam corner, trim flush to a wall) rather than
  merely resting on top. A **cone** of rays would be the wrong tool for seating — a cone samples a
  *viewpoint* (line-of-sight); seating samples a *footprint*, which is why Tier 2 fires a parallel
  bundle, not a fan.
- **Mirror, don't rebuild, for symmetric layouts.** Build one verified unit (a hoop, a guard post),
  read its realized `global_position`, then place the twin by negating one axis and flipping the yaw
  (`spatial look_at` or a `node set --property rotation_degrees`) — the math guarantees the symmetry
  you'd otherwise eyeball wrong across two independent builds.
- **Face things with `spatial look_at --target <node>` (or `--point`), never Euler** — hand-computed
  `rotation_degrees` for "aim at" is reliably ~20° off.
- **Verify numerically + from multiple vantages.** `spatial relate` after a placement, `spatial lint
  --check-floating` after a set (catches coincident duplicates and unsupported/sunk pieces); then
  teleport the camera (`editor set-camera`) or player (`runtime set global_position`) to several spots
  and screenshot each. One frame hides the error — this is the placement-side of the **3-second
  screenshot test**.

(`spatial` is the ergonomic layer over these reflective primitives; its design rationale and the
edit-time-vs-runtime physics split are in `docs/spatial-and-discovery-transfer.md`.)

## Blockout building blocks (the recipes every tactic reuses)

Make these once; the tactics below compose them. CSG shapes carry their own collision via
`use_collision` — **no separate `StaticBody3D` + `CollisionShape3D` needed** for static
geometry (confirmed on `CSGShape3D`). Apply the **color language** above (one color per
function) so the space reads at a glance.

**Walkable surface / wall / platform / ramp** — a CSG box that you can stand on and that blocks:
```
node add --type CSGBox3D --name Floor --parent-path .
node set --node-path Floor --properties '{"size":"Vector3(40, 1, 40)","position":"Vector3(0,0,0)","use_collision":true}'
# a wall: thin on one axis, raised; a ramp: rotate it, e.g. "rotation_degrees":"Vector3(0,0,20)"
```

**Goal beacon** — tall, lit, visible from far off (the "lighthouse"):
```
node add --type CSGCylinder3D --name Goal --parent-path .
node set --node-path Goal --properties '{"radius":1.5,"height":20,"position":"Vector3(0,10,-60)"}'
node add --type OmniLight3D --name Beacon --parent-path Goal
node set --node-path Goal/Beacon --properties '{"position":"Vector3(0,12,0)","omni_range":50,"light_energy":4}'
```

**Trigger volume** — fires when the player enters (goal reveals, encounter starts, doors open):
```
node add --type Area3D --name Trigger --parent-path .
node add --type CollisionShape3D --name Col --parent-path Trigger
node add-resource --node-path Trigger/Col --property shape --resource-type BoxShape3D
node set --node-path Trigger/Col --properties '{"position":"Vector3(0,1,0)"}'
node connect --source-path Trigger --signal-name body_entered --target-path <handler> --method-name <fn>
```

**Fatal drop / killzone** — a flat trigger far below the play space that respawns the player:
```
# build a wide Trigger (above) at y=-10, then in its handler:
#   func _on_kill(body): if body.is_in_group("player"): body.global_position = $SpawnPoint.global_position
```
The same node, with its respawn target set to a **lower recovery platform** instead of the
start, becomes a **safety net** (below).

**Attention light** — `OmniLight3D` / `SpotLight3D` over the feature you want noticed (light
raises contrast, which is what actually draws the eye — see Attract attention).

**Animated attractor** — an `AnimationPlayer` rotating a fan or swaying a door; movement pulls
attention (`animation.*` to author the track).

**Label intent** — a `Label3D` reading "LOCKED", "OBJECTIVE", "CLIMBABLE" on a box is legit
blockout communication, not shipped art.

**The loop after any build:**
```
scene play --mode current
runtime screenshot --save-path user://shot.png    # what does the player actually SEE here?
runtime set --node-path Player --properties '{"global_position":"Vector3(0,1,-20)"}'  # teleport to a spot, re-screenshot
editor set-camera ...                              # or frame a specific juncture to judge a sightline
input action --action move_forward --pressed true  # actually DRIVE the character (needs an InputMap action)
```
Note: `input move` is **mouse motion**, not walking — drive the character with `input action`
(or `input key`) against your InputMap actions, and read the result back with `runtime get
--node-path Player --properties '["global_position"]'` (input is fire-and-forget). To inspect a
sightline without driving, **teleport** the player via `runtime set` or move the camera.

## 2.5D & side-view levels — depth, layers, and value

"2.5D" is **two different build problems** — decide which you're greyboxing, because the depth
mechanism and tooling differ:

- **3D geometry, constrained camera** (side-on or fixed ortho — Trine/Ori-like, or diorama
  puzzles à la Hitman GO). Build with the CSG **building blocks** as usual, then lock the camera
  (orthographic `Camera3D`, fixed angle). Depth separation is *real* — use Z position. Most of
  this doc's tactics apply directly.
- **Layered 2D** (sprites/quads stacked with parallax). Build with `ColorRect`/`Polygon2D` on
  ordered `CanvasLayer` / `Parallax2D` layers. Depth is *faked* by draw order + parallax — so
  separating the playable plane from décor is entirely on you.

Either way the core 2.5D problem is the same: **a flat screen makes depth ambiguous**, so the
player must instantly tell *what's playable* from *what's backdrop*. The volume/sightline focus
of 3D shifts to **readability, depth separation, path clarity, and camera framing**. What a 2.5D
greybox validates: **layer separation** (background vs. playable vs. foreground unmistakable),
**path clarity** (the route reads at a glance), **jump distances/reach** (gaps read as within the
character's actual jump), **interaction points** (interactables stand out from décor),
**character readability** (the silhouette is never lost against the background), and **camera
framing** (the constrained camera keeps all of it in frame).

### Value hierarchy beats color for depth

Color codes *function* (the palette above); **value (brightness) codes depth**. For clean,
readable styles (puzzle, narrative, cozy), lean on a value ladder more than hue — many great 2.5D
games read almost entirely in grayscale because contrast does the work:

| Layer | Brightness |
| --- | --- |
| Background (non-interactive) | ~20% |
| Midground décor | ~40% |
| Playable surfaces | ~70% |
| Interactables | ~90% |

Build it by setting that value as the piece's color — `node set … '{"color":"Color(0.2,0.2,0.2,1)"}'`
for 2D, or a flat `albedo_color` material for 3D (see building blocks). Genre palettes then layer
*function* color **on top of** the value ladder — e.g. a track-puzzle board: neutral grey board,
blue track, green destination, red blocked, yellow special; a narrative side-view: grey
environment, cyan walkable, yellow interaction hotspot, green exit/transition, magenta trigger
volume.

### The grayscale test (unique to 2.5D — actually run it)

**Strip the color and check the level still reads.** If the playable path vanishes in grayscale,
it leans on color instead of shape/contrast/composition — fix the *value* separation, don't just
recolor.

- **Lightweight:** take a `runtime screenshot` and judge whether the playable plane reads by value
  alone (assess the image directly — squint at it).
- **Rigorous (3D / 2.5D-in-3D):** desaturate the whole render via a `WorldEnvironment`, screenshot,
  then revert:
  ```
  node add --type WorldEnvironment --name _GrayTest --parent-path .
  node add-resource --node-path _GrayTest --property environment --resource-type Environment \
    --resource-properties '{"adjustment_enabled":true,"adjustment_saturation":0.0}'
  # scene play -> runtime screenshot -> read it -> then: node delete --node-path _GrayTest
  ```
  (If the scene already has a `WorldEnvironment`, set `adjustment_saturation` to 0 on its existing
  `Environment` instead of adding a second.)
- **2D-only:** `CanvasModulate` **can't** desaturate (it only multiplies a tint) — use a top
  `CanvasLayer` → full-rect `ColorRect` with a small luminance shader sampling `hint_screen_texture`,
  or just eyeball the screenshot.

## Greybox lighting — answer gameplay questions, not art questions

Light a greybox to make it **readable**, not pretty. Tuning bloom/fog/shadows/grading before the
level is proven is wasted effort and slows iteration. Add lighting in three stages, gated on the
work (this is the lighting view of Presentation stages above):

**Stage 1 — Functional (always).** Maximum readability, like a CAD model: one `DirectionalLight3D`,
ambient fill high enough that shadows never go black, **no** post/fog/bloom, neutral color.
```
node add --type DirectionalLight3D --name Key --parent-path .
node set --node-path Key --properties '{"rotation_degrees":"Vector3(-50, -40, 0)","light_energy":1.0}'
node add --type WorldEnvironment --name Env --parent-path .
node add-resource --node-path Env --property environment --resource-type Environment \
  --resource-properties '{"ambient_light_source":2,"ambient_light_color":"Color(0.6,0.6,0.65,1)","ambient_light_energy":0.6}'
```
(`ambient_light_source` 2 = "Color"; confirm the enum with `engine class-info --class Environment`.)
Then sanity-check the four questions on a `runtime screenshot`: can I instantly see **the player**,
**interactables**, **which layer is playable**, and **understand the level** from the still?

**Stage 2 — Gameplay (once mechanics work).** Light to *guide*: bright = go here, dark =
non-essential, `SpotLight3D` = important object, light beam = exit. Players subconsciously follow
the brightest path — this is the lit form of "Attract attention" below. Let unimportant space fall dark.

**Stage 3 — Mood (only after gameplay is proven).** Rim/colored lights, fog, bloom, volumetrics,
post — now the question is "does it *feel* right?", not "can I understand this?". This is art
polish; it waits (Presentation-stages layer 4).

**2.5D rig (enough for most prototypes):** key `DirectionalLight3D` + ambient fill + an optional
**back/rim light** behind the player — a *second light node*, not a material trick, so it's robust
on grey geometry. A subtle rim lifts the character silhouette off a grey background. Lighting is
also a way to build the **depth value hierarchy** (2.5D section): light each layer toward its target
value (background dim → player brightest) instead of, or alongside, material albedo value.

## Give the player a clear goal (beat blank-canvas syndrome)

Place the **player** and a **visible goal** first; then you only build the *gap between them*,
and you have a landmark to compose every sightline around. A clear goal makes the player move
**deliberately** instead of meandering. **Reiterate the goal** along the path — each re-framing
re-orients them (pinch points control those shots).

**Build:** drop a player start and a **goal beacon** (building blocks) at opposite ends, then
fill between. `scene play` and confirm the beacon is visible from spawn with `runtime
screenshot`; if not, raise it or clear the sightline.

## Motivate movement by blocking sightlines

A room that reveals everything at once is dead — no reason to move. **Block sightlines** so the
player circles to gather info from new angles and assembles the map in their head. Aim for **no
single vantage** that shows the whole room.

**Build:** add **wall/box blockers** (building blocks) between the entrance and the exit/secrets
— pillars, machinery-sized boxes mid-room. Test: `scene play`, then `runtime set` the player (or
camera) to the entry and each corner, `runtime screenshot` at each. **If any one screenshot shows
the whole room and its exit, add another blocker.**

## Block the player creatively — "tearing down walls"

Don't fence with flat walls. Block in ways that are interesting *and* functional: a torn-open
wall over a **fatal drop** seals escape as surely as a wall but reads better — and the opening
lets you frame the goal through it.

**Build:** instead of a tall solid wall, place a low broken parapet (a short box) at the edge and
a **killzone** (building blocks) in the void beyond. Frame the goal through the gap with `editor
set-camera`.

## Tension and release

Lead the player to a **dead end** (two locked doors) so they **backtrack** — and reveal the real
path from the new angle on the way back (a route that was sightline-blocked before). The pocket
of "where do I go?" releases into "it was behind me." At level scale: **lose sight of the goal**
(route through a tunnel/woods), let them get briefly lost, then **pinch them into a spot where
the goal reappears**.

**Build:** put two non-opening doors (boxes, `Label3D` "LOCKED") at a path's end; place the true
exit behind a blocker that's only visible when facing back toward the entrance. For the level beat:
run the path through a corridor of tall boxes that occlude the goal beacon, ending at a pinch point
(below) that re-frames it. Verify both with walk-through screenshots.

## One-way valve — nudge forward, keep it manageable

A drop the player can't climb back up gently pushes them on and **caps how far they wander
backward**, so a big space stays digestible. Use one before opening into a larger area. Always
pair with a **shortcut** so earlier space isn't sealed forever.

**Build:** a height delta **bigger than the player's jump height** with no ramp on the far side —
pure layout, no special node. Verify: after `scene play`, drive the player back toward it with
`input action` + jump and confirm via `runtime get --node-path Player --properties
'["global_position"]'` that they **can't** remount.

## Privileged perspective — let them plan before they commit

Before a combat/stealth space, enter from **above / a safe vantage** so the player reads the
layout and forms a plan without the duress, then advances at their own pace.

**Build:** put the entrance on a raised platform (a box at height) overlooking the encounter area,
with stairs/ramp down. Confirm the overview reads: `editor set-camera` to the entry viewpoint,
`runtime screenshot` — the player should see the threats and the routes from up there.

## Make a space feel larger — the illusion of choice

Offer **several routes that converge on one point**. The player can't take them all, so any route
they skip leaves unknown (therefore infinite-feeling) space. Cheap depth: three short alternate
paths through *one* space, not three spaces.

**Build:** from a hub box-room, cut three openings to three short corridors that all rejoin at the
next trigger/door. Keep each corridor a few boxes long — it's the *branching*, not the length,
that sells size.

## Attract attention — draw the eye down a chosen route

When routes are many, lead the eye:

- **Light = contrast, not moth-to-flame.** A lit feature is *easier to read*, so it reads as
  important. **Build:** put an **attention light** (building blocks) on the thing you want noticed.
- **Movement / noise** pull attention. **Build:** an **animated attractor** (a rotating fan box, a
  swaying door) via `animation.*`.
- **Affordances communicate function.** A *doorway/arch* says "pass through," *steps* say "climb,"
  a *window* says "climb through" (players are cat burglars). **Build:** shape the opening like the
  action you want — an arch box for passage, stepped boxes for climbing. Curve stairs out of sight
  to add **mystery**.
- **Parallax / layered geometry / fog** give **depth cues** a flat screen loses. **Build (3D):**
  stagger boxes at different depths; add a `WorldEnvironment` with fog. **Build (2D):**
  `Parallax2D` / `CanvasLayer` layers.

## Create mystery — seed, don't show

Make the player **assume something exists** but discover *what*. A door ajar, swaying, light
bleeding around it — they can't see behind but know it opens.

**Build:** a partly-open door (a box rotated to a gap) with an **attention light** behind it and a
**trigger** just past it, so the reveal lands when they push through. Don't show what's behind in
any earlier sightline.

## Build a vocabulary you can pay off or subvert

Reuse a **recognizable usable element** (the talk's climbable pipes — used to escape, then again
at a bridge, then near the end). Once taught, the player makes their own plans; then **pay it off**
(it works — vindicating) or **subvert it** (path goes elsewhere — surprising).

**Build:** pick one climbable motif (e.g. a `CSGCylinder3D` "pipe" in a fixed color) and place it
identically each time it's usable. **Consistency is the contract** — never reuse that color/shape
for non-climbable geometry, or the language breaks.

## Communicate blockage honestly — match affordance to intent

Every blocker says something; make it say the right thing.

- **Bars** read "not meant to go here" — they block *and* signal intent. A **gap**, after you've
  taught the player to jump gaps, reads "jump here" — so a too-wide gap used as a wall is a lie
  that makes them fail an invited jump. **Use the blocker whose *meaning* matches your intent.**
- **Unactionable things must look unactionable.** A door they can't use shouldn't look usable from
  afar. **Build:** barricade it with furniture boxes, or just **delete it** — an unrealistic-clear
  space beats a realistic-frustrating one (`node delete`).

## Shortcuts — shrink the world, respect the player's time

After a valve or a cleared challenge, open a **shortcut back** to earlier space — it re-connects
the level, makes it feel smaller, and lets a proven challenge be skipped on repeat traversal.

**Build:** add a door/opening (a **trigger** that swaps a wall box out, or a kicked-open gate) from
the new area straight into a previously-visited room. Repurpose old **dead ends** as the shortcut's
mouths.

## Pinch points — control the shot without taking control

Funnel the player through a **narrow doorway**. You know exactly where they are, so you know where
the **camera** is — compose a reveal (re-frame the goal) **without cutting away or seizing
control**.

**Build:** narrow the path to a one-box-wide opening; just past it, place the goal beacon / vista
in view. Pre-frame with `editor get-camera`/`set-camera`, then `scene play` + `runtime screenshot`
from the doorway to confirm the reveal lands.

## Safety nets — fail without breaking flow

A failed jump shouldn't mean a game-over and restart — that breaks flow. Give failure a **soft
landing** the player climbs back from, without removing the challenge (they still must make the
jump).

**Build:** under a platforming gap, place a **lower recovery platform** with a ramp/stairs back up
— or a **killzone** whose handler respawns them at a checkpoint just before the jump, not at level
start. Verify by **failing the jump on purpose** during `scene play` and confirming you recover in
the flow.

## Problem-solution ordering — gate the information

The player must **meet the problem before the solution**, or the solution is meaningless (find the
key before the locked gate and the gate feels already-open). **Make the problem unavoidable, route
the solution behind it.**

**Build:** sequence with **triggers**. Put the locked gate on the main path so it's hit first; place
the key behind a barrier that only the act of reaching the gate opens (a trigger at the gate drops a
crate/ramp that unlocks the route to the key). Test the *order* by walking it — you should be unable
to reach the key first.

## Build on uneven terrain — get off the grid

Flat on-grid boxes yield dull levels. Place **start** and **end**, then build a **mess of uneven
terrain between** and make architecture comply with the contours — buildings cut into a hillside
give a ground entrance that drops to a storage level that opens onto ground again: natural
elevation and vantage points. Rooms can be internally gridded; just not all on the *same* grid.

**Build:** vary `position.y` and `rotation_degrees` across your floor/platform boxes; stack and
embed boxes at different heights rather than tiling one plane. Stairs/ramps (rotated boxes) connect
the levels.

## Checklist when laying out a blockout

- Player start + **visible goal beacon** placed first; goal **reiterated** along the path.
- **No single vantage** reveals the whole space — blockers added until walk-through screenshots
  prove it.
- Boundaries are **interesting and honest** (fatal drops/bars, not flat walls); each blocker's
  *look* matches its intent.
- A **usable-element vocabulary** is taught early, kept consistent, and reused (paid off or subverted).
- **One-way valves** keep big spaces manageable; **shortcuts** keep them interconnected.
- Hard spaces get a **privileged perspective**; failures get a **safety net** (checkpoint, not restart).
- **Pinch points** placed where you direct attention without seizing control.
- Problems met **before** their solutions (trigger-gated); multiple routes **converge** to feel large.
- Terrain is **uneven / off-grid**; rooms sized with temp furniture for final scale.
- **Color-coded, not art-finished** — CSG + the greybox color language (one color = one rule,
  fixed for the whole project); no textures/props until the layout is proven.
- **For 2.5D / side-view:** layers separated by **value** (not just hue) — run the **grayscale
  test** and confirm the playable path still reads; jump distances and camera framing validated.
- **Lighting answers gameplay questions** — functional first (player/ground/hazards/interactables
  instantly legible); mood/post saved for after the level is proven.
- **3-second screenshot test:** one `runtime screenshot` should convey the level's purpose to a
  fresh viewer in ~3s. If not, the gap is composition / contrast / lighting — **not** missing art.
- **Walk it** every iteration: `scene play` → `runtime screenshot` (teleport with `runtime set`
  or drive with `input action`) → `runtime get` to read state back → adjust.
```
