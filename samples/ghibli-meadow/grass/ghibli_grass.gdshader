// Ghibli-style stylized grass blades, adapted from a Blender node tutorial
// (Musgrave/noise patch color + toon shading; www.youtube.com/watch?v=HO9qdDPBuAo)
// with an original wind system. The Blender->Godot map:
//   - Musgrave+noise "generated texture" -> world-XZ seamless FBM (patch_noise)
//     mixed between two grass tones (cool-dark vs warm-light, per the
//     tutorial's color-theory section), brightness/contrast uniforms kept.
//   - "Normal from the plane below" -> per-instance terrain normal packed in
//     INSTANCE_CUSTOM.yz, assigned to NORMAL, so blades shade as a carpet
//     that follows the hills instead of per-blade.
//   - Diffuse -> ShaderToRGB -> tight linear ColorRamp -> smoothstep toon
//     step in light() (toon_edge/toon_softness). Colored lights tint
//     correctly for free: LIGHT_COLOR is applied after the value step, which
//     is exactly what the tutorial's HSV separate/combine dance fakes.
//   - Shadow-color mix -> shadow_tint floor on the directional light.
//   - The accidental "black outline" ramp trick -> terminator_band darkening.
// Wind (not in the tutorial): a gust field scrolls across the meadow along
// wind_direction (big soft fronts, the Totoro look), each blade adds phase
// flutter on top, and gusts lighten the tips (wind_sheen) like light catching
// flattened grass.

shader_type spatial;
render_mode cull_disabled, specular_disabled, world_vertex_coords;

group_uniforms Tones;
uniform vec4 tone_shadowed : source_color = vec4(0.10, 0.34, 0.29, 1.0);
uniform vec4 tone_lit : source_color = vec4(0.58, 0.78, 0.26, 1.0);
uniform sampler2D patch_noise : repeat_enable, filter_linear_mipmap;
uniform float patch_scale : hint_range(0.001, 0.2) = 0.025;
uniform float patch_brightness : hint_range(-1.0, 1.0) = 0.0;
uniform float patch_contrast : hint_range(0.0, 3.0) = 1.3;

group_uniforms Toon;
uniform float toon_edge : hint_range(0.0, 1.0) = 0.45;
uniform float toon_softness : hint_range(0.005, 0.5) = 0.06;
uniform vec4 shadow_tint : source_color = vec4(0.38, 0.52, 0.62, 1.0);
uniform float terminator_band : hint_range(0.0, 1.0) = 0.2;

group_uniforms Blade;
uniform float root_darken : hint_range(0.0, 1.0) = 0.38;
uniform float tip_lighten : hint_range(0.0, 1.0) = 0.12;

group_uniforms Wind;
uniform float wind_direction_deg : hint_range(0.0, 360.0) = 35.0;
uniform float wind_strength : hint_range(0.0, 2.0) = 0.45;
uniform float wind_speed : hint_range(0.0, 8.0) = 1.6;
uniform float gust_scale : hint_range(0.002, 0.1) = 0.015;
uniform float flutter : hint_range(0.0, 1.0) = 0.25;
uniform float wind_sheen : hint_range(0.0, 1.0) = 0.35;
uniform sampler2D wind_noise : repeat_enable, filter_linear_mipmap;
uniform float wave_time = 0.0;

varying float v_patch;
varying float v_t;
varying float v_gust;

void vertex() {
	// world_vertex_coords: VERTEX/NORMAL are world-space here.
	vec3 base = MODEL_MATRIX[3].xyz;
	float t = UV.y; // 0 at the root, 1 at the tip
	vec2 wdir = vec2(cos(radians(wind_direction_deg)), sin(radians(wind_direction_deg)));

	// Gust front: one soft noise field scrolling along the wind direction.
	vec2 guv = base.xz * gust_scale - wdir * (wave_time * wind_speed * 0.03);
	float gust = texture(wind_noise, guv).r;

	// Per-blade flutter riding on the gust, phase from INSTANCE_CUSTOM.x.
	float phase = INSTANCE_CUSTOM.x * 6.2831853;
	float fl = sin(wave_time * (3.0 + 4.0 * fract(INSTANCE_CUSTOM.x * 7.13)) + phase);

	float bend = (gust * gust * wind_strength
		+ fl * flutter * (0.15 + gust * 0.5) * wind_strength) * t * t;
	VERTEX.xz += wdir * bend;
	VERTEX.y -= bend * bend * 0.35; // arc shortening so tips don't stretch

	// The carpet trick: shade with the terrain normal under this blade.
	float ny = sqrt(max(0.0, 1.0 - INSTANCE_CUSTOM.y * INSTANCE_CUSTOM.y - INSTANCE_CUSTOM.z * INSTANCE_CUSTOM.z));
	NORMAL = normalize(vec3(INSTANCE_CUSTOM.y, ny, INSTANCE_CUSTOM.z));

	v_patch = texture(patch_noise, base.xz * patch_scale).r;
	v_gust = gust;
	v_t = t;
}

void fragment() {
	float p = clamp((v_patch - 0.5) * patch_contrast + 0.5 + patch_brightness, 0.0, 1.0);
	vec3 col = mix(tone_shadowed.rgb, tone_lit.rgb, p);
	col *= mix(1.0 - root_darken, 1.0 + tip_lighten, v_t);
	col += tone_lit.rgb * wind_sheen * v_gust * v_gust * v_t;
	ALBEDO = col;
}

void light() {
	float ndl = dot(NORMAL, LIGHT) * 0.5 + 0.5;
	float d = ndl * ATTENUATION;
	float lit = smoothstep(toon_edge, toon_edge + toon_softness, d);
	// Narrow darkened strip at the step edge (the tutorial's happy accident).
	float band = smoothstep(toon_edge - toon_softness * 2.0, toon_edge, d)
		* (1.0 - smoothstep(toon_edge, toon_edge + toon_softness * 2.0, d));
	vec3 floor_col = LIGHT_IS_DIRECTIONAL ? shadow_tint.rgb : vec3(0.0);
	vec3 shade = mix(floor_col, vec3(1.0), lit) * (1.0 - terminator_band * band);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR / PI * shade;
}
