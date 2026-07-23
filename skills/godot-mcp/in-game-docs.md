# In-game documentation — Gyms, Zoos, and Museums

From the workflow-design talk *"Gyms, Zoos, and Museums: your documentation should be in-game."* The core question: **are you shipping your documentation, or your game?** A separate GDD or wiki goes stale the moment you start iterating, because you're maintaining **two** things — the game and the doc. The fix: **document in-game, spatially and contextually close to the content**, so you maintain **one** thing.

**For a solo or small team this matters more, not less.** The "game of telephone" the talk describes (asking a teammate, who points to Slack, which points to Confluence…) is, for you, a game of telephone *with your future self*. Three months on you've forgotten your own jump distance, your asset scales, your system rules. In-game docs become a single source of truth you maintain **for free while building**, not a separate chore you'll abandon.

The `doc` command group builds all four patterns. Every recipe below was driven against a live editor. They need a **3D scene** open (`scene create … --root-type Node3D` then `scene open …`).

---

## 1. Gym — character-controller metrics

"How far can a player jump?" shouldn't send anyone to a stale table. Build a **gym**: geometry you can literally run at, colour-graded green (easy) → orange (hard) → red (impossible). It's the single source of truth for movement metrics, and it doubles as a smoke test (run a bot through it overnight; did it get stuck?).

**Build a whole gym in one shot** — rows of jump gaps, step heights, and slope ramps at increasing values, auto-graded and labeled:

```
godot-mcp doc gym
# defaults: gaps [1,2,3,4,5], heights [0.3,0.6,1,1.5], slopes [20,30,40,50]
# → a Gym node: 13 labeled stations + a ground plane, green→orange→red by difficulty
```

Tune it to *your* controller's real numbers:

```
godot-mcp doc gym --gaps "[1.5,2.5,3.5,4.5]" --heights "[0.4,0.8,1.2]" --slopes "[25,40,55]" --spacing 4
```

**Or place one metric station** (the gym building block) where you need it — `gap`, `height`, `slope`, or a pure `distance` measuring stick:

```
godot-mcp doc metric --type gap     --value 3.5 --at "Vector3(0,0,0)"  --difficulty hard
godot-mcp doc metric --type height  --value 1.2 --at "Vector3(0,0,4)"  --difficulty easy
godot-mcp doc metric --type slope   --value 35  --at "Vector3(0,0,8)"
godot-mcp doc metric --type distance --value 5  --at "Vector3(0,0,12)"   # a labeled measuring stick
```

Each station is a labeled, colour-coded mini-structure. Drop your actual character controller in and run it.

## 2. Zoo — see every asset at a glance

The classic asset-browser problem: thumbnails tell you nothing about **scale**, or what an asset looks like **in your level's lighting**, and searching by name fails (is it `iron_gate`, `steel_gate`, or `metal_gate`?). A **zoo** lays every asset out at once, so you grab the right one by *looking*, no name lookup, no asset getting lost. Generatable — Godot's *AssetPlacer* has this exact "Generate Zoo" feature, and so do we:

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

Now the answers are visual: which two assets are the same size? Is this rock the right scale for that wall? Just look. The zoo is also where visual QA happens — spot the broken-shader asset, or screenshot-diff the zoo overnight to catch what changed.

## 3. Museum — show how a system works

For technology and systems (cloth, destruction, a scripting flow), 50 pages of wiki is the wrong format — most of it is clearer in 3D. A **museum** is a row of labeled exhibit pads; you drop a *live* demo on each, and each pad links to the deeper API docs for when someone wants to read.

```
godot-mcp doc museum --exhibits '["Cloth", {"name":"Destruction","link":"https://docs.godotengine.org/…","text":"how it shatters"}, {"name":"Scripting","text":"live cat-script demo"}]'
# → a Museum: one labeled pad per exhibit, each carrying a doc-note with its link
```

The links live as **doc-notes**, so they show up in `doc note --action list --category info` — your museum's "read more" index is queryable. Drop the actual system demo onto each pad; the museum gives you the layout, the labels, and the links. Use it for the **don'ts** too ("no overhangs — our system breaks here").

## 4. Spatial notes — the level *is* the doc

The bonus pattern, and the most broadly useful: leave notes **in the world**, contextually next to what they're about. Region labels ("dungeon two is here"), "don't move this", art-review flags, to-dos — each carrying a category, text, a screenshot path, a ticket link. Godot's own right-click → *Open Documentation* is praised in the talk as exactly this instinct.

```
# drop a standalone marker note at a world position
godot-mcp doc note --action add --at "Vector3(40,0,12)" --category todo \
  --text "balance this jump — feels too far" --link "https://tracker/PROJ-214"

# or attach a note to an existing node (click it in the editor, then use 'selected')
godot-mcp doc note --action add --node-path selected --category bug --text "boss name changed 3× — pick one"

# review the open notes (filter by category; resolved are hidden by default)
godot-mcp doc note --action list
godot-mcp doc note --action list --category art --include-resolved

# close one out (or --delete to remove the marker entirely)
godot-mcp doc note --action resolve --node-path "Note_Todo"
```

Notes are stored as node metadata (`_doc_note`), so they ride along in the scene and never desync from the thing they describe. `doc note --action list` walks the open scene and reports them with paths you can feed straight back to other commands.

---

## The discipline

- **Know what to document where.** The talk is emphatic: engineers read text docs (especially APIs); artists and designers will not. Put movement/asset/system truth *in-game*; keep API text where engineers expect it. This isn't "don't document" — it's "document the right thing in the right place."
- **One source of truth.** When someone (or future-you) asks "how far can a player jump?", the answer is "run the gym," not "find the table." Update the gym, not a doc *and* the game.
- **It's generatable, so it stays current.** Because `doc gym`/`doc zoo` regenerate from your real numbers and real asset folders, refreshing them is one command — which is the whole point. A doc you can rebuild in a second is a doc you'll actually keep.
- **Combine them.** Zoo + notes (flag the asset that needs a material change). Gym + zoo (an item range you can pick up and test). The patterns compose, like the rest of the toolset.

These are scaffolds: `doc.*` gives you the labeled, measured, lit *structure* — you drop the live content (your controller, your assets, your system demos) onto it.
