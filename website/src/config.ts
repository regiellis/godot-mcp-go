// Site metadata and the docs sidebar. Edit the nav here; the sidebar renders it.
// `slug` is the docs path (no base, no leading slash). Authored pages live under
// src/content/docs/; guides are glob-imported from ../skills/godot-mcp/*.md and
// keyed by filename (see GUIDES), so they never drift from the real craft docs.

export const SITE = {
  name: "godot-mcp",
  tagline: "Drive a running Godot 4.7 editor from the CLI and from AI agents.",
  description:
    "A Go CLI and GDScript editor addon that drive a live Godot 4.7 editor over WebSocket: build scenes, write GDScript or C#, play and inspect the running game, and introspect the engine's real API. 312 commands across 49 groups.",
  repo: "https://github.com/regiellis/godot-mcp-go",
  editorVersion: "Godot 4.7+",
};

export type NavItem = { label: string; slug: string; badge?: string };
export type NavGroup = { group: string; items: NavItem[] };

// The craft references, rendered from ../skills/godot-mcp/<slug>.md. Order here
// is the reading order within each group. Descriptions are the card/subtitle text.
export type Guide = { slug: string; title: string; group: string; desc: string };

export const GUIDE_GROUPS = ["Foundations", "2D", "3D and spatial", "Systems", "Genres", "Interop"];

export const GUIDES: Guide[] = [
  { slug: "gdscript-style", group: "Foundations", title: "GDScript style", desc: "Idioms a competent Godot dev ships: static typing, signals over polling, Resources for data." },
  { slug: "game-patterns", group: "Foundations", title: "Game patterns", desc: "Buildable patterns mapped to command sequences: movement, game feel vs juice, components, state machines, HUD." },
  { slug: "project-structure", group: "Foundations", title: "Project structure", desc: "How a shipped project is laid out to scale: code/asset separation, feature slices, data/view split, composition." },
  { slug: "gdscript-architecture", group: "Foundations", title: "GDScript architecture", desc: "Large-scale runtime architecture: autoload tiering, service locator, path-addressed stores, scene routing." },

  { slug: "platformer-2d", group: "2D", title: "2D platformers", desc: "The component actor, an intent API, physics-expression AnimationTree transitions, codeless moving platforms." },
  { slug: "topdown-2d", group: "2D", title: "Top-down 2D", desc: "Layered TileMapLayer stacks, gameplay as terrain painting, a component library, the one-clock day/night pattern." },
  { slug: "ui-polish-2d", group: "2D", title: "2D UI polish", desc: "Comp-faithful UI: a design-token class, drawn controls, the screen-builder traps that silently swallow writes." },
  { slug: "lighting-2d", group: "2D", title: "2D lighting", desc: "The full 2D lighting stack: the CanvasModulate/PointLight2D/occluder triad, emissive exemptions, real glow, SDF." },
  { slug: "tile-constraint", group: "2D", title: "Constraint tiling", desc: "The Townscaper/Bad North PCG family: the dual-grid fix, Wave Function Collapse from an example, variant buckets." },

  { slug: "level-design", group: "3D and spatial", title: "Level design", desc: "Playable greybox levels: the Big to Small risk order, a greybox colour language, spatial-communication tactics." },
  { slug: "character-3d", group: "3D and spatial", title: "3D character controllers", desc: "One camera-relative movement core for FPS, third-person, and platformer, plus the floor contract and rigs." },
  { slug: "environment-art", group: "3D and spatial", title: "Environment art", desc: "The art pass after the greybox is proven: PBR materials, real lighting, post restraint, set dressing, the paper diorama." },

  { slug: "menus-settings", group: "Systems", title: "Menus and settings", desc: "The meta-game screens: pause done right, the settings widget family, ConfigFile persistence, input remapping." },
  { slug: "audio-music", group: "Systems", title: "Audio and music", desc: "Bus architecture, SFX variation, interactive music, sidechain ducking, spectrum-driven visuals, loop points." },
  { slug: "shaders-vfx", group: "Systems", title: "Shaders and VFX", desc: "gdshader authoring and wiring, the 2D VFX kit, and a programmatic compile-verification loop." },
  { slug: "save-systems", group: "Systems", title: "Save systems", desc: "Authoritative vs derived state, the persist-group collector, the five-format tradeoff, atomic autosave." },
  { slug: "multiplayer-patterns", group: "Systems", title: "Multiplayer", desc: "Scene-tree replication, ENet, authority gates, @rpc arguments, the co-op skeleton, intent RPCs vs synced state." },
  { slug: "mobile-touch", group: "Systems", title: "Mobile and touch", desc: "Index-keyed multitouch, on-screen controls, pinch/pan gestures, safe-area HUD insets." },
  { slug: "rhythm-games", group: "Systems", title: "Rhythm games", desc: "The corrected audio clock pushed down the tree, beatmap data, notes as functions of time, windowed judging." },
  { slug: "in-game-docs", group: "Systems", title: "In-game docs", desc: "Gyms, zoos, and museums: document the game in-game with doc.* recipes so it never goes stale." },

  { slug: "event-deck-games", group: "Genres", title: "Event / decision games", desc: "Reigns-like architecture: immutable cards plus a mutable overlay that is the save, weighted selection, condition DSLs." },
  { slug: "run-based-games", group: "Genres", title: "Run-based / roguelite", desc: "The reactive data blackboard, wave assembly under a weight budget, seeded staged worldgen with a self-audit." },
  { slug: "deckbuilder-patterns", group: "Genres", title: "Deckbuilders", desc: "The logic layer: an action queue, a hook pipeline for powers and relics, data-driven cards, event-sourced history." },
  { slug: "narrative-game-patterns", group: "Genres", title: "Narrative / visual novel", desc: "Both families (Ink and graph dialogue) plus the manifest-driven product shell: boot flow, versioned saves, chapter select." },

  { slug: "unreal-import-cleanup", group: "Interop", title: "Unreal import cleanup", desc: "Fixing a scene exported from Unreal: env, lights, junk, imports order, and why it comes in washed out." },
  { slug: "csharp-godot", group: "Interop", title: "C# in Godot", desc: "C#-in-Godot idioms for editing a C# project. Pair with the csharp group: setup scaffolds the solution, build compiles with structured diagnostics." },
];

