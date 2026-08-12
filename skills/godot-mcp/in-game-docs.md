# In-game documentation: Gyms, Zoos, and Museums

From the workflow-design talk *"Gyms, Zoos, and Museums: your documentation should be in-game."* A separate GDD or wiki goes stale the moment you start iterating, because you're maintaining **two** things, the game and the doc. The fix: **document in-game, spatially and contextually close to the content**, so you maintain **one** thing.

**For a solo or small team this matters more, not less.** The "game of telephone" the talk describes (asking a teammate, who points to Slack, which points to Confluence…) is, for you, a game of telephone *with your future self*. Three months on you've forgotten your own jump distance, your asset scales, your system rules. In-game docs become a single source of truth you maintain **for free while building**, not a separate chore you'll abandon.

The `doc` command group builds all four patterns. Every recipe below was driven against a live editor. They need a **3D scene** open (`scene create … --root-type Node3D` then `scene open …`); *The 2D equivalent* at the end covers a canvas project.

---

## 1. Gym: character-controller metrics

"How far can a player jump?" shouldn't send anyone to a stale table. Build a **gym**: geometry you can literally run at, colour-graded green (easy) → orange (hard) → red (impossible). It's the single source of truth for movement metrics, and it doubles as a smoke test (run a bot through it overnight; did it get stuck?).

**Build a whole gym in one shot**, with rows of jump gaps, step heights, and slope ramps at increasing values, auto-graded and labeled:

```
godot-mcp doc gym
# defaults: gaps [1,2,3,4,5], heights [0.3,0.6,1,1.5], slopes [20,30,40,50]
# → a Gym node: 13 labeled stations + a ground plane, green→orange→red by difficulty
```

Tune it to *your* controller's real numbers:

```
godot-mcp doc gym --gaps "[1.5,2.5,3.5,4.5]" --heights "[0.4,0.8,1.2]" --slopes "[25,40,55]" --spacing 4
```

**Or place one metric station** (the gym building block) where you need it, choosing `gap`, `height`, `slope`, or a pure `distance` measuring stick:

```
godot-mcp doc metric --type gap     --value 3.5 --at "Vector3(0,0,0)"  --difficulty hard
godot-mcp doc metric --type height  --value 1.2 --at "Vector3(0,0,4)"  --difficulty easy
godot-mcp doc metric --type slope   --value 35  --at "Vector3(0,0,8)"
godot-mcp doc metric --type distance --value 5  --at "Vector3(0,0,12)"   # a labeled measuring stick
```

Each station is a labeled, colour-coded mini-structure. Drop your actual character controller in and run it.

## 2. Zoo: see every asset at a glance

The classic asset-browser problem: thumbnails tell you nothing about **scale**, or what an asset looks like **in your level's lighting**, and searching by name fails (is it `iron_gate`, `steel_gate`, or `metal_gate`?). A **zoo** lays every asset out at once, so you grab the right one by *looking*, no name lookup, no asset getting lost. It is generatable. Godot's *AssetPlacer* has this exact "Generate Zoo" feature, and so do we:

```
godot-mcp doc zoo --from res://assets/props --cols 6
# instantiates every asset in the folder into a labeled grid, with:
#   - the filename + real AABB dimensions on each
#   - a scale reference (1m + 2m cubes + a 1.8m character capsule)
#   - a ground plane and a sun (so you judge scale and lighting honestly)
```

Or pass an explicit set, and turn off pieces you don't want:

```
godot-mcp doc zoo --scenes '["res://enemies/grunt.tscn","res://enemies/brute.tscn"]' --scale-ref --lighting=false
```

Now the answers are visual: which two assets are the same size? Is this rock the right scale for that wall? Just look. The zoo is also where visual QA happens: spot the broken-shader asset, or screenshot-diff the zoo overnight to catch what changed.

## 3. Museum: show how a system works

For technology and systems (cloth, destruction, a scripting flow), 50 pages of wiki is the wrong format, because most of it is clearer in 3D. A **museum** is a row of labeled exhibit pads; you drop a *live* demo on each, and each pad links to the deeper API docs for when someone wants to read.

```
godot-mcp doc museum --exhibits '["Cloth", {"name":"Destruction","link":"https://docs.godotengine.org/…","text":"how it shatters"}, {"name":"Scripting","text":"live cat-script demo"}]'
# → a Museum: one labeled pad per exhibit, each carrying a doc-note with its link
```

The links live as **doc-notes**, so they show up in `doc note --action list --category info`, which makes your museum's "read more" index queryable. Drop the actual system demo onto each pad; the museum gives you the layout, the labels, and the links. Use it for the **don'ts** too ("no overhangs, because our system breaks here").

## 4. Spatial notes: the level *is* the doc

The bonus pattern: leave notes **in the world**, contextually next to what they're about. Region labels ("dungeon two is here"), "don't move this", art-review flags, and to-dos, each carrying a category, text, a screenshot path, a ticket link. Godot's own right-click → *Open Documentation* is praised in the talk as exactly this instinct.

