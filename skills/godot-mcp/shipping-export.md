# Shipping & Export: the release pipeline

When a project leaves the editor for players, three problems appear that the build-and-playtest
loop never surfaces: dev tooling riding along inside the pck, the pck itself being an open book
(stock tools list and extract every script and scene), and an oversized runtime. The pipeline
below closes all three, proven end to end on a real desktop release. Throughout it,
**verify by receipts, not by exit codes**. A green export means the exporter ran, not that
the build is right.

## Pick your target

The first five sections below are platform-independent: the export filters, the headless loop, pck
encryption, the size knobs, and the platform-SDK gate read the same whether the artifact is an
`.exe`, an `.apk`, or a folder of wasm. The per-platform sections after them cover what each
target adds.

| Target | Exports from a Windows dev machine | Host tooling it needs | Signing identity |
| --- | --- | --- | --- |
| Windows, Linux desktop | yes | export templates | optional (`codesign/*` on the Windows preset) |
| Android | yes | JDK, Android SDK, platform-tools | release keystore, yours to generate and keep |
| Web | yes | a static server for testing | none; the browser enforces headers instead |
| macOS | bundle yes, signing and notarization no | Apple tooling for the signing leg | Apple Developer certificate |
| iOS | preset and Xcode project only | Xcode on a Mac for the final leg | Apple Developer provisioning profile |

Read the ground before touching a preset. Every one of these answers without an export configured
and says what is missing:

```
godot-mcp export info            # templates installed? export_presets.cfg present?
godot-mcp export list-presets    # name, platform, runnable, export_path per preset
godot-mcp export project --preset-name "Windows Desktop" --debug=false
```

`export project` returns the headless command line rather than running it, because a Godot 4 editor
plugin cannot export. `godot-mcp export "<preset>"` is the local subcommand that runs that command
line for you, and it needs no editor at all.

## The dev-tooling boundary: this addon must never ship

The godot-mcp addon is a WebSocket command server with arbitrary-eval and input-injection
surfaces, and its two game-side autoloads stat IPC files every frame. None of that belongs in a
player build.

1. **Export filters.** In the preset: `exclude_filter="addons/godot_mcp/*,tools/*"` (plus any
   other dev-only trees). `.gdignore`d folders never export, but plain `.gd`/`.tscn`/`.tres`
   under an addon all do unless excluded.
