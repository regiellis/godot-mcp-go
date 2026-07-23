# Save/load systems (Godot 4.7+) — building with godot-mcp

The unifying reference for persistence. Four other docs cover a *slice* of saving from their
genre's angle — this one owns the shared architecture and the format decisions. **Verify exact
APIs against the live engine** (`engine class-info --class FileAccess`) before writing — the
serializer flags below were confirmed on 4.7, but signatures evolve.

Where to jump instead of reading here:
- **`gdscript-architecture.md`** — big game, bulk mutable state: the *two-tier save* (small
  checksummed Resource header + JSON-diff-per-checkpoint), when bulk state dwarfs the delta.
- **`topdown-2d.md`** — component game: saveables carry a `SaveDataComponent` holding a
  *polymorphic Resource*; adding a saveable type = a new Resource subclass, no central switch.
- **`narrative-game-patterns.md`** — story game: the save *wraps an opaque story snapshot*
  (`{version, slot_id, snapshot_json, ...}`) with a `.bak` fallback and never introspects it.
- **`menus-settings.md`** — *settings* (audio, video, keybinds) persist to `user://settings.cfg`
  via `ConfigFile`. Keep them out of the save game; the two have different lifetimes.

## What to save: authoritative state, not derived state

Save the **inputs to your simulation, not its outputs.** Player position, inventory, quest
flags, RNG seed, current scene key are *authoritative*. Health bars, pathfinding results,
particle state are *derived* — recomputed on load. Saving derived state bloats the file and
rots the moment the derivation changes.

- **The "everything in one dict" trap.** Dumping `get_tree()` into one nested Dictionary feels
  fast and rots fast: private fields leak into the format, a refactor breaks old saves, and you
  can't reason about what a slot holds. Save a *deliberate* per-type projection of each entity.
- **Granularity.** Persist at the coarsest unit that still reloads correctly — a puzzle game
  saves "level N, moves so far"; an open-world game saves per-region deltas. Finer is wasted
  bytes and migration surface; coarser loses progress players expect kept.

## The collector pattern (the flagship)

Each saveable node joins a `"persist"` group and exposes `save_state() -> Dictionary` /
`load_state(d)`. A `SaveManager` autoload sweeps the group, keys each record by a stable
identity, and never knows an entity's internals — each owns its own shape.

```gdscript
# on each saveable node (player, chest, door, enemy)
func _ready() -> void:
	add_to_group("persist")

func save_state() -> Dictionary:
	return {"pos": [position.x, position.y], "hp": health}   # Vector2 flattened for JSON

func load_state(d: Dictionary) -> void:
	var p: Array = d.get("pos", [0.0, 0.0])
	position = Vector2(p[0], p[1])
	health = d.get("hp", max_health)                          # tolerate a missing key
```

```gdscript
# SaveManager autoload — keys each record by scene_file_path + node path
func collect() -> Dictionary:
	var nodes := {}
	for node in get_tree().get_nodes_in_group("persist"):
		if not node.has_method("save_state"):
			continue
		var path := str(node.get_path())
		nodes["%s::%s" % [node.scene_file_path, path]] = {
			"scene": node.scene_file_path,             # to re-instance if it was spawned
			"path": path,
			"parent": str(node.get_parent().get_path()),
			"state": node.save_state(),
		}
	return {"version": VERSION, "nodes": nodes}
```

**The respawned-node identity problem — be honest about it.** Keying by `scene_file_path` +
node path is stable *only for nodes authored into the scene*. The moment something is
`queue_free()`d (an enemy dies) or `instantiate()`d at runtime (a dropped item, a spawned
pickup), that identity breaks: a freed node has no state to patch, a runtime-spawned one has no
authored path to match. A "patch each node's state" loop silently loses both. Store **spawn
records, not just state patches** — the collector keeps each record's `scene` + `parent`, so
restore *re-instantiates* what isn't already in the tree. Record deaths too (a "dead" set, or
free-on-load anything the save omits), or they resurrect.

```gdscript
func restore(data: Dictionary) -> void:
	var tree := get_tree()
	for key in data.get("nodes", {}):
		var rec: Dictionary = data["nodes"][key]
		var node := tree.root.get_node_or_null(NodePath(rec["path"]))
		if node == null:                                    # was spawned at runtime — re-create it
			var parent := tree.root.get_node_or_null(NodePath(rec["parent"]))
			if parent == null or rec.get("scene", "") == "":
				continue
			node = (load(rec["scene"]) as PackedScene).instantiate()
			parent.add_child(node)
		node.load_state(rec["state"])
```

