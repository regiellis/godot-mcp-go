# Shipping & Export — the release pipeline

When a project leaves the editor for players, three problems appear that the build-and-playtest
loop never surfaces: dev tooling riding along inside the pck, the pck itself being an open book
(stock tools list and extract every script and scene), and an oversized runtime. This is the
pipeline that closes all three, proven end to end on a real desktop release. The
discipline throughout is the same as everywhere else in this skill: **verify by receipts, not by
exit codes** — a green export means the exporter ran, not that the build is right.

## The dev-tooling boundary: this addon must never ship

The godot-mcp addon is a WebSocket command server with arbitrary-eval and input-injection
surfaces, and its two game-side autoloads stat IPC files every frame. None of that belongs in a
player build.

1. **Export filters.** In the preset: `exclude_filter="addons/godot_mcp/*,tools/*"` (plus any
   other dev-only trees). `.gdignore`d folders never export, but plain `.gd`/`.tscn`/`.tres`
   under an addon all do unless excluded.
2. **Disable the plugin before exporting.** Disabling removes the `MCPGameInspector` /
   `MCPGameInput` autoloads from `project.godot` — removal matches entries by the addon's own
   script paths, so autoloads persisted into the file by an earlier session are cleaned too, and
   any unrelated autoload a project declares itself is untouched. Re-enabling self-installs them
   again; there is nothing to restore by hand. (Disabling kills the CLI's own server —
   expected; the export step below runs headless without it.)
3. **Receipts.** After exporting, string-scan the pck: the excluded paths and autoload names must
   score zero hits, and known-good game paths must be present:

   ```powershell
   $t = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes("Game.pck"))
   ([regex]::Matches($t, 'godot_mcp')).Count      # 0 or the addon shipped
   ([regex]::Matches($t, 'MCPGame')).Count        # 0 covers project.binary's autoload list
   ([regex]::Matches($t, 'res://scenes')).Count   # >0 control: the game itself is in there
   ```

## The headless export loop

No editor needed once the preset exists (the exporting binary must still be the project's editor
build):

```
godot --headless --path . --export-release "Windows Desktop" "out/Game.exe"
```

- Exit 0 plus a final `[ DONE ] savepack` line is the transport signal; the receipts above and a
  boot test are the real verdict.
- Templates resolve from `%APPDATA%/Godot/export_templates/<major.minor.patch.status>/` unless
  the preset's `custom_template/*` points elsewhere (which is how keyed/size-optimized templates
  ship — below).
- Boot the exe and let it hold past its first scene: a window with the right title that survives
  ~10s is the cheapest whole-pipeline receipt there is.

## PCK encryption: keyed custom templates

Godot encrypts the pck (AES-256) only when the **export templates themselves carry the key** —
official templates cannot do it. Understand what it buys: casual extraction is blocked, but the
key necessarily lives inside the shipped exe, so a determined reverse-engineer can dig it out.
Deterrence, not DRM.

1. **Generate a 256-bit key once** (64 hex chars) and keep it **outside the repo** — never
   commit it, never print it into a log or chat transcript:

   ```powershell
   $b = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($b)
   ($b | ForEach-Object { $_.ToString('x2') }) -join '' | Set-Content ~\.godot-keys\game.key -NoNewline
   ```

   Back the file up. A lost key just means rebuilding templates with a new one, but every future
   export of the same build needs the same key.

2. **Bake it into templates.** Set `SCRIPT_AES256_ENCRYPTION_KEY` in the environment and build
   the template target with the same feature flags as the project's editor build:

   ```powershell
   $env:SCRIPT_AES256_ENCRYPTION_KEY = (Get-Content ~\.godot-keys\game.key -Raw).Trim()
   scons target=template_release arch=x86_64 production=yes   # + d3d12=yes etc. to match
   ```

   On a warm build tree this is an incremental recompile-and-relink measured in **seconds, not
   minutes** — the key lands in one generated file. Copy the built template (and its `.console`
   sibling) somewhere stable next to the key; later builds overwrite `bin/`.

3. **Wire the preset**: `encrypt_pck=true`, `encrypt_directory=true`,
   `encryption_include_filters="*"` (encrypting everything is cheap for small pcks), and
   `custom_template/release` pointing at the keyed template.

4. **Supply the key at export time via `GODOT_SCRIPT_ENCRYPTION_KEY`** (verified working live)
   in the environment of the headless export. The preset's key field works too but persists the
   key in plaintext into `export_presets.cfg` — a committed file. The env var keeps it out.

5. **Receipts.** The plaintext scan from above flips: game paths and `gd_scene` markers drop to
   **zero** hits in an encrypted pck. Then boot the exe — **a booting game IS the key-match
   proof**; `ERR_FILE_CORRUPT` at startup means the template's baked key and the export-time key
   disagree (or the template is an unkeyed one).

## Size-optimized templates

The same custom-template slot takes size work. The scons knobs, in descending order of value for
a typical 2D game (official numbers, condensed):

- `production=yes` — the baseline for anything shipped (implies dead-code stripping and sane
  defaults); `debug_symbols=no` alone is a 5–10× binary reduction when not already implied.
- `optimize=size` (or `size_extra`) — high savings, mild CPU cost; what web builds already do.
- `lto=full` — high savings; slow links and 12–16 GB RAM at build time. Release-only.
- `disable_3d=yes` — ~15% off a 2D-only game. **Template targets only** (the editor cannot build
  without 3D); grep the project for 3D node types first.
- `module_text_server_adv_enabled=no module_text_server_fb_enabled=yes` — high savings; loses
  RTL text, ligatures and OpenType features. Only for Latin/Greek/Cyrillic-only games.
- `disable_advanced_gui=yes` — moderate; deletes Tree, ItemList, TextEdit, GraphEdit,
  ColorPicker, FileDialog and friends. Many UI-heavy games can't take this — audit first.
- `build_profile=<file>.gdbuild` — moderate-to-high, project-derived class stripping. The sharp
  edge: it can strip classes only reached via reflection/`load()` at runtime.
- Per-module `module_*_enabled=no` (see `scons --help`) and physics you don't use
  (`module_jolt_enabled=no`, `disable_physics_3d=yes`) — small each, additive.
- Distribution: 7-Zip Ultra for desktop zips typically shaves another 1–5 MB.

**Every knob gets the same gate:** export, run the receipts, boot the game, and run the
project's own regression suite against a restored dev environment. A build that lost a module it
actually needed usually still boots — it fails at the moment the feature is touched, which is
exactly what a playtest suite catches and a boot test does not.

## The restore step

Shipping state and dev state differ (plugin off, autoloads gone). After exporting, put the
project back deliberately: re-enable the plugin (autoloads self-install on load) or
`git checkout` the project file if the flow edited it, relaunch the editor, and run the
project's verification so the next session starts from a proven-green baseline.
