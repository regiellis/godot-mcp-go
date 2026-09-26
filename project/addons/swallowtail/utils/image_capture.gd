extends RefCounted
## Shared by the two screenshot paths: editor_commands (the editor window) and
## game_inspector (the running game). Static only, so either process can
## preload it, and it must parse at the 4.3 floor (back-compat contract).

const _LINEAR_FORMATS := [Image.FORMAT_RGBAH, Image.FORMAT_RGBAF, Image.FORMAT_RGBH, Image.FORMAT_RGBF]

## An HDR 2D viewport (rendering/viewport/hdr_2d, which the editor applies to
## its own root viewport too, or Viewport.use_hdr_2d set at runtime) hands back
## a half-float image holding LINEAR color. PNG is 8-bit sRGB, so encoding those
## values as they are made every capture read far darker than the window: a 0.3
## gray landed at 0x12 instead of 0x4c (measured live on 4.7.2).
## Image.linear_to_srgb only takes the 8-bit formats, so quantize first, then
## apply the curve. The method arrived in 4.4, so it is called dynamically; on
## an older engine the frame stays linear and the result says so. Returns
## {hdr, converted}; an SDR capture is already RGBA8 sRGB and is left untouched.
static func to_srgb8(image: Image) -> Dictionary:
	if image.get_format() not in _LINEAR_FORMATS:
		return {"hdr": false, "converted": false}
	if not image.has_method("linear_to_srgb"):
		return {"hdr": true, "converted": false}
	image.convert(Image.FORMAT_RGBA8)
	image.call("linear_to_srgb")
	return {"hdr": true, "converted": true}


## Write the capture's color facts into a result: hdr_2d always, and
## color_space "linear" only when an HDR frame could not be converted, so an
## SDR result keeps its shape.
static func stamp(result: Dictionary, conversion: Dictionary) -> Dictionary:
	result["hdr_2d"] = bool(conversion.get("hdr", false))
	if result["hdr_2d"] and not bool(conversion.get("converted", false)):
		result["color_space"] = "linear"
	return result
