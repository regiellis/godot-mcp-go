# Narrative / visual-novel architecture

The systems a story-driven game needs: branching script, on-screen dialogue, scripted
commands woven into prose, choices, chapter flow, and data-driven in-world content (a fake
phone/social-media OS). Reverse-engineered from a shipped commercial Godot narrative game
(real GDScript source), plus a studied graph-dialogue addon for the node-graph family and
the VN quality-of-life layer. Patterns are durable and language-agnostic in spirit; build
them via the CLI (`script.create`, `scene.*`, `project.add_autoload`). Read
`gdscript-architecture.md` first — narrative leans on its Store/Service/Index spine.

The core idea: **keep the story in a branching-script format, keep effects in code, and
bridge them with two narrow seams** — *external functions* (script ↔ game state) and a
*command bus* (script → game actions). Everything else hangs off those seams.

## Run branching script with Ink (or an equivalent runner)

The game authors story in **Ink** (inkle's narrative language), compiles to `.inkb`, and
runs it through a GDExtension runner. The pattern, independent of which runner you pick:

- Story files keyed hierarchically (`1.1a`, `2.3.flashback`) resolving to
  `id.inkb` / `id/_main.inkb`. **Localized** files live under `locales/<lang>/…` and the
  loader falls back to the default locale when a translation is missing.
- A `Story` autoload owns runner creation, caching, and a tiny API: advance lines, read
  choices, read **tags**.

```gdscript
var story := InkStory.open(file)
var runner := InkRunner.from_ink_story(story)
runner.can_continue(); runner.advance(); runner.get_choices()
runner.choose_choice_index(i); runner.get_global_tags()
```

**Pattern: story-as-data in a runner.** Branching/state logic lives in the script language;
GDScript only drives the runner and renders output. (If not Ink: any line-emitting branching
format works — the rest of this file is runner-agnostic.)

### Seam 1 — external functions (script ↔ game state)

Ink calls back into GDScript through **bound external functions**, which the game wires to
the Store. The slick trick: reflect over methods with a prefix and auto-bind them.

```gdscript
class StoryExternalFunctions:
    const FUNC_PREFIX = "__"
    func bind(runner):
        for m in get_method_list():
            if m.name.begins_with(FUNC_PREFIX):
                runner.bind_external_function(m.name.trim_prefix(FUNC_PREFIX), Callable(self, m.name))
    func __get_bool(path, default): return Store.get_value(_state_path(path)) if ... else default
    func __set_int(path, v): Store.set_value(_state_path(path), v); return true
```

So Ink can read/write persistent state (`__set_bool`, `__is_fb_post_liked`, …) without
knowing about Godot. **Pattern: a thin, auto-bound bridge from the script VM to your state
store.**

### Substory-type routing from tags

The runner's **global tags** carry a header (`type: "chat"`, `characters`, `player`,
`color`…). A factory reads the header and returns the right presentation object:

```gdscript
match header.type:
    "chat":     return Conversation.new(id, runner, header, ctx)  # messaging UI
    "dialogue": return Dialogue.new(id, runner, header, ctx)      # speech bubbles + choices
    _:          return Substory.new(id, runner, header, ctx)      # plain narrative
```

**Pattern: declare presentation mode in the story header**, route to a handler — one story
format, several on-screen treatments.

## A line format + a command bus (the heart of scripted scenes)

Each line the runner emits is classified by regex and routed:

- `$ command args --flags` → a **Command** (do something in the game)
- `char_key(duration): text` → a **dialogue line** (show a speech bubble)
- `:  text` → an inner thought (thought bubble)
- `sender: message` → a chat message

```gdscript
# Constants
REGEX_COMMAND  := "\\$\\s+([a-zA-Z0-9._-]+)\\s*(.*)\\s*"
REGEX_DIALOGUE := "(?'char_key'[\\w:-]+)\\s*(?:\\((?'duration'.+)\\))?\\:\\s*(?'text'.+)"
```

### Command bus = chain of responsibility

Commands are **not** a giant `match` in one file. Any component can register a handler;
`Story.run_command` walks the handlers and the **first to return a non-sentinel result
wins** (a `CMD_RETURN_NONE` constant is the "not handled" signal). Handlers
register/unregister with tree lifecycle:

