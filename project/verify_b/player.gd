extends CharacterBody2D

## Minimal platformer actor used to measure the jump arc for level-design gaps.

@export var speed: float = 400.0
@export var jump_velocity: float = -900.0

var _gravity: float = ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)


func _physics_process(delta: float) -> void:
    if not is_on_floor():
        velocity.y += _gravity * delta
    if Input.is_action_just_pressed("jump") and is_on_floor():
        velocity.y = jump_velocity
    var direction: float = Input.get_axis("move_left", "move_right")
    velocity.x = direction * speed
    move_and_slide()