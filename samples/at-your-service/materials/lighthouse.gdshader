shader_type spatial;
render_mode cull_back;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
void fragment() {
 vec3 original = texture(albedo_texture, UV).rgb;
 float red = smoothstep(0.08, 0.25, original.r - max(original.g, original.b));
 vec3 mulberry = vec3(0.22, 0.067, 0.115) * (0.7 + original.r);
 ALBEDO = mix(original, mulberry, red);
 ROUGHNESS = 0.85;
}