```gdscript
func _enter_tree(): Story.add_command_handler(_run_command)
func _exit_tree():  Story.remove_command_handler(_run_command)
func _run_command(cmd):
    match cmd.name:
        "play_sound_persist": _play(cmd.params[0]); return true
        _: return Constants.CMD_RETURN_NONE     # let someone else handle it
```

In the shipped game dozens of components self-register: `DialogueHandler` owns `say`,
`StateContainer` owns flag/dict commands (`F`, `D`), `AudioUtils` owns sound commands, the
scene manager owns `start_skit`, and `Story` owns global ones (`wait`, `change_scene`,
`unlock_ach`…). **Pattern: a command bus with chain-of-responsibility handlers** — adding a
new `$ verb` means a component registering a handler, never editing a central dispatcher.
This is the narrative-game analogue of the deck-builder's hook pipeline.

### Commands embedded inside dialogue text

Beyond whole-line commands, dialogue text carries inline directives processed during the
character-by-character reveal: `[....]` (pauses), `[$ emit paused]` (run a command mid-line),
`[>2.0]` (speed multiplier). **Pattern: inline markup for fine-grained narrative timing.**

## Presenting dialogue: state-machine bubbles + an event bus

A `SpeechBubble` is driven by a small **state machine** (Hidden → RevealText →
PendingAdvance → Hidden; a parallel RevealChoices → PendingChoice branch). It resolves
*where* to appear by asking the `Index` for the character's `SpeechBubblePivot` by alias
(3D-unprojected or 2D), and adapts to stay on-screen.

Choices flow back into the runner: `runner.get_choices()` → render → player picks → 
`runner.choose_choice_index(i)` → continue. **Timed choices** push a countdown with a
fallback index for time-pressure beats.

Story-wide coordination uses a tiny **event bus** on the `Story` autoload: `Story.emit(name)`
and `await Story.wait_for(name)` — so a scene can block until a narrative beat fires without
direct references. **Pattern: dialogue UI as a state machine + a story event bus for
loosely-coupled sequencing.**

### Skits: embedded interactive scenes

A `SkitContainer` (with an `id`, indexed) runs a sub-story scoped to its own subtree — it
resolves pivots/commands locally unless allowed global access. Triggered from script
(`$ start_skit --wait WakeUp`), it emits `skit_started`/`skit_finished`. **Pattern: scope a
sub-story to a container** so the same dialogue machinery drives small in-world vignettes.

## The graph-dialogue family (when you don't want a script language)

The alternative to Ink: dialogue as a **JSON node graph** — typed nodes keyed by id, each
carrying `next` (or a `branches` map), interpreted by a walker. Same two seams as above, just
wearing different clothes. Distilled from a studied dialogue addon; core verified against the live engine.

**The graph is data; the interpreter is a `match`.** Flow control ships as *node types*, not
code: `show_message` (text per language: `{"ENG": ...}`, optional `choices`),
`condition_branch` (`branches: {True, False}`), `chance_branch` (weighted),
`random_branch`, `repeat` (loop N times via a counter dict, exit to `next_done`), `wait`,
`set_local_variable`, `action`. The walker is ~10 lines:

```gdscript
var node: Dictionary = nodes[next_id]
match node.type:
    "show_message":     show_message(node)          # sets next from node.next or a choice
    "condition_branch": next_id = node.branches["True"] if evaluate(node.condition) else node.branches["False"]
    "action":           execute_action(node.action_name, node.get("params", {})); next_id = node.next
```

Writers get non-linearity (chance/repeat/conditions) without touching code, and the format is
diffable, generatable, and migratable. **Version the format**: a `version` field, per-node
converters that upgrade old files on load, and a migration tool — dialogue data outlives code.

**Seam A — a safe evaluator, not `eval`.** Conditions and `@var@` text interpolation go through
Godot's `Expression` class with an allowlisted context (the dialogue's local variables plus a
few globals) — writers get `gold >= 10 and not met_guide`, never arbitrary code:

```gdscript
var expression := Expression.new()
expression.parse(input, PackedStringArray(context.keys()))
var result: Variant = expression.execute(context.values(), self)
```

