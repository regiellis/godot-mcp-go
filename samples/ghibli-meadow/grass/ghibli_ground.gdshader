// Ground under the Ghibli grass: the same patch-noise two-tone color and toon
// step as ghibli_grass.gdshader (uniform names match — the meadow driver
// mirrors the shared ones each frame) so the carpet and the soil read as one
// surface, just darkened. No wind, no blade gradient.

shader_type spatial;
render_mode specular_disabled;

group_uniforms Tones;
uniform vec4 tone_shadowed : source_color = vec4(0.10, 0.34, 0.29, 1.0);
uniform vec4 tone_lit : source_color = vec4(0.58, 0.78, 0.26, 1.0);
uniform sampler2D patch_noise : repeat_enable, filter_linear_mipmap;
uniform float patch_scale : hint_range(0.001, 0.2) = 0.025;
uniform float patch_brightness : hint_range(-1.0, 1.0) = 0.0;
uniform float patch_contrast : hint_range(0.0, 3.0) = 1.3;
uniform float ground_darken : hint_range(0.0, 1.0) = 0.35;

group_uniforms Toon;
uniform float toon_edge : hint_range(0.0, 1.0) = 0.45;
uniform float toon_softness : hint_range(0.005, 0.5) = 0.06;
uniform vec4 shadow_tint : source_color = vec4(0.38, 0.52, 0.62, 1.0);
uniform float terminator_band : hint_range(0.0, 1.0) = 0.2;

varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float n = texture(patch_noise, v_world_pos.xz * patch_scale).r;
	float p = clamp((n - 0.5) * patch_contrast + 0.5 + patch_brightness, 0.0, 1.0);
	vec3 col = mix(tone_shadowed.rgb, tone_lit.rgb, p);
	ALBEDO = col * (1.0 - ground_darken);
}

void light() {
	float ndl = dot(NORMAL, LIGHT) * 0.5 + 0.5;
	float d = ndl * ATTENUATION;
	float lit = smoothstep(toon_edge, toon_edge + toon_softness, d);
	float band = smoothstep(toon_edge - toon_softness * 2.0, toon_edge, d)
		* (1.0 - smoothstep(toon_edge, toon_edge + toon_softness * 2.0, d));
	vec3 floor_col = LIGHT_IS_DIRECTIONAL ? shadow_tint.rgb : vec3(0.0);
	vec3 shade = mix(floor_col, vec3(1.0), lit) * (1.0 - terminator_band * band);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR / PI * shade;
}