**Build:** `script create` + `project add-autoload --name SaveManager --path
res://systems/save_manager.gd`; each saveable gets `add_to_group("persist")` + the two methods.
`save_to_slot`/`load_from_slot` wrap collect/restore over the format and slot helpers below.

## Format tradeoffs (pick per need, honestly)

| Format | Types preserved | Human-readable | Notes |
|---|---|---|---|
| `ConfigFile` | Variants (typed) | yes (INI) | **Settings only** — see `menus-settings.md`. Not save games. |
| `JSON` | no (numbers/strings/arrays/dicts) | yes, diffable | Portable, tool-friendly. **Vectors/floats need care** (below). |
| `var_to_str`/`str_to_var` | full Variant incl. Vector2/Color | yes | Text *and* type-faithful. Godot-only reader. |
| `FileAccess.store_var`/`get_var` | full Variant | no (binary) | Fast, compact, opaque. |
| `Resource` + `ResourceSaver` (`.tres`) | typed, `@export`ed | `.tres` yes / `.res` no | Editor-inspectable. **Security caveat below.** |

- **JSON is the portable default but loses types.** `JSON.parse_string` returns every number as
  a `float` and has no `Vector2`/`Color` — a naive `Vector2(10, 20)` errors on read. Two fixes:
  (a) **serialize helpers** — flatten to arrays out, rebuild in (`[v.x, v.y]` / `Vector2(a[0],
  a[1])`), the pattern the collector uses; (b) `JSON.from_native(v, false)` /
  `JSON.to_native(j, false)` tag engine types into a JSON-safe structure and back.
- **`var_to_str` is the underrated middle.** It writes `Vector2(10, 20)` as literal text and
  `str_to_var` reads it back with the Vector intact — full Variant fidelity, still diffable and
  hand-editable, no serialize helpers. Cost: only Godot reads it.
- **Binary `store_var`/`get_var` is fastest and smallest**, opaque on disk. Pass
  `store_var(data, false)` / `get_var(false)` — the `false` keeps arbitrary object
  instantiation out of the reader (same risk as below).
- **`Resource` + `ResourceSaver` is inspectable but unsafe for untrusted saves.** A `@export`ed
  `SaveData extends Resource` saved via `ResourceSaver.save(data, "user://save.tres")` is typed
  and inspector-editable — great for *authored* data. But **loading a `.tres`/`.res` instantiates
  whatever types and scripts the file declares**, so a tampered save can run code on load.
  `FileAccess.get_var` and `JSON.to_native` gate this behind an `allow_objects` flag;
  `ResourceLoader.load` has **none**. Standing community guidance: **never `load()` a save a
  player could swap** — use JSON or `store_var(..., false)` there, reserve Resource saves for
  shipped content and local headers. (`open_encrypted_with_pass` only obfuscates: the key ships
  in your binary.)

## Versioning and migration

Put a **`version` int in every save** from day one — the cheapest future-proofing there is.
On load, run a migration ladder that upgrades stepwise, and read every optional field through
`dict.get(key, default)` so a missing key is a default, not a crash.

```gdscript
func migrate(data: Dictionary) -> Dictionary:
	var v: int = data.get("version", 1)
	if v < 2:
		data["gold"] = data.get("coins", 0)   # v1->v2 renamed coins->gold
		data.erase("coins")
		v = 2
	if v < 3:
		data["difficulty"] = "normal"          # v2->v3 added a field
		v = 3
	data["version"] = v
	return data
```

Stepwise (each `if v < N` upgrades one version) migrates a v1 save 1→2→3 in one pass — never a
v1→v3 jump. `gdscript-architecture.md`'s Resource header does the same with `match save.version`.

## Slots and metadata

Lay out `user://saves/slot_N/` with the payload plus a **sidecar meta** the load menu reads
*without* deserializing the whole game — timestamp, playtime, a thumbnail.