**Seam B — an action registry.** Dialogue triggers game effects only by name through registered
callables; namespaced *variable providers* (`"player"` → callable answering `"health"`) expose
game state read-only. The graceful-degradation detail worth copying: an **unregistered** action
emits `action_requested(name, params)` instead of erroring, so a scene can handle one-off
actions by signal without registering globally. This is the graph-family's command bus.

**VN quality-of-life is a small, separable layer** (players expect all three):
- **Skip**: hold-to-skip that only fast-forwards *visited* nodes — keep a
  `"path:node_id"` visited set; never skip through choices.
- **Auto-advance**: arm a one-shot timer only when the message finished revealing *and* no
  choice is pending; cancel on any manual input.
- **Backlog**: a capped ring buffer of typed entries (message vs choice, speaker, node id),
  searchable; feed it from the same place that shows messages.
- **Resume**: a `DialogueState` Resource (current path + node id, variables, flags, visited,
  repeat counters) — `resume_from_state()` is just "load file, `next_id = saved`, step".

**Presentation: one Message contract, N skins.** Box (bottom panel) and Bubble (speech balloon)
both implement `show_new_message(text)` / `finish_message()` + `started/finished` signals; each
node picks its skin (`is_box`), a global override forces one. Mechanics worth stealing:
- **World-anchored bubbles**: 2D follows `speaker.get_global_transform_with_canvas().origin`;
  3D follows `camera.unproject_position(speaker.global_position)` — same bubble, both worlds.
- **Typewriter over BBCode**: pair an invisible `Label` (gets the tag-stripped text, drives
  layout) with a `RichTextLabel` (gets the BBCode), and advance `visible_characters` on both.
- **Measure-then-wrap**: show the bubble with autowrap off, wait one frame, and only if it
  exceeds max width flip autowrap on and clamp — short lines get tight bubbles.
- **Conditional choices stay visible but disabled** with the unmet condition as tooltip —
  players see the door they couldn't open.
- A per-character `CharacterData` Resource (portraits by emotion, name/text colors, voice
  blip pitch, preferred skin) in a `CharacterDatabase` keeps styling out of the graph.

## Chapter flow via a scene directory

Scenes are keyed (`"1.1a"`) and chained through a JSON `SceneDirectory` (chapters → ordered
scenes, per-playthrough variants, hidden/unlocked). `to_next_scene()` follows the chain;
crossing a chapter boundary shows a chapter title. See `gdscript-architecture.md` "Game
orchestrator". **Pattern: author the macro-flow as data**, not as `change_scene` calls
scattered through scenes.

## Data-driven in-world apps (the fake phone/PC OS)

A standout: the social feed, web browser, email, and forum are **entirely data-driven** off
the Store's JSON databases — no bespoke code per post.

- **Domain objects are live JSON proxies.** A class wraps a dict from the Store; its
  properties get/set straight into that dict, so mutations persist with no explicit save:

  ```gdscript
  var liked: bool:
      set(v): _dict.liked = v      # writes through to the Store-backed dict
      get: return _dict.get("liked", false)
  ```

- **UI binds from data.** A feed screen reads `Store.get_value("fb://posts/<id>")`,
  wraps it in a domain object, instances a view per item. A like button just flips the
  proxy property; a dirty-checker re-renders.
- **References as strings** (`author_ref = "fb://profiles/alice"`) model the social graph
  and lazy-load via the Store — circular relationships without deep copies.
- **URLs parse to Store paths** (`https://site/2014/11/article` → a nested lookup), so a
  "web" is just addressable data, and a `content_type` field selects which view scene to
  instance (text / picture / album / video) through one pipeline.

Player actions mutate the proxies → the Store diffs them per scene (see the two-tier save
in `gdscript-architecture.md`), so the world *remembers* what you liked or read.
**Pattern: in-world apps = JSON databases + proxy domain objects + view-per-item binding.**
Content authors add posts/emails by editing JSON, not code.

## The product shell (everything around the story)

Mined from a VN engine's starter game; the save/settings core validated against the live engine. The shell —
boot, title, saves, settings, extras — is where "demo" and "shippable" diverge, and it
generalizes far beyond VNs. The organizing idea: **the shell is data-driven from manifests**,
so re-skinning the product never touches code.