// Authored pages, in reading order. Guides are appended as their own groups below.
const AUTHORED: NavGroup[] = [
  {
    group: "Getting started",
    items: [
      { label: "Overview", slug: "" },
      { label: "Quickstart", slug: "quickstart" },
      { label: "Installation", slug: "installation" },
      { label: "Use with an AI client", slug: "mcp-setup" },
      { label: "Addressing AI use in game development", slug: "on-ai" },
    ],
  },
  {
    group: "Working with the editor",
    items: [
      { label: "Discover, then drive", slug: "discover-then-drive" },
      { label: "Spatial placement", slug: "spatial-placement", badge: "deep" },
      { label: "Playtest loop", slug: "playtest-loop" },
      { label: "C# projects", slug: "csharp" },
      { label: "Live-engine gotchas", slug: "gotchas" },
      { label: "Live dashboard", slug: "dashboard" },
    ],
  },
  {
    group: "Reference",
    items: [
      { label: "Command groups", slug: "commands" },
      { label: "Custom commands", slug: "extending" },
      { label: "How it works", slug: "how-it-works" },
    ],
  },
  {
    group: "Building the Godot way",
    items: [{ label: "Guides overview", slug: "guides" }],
  },
];

const GUIDE_SECTIONS: NavGroup[] = GUIDE_GROUPS.map((g) => ({
  group: g,
  items: GUIDES.filter((gd) => gd.group === g).map((gd) => ({
    label: gd.title,
    slug: `guides/${gd.slug}`,
  })),
}));

const SHOWCASE: NavGroup[] = [{ group: "Showcase", items: [{ label: "Samples", slug: "samples" }] }];

export const SIDEBAR: NavGroup[] = [...AUTHORED, ...GUIDE_SECTIONS, ...SHOWCASE];

// Flattened, in reading order, for prev/next navigation.
export const NAV_FLAT: NavItem[] = SIDEBAR.flatMap((g) => g.items);

export function guideBySlug(slug: string): Guide | undefined {
  return GUIDES.find((g) => g.slug === slug);
}
