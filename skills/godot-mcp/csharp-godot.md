# C# in Godot — idioms

A reference for working in a **C# Godot project**. Idioms verified against a shipped
commercial Godot C# game (decompiled), so they reflect real shipping practice — not
tutorials.

> **Scope / fit.** The `godot-mcp` CLI authors **GDScript** (`script.create`/`script.edit`
> write `.gd`); it does not compile C#. So this file is guidance for when you're editing a
> C# Godot codebase directly (in the filesystem, building with `dotnet`/Godot's build),
> not something you drive through the addon. The `engine.*` discovery commands still help —
> the live `ClassDB` API is identical whether you call it from C# or GDScript, so
> `engine class-info --class Tween` etc. remain your source of truth for current signatures.
> For *what to build*, `project-structure.md` and `deckbuilder-patterns.md` are
> language-agnostic and apply here too.

## Node classes: `partial`, inherit a Godot type

Every script that Godot instantiates is a `partial class` deriving from a Godot node type.
**`partial` is mandatory** — Godot's source generator emits the other half (the
`MethodName`/`PropertyName`/`SignalName` lookup classes, marshalling, signal glue) into a
sibling partial. Omitting it breaks generation.

```csharp
using Godot;

public partial class CardView : Control     // partial + Godot base type
{
    // ...
}
```

- File-scoped namespaces (`namespace Game.Cards;`) and one public type per file.
- `[GlobalClass]` to register the type for the editor's "create node" / inspector lists.
- `[Tool]` **only** for scripts that must run in the editor (editor plugins, `@tool`-style
  preview behavior) — not for normal gameplay nodes.

## Reference child nodes: `GetNode<T>("%Unique")` in `_Ready`

Cache children in `_Ready()` as private fields. The dominant idiom in the shipped game is
**unique-name access** (`%Name`), with plain relative paths for simple cases:

```csharp
private MegaLabel _goldLabel;
private TextureRect _icon;

public override void _Ready()
{
    _goldLabel = GetNode<MegaLabel>("%GoldLabel");   // % = scene-unique, survives reparenting
    _icon      = GetNode<TextureRect>("Icon");        // relative path for a stable direct child
}
```

- Prefer `%Unique` over deep `"A/B/C"` paths — same rule as GDScript.
- `[Export]` a `Node`/`NodePath` field when the wiring should be done in the inspector
  (the `.tscn` stores it as `node_paths=PackedStringArray(...)`).
- Resolve `GetNode` in `_Ready`, never in the constructor (the tree isn't ready yet).
- Pass non-node dependencies via an explicit `Initialize(state)` method after instantiation
  rather than the constructor.

## Signals: `[Signal]` for nodes, `event Action` for models

Two distinct mechanisms, used deliberately:

```csharp
// Node-to-node: Godot signal (shows in editor, crosses the C#/GDScript boundary)
[Signal] public delegate void ReleasedEventHandler(NClickableControl button);
// emit:
EmitSignal(SignalName.Released, this);

// Plain C# data/model class (not a Node): use a C# event
public event Action<int, int> BlockChanged;
public event Action Died;
```

- Use `[Signal] delegate …EventHandler` for **Node** classes and anything the editor or
  GDScript must see/connect.
- Use plain C# `event Action<…>` for **non-Node** model/state classes (a `Creature`,
  `RunManager`) — lighter, strongly typed, no marshalling. The shipped game's data layer is
  almost entirely C# events; its nodes use `[Signal]`.
- Connect built-in signals with `Connect(Control.SignalName.MouseEntered,
  Callable.From(OnMouseEntered))` — `Callable.From` wraps a C# method with no boilerplate.

## Exports

```csharp
[Export] private float _duration = 0.5f;
[Export] private Godot.Collections.Array<NParticlesContainer> _particles;
[Export] private Curve _particlesCurve;
```

Inline C# defaults; use Godot collection types (`Godot.Collections.Array<T>`,
`Dictionary<,>`) for exported containers so they marshal. Custom `Resource` subclasses
export and edit in the inspector like built-ins.

