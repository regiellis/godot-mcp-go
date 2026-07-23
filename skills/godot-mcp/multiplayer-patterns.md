# Godot multiplayer patterns (Godot 4.7+) — high-level networking with godot-mcp

Building co-op / versus games on Godot's **high-level multiplayer** (`SceneMultiplayer` +
RPC + the replication nodes), mapped to the CLI. The `multiplayer` command group wires the
two replication nodes; everything else is plain `node.*` / `script.*` plus the live API.
**Verify APIs against the running engine** (`engine class-info --class MultiplayerAPI`). The class surface
below was read from the running 4.7.1 build, but *two-peer behavior cannot be exercised from
this single-instance CLI* — the runtime claims are the standard architecture, proven with two
real instances (see "Testing locally"), not something this session watched replicate.

## The mental model

High-level multiplayer replicates a **scene tree**, not packets. Every peer runs the same
scene with the same node paths — `/root/Game/Players/12345` must exist and mean the same
thing everywhere, because RPCs and synchronizers address nodes **by path**. Break path
symmetry and every message silently misfires.

- **One `MultiplayerAPI` per node.** Each `Node` exposes `multiplayer` (verified) — by default
  all share the tree's one API. It carries the peer, the connection signals, and
  `get_unique_id()` / `is_server()` / `get_peers()` / `get_remote_sender_id()` (all verified).
- **Server-authoritative is the default.** State lives on the server; clients send **intent**
  ("move left", "fire"), the server simulates, the result streams back. Clients never own
  truth — that is what makes a game hard to cheat. The pragmatic co-op shortcut (client owns
  its own player) is under Authority, with its tradeoff stated.
- **Unique ids.** The server is **always peer `1`**; each client gets a random positive id.
  `multiplayer.get_unique_id()` returns this peer's id (`1` = "I am the server").

This doc is realtime state replication; for request/response web traffic (leaderboards) use
`HTTPRequest`, not this stack — see `game-patterns.md` "Networking — HTTP".

## Connection & peers

`ENetMultiplayerPeer` is the transport. Verified: `create_server(port, max_clients, ...)` and
`create_client(address, port, ...)` both return an `Error` int (`OK == 0` — **check it**).
Assign the peer to `multiplayer.multiplayer_peer` and the tree is networked.

```gdscript
extends Node   # autoload "Net", registered via `project add-autoload`
const PORT := 8910

func host() -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, 4)   # port, max_clients
	if err != OK: return err                 # port in use — never assume it bound
	multiplayer.multiplayer_peer = peer      # this peer is now id 1 (the server)
	return OK

func join(address: String) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK: return err
	multiplayer.multiplayer_peer = peer
	return OK
```

**Connection signals live on `MultiplayerAPI`, not `SceneTree`** (verified — 4.x moved them
off the tree). Wire once in the autoload's `_ready`: `peer_connected(id)` /
`peer_disconnected(id)` fire on every peer; `connected_to_server()` / `connection_failed()` /
`server_disconnected()` are client-only. Server-side `peer_connected` is where you spawn the
newcomer's player. Host/Join **buttons** and the lobby menu belong to a Control scene — build
it with the container-driven skeleton in `menus-settings.md`; the `pressed` handler calls
`Net.host()` / `Net.join(address)`. Autoload tiering: `gdscript-architecture.md`.

## Authority — who owns each node

Authority decides which peer's copy of a node is truth (verified `Node` methods):
`set_multiplayer_authority(id, recursive = true)` claims a node (and its subtree);
`is_multiplayer_authority()` asks "do I own this?"; `get_multiplayer_authority()` returns the
owner. **Authority defaults to the server (1)** until reassigned. **Gate simulation on it** —
the owner runs the logic (`if not is_multiplayer_authority(): return` at the top of
`_physics_process`), everyone else just displays the replicated result (skeleton below).

- **Server owns the world** — enemies, doors, score, physics. Authority stays `1`. Discrete
  facts go out as RPCs from the server; continuous state rides a synchronizer.
- **Each client owns its own player** (client-authoritative input) — the *pragmatic co-op
  shortcut*. In `_ready`, `set_multiplayer_authority(str(name).to_int())` (node named for its peer
  id, below); the gate lets only the owner drive it. Cheap, responsive, no round-trip lag on
  your own avatar. **Tradeoff: it trusts the client** — a modded client can teleport or
  speed-hack, because its position *is* the truth. Fine for friendly co-op, wrong for
  competitive, where authority stays on the server: the client sends an intent RPC
  (`request_move(dir)`), the server validates and simulates, and the synchronizer streams the
  vetted position back.

## @rpc — remote procedure calls