- **One project manifest** (a TOML file: `[project]`, `[boot]`, `[title]`, `[window]`) drives
  the whole shell: window title, splash entries, which scenes are title/settings/extras, music.
  A ~100-line TOML-subset parser (sections, scalars, flat arrays) is all it takes; parse once
  at boot and stash on the tree (`get_tree().set_meta`) for every screen to read.
- **Boot flow**: play splash images/videos from the manifest — or, with none configured,
  *procedural text cards* from the project's own metadata (studio name, title), so the flow is
  complete on day one. Fade in → wait-or-skip → fade out → a short **black dwell** between
  cards (cuts without it read as flashes). Skip is one flag checked by every wait.
- **Saves: version + wrap, never introspect.** The payload is
  `{version, slot_id, saved_at_unix, snapshot_json, custom_state, custom_meta}` where
  `snapshot_json` is the story runner's own **opaque** state export — the save system never
  knows story internals. External systems register as *providers* contributing custom state
  under namespaced keys (with key-collision detection). Before overwriting a slot, copy it to
  `.bak`; loads that fail fall back to the backup, and every failure path returns a *named
  reason* (`slot_not_found`, `backup_write_failed`) surfaced by signal, never a crash. Slot UI
  is powered by `list_slots_metadata()` — enumerate, validate, sort by recency.
- **Settings are a table, not a screen of code.** Each setting is one registration row
  (`key, control, kind, options, default, section`); load/apply/persist (`ConfigFile`) iterate
  the table. Four tabs is the shipped shape: General, Display, Sound, **Accessibility**
  (subtitle size/background, colorblind overlay, QTE-off) — plan the a11y tab from the start.
- **Chapter select and extras read TOML too**: `episodes.toml`/`chapters.toml` feed the episode
  carousel + scene gallery; `extras.toml` is a card grid (thumbnail, badge, lock state, target
  scene or URL). Content unlocks are data rows, not screens.
- Give every screen a tiny `ScreenBase` (fade-in, back navigation, manifest access) so screens
  stay declarative.

## Localize narrative content, not just UI strings

Two layers: Godot `tr()` + `.translation` files for chrome (menus, settings), and
**per-locale data files** for narrative — localized `.inkb` under `locales/<lang>/` and
localized JSON DBs (`state_ja.json`, `fb_ja.json`), each falling back to the default
locale. A `locale_changed` signal makes the store **reload all databases** live. Remember
**font remapping** per locale for CJK. **Pattern: localize the data layer with
default-locale fallback**, and reload state on locale change.

## Transferable rules

1. Author branching story in a script language (Ink) run through a runner; GDScript only drives + renders.
2. Bridge script→state with **auto-bound external functions** into a central store.
3. Declare presentation mode in the **story header tags**; route to a handler per mode.
4. Classify emitted lines by regex into **commands vs. dialogue vs. chat vs. thought**.
5. Dispatch `$ commands` through a **chain-of-responsibility bus**; components self-register handlers.
6. Allow **inline command markup** in dialogue text for reveal timing.
7. Drive dialogue UI with a **state machine**; resolve speaker anchors via the node **Index**.
8. Coordinate beats with a **story event bus** (`emit`/`await wait_for`), not direct refs.
9. Author chapter macro-flow as a **keyed scene directory**, not scattered `change_scene` calls.
10. Build in-world apps as **JSON data + proxy objects + view-per-item**; localize the data layer with fallback.
11. Or skip the script language: dialogue as a **versioned JSON node graph** + a `match` interpreter; flow control as node types.
12. Gate writer-facing logic behind a **safe `Expression` evaluator** and an **action registry** (unhandled → signal, never error).
13. Ship the VN QoL layer — visited-gated skip, choice-aware auto-advance, backlog, resumable `DialogueState` — it's small and players expect it.
14. One **Message contract, N skins** (box/bubble); anchor bubbles via canvas transform (2D) or `unproject_position` (3D).
15. Drive the product shell from **manifests** (project/episodes/extras as TOML); saves wrap an opaque story snapshot with version + `.bak` fallback + named failure reasons; settings are a registration table with an Accessibility tab from day one.
