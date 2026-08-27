// Godot 4.7 port of Daniel Shervheim's "Stylized Water" for Unity
// (https://github.com/danielshervheim/unity-stylized-water, BSD 3-Clause,
// Copyright (c) 2019 Daniel Shervheim — notice retained per license; see
// res://assets/shervheim_demo/LICENSE for the full text).
//
// Ported surface: Beer's-law depth transmittance + camera-distance far color,
// two simple sine waves with a finite-difference TBN, MotionFourWayChaos
// normal/foam panning, fresnel reflections, backlit wavetip SSS, hard sun
// specular, sparkle glints, and optical-depth edge foam.
//
// Deliberate divergences from the source (each noted inline):
//   - The reflection cubemap (unity_SpecCube0) is replaced by a two-color sky
//     gradient — a Godot spatial shader cannot sample the Environment sky.
//   - Sun specular + SSS live in light(), so they respect shadows (ATTENUATION)
//     and work for any light; the custom shadow-map machinery (default-off
//     upstream) is not ported.
//   - Foam UV distortion uses normal_ts.xy, not the source's .xz (z is the
//     near-constant out-of-plane component; x/y carry the actual distortion).
//   - Textures ship as procedural NoiseTexture2D stand-ins: the repo's texture
//     files are third-party (RiME breakdown, dualheights.se), not BSD-covered.
//
// wave_time is driven by shervheim_water.gd so CPU height queries stay
// phase-locked with the GPU waves (same convention as stylized_water.gdshader).
shader_type spatial;
render_mode world_vertex_coords, depth_draw_always, specular_schlick_ggx;

group_uniforms densities;
uniform float depth_density : hint_range(0.0, 1.0) = 0.5;
uniform float distance_density : hint_range(0.0, 1.0) = 0.025;

group_uniforms wave_normals;
uniform sampler2D wave_normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float wave_normal_scale = 20.0;
uniform float wave_normal_speed = 0.05;

group_uniforms base_color;
uniform vec4 shallow_color : source_color = vec4(0.443, 0.914, 0.663, 1.0);
uniform vec4 deep_color : source_color = vec4(0.0, 0.012, 0.123, 1.0);
uniform vec4 far_color : source_color = vec4(0.119, 0.48, 0.811, 1.0);

group_uniforms reflections;
uniform float reflection_contribution : hint_range(0.0, 1.0) = 1.0;
uniform vec4 sky_horizon_color : source_color = vec4(0.66, 0.82, 0.92, 1.0);
uniform vec4 sky_top_color : source_color = vec4(0.25, 0.5, 0.85, 1.0);

group_uniforms subsurface_scattering;
uniform vec4 sss_color : source_color = vec4(0.152, 0.274, 0.063, 1.0);

group_uniforms foam;
uniform sampler2D foam_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform float foam_contribution : hint_range(0.0, 1.0) = 0.549;
uniform float foam_scale = 10.0;
uniform float foam_speed = 0.1;
uniform float foam_noise_scale : hint_range(0.0, 1.0) = 0.32;

group_uniforms sun_specular;
uniform vec4 sun_specular_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float sun_specular_exponent = 3500.0;

group_uniforms sparkle;
uniform sampler2D sparkles_normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float sparkle_scale = 75.0;
uniform float sparkle_speed = 0.025;
uniform vec4 sparkle_color : source_color = vec4(0.549, 0.961, 0.816, 1.0);
uniform float sparkle_exponent = 20000.0;

group_uniforms edge_foam;
uniform vec4 edge_foam_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float edge_foam_depth = 0.25;

group_uniforms wave_1;
uniform float wave1_direction : hint_range(0.0, 1.0) = 0.5;
uniform float wave1_amplitude = 0.25;
uniform float wave1_wavelength = 10.0;
uniform float wave1_speed = 0.25;

group_uniforms wave_2;
uniform float wave2_direction : hint_range(0.0, 1.0) = 0.25;
uniform float wave2_amplitude = 0.2;
uniform float wave2_wavelength = 10.0;
uniform float wave2_speed = 1.0;

group_uniforms;
uniform float wave_time = 0.0;

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

varying vec3 v_world_pos;
varying float v_wave_height;

// ---------- WaterUtilities.cginc ports ----------

float simple_wave(vec2 position, vec2 direction, float wavelength, float amplitude, float speed, float t) {
	float x = PI * dot(position, direction) / wavelength;
	return amplitude * sin(x + speed * t);
}

float get_wave_height(vec2 world_position, float t) {
	vec2 dir1 = vec2(cos(PI * wave1_direction), sin(PI * wave1_direction));
	vec2 dir2 = vec2(cos(PI * wave2_direction), sin(PI * wave2_direction));
	float wave1 = simple_wave(world_position, dir1, wave1_wavelength, wave1_amplitude, wave1_speed, t);
	float wave2 = simple_wave(world_position, dir2, wave2_wavelength, wave2_amplitude, wave2_speed, t);
	return wave1 + wave2;
}