```gdscript
func slot_dir(slot: int) -> String:
	return "user://saves/slot_%d" % slot

func write_meta(slot: int, playtime: float) -> void:
	DirAccess.make_dir_recursive_absolute(slot_dir(slot))
	var meta := {
		"saved_at": Time.get_datetime_string_from_system(false, true),  # local, space-separated
		"unix": Time.get_unix_time_from_system(),                        # sort key
		"playtime_s": playtime,
	}
	var f := FileAccess.open(slot_dir(slot) + "/meta.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(meta, "\t"))
	f.close()

func write_thumb(slot: int) -> void:
	var img := get_viewport().get_texture().get_image()   # last rendered frame
	img.resize(320, 180)
	img.save_png(slot_dir(slot) + "/thumb.png")

func list_slots() -> Array:                               # for the load screen
	if not DirAccess.dir_exists_absolute("user://saves"):
		return []
	return Array(DirAccess.get_directories_at("user://saves")).filter(
		func(n): return n.begins_with("slot_"))
```

Build the menu from the tiny meta files alone (sort by `unix` for "most recent"); the full
slot loads only on click.

## Async and threaded saves

Most saves are a small Dictionary that finishes **sub-frame** — write them synchronously.
**Don't thread until a save visibly hitches** (large worlds, thumbnail encode, big blobs):

- **`WorkerThreadPool`** runs the write off the main thread. `add_task` returns an id; poll
  `is_task_completed`, then `wait_for_task_completion` to reclaim it (required, even when done).
  ```gdscript
  func save_async(path: String, text: String) -> void:
  	_task_id = WorkerThreadPool.add_task(_write_worker.bind(path, text), false, "save")
  func _write_worker(path: String, text: String) -> void:
  	var f := FileAccess.open(path, FileAccess.WRITE); f.store_string(text); f.close()
  func _process(_dt) -> void:
  	if _task_id != -1 and WorkerThreadPool.is_task_completed(_task_id):
  		WorkerThreadPool.wait_for_task_completion(_task_id); _task_id = -1; saved.emit()
  ```
  **Build the snapshot on the main thread**, hand the worker only plain data (the serialized
  string / a duplicated dict) — never touch the scene tree from a worker.
- **Simpler alternative: `call_deferred` + chunking.** Serialize a slice per idle callback so no
  single frame does all the work — no thread, no data-race surface. Enough for big-but-not-huge.

## Autosave and crash-safe writes

- **Trigger on checkpoints, plus a low-frequency timer** (a `Timer` node firing every ~120 s).
  **Never autosave mid-combat** — a save that captures a half-resolved fight reloads broken;
  gate it (`if _in_combat: return`) and let the next checkpoint catch it.
- **Write atomically: temp then rename.** A crash *during* a write leaves a truncated, wiped
  slot. Write to `save.json.tmp`, `close()`, then `DirAccess.rename_absolute(tmp, final)` — the
  rename is atomic on every desktop filesystem, so the slot is only ever the last *complete*
  write. Keep a `.bak` of the prior slot too (as the other two docs' headers do).

```gdscript
func write_atomic(path: String, text: String) -> void:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE); f.store_string(text); f.close()
	DirAccess.rename_absolute(tmp, path)
```

## Verify by driving (prove the round-trip in a playing game)

A save that returns `OK` is not a save that *round-trips*. Prove it against the live game:

```
scene play --mode main
runtime eval --code 'SaveManager.save_to_slot(0); emit(FileAccess.file_exists("user://saves/slot_0/save.json"))'
runtime set --node-path Player --property position --value "Vector2(999,999)"   # corrupt live state
runtime eval --code 'SaveManager.load_from_slot(0); emit(get_node("Player").position)'   # expect the SAVED pos, not 999
scene stop
```

The load must restore the *saved* position, not the corrupted one — proof the write, format,
and `load_state` agree. Extend it: kill an enemy, save, reload, confirm it stays dead; bump
`version`, reload an old slot, confirm `migrate` ran. `runtime eval` runs in the game's own
process, so it reads the real `user://` and autoloads — not the editor's.

## Common mistakes

- **Floats/Vectors through raw JSON** — use serialize helpers, `JSON.from_native`, or `var_to_str`.
- **`load()`ing an untrusted Resource save** — runs embedded scripts; use JSON / `store_var(..., false)`.
- **Saving node references** — save *data* (path, id, scene string) and rebuild the node on load.
- **Patching state without spawn records** — freed/spawned nodes desync; store `scene` + `parent`.
- **No `version` field** — the first format change orphans every existing save.
- **Non-atomic writes** — a crash mid-write corrupts the slot. Temp-then-rename, keep a `.bak`.
- **Autosaving mid-combat**, or threading a save that was already sub-frame — risk, no win.
- **Trusting remembered API signatures** — confirm against the running engine with `engine class-info`/`search`.
