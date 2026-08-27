@tool
class_name ShervheimWater
extends MeshInstance3D
## Driver for shervheim_water.gdshader: owns the wave clock (pushed as the
## wave_time uniform, same convention as WaterSurface) and mirrors the two-sine
## wave math so CPU callers can query the surface height. Group "water".

# Wrap the clock: float32 shader math degrades after hours of accumulated time
# (verified live at ~11800 s: magenta sparkle garbage, blown foam). 3600 s is
# verified clean; the once-an-hour phase pop is acceptable for this scene.
const TIME_WRAP := 3600.0

## The upstream repo's material presets, transcribed from its
## "Assets/Stylized Water/Materials/Stylized Water {1,2,3}.mat" files
## (github.com/danielshervheim/unity-stylized-water; property names map 1:1 to
## the port's snake_case uniforms; HDR colors keep their >1 components).
## Served to the demo panel via get_presets().
const PRESETS := {
	"Water 1 (calm teal)": {
		"depth_density": 0.5, "distance_density": 0.025,
		"wave_normal_scale": 20.0, "wave_normal_speed": 0.05,
		"shallow_color": Color(0.4431, 0.9137, 0.6627),
		"deep_color": Color(0.0, 0.0125, 0.1226),
		"far_color": Color(0.1186, 0.48, 0.8113),
		"reflection_contribution": 1.0,
		"sss_color": Color(0.1522, 0.2736, 0.0632),
		"foam_contribution": 0.549, "foam_scale": 10.0, "foam_speed": 0.1,
		"foam_noise_scale": 0.32,
		"sun_specular_color": Color(1, 1, 1), "sun_specular_exponent": 3500.0,
		"sparkle_scale": 75.0, "sparkle_speed": 0.025,
		"sparkle_color": Color(0.549, 0.9608, 0.8157), "sparkle_exponent": 20000.0,
		"edge_foam_color": Color(1, 1, 1), "edge_foam_depth": 0.25,
		"wave1_direction": 0.5, "wave1_amplitude": 0.25, "wave1_wavelength": 10.0, "wave1_speed": 0.25,
		"wave2_direction": 0.25, "wave2_amplitude": 0.2, "wave2_wavelength": 10.0, "wave2_speed": 1.0,
	},
	"Water 2 (flat cartoon)": {
		"depth_density": 0.417, "distance_density": 0.0075,
		"wave_normal_scale": 50.0, "wave_normal_speed": 0.01,
		"shallow_color": Color(0.1669, 0.9983, 1.4151),
		"deep_color": Color(0.0078, 0.102, 0.2745),
		"far_color": Color(0.42, 0.6282, 0.7358),
		"reflection_contribution": 0.0,
		"sss_color": Color(0, 0, 0),
		"foam_contribution": 0.657, "foam_scale": 10.0, "foam_speed": 0.1,
		"foam_noise_scale": 0.32,
		"sun_specular_color": Color(0, 0, 0), "sun_specular_exponent": 1.0,
		"sparkle_scale": 1.0, "sparkle_speed": 1.0,
		"sparkle_color": Color(0, 0, 0), "sparkle_exponent": 1.0,
		"edge_foam_color": Color(1, 1, 1), "edge_foam_depth": 0.5,
		"wave1_direction": 0.382, "wave1_amplitude": 0.1, "wave1_wavelength": 2.0, "wave1_speed": 0.25,
		"wave2_direction": 0.618, "wave2_amplitude": 0.15, "wave2_wavelength": 7.5, "wave2_speed": 1.0,
	},
	"Water 3 (green sparkle)": {
		"depth_density": 0.417, "distance_density": 0.02,
		"wave_normal_scale": 25.0, "wave_normal_speed": 0.05,
		"shallow_color": Color(1.1505, 1.3, 0.8891),
		"deep_color": Color(0.2039, 1.0, 0.4171),
		"far_color": Color(0.0834, 0.2986, 0.7075),
		"reflection_contribution": 0.5,
		"sss_color": Color(0, 0, 0),
		"foam_contribution": 0.471, "foam_scale": 10.0, "foam_speed": 0.1,
		"foam_noise_scale": 0.775,
		"sun_specular_color": Color(0, 0, 0), "sun_specular_exponent": 1.0,
		"sparkle_scale": 25.0, "sparkle_speed": 0.1,
		"sparkle_color": Color(0.7406, 1.0, 0.9358), "sparkle_exponent": 25000.0,
		"edge_foam_color": Color(1, 1, 1), "edge_foam_depth": 0.1,
		"wave1_direction": 0.382, "wave1_amplitude": 0.1, "wave1_wavelength": 2.0, "wave1_speed": 0.25,
		"wave2_direction": 0.618, "wave2_amplitude": 0.15, "wave2_wavelength": 7.5, "wave2_speed": 1.0,
	},
}

var _time := 0.0


func _ready() -> void:
	add_to_group("water")


## Preset dictionaries for the demo panel's picker (see PRESETS above).
func get_presets() -> Dictionary:
	return PRESETS


func _process(delta: float) -> void:
	_time = fposmod(_time + delta, TIME_WRAP)
	var mat := material_override as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("wave_time", _time)


## Water surface height (world Y) at a horizontal world position — the CPU twin
## of the shader's get_wave_height(), reading the wave uniforms off the material.
func get_wave_height(world_pos: Vector3) -> float:
	var mat := material_override as ShaderMaterial
	if mat == null:
		return global_position.y
	var h := 0.0
	for i in [1, 2]:
		var direction: float = mat.get_shader_parameter("wave%d_direction" % i)
		var amplitude: float = mat.get_shader_parameter("wave%d_amplitude" % i)
		var wavelength: float = mat.get_shader_parameter("wave%d_wavelength" % i)
		var speed: float = mat.get_shader_parameter("wave%d_speed" % i)
		var d := Vector2(cos(PI * direction), sin(PI * direction))
		var x := PI * d.dot(Vector2(world_pos.x, world_pos.z)) / wavelength
		h += amplitude * sin(x + speed * _time)
	return global_position.y + h