// Finite-difference TBN of the wave surface; d controls the normal sharpness.
// (HLSL transpose(float3x3(rows)) == GLSL mat3(columns), so no transpose here.)
mat3 get_wave_tbn(vec2 world_position, float d, float t) {
	float wave_height = get_wave_height(world_position, t);
	float wave_height_dx = get_wave_height(world_position - vec2(d, 0.0), t);
	float wave_height_dz = get_wave_height(world_position - vec2(0.0, d), t);
	vec3 tangent = normalize(vec3(0.0, wave_height - wave_height_dz, d));
	vec3 binormal = normalize(vec3(d, wave_height - wave_height_dx, 0.0));
	// Source order cross(binormal, tangent) yields a DOWNWARD normal, which its
	// pow(1 + dot) fresnel silently relied on (the two sign quirks cancel to
	// Schlick). We keep an upward normal and real Schlick instead.
	vec3 normal = normalize(cross(tangent, binormal));
	return mat3(tangent, binormal, normal);
}

vec2 panner(vec2 uv, vec2 direction, float speed, float t) {
	return uv + normalize(direction) * speed * t;
}

// Unity's UnpackNormal counterpart. Read only RG and reconstruct Z: Godot's
// normal-map import compresses to RGTC, which drops the blue channel — a plain
// rgb*2-1 unpack reads z as -1 and flips every normal downward.
vec3 unpack_normal(vec4 texel) {
	vec2 xy = texel.rg * 2.0 - 1.0;
	return vec3(xy, sqrt(max(1.0 - dot(xy, xy), 0.0)));
}

vec3 motion_four_way_chaos_normal(sampler2D tex, vec2 uv, float speed, float t) {
	vec2 uv1 = panner(uv + vec2(0.000, 0.000), vec2(0.1, 0.1), speed, t);
	vec2 uv2 = panner(uv + vec2(0.418, 0.355), vec2(-0.1, -0.1), speed, t);
	vec2 uv3 = panner(uv + vec2(0.865, 0.148), vec2(-0.1, 0.1), speed, t);
	vec2 uv4 = panner(uv + vec2(0.651, 0.752), vec2(0.1, -0.1), speed, t);
	vec3 sample1 = unpack_normal(texture(tex, uv1));
	vec3 sample2 = unpack_normal(texture(tex, uv2));
	vec3 sample3 = unpack_normal(texture(tex, uv3));
	vec3 sample4 = unpack_normal(texture(tex, uv4));
	return normalize(sample1 + sample2 + sample3 + sample4);
}

vec3 motion_four_way_chaos(sampler2D tex, vec2 uv, float speed, float t) {
	vec2 uv1 = panner(uv + vec2(0.000, 0.000), vec2(0.1, 0.1), speed, t);
	vec2 uv2 = panner(uv + vec2(0.418, 0.355), vec2(-0.1, -0.1), speed, t);
	vec2 uv3 = panner(uv + vec2(0.865, 0.148), vec2(-0.1, 0.1), speed, t);
	vec2 uv4 = panner(uv + vec2(0.651, 0.752), vec2(0.1, -0.1), speed, t);
	return (texture(tex, uv1).rgb + texture(tex, uv2).rgb + texture(tex, uv3).rgb + texture(tex, uv4).rgb) / 4.0;
}

vec3 motion_four_way_sparkle(sampler2D tex, vec2 uv, vec4 coordinate_scale, float speed, float t) {
	vec2 uv1 = panner(uv * coordinate_scale.x, vec2(0.1, 0.1), speed, t);
	vec2 uv2 = panner(uv * coordinate_scale.y, vec2(-0.1, -0.1), speed, t);
	vec2 uv3 = panner(uv * coordinate_scale.z, vec2(-0.1, 0.1), speed, t);
	vec2 uv4 = panner(uv * coordinate_scale.w, vec2(0.1, -0.1), speed, t);
	vec3 sample1 = unpack_normal(texture(tex, uv1));
	vec3 sample2 = unpack_normal(texture(tex, uv2));
	vec3 sample3 = unpack_normal(texture(tex, uv3));
	vec3 sample4 = unpack_normal(texture(tex, uv4));
	vec3 normal_a = vec3(sample1.x, sample2.y, 1.0);
	vec3 normal_b = vec3(sample3.x, sample4.y, 1.0);
	return normalize(vec3((normal_a + normal_b).xy, (normal_a * normal_b).z));
}

// The cubemap stand-in: reflected sky as a horizon→zenith gradient.
vec3 sample_sky(vec3 dir) {
	return mix(sky_horizon_color.rgb, sky_top_color.rgb, clamp(dir.y, 0.0, 1.0));
}

// ---------- stages ----------

void vertex() {
	v_wave_height = get_wave_height(VERTEX.xz, wave_time);
	VERTEX.y += v_wave_height;
	v_world_pos = VERTEX;
}