2. **Disable the plugin before exporting.** Disabling removes the `MCPGameInspector` /
   `MCPGameInput` autoloads from `project.godot`. Removal matches entries by the addon's own
   script paths, so autoloads persisted into the file by an earlier session are cleaned too, and
   any unrelated autoload a project declares itself is untouched. Re-enabling self-installs them
   again; there is nothing to restore by hand. (Disabling also kills the CLI's own server, which
   is expected: the export step below runs headless without it.)
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
godot-mcp export "Windows Desktop"
```

The output path defaults to the preset's own `export_path`, and `--out PATH` overrides it. The
command runs the export in the foreground, exits with Godot's code, and reports the file it
produced, its size, and the `ERROR`/`WARNING` lines it parsed out of
`<project>/.godot/godot-mcp-export.log`. Where the CLI is not installed, the raw form is what it
runs for you:

```
godot --headless --path . --export-release "Windows Desktop" "out/Game.exe"
```

- **An export that exits 0 and wrote nothing is the failure to watch for**, and `godot-mcp export`
  turns it into a non-zero exit with `exists: false` rather than a clean run. Missing export
  templates are the usual cause, and the parsed errors name each file the engine looked for.
- Exit 0 plus a final `[ DONE ] savepack` line is the transport signal; the receipts above and a
  boot test are the real verdict.
- Templates resolve from `%APPDATA%/Godot/export_templates/<major.minor.patch.status>/` unless
  the preset's `custom_template/*` points elsewhere, which is how the keyed and size-optimized
  templates below ship.
- Boot the exe and let it hold past its first scene: a window with the right title that survives
  ~10s is the cheapest whole-pipeline receipt there is.
- **When the pck is buried, export one on its own to scan**. Adding `--pack` and an
  `--out out/receipt.pck` writes the data half of the same preset as a standalone file, so the
  string scan above works for an APK, a web build, or a desktop preset with
  `binary_format/embed_pck=true`, none of which leave a loose `.pck` to read. `--patch` with
  `--patches a.pck,b.pck` does the same for a changed-files-only pack.

## PCK encryption: keyed custom templates

Godot encrypts the pck (AES-256) only when the **export templates themselves carry the key**,
which official templates cannot do. Understand what it buys: casual extraction is blocked, but the
key necessarily lives inside the shipped exe, so a determined reverse-engineer can dig it out.
Deterrence, not DRM.

1. **Generate a 256-bit key once** (64 hex chars) and keep it **outside the repo**. Never commit
   it, and never print it into a log or chat transcript:

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

   The key lands in one generated file, so on a warm build tree this is an incremental
   recompile-and-relink measured in **seconds, not minutes**. Copy the built template (and its `.console`
   sibling) somewhere stable next to the key; later builds overwrite `bin/`.

3. **Wire the preset**: `encrypt_pck=true`, `encrypt_directory=true`,
   `encryption_include_filters="*"` (encrypting everything is cheap for small pcks), and
   `custom_template/release` pointing at the keyed template.

4. **Supply the key at export time via `GODOT_SCRIPT_ENCRYPTION_KEY`** (verified working live)
   in the environment of the headless export. The preset's key field works too, but it persists
   the key in plaintext into `export_presets.cfg`, a committed file. The env var keeps it out.

5. **Receipts.** The plaintext scan from above flips: game paths and `gd_scene` markers drop to
   **zero** hits in an encrypted pck. Then boot the exe, because **a booting game IS the
   key-match proof**. `ERR_FILE_CORRUPT` at startup means the template's baked key and the
   export-time key disagree (or the template is an unkeyed one).

### `export_presets.cfg` is secret-bearing: commit an `.example`

Step 4 keeps the encryption key out of the file at export time, but the file itself is still not a
safe thing to commit. Every preset carries a `script_encryption_key` field, and a real project adds
`codesign/password`, keystore passwords, and store credentials beside it. One committed preset with
a filled key hands the pck open to anyone who clones the repo, and rotating it means rebuilding
templates.

The convention that keeps CI working anyway:

- Gitignore `export_presets.cfg`. Treat it as local machine state.
- Commit `export_presets.cfg.example` with every secret field emptied (`script_encryption_key=""`,
  passwords blank) and everything else intact: preset names, platforms, export paths,
  include/exclude filters, `custom_features`. Those are the parts a build needs and none of them
  is a secret.
- Have CI copy it into place as the first build step, then supply the real values from the
  runner's secret store as environment variables:

  ```yaml
  - run: cp export_presets.cfg.example export_presets.cfg
  - run: godot-mcp export "Web" --out build/web/index.html
    env:
      GODOT_SCRIPT_ENCRYPTION_KEY: ${{ secrets.PCK_KEY }}
  ```

- Verify the copy landed before blaming the export. `godot-mcp export info` reports
  `"has_export_presets": false` and `godot-mcp export list-presets` answers
  `"No export_presets.cfg found"` when it did not, which is a clearer failure than the engine's.

Keep the two files in step. A preset added locally and not mirrored into the `.example` breaks the
build for everyone else, and the failure names a missing preset rather than a missing file.

## Size-optimized templates

The same custom-template slot takes size work. The scons knobs, in descending order of value for
a typical 2D game (official numbers, condensed):

- `production=yes` is the baseline for anything shipped (it implies dead-code stripping and sane
  defaults); `debug_symbols=no` alone is a 5 to 10× binary reduction when not already implied.
- `optimize=size` (or `size_extra`): high savings, mild CPU cost, and what web builds already do.
- `lto=full` also gives high savings, at the cost of slow links and 12 to 16 GB RAM at build
  time. Release-only.
- `disable_3d=yes` takes ~15% off a 2D-only game. **Template targets only** (the editor cannot
  build without 3D); grep the project for 3D node types first.
- `module_text_server_adv_enabled=no module_text_server_fb_enabled=yes`: high savings, but it
  loses RTL text, ligatures and OpenType features. Only for Latin/Greek/Cyrillic-only games.
- `disable_advanced_gui=yes` is moderate, and deletes Tree, ItemList, TextEdit, GraphEdit,
  ColorPicker, FileDialog and friends. Many UI-heavy games can't take this, so audit first.
- `build_profile=<file>.gdbuild` is moderate-to-high, project-derived class stripping. The sharp
  edge: it can strip classes only reached via reflection/`load()` at runtime.
- Per-module `module_*_enabled=no` (see `scons --help`) and physics you don't use
  (`module_jolt_enabled=no`, `disable_physics_3d=yes`) are small each, additive.
- Distribution: 7-Zip Ultra for desktop zips typically shaves another 1 to 5 MB.

**Every knob gets the same gate:** export, run the receipts, boot the game, and run the
project's own regression suite against a restored dev environment. A build that lost a module it
actually needed usually still boots. It fails at the moment the feature is touched, which is
exactly what a playtest suite catches and a boot test does not.

## Platform SDKs behind a feature tag

A Steam, console, or web-portal SDK is a native addon that only exists on one target. Calling into
it from anywhere in the game means every other build carries the dependency and crashes on a null
the moment a leaderboard call runs on a platform without it. Isolate it behind three gates:

1. **A custom export feature.** The preset for that platform sets `custom_features="steam"`;
   every other preset leaves it empty. `OS.has_feature("steam")` is then true in exactly those
   builds and nowhere else.
2. **One wrapper scene, the only file that touches the SDK.** `res://platforms/steam/sdk.gd` owns
   every call into the addon and exposes the game's own vocabulary back:
   `user_name_changed`, `init_finalized`, `submit_score()`. Nothing outside that file names the
   addon, so removing the SDK is deleting one directory and one preset field.
3. **Loaded only when the tag is on**, and reached only through a null-safe accessor:

   ```gdscript
   func platform_sdk() -> Node:                    # null on every build without the tag
       return get_node_or_null("SteamSDK")

   func init_platform() -> void:
       if not OS.has_feature("steam"):
           platform_ready.emit()                    # the no-SDK path still completes
           return
       var sdk := preload("res://platforms/steam/sdk.tscn").instantiate()
       sdk.name = "SteamSDK"
       add_child(sdk)
       sdk.init_finalized.connect(platform_ready.emit, CONNECT_ONE_SHOT)
       sdk.init()
   ```

   Every caller goes through `platform_sdk()` and checks for null. The wrapper's own `init()`
   checks the addon singleton the same way, because a tagged build can still run with the SDK
   unavailable (Steam not running, an overlay that failed to attach).

The `platform_ready` signal firing on both paths is what keeps the boot sequence identical
everywhere. A flow that waits for an SDK callback hangs forever on the web build otherwise.

**Verify the tag rather than assuming it.** Feature tags come from the export preset, so the
editor and any editor-launched game answer `false` for a custom one:

```sh
godot-mcp runtime eval --code 'emit({"steam": OS.has_feature("steam"), "editor": OS.has_feature("editor"),
  "template": OS.has_feature("template"), "debug": OS.is_debug_build()})'
# { "steam": false, "editor": true, "template": false, "debug": true }
```

That reading is the point: the SDK path is unreachable during development, so the null-safe branch
is the one being exercised every day. Confirm the tagged branch on a real exported build, by
running the exe and reading the same four values from its log.

## Android

Two keystores exist and they are not interchangeable. The **debug** keystore is a throwaway the
editor generates; the **release** keystore is one `keytool` generates once and Google Play binds to
the application identity permanently. Losing it means never updating that listing again, so it is
backed up like the encryption key and kept out of the repo.

**Editor-side prerequisites** (set in Editor Settings → Export → Android, or the export fails with
a message naming the missing piece): a JDK, the Android SDK, and platform-tools on the machine that
runs the export. The `adb` path comes from `export/android/adb`, falling back to a PATH lookup, and
the debug keystore trio falls back to `export/android/debug_keystore`, `..._user`, `..._pass`.

**Preset fields that decide the build shape:**

- `package/unique_name` is the reverse-DNS identifier. Permanent per listing, like the keystore.
- `version/code` (machine-readable, must increment every Play upload) and `version/name`.
- `keystore/debug`, `keystore/debug_user`, `keystore/debug_password`; `keystore/release`,
  `keystore/release_user`, `keystore/release_password`; `package/signed` gates signing at all.
- `gradle_build/use_gradle_build`: off packages the prebuilt template APK, on compiles a real
  Gradle project from `gradle_build/gradle_build_directory` (default `res://android`). Plugins,
  GDExtension, and custom manifest entries need it on, and `gradle_build/min_sdk` /
  `gradle_build/target_sdk` apply only on that path. Install the template once with
  `godot --headless --path . --install-android-build-template`.
- `gradle_build/export_format` picks APK or AAB. AAB is the Play upload; APK is what installs on a
  device. Keep two presets rather than flipping one, since the device loop below needs the APK.
- `architectures/arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`: arm64 alone covers current phones
  and is the smallest, while x86_64 buys emulator testing.

**Keystore passwords stay out of `export_presets.cfg`**, which is a committed file. Every keystore
field has an environment override that wins over it, so a headless release export signs like this:

```powershell
$env:GODOT_ANDROID_KEYSTORE_RELEASE_PATH     = "$HOME\.godot-keys\release.keystore"
$env:GODOT_ANDROID_KEYSTORE_RELEASE_USER     = "upload"
$env:GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD = (Get-Content ~\.godot-keys\release.pass -Raw).Trim()
godot-mcp export "Android Play" --out out/game.aab
```

The debug trio is `GODOT_ANDROID_KEYSTORE_DEBUG_PATH` / `_USER` / `_PASSWORD`. Same rule as the
encryption key: environment at export time, never a value in the repo.

**Build: the device loop.** `android deploy` runs export, `adb install -r`, and launch as one call:

```
godot-mcp android list-devices                       # serial + state per attached device
godot-mcp android preset-info                        # index, name, export_path, package_name
godot-mcp android deploy --preset-name "Android Dev" --device-serial R5CT10 --debug=true
godot-mcp android deploy --preset-name "Android Dev" --skip-export=true   # reinstall what exists
```

The result carries a `steps` array with a per-step exit code, so a failure names which of the three
legs broke. `list-devices` and `preset-info` fail cleanly when platform-tools or the preset are
absent, which makes them the preflight rather than a separate check. Deploy installs whatever sits
at the preset's `export_path`, so pointing it at an AAB fails at `adb install`.

**Receipts for an APK or AAB.** Both are zip containers and neither exposes a loose pck, so the
plaintext scan runs against a standalone pack:

```powershell
godot-mcp export "Android Dev" --pack --out out/receipt.pck
$t = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes("out/receipt.pck"))
([regex]::Matches($t, 'godot_mcp')).Count      # 0 or the addon shipped
Expand-Archive out/game.apk out/apk_check -Force
Get-ChildItem out/apk_check -Recurse | Select-Object -ExpandProperty FullName   # no addons/ paths
```

The boot receipt becomes an on-device one: `android deploy --launch=true` and confirm the app holds
past its first scene, with `adb logcat` open for the stack trace when it does not.

Note what that `Expand-Archive` also proves: an APK is a zip anyone can open, and the pck inside
it reads like any other pck. `encrypt_pck` from the encryption section applies to Android exports
unchanged and is the only thing standing between a curious player and the scripts. The receipts
above check content, not protection, so run the plaintext string scan against the pck pulled from
the APK when encryption is on.

## Web (HTML5)

The artifact is a directory of files: `index.html`, a `.js` loader, a `.wasm`, the `.pck`, and
support files. Point `export_path` at the `.html` and export into an empty directory of its own.

**Serve it. A web export opened from `file://` fails**, and the export that produced it was green,
which is the receipt-versus-exit-code rule in its most common form. The loader fetches the wasm and
the pck, and those fetches are cross-origin under `file://`. Use the editor's run-in-browser flow,
or any static server, and read the browser console rather than the export log.

**Threads decide how the site must be configured.** `variant/thread_support` true gives the export
threads and requires a cross-origin-isolated site: the server must send
`Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`, which
also blocks the page from embedding third-party content. False drops the requirement to plain
HTTPS at the cost of performance and audio stability. The failure mode to recognize: threads on,
headers missing, `SharedArrayBuffer is not defined` in the console, and a build that exported
perfectly. `variant/extensions_support` enables GDExtension for the web build and is separate.

Shipping-shape fields: `progressive_web_app/enabled` (installable PWA), `html/export_icon`
(project icon as favicon), `html/head_include` (extra `<head>` tags), `html/canvas_resize_policy`.

**Size discipline is stricter here than on desktop**, because every byte is a download before the
first frame. The wasm is the floor and the pck is what the project controls, so audit imported
texture and audio settings before reaching for template surgery. Serve with gzip or brotli
compression on; wasm compresses hard, and enabling it on the host is a larger win than most build
flags. The size knobs above still apply to a custom web template through `custom_template/release`.

**PCK encryption on web: the mechanism works, the protection does not.** Building a keyed web
template and setting `encrypt_pck` behaves exactly as on desktop, and the plaintext receipts flip
the same way. The value is different: the key ships inside a wasm binary the browser downloads to
the player's machine, and the pck itself crosses the network where any devtools network tab
captures it. Encrypt if the same key already covers other platforms; treat it as protection on web
and the reasoning is wrong.

## macOS

The bundle exports from any host. The signing leg is where the host decides what is possible.

**Preset fields.** `application/bundle_identifier` (reverse-DNS, permanent per listing) and
`export/distribution_type` choose the artifact's purpose. The signing family is
`codesign/codesign` (an integer selecting the tool), `codesign/certificate_file`,
`codesign/certificate_password`, `codesign/apple_team_id`, `codesign/provisioning_profile`, and
`codesign/custom_options`. Notarization mirrors it: `notarization/notarization` (again an integer
tool selector), then either the API-key trio `notarization/api_uuid`, `notarization/api_key`,
`notarization/api_key_id`, or the Apple-ID pair `notarization/apple_id_name`,
`notarization/apple_id_password`. **Which tools the two integer fields offer depends on the editor
build and the host**, so read the dropdown in the Export dialog instead of writing an index into
the cfg by hand.

Credentials get the same treatment as the Android keystore, and the same environment overrides
exist: `GODOT_MACOS_CODESIGN_CERTIFICATE_FILE`, `GODOT_MACOS_CODESIGN_CERTIFICATE_PASSWORD`,
`GODOT_MACOS_CODESIGN_PROVISIONING_PROFILE`, `GODOT_MACOS_NOTARIZATION_API_KEY`,
`GODOT_MACOS_NOTARIZATION_API_KEY_ID`, `GODOT_MACOS_NOTARIZATION_API_UUID`,
`GODOT_MACOS_NOTARIZATION_APPLE_ID_NAME`, `GODOT_MACOS_NOTARIZATION_APPLE_ID_PASSWORD`.

**Entitlements, in one pass.** They live under `codesign/entitlements/*` and each one widens what
the signed app may do, so grant the few that are needed and leave the rest off:

- `app_sandbox/enabled` plus the per-resource toggles (`device_usb` and `device_bluetooth` for
  controllers, `files_downloads`, `files_movies`, `files_music`, and friends). Required for the App
  Store; unnecessary weight for direct distribution.
- `allow_jit_code_execution`, `allow_unsigned_executable_memory`,
  `allow_dyld_environment_variables`. Grant these only for a GDExtension that needs dynamic or
  self-modifying native code. Each one relaxes the runtime protections signing exists to assert.
- `codesign/entitlements/additional` takes raw plist for anything the fields do not cover.

**What a Windows dev machine cannot do.** Apple's signing tools and the notarization submission are
macOS-side, and notarization is a network round trip to Apple whose requirements and tooling change
on Apple's schedule rather than Godot's. Treat Apple's current documentation as the authority for
that leg and this section as the map of where Godot's fields plug into it. From Windows the
reachable work is the preset, the export filters, and the pck receipt via `--export-pack`. The
verification commands (`codesign --verify --deep --strict --verbose=2`, `spctl -a -vv`) run on a
Mac, and there is no substitute for running them before shipping a bundle.

## iOS

The export writes an Xcode project. **The final build, sign, and `.ipa` leg needs Xcode on a Mac**,
which is a hard boundary rather than a matter of installing more tooling on the dev machine.

Preset fields worth setting before the handoff: `application/bundle_identifier`,
`application/app_store_team_id` (the 10-character Apple Team ID),
`application/provisioning_profile_uuid_debug` and `..._release`, or their
`application/provisioning_profile_specifier_debug` / `..._release` counterparts when the profile is
named rather than identified by UUID. Leaving the UUID empty lets Xcode download or create a
profile automatically, which is the path of least friction for a first build.
`architectures/arm64` is the only device architecture, and `custom_template/release` takes a keyed
or size-optimized template as everywhere else.

The dev-tooling boundary pays off harder here than anywhere: App Store review turnaround measures
in days, so run the pck scan before every submission rather than after a rejection. From Windows,
`--export-pack` plus the string scan is the whole verifiable surface, and it is worth doing.

## The restore step

Shipping state and dev state differ (plugin off, autoloads gone). After exporting, put the
project back deliberately: re-enable the plugin (autoloads self-install on load) or
`git checkout` the project file if the flow edited it, relaunch the editor, and run the
project's verification so the next session starts from a proven-green baseline.
