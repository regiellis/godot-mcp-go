// Trees standing in the Ghibli grass. The toon light() is the same one
// ghibli_ground.gdshader and ghibli_grass.gdshader use, so bark, foliage, soil
// and blades all step at the same terminator and read as one illustrated
// surface. The two-tone patch colour is here too, sampled in world XZ like the
// carpet, which keeps a canopy from reading as a flat cut-out against it.
//
// One material, two instances: bark and foliage differ only by their tones and
// their patch scale, so a canopy varies over centimetres and the trunk barely
// varies at all.

shader_type spatial;
render_mode specular_disabled;

group_uniforms Tones;
uniform vec4 tone_shadowed : source_color = vec4(0.09, 0.28, 0.20, 1.0);
uniform vec4 tone_lit : source_color = vec4(0.44, 0.70, 0.28, 1.0);
uniform sampler2D patch_noise : repeat_enable, filter_linear_mipmap;
uniform float patch_scale : hint_range(0.001, 2.0) = 0.35;
uniform float patch_contrast : hint_range(0.0, 3.0) = 1.1;

group_uniforms Shaping;
// Lifts the tone toward `tone_lit` with height up the canopy, so a blob cluster
// reads as one lit mass rather than several separate balls.
uniform float crown_lift : hint_range(0.0, 1.0) = 0.35;
uniform float crown_origin = 0.0;
uniform float crown_span : hint_range(0.1, 10.0) = 3.0;

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
	float p = clamp((n - 0.5) * patch_contrast + 0.5, 0.0, 1.0);
	float h = clamp((v_world_pos.y - crown_origin) / crown_span, 0.0, 1.0);
	p = clamp(p + h * crown_lift, 0.0, 1.0);
	ALBEDO = mix(tone_shadowed.rgb, tone_lit.rgb, p);
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