## Lifecycle and async

- `_Ready` — grab children, set up. `_EnterTree`/`_ExitTree` — **subscribe/unsubscribe**
  external events here (subscribe in enter, unsubscribe in exit; nodes get re-parented and
  leak otherwise):

```csharp
public override void _EnterTree() { RunManager.Instance.ActEntered += OnActEntered; }
public override void _ExitTree()  { RunManager.Instance.ActEntered -= OnActEntered; }
```

- Async is `Task`-based and integrates with Godot via `ToSignal` and tweens:

```csharp
Tween t = CreateTween().SetParallel();
t.TweenProperty(_banner, "modulate:a", 1f, 0.5)
 .SetEase(Tween.EaseType.Out).SetTrans(Tween.TransitionType.Quad);
await ToSignal(t, Tween.SignalName.Finished);     // await an animation
await ToSignal(GetTree(), SceneTree.SignalName.ProcessFrame);  // wait one frame
```

- `await Task.Delay(ms)` for plain delays (thread a `CancellationToken` for cancelable
  waits). Chain tween steps with `.Chain()`; intervals with `.TweenInterval()`.

## Data: `Resource` for inspector data, plain classes for logic

- Serializable/inspector-editable data → a `Resource` subclass with `[Export]` fields.
- Transient runtime models / game logic → **plain C# classes** (not `Resource`/`Node`),
  with C# events for change notification. Keep rules out of the scene tree so they're
  unit-testable. (This is the model/entity/view split from `deckbuilder-patterns.md`.)

## Interop: calling GDScript from C#

Some engine features ship as GDExtension/GDScript-only APIs (FMOD audio is the canonical
case). Bridge them with a **GDScript autoload proxy** and call it via `Node.Call`, caching
method names as `StringName` to avoid per-call allocation:

```csharp
private static readonly StringName _playOneShot = new StringName("play_one_shot");
private Node _audio;
public override void _EnterTree() => _audio = GetNode<Node>("%AudioProxy");
public void PlaySfx(string path) => _audio.Call(_playOneShot, path);
```

Keep GDScript to these proxies, `[Tool]`/`EditorPlugin` scripts, and quick VFX-iteration
tools; keep gameplay/logic in C#. (See the GDScript-usage notes in this skill set.)

## Safe-node extension helpers

Build a small set of `static` extension methods on `Node`/`Control` and use them
everywhere — the shipped game leans on these heavily:

```csharp
node.QueueFreeSafely();          // validity check (+ object-pool return) before freeing
parent.AddChildSafely(child);    // main-thread check, else CallDeferred(AddChild)
control.TryGrabFocus();          // no-op if invalid
var hud = node.GetAncestorOfType<NHud>();
foreach (var c in node.GetChildrenRecursive<NCard>()) { ... }
```

They centralize the recurring guards (is-valid, on-main-thread, deferred tree mutation)
that otherwise get forgotten at individual call sites.

## Top idioms

1. `public partial class X : <GodotType>` — `partial` is required for source generation.
2. Cache children in `_Ready` via `GetNode<T>("%Unique")`; avoid `../../` paths and constructors.
3. `[Signal] delegate …EventHandler` for nodes; plain `event Action<…>` for non-node models.
4. `Connect(SignalName.X, Callable.From(Handler))` — no lambda boilerplate.
5. Subscribe in `_EnterTree`, unsubscribe in `_ExitTree` — prevent leaks on reparent.
6. `[Export]` with inline defaults; `Godot.Collections.Array<T>`/`Dictionary` for exported containers.
7. `await ToSignal(tween, Tween.SignalName.Finished)` / `ProcessFrame`; `Task.Delay` with a token.
8. `Resource` subclass for inspector data; plain C# class for logic (testable, tree-free).
9. Bridge GDScript-only APIs via an autoload proxy + `Node.Call(StringName)`; cache the `StringName`.
10. Wrap node ops in safe extension helpers (`QueueFreeSafely`, `AddChildSafely`, …).
11. Verify any API against the live engine (`engine class-info`/`engine search`) — never from memory.