void fragment() {
	// Their convention: viewDirWS points camera → fragment.
	vec3 view_dir_ws = normalize(v_world_pos - CAMERA_POSITION_WORLD);

	// --- normals: analytic wave TBN x four-way-chaos normal map ---
	mat3 tangent_to_world = get_wave_tbn(v_world_pos.xz, 0.01, wave_time);
	vec3 normal_ts = motion_four_way_chaos_normal(wave_normal_map, v_world_pos.xz / wave_normal_scale, wave_normal_speed, wave_time);
	vec3 normal_ws = tangent_to_world * normal_ts;
	NORMAL = normalize((VIEW_MATRIX * vec4(normal_ws, 0.0)).xyz);

	// --- depth and color buffers ---
	vec3 frag_color = texture(screen_texture, SCREEN_UV).rgb;
	// Godot Forward+ uses an INFINITE far plane with reversed-z: a sky pixel's
	// raw depth is exactly 0.0 and the eye-depth reconstruction divides by
	// w -> 0, turning the optical depth into NaN (Unity's finite far plane made
	// this huge-but-finite). Clamp so sky-backed water reads as "very deep".
	float frag_depth = max(texture(depth_texture, SCREEN_UV).r, 1e-7);

	// --- depth (Beer's law) and distance masks ---
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, frag_depth, 1.0);
	float scene_eye_depth = -(scene_view.z / scene_view.w);
	float water_eye_depth = -VERTEX.z;
	float optical_depth = abs(scene_eye_depth - water_eye_depth);
	float transmittance = exp(-depth_density * optical_depth);
	float distance_mask = exp(-distance_density * length(v_world_pos - CAMERA_POSITION_WORLD));

	// --- base color ---
	vec3 base_color = frag_color * shallow_color.rgb;
	base_color = mix(deep_color.rgb, base_color, transmittance);
	base_color = mix(far_color.rgb, base_color, distance_mask);

	// --- reflected color (fresnel-weighted sky gradient) ---
	// Divergence: the source computes pow(1 + cos, 5), which blows up to 2^5 when
	// looking straight down (their demo cameras stay near-grazing, so it never
	// showed). Proper Schlick (1 - cos) keeps reflections at grazing angles only.
	float fresnel_mask = pow(1.0 - clamp(dot(normal_ws, -view_dir_ws), 0.0, 1.0), 5.0);
	vec3 reflected_color = sample_sky(reflect(view_dir_ws, normal_ws));
	reflected_color = reflected_color * fresnel_mask * distance_mask;
	reflected_color = reflected_color * reflection_contribution;

	// --- foam ---
	vec2 foam_uv = (v_world_pos.xz / foam_scale) + (foam_noise_scale * normal_ts.xy);
	vec3 foam_color = motion_four_way_chaos(foam_texture, foam_uv, foam_speed, wave_time);
	foam_color = foam_color * distance_mask * foam_contribution;

	// --- sparkles ---
	vec3 sparkly1 = motion_four_way_sparkle(sparkles_normal_map, v_world_pos.xz / sparkle_scale, vec4(1.0, 2.0, 3.0, 4.0), sparkle_speed, wave_time);
	vec3 sparkly2 = motion_four_way_sparkle(sparkles_normal_map, v_world_pos.xz / sparkle_scale, vec4(1.0, 0.5, 2.5, 2.0), sparkle_speed, wave_time);
	float sparkle_mask = dot(sparkly1, sparkly2) * clamp(3.0 * sqrt(clamp(sparkly1.x * sparkly2.x, 0.0, 1.0)), 0.0, 1.0);
	sparkle_mask = ceil(clamp(pow(sparkle_mask, sparkle_exponent), 0.0, 1.0)) * distance_mask;
	vec3 sparkle_col = sparkle_color.rgb * sparkle_mask;

	// --- edge foam ---
	float edge_foam_mask = round(clamp(exp(-optical_depth / edge_foam_depth), 0.0, 1.0));
	vec3 edge_foam_col = edge_foam_color.rgb * edge_foam_mask;

	// Sun specular and SSS ride in light(); everything else is authored color.
	ALBEDO = vec3(0.0);
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
	EMISSION = base_color + reflected_color + foam_color + sparkle_col + edge_foam_col;
}

void light() {
	vec3 view_dir = -VIEW; // camera → fragment, their convention (view space)

	// sun specular: hard-clipped mirror dot (round() makes it binary)
	vec3 view_r = reflect(view_dir, NORMAL);
	float sun_mask = clamp(dot(view_r, LIGHT), 0.0, 1.0);
	sun_mask = round(clamp(pow(sun_mask, sun_specular_exponent), 0.0, 1.0));
	SPECULAR_LIGHT += sun_specular_color.rgb * sun_mask * ATTENUATION;

	// subsurface scattering: backlit wavetips only
	float sss_mask = clamp(dot(view_dir, LIGHT), 0.0, 1.0);
	DIFFUSE_LIGHT += sss_color.rgb * max(v_wave_height, 0.0) * sss_mask * ATTENUATION;
}
