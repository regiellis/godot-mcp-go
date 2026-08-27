# Lighthouse Demo

A stylized water surface with a lighthouse, built in Godot 4.7 by an agent
driving [godot-mcp](https://github.com/regiellis/godot-mcp-go).

Run it:

```bash
godot --path .
```

Fly the camera with `WASD`, `Q`/`E` for down and up, right mouse to look, and
shift to move faster. The panel on the right retunes the water live: every
control is built from the shader's own uniform list, so it reflects whatever the
material actually exposes.

## What it shows

- A water shader with waves, foam, caustics, refraction, and depth-faded shore
  blending, driven by a `@tool` script so the editor viewport matches play mode.
- Presets that swap the whole look in one call.

## Credits and licence

The water shader is a Godot port of **Daniel Shervheim's** open-source Unity
*Stylized Water* project, used under the BSD 3-Clause licence. The wave, foam,
caustic, and sea-pattern textures and the lighthouse model come from that
project. Its licence and README are kept in `assets/shervheim_demo/`, and the
port and this scene are covered by the same terms.

Upstream: <https://github.com/danielshervheim/unity-stylized-water>

The demo panel and the fly camera are part of this project and carry its own
licence.

Two upstream files were re-encoded rather than shipped as-is: `SeaPattern` moved
from a 12 MB uncompressed TGA to a 4 MB PNG, which Godot imports identically,
and a dangling `mtllib` line was removed from `lighthouse.obj` because the
material file it named was never part of the upstream distribution.
