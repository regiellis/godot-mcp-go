class_name WaterFlyCamera
extends Camera3D
## Godot port of danielshervheim/unity-stylized-water's DemoScene FlyingCamera.cs
## (BSD 3-Clause, (c) 2019 Daniel Shervheim; see res://assets/shervheim_demo/LICENSE).
## Same controls, Godot-idiomatic input: hold RIGHT MOUSE to look (captures the
## mouse; Unity's version was always-on), WASD to fly, SPACE up / SHIFT down,
## mouse WHEEL to change speed. Shared by both water scenes.

@export var movement_speed := 8.0 ## meters per second
@export var look_sensitivity := 0.15 ## degrees per mouse pixel

var _pitch := 0.0
var _yaw := 0.0


func _ready() -> void:
	_pitch = rotation_degrees.x
	_yaw = rotation_degrees.y


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			movement_speed = minf(movement_speed * 1.2, 100.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			movement_speed = maxf(movement_speed / 1.2, 0.5)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_pitch = clampf(_pitch - event.relative.y * look_sensitivity, -90.0, 90.0)
		_yaw -= event.relative.x * look_sensitivity
		rotation_degrees = Vector3(_pitch, _yaw, 0.0)


func _process(delta: float) -> void:
	var forward := (1.0 if Input.is_key_pressed(KEY_W) else 0.0) - (1.0 if Input.is_key_pressed(KEY_S) else 0.0)
	var strafe := (1.0 if Input.is_key_pressed(KEY_D) else 0.0) - (1.0 if Input.is_key_pressed(KEY_A) else 0.0)
	var lift := (1.0 if Input.is_key_pressed(KEY_SPACE) else 0.0) - (1.0 if Input.is_key_pressed(KEY_SHIFT) else 0.0)
	var basis3 := global_transform.basis
	global_position += (-basis3.z * forward + basis3.x * strafe + basis3.y * lift) * movement_speed * delta