`@rpc` marks a function callable across the wire. **Its annotation arguments cannot be read
from `ClassDB`** (parser sugar), so the accepted set was verified by **compiling variants**
through `script validate` — an invalid argument is a hard parse error. Confirmed-valid
arguments (order-independent, all optional):

- **Who may call:** `"authority"` (default — only the node's authority) or `"any_peer"`
  (required for client→server intent).
- **Local execution:** `"call_remote"` (default — remote peers only) or `"call_local"` (also
  runs on the caller, so the sender sees its own effect).
- **Transfer mode:** `"reliable"` (resent until acked — state, chat), `"unreliable"` (default
  — high-frequency streams), `"unreliable_ordered"` (drops stale, keeps order); plus a
  trailing **int** channel (default `0`) to avoid head-of-line blocking between traffic.

Verified to **compile**: `@rpc`, `@rpc("any_peer")`, `@rpc("call_local")`, `@rpc("reliable")`,
`@rpc("unreliable_ordered")`, and the full `@rpc("any_peer", "call_local", "reliable", 2)`.
Verified to **fail**: `@rpc("bogus_mode")` and `@rpc(..., "super_reliable", 0)` — a wrong mode
string is a parse error, so validate any hand-written annotation before trusting it.

Invoke with `rpc("method", args...)` (all peers) or `rpc_id(1, "method", args...)` (one target
— here the server). **Always validate an `any_peer` RPC's caller** with
`multiplayer.get_remote_sender_id()` (verified), or a client calls your server functions
directly. Author RPCs with `script edit` (annotated methods on the node's script) + `editor reload`.

```gdscript
@rpc("any_peer", "reliable")
func request_fire() -> void:
	var who := multiplayer.get_remote_sender_id()
	if not _player_owns_a_gun(who):   # never trust the call blindly
		return
	_spawn_bullet_for(who)            # server authoritative: server does the work
```

## MultiplayerSpawner — replicate node existence

A synchronizer replicates *properties of existing nodes*; a `MultiplayerSpawner` replicates
**the existence** of nodes. Verified: `add_spawnable_scene(path)`, `spawn_path` (NodePath),
`spawn_limit` (int), `spawn_function` (Callable), `spawn(data)`.

- **Auto-spawn:** when the **server** `add_child()`s a node under the spawner's `spawn_path`
  node, and that scene is in the spawnable list, the spawner recreates it on every client —
  the common path; you never call `spawn()` yourself.
- **`spawn_function`** handles **custom-data** spawns: a `Callable(data) -> Node`, then
  `spawn(data)` (character choice, spawn point). Our command doesn't set it; assign in code.

Our command wires the awkward `spawn_path` NodePath (a **scene-relative** path it resolves to
the stored spawner-relative one) and the scene list, validating each exists (`missing_scenes`);
`--spawn-limit` caps concurrent spawns:

```
node add --type Node --name Players --parent-path .
multiplayer add-spawner --parent-path . --name PlayerSpawner \
    --spawn-path Players --scenes '["res://entities/player.tscn"]'
multiplayer info --node-path PlayerSpawner    # read spawn_path + spawnable_scenes back
scene save
```

## MultiplayerSynchronizer — replicate node properties

Streams chosen properties from a node's **authority** to everyone else, driven by a
`SceneReplicationConfig`. Verified: `root_path` (NodePath, default `..` — its parent),
`replication_config`, `replication_interval`, `delta_interval`, `public_visibility` (bool),
`set_visibility_for(peer, visible)`, `visibility_update_mode`. The config is built with
`add_property(path)` + `property_set_spawn/sync/watch(path, enabled)` (all verified).

- **Property paths are relative to `root_path`.** `.:position` is the root node's own
  `position`; `Sprite2D:modulate` a child's. Make the synchronizer a **child of** what it
  syncs and leave `root_path` default.
- **`sync` vs `watch`:** a *synced* property sends every interval; a *watched* one sends (on
  `delta_interval`) only when it changes — cheaper for rarely-moving state. *spawn* includes
  the value in the initial spawn snapshot.
- **`replication_interval`** throttles frequency — `0` (default) = every network frame (the
  bound setter names its arg `milliseconds`). **Visibility:** `public_visibility = false` +
  `set_visibility_for(peer, true)` scopes a synchronizer to specific peers (fog-of-war).

**The direction gotcha:** a synchronizer replicates **FROM the authority of its `root_path`
node TO everyone else.** If the player's authority is its owning client, that client's
position is the source and streams outward; if authority is the server, the server's copy
wins. Set authority *before* relying on the sync, or you stream the wrong copy and rubber-band.

```
multiplayer add-synchronizer --parent-path . --name Sync --root . \
    --properties '[".:position", ".:rotation"]'
multiplayer add-sync-property --node-path Sync --property ".:velocity" --watch=true --sync=false
scene save
```

## The canonical co-op skeleton

The flagship — a host/join lobby, a spawner minting one player per peer, per-peer authority,
and a synchronizer streaming each player's transform. Client-authoritative input (the
shortcut); the notes above say how to harden it to server-authoritative.

**1. Player scene** — gates on authority, self-assigns authority from its node name:

```
scene create --path res://entities/player.tscn --root-type CharacterBody2D --root-name Player
scene open --path res://entities/player.tscn
node add --type Sprite2D --name Sprite --parent-path .
node add --type CollisionShape2D --name Col --parent-path .
node add-resource --node-path Col --property shape --resource-type CircleShape2D
multiplayer add-synchronizer --parent-path . --name Sync --root . --properties '[".:position"]'
script create --path res://entities/player.gd --extends CharacterBody2D
script attach --node-path . --script-path res://entities/player.gd
scene save
```

```gdscript
extends CharacterBody2D
@export var speed := 300.0

func _ready() -> void:
	set_multiplayer_authority(str(name).to_int())    # node is named for its peer id

func _physics_process(_delta: float) -> void:
	if not is_multiplayer_authority():
		return                                   # non-owners are moved by the Sync node
	var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	velocity = dir * speed
	move_and_slide()
```

**2. Game scene** — a `Players` container plus the spawner over it:

```
scene create --path res://game.tscn --root-type Node2D --root-name Game
scene open --path res://game.tscn
node add --type Node --name Players --parent-path .
multiplayer add-spawner --parent-path . --name PlayerSpawner \
    --spawn-path Players --scenes '["res://entities/player.tscn"]'
scene save
```

**3. Server spawns on connect** (in the `Net` autoload). The server instances a player named
for the peer id under `Players`; the spawner replicates it, and each player's `_ready` claims
authority from its name — so the owner drives it and its synchronizer streams the result out:

```gdscript
const PLAYER := preload("res://entities/player.tscn")

func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return                                   # only the server spawns
	var p := PLAYER.instantiate()
	p.name = str(id)                             # path symmetry: /Game/Players/<id> everywhere
	get_node("/root/Game/Players").add_child(p)  # spawner sees the add → replicates it
```

Spawn the host's own player the same way after `host()` (call `_on_peer_connected(1)`).

## Intent RPCs vs synchronized state — never both for one fact

The most common design error is replicating one fact two ways. Split by shape:

- **Continuous state → `MultiplayerSynchronizer`.** Positions, rotations, health — changes
  every frame, only the *latest* value matters (a dropped unreliable packet self-corrects).
- **Discrete events → RPCs.** Fire, jump, pickup, chat, "round over" — one-shot facts that
  must arrive exactly once (`"reliable"`) and are meaningless to poll.

Pick one per fact. Do **not** sync a `bool is_firing` *and* send a `fire()` RPC — the receiver
acts twice. And never sync **derived** state: replicate the source and recompute UI locally.

## Testing locally — be honest about the harness

Networking needs **two running instances**, and this CLI cannot provide the second: the
`runtime` / `input` groups broker **one** game process over file IPC — no multi-instance
driver here. Options, most practical first:

- **Editor "Debug ▸ Customize Run Instances"** — Godot 4's editor launches N instances at
  once, each with its own args/feature tags (one server, the rest clients). An editor feature,
  not a CLI one; drive it by hand.
- **Two OS processes** with a role flag your `_ready` reads: `godot --path . -- --server` and
  `godot --path . -- --client` (parse `OS.get_cmdline_args()` → `Net.host()` / `Net.join(...)`);
  a one-key test can spawn the second via `OS.create_process`.
- **What the CLI *can* verify** on its single instance: scene structure (`scene tree`), that
  the spawner/synchronizer hold the right config (`multiplayer info`), that scripts compile and
  RPC annotations parse (`script validate`). The replication itself you confirm across two windows.

## Common mistakes to avoid

- **Peer set after scenes load.** Assign `multiplayer.multiplayer_peer` and wire its signals
  *before* the networked scene enters the tree, or early spawns/RPCs fire into a peerless tree.
- **Missing authority checks** — every networked `_physics_process` / input handler needs the
  `if not is_multiplayer_authority(): return` gate, or peers simulate every node and diverge.
- **Mismatched node paths** — a player named `str(id)` on the server but auto-named `Player2`
  on a client means every path-addressed message misses. Keep names identical everywhere.
- **Trusting client RPCs** — an `@rpc("any_peer")` handler that skips `get_remote_sender_id()`
  validation lets any client run server logic with forged args.
- **Syncing derived state**, or **both an RPC and a synced property for one fact** (receiver
  double-acts) — see "Intent vs state".
- **Trusting a remembered signal home** — connection signals are on `MultiplayerAPI`, not
  `SceneTree`; confirm any networking API with `engine class-info` before writing it.