```
# drop a standalone marker note at a world position
godot-mcp doc note --action add --at "Vector3(40,0,12)" --category todo \
  --text "balance this jump, feels too far" --link "https://tracker/PROJ-214"

# or attach a note to an existing node (click it in the editor, then use 'selected')
godot-mcp doc note --action add --node-path selected --category bug --text "boss name changed 3 times, pick one"

# review the open notes (filter by category; resolved are hidden by default)
godot-mcp doc note --action list
godot-mcp doc note --action list --category art --include-resolved

# close one out (or --delete to remove the marker entirely)
godot-mcp doc note --action resolve --node-path "Note_Todo"
```

Notes are stored as node metadata (`_doc_note`), so they ride along in the scene and never desync from the thing they describe. `doc note --action list` walks the open scene and reports them with paths you can feed straight back to other commands.

## The 2D equivalent: the same four patterns without `doc.*`

**The `doc.*` scaffolds are 3D only.** `doc gym`, `doc zoo`, `doc museum`, and `doc metric` each refuse a non-Node3D root, because their stations are CSG boxes and their labels are `Label3D`. The thesis is dimension-free, so a canvas project builds the same four patterns out of the generic commands.

`doc note` is the exception, and most of it carries over. `--action list`, `--action add --node-path X`, and `--action resolve` all work against a 2D scene: a note is metadata under the `_doc_note` key, and the walk that collects them is a plain node walk. Only `--action add --at "Vector3(…)"` is 3D. It drops a `Marker3D`, so a 2D root is refused with a pointer at `--node-path`. In 2D, place the marker with `node add --type Marker2D` and write the key with `node set-meta`.

What maps over:

- **Gym** is a flat scene of measured jump gaps, speed corridors, and step heights laid out left to right at rising values, with the number on each station. `StaticBody2D` platforms are the geometry you actually run at; `ColorRect` or `Polygon2D` carries the green → orange → red grading; `Label` carries the distance.
- **Zoo**: a grid of `scene instance` calls with a `Label` caption under each. Scale in 2D is pixel size against your character, so put the character scene in the grid as the reference instead of the 1m/2m cubes.
- **Museum** is a row of exhibit pads: `ColorRect` slabs, one `Label` each, the live demo scene instanced on top.
- **Spatial notes** are `Marker2D` plus `node set-meta`. Metadata rides in the scene exactly as `_doc_note` does on a 3D marker, so the note stays attached to what it describes. Read one back with `godot-mcp node get-meta --node-path X --key _doc_note`, or the whole set with `godot-mcp doc note --action list`, which walks a 2D scene and reports each note with a path that feeds straight back into other commands.

**Build a 2D gym**: three ground slabs separated by two measured gaps, each graded and labeled:

```
godot-mcp scene create --path res://docs/gym_2d.tscn --root-type Node2D --root-name Gym2D

# ground the controller runs along; the gaps between slabs are what's under test
godot-mcp scene2d add-body --type StaticBody2D --name Ground_0 --shape rectangle --size "Vector2(256,32)" --position "Vector2(0,400)"
godot-mcp scene2d add-body --type StaticBody2D --name Ground_1 --shape rectangle --size "Vector2(256,32)" --position "Vector2(400,400)"
godot-mcp scene2d add-body --type StaticBody2D --name Ground_2 --shape rectangle --size "Vector2(256,32)" --position "Vector2(864,400)"
# shapes centre on the body, so slab 0 spans x -128..128 and slab 1 spans 272..528: a 144 px gap, then 208 px

# grade each gap the way doc gym does, green for clearable and orange for the ceiling
godot-mcp node add --type ColorRect --name Grade_144 --properties '{"position":"Vector2(128,432)","size":"Vector2(144,16)","color":"#3faf5a"}'
godot-mcp node add --type ColorRect --name Grade_208 --properties '{"position":"Vector2(528,432)","size":"Vector2(208,16)","color":"#d86b2b"}'

# the measurement, readable in the viewport
godot-mcp node add --type Label --name Gap_144 --properties '{"position":"Vector2(140,340)","text":"144 px (easy)"}'
godot-mcp node add --type Label --name Gap_208 --properties '{"position":"Vector2(540,340)","text":"208 px (max jump)"}'

# a spatial note carrying its own to-do
godot-mcp node add --type Marker2D --name Note_Tuning --properties '{"position":"Vector2(632,300)"}'
godot-mcp node set-meta --node-path Note_Tuning --key _doc_note \
  --value '{"category":"todo","text":"208 px is the ceiling, re-measure once the dash lands"}'

godot-mcp scene save
```

Instance your real controller into that scene and run it. The numbers in the labels are claims until the controller clears the gap, which is the whole point of a gym over a table.

---

## The discipline

- **Know what to document where**. The talk is emphatic: engineers read text docs (especially APIs); artists and designers will not. Put movement/asset/system truth *in-game*; keep API text where engineers expect it. Document the right thing in the right place.
- **One source of truth**. When someone (or future-you) asks "how far can a player jump?", the answer is "run the gym," not "find the table." Update the gym, not a doc *and* the game.
- **It's generatable, so it stays current**. Because `doc gym`/`doc zoo` regenerate from your real numbers and real asset folders, refreshing them is one command. A doc you can rebuild in a second is a doc you'll actually keep.
- **Combine them**. Zoo + notes (flag the asset that needs a material change). Gym + zoo (an item range you can pick up and test). The patterns compose, like the rest of the toolset.

These are scaffolds. `doc.*` gives you the labeled, measured, lit *structure*, and you drop the live content (your controller, your assets, your system demos) onto it.
