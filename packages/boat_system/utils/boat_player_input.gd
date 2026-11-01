@tool
class_name BoatPlayerInput
extends "res://packages/boat_system/components/boat_component.gd"
## Optional camera-relative directional input and steering. Does not provide buoyancy.

const EngineComponent := preload("res://packages/boat_system/components/boat_engine.gd")

## Enable player steering and throttle commands while the boat is in water.
## Remove this component to control a boat entirely through AI or another system.
@export var controls_enabled: bool = true
## Optional engine to receive throttle. Uses a sibling named Engine when unassigned.
## Leave absent for steering-only input on a sail-driven or externally powered boat.
@export var engine: EngineComponent
## Camera whose horizontal view defines WASD directions; uses the active camera if empty.
@export var control_camera: Camera3D
## Maximum yaw steering speed in degrees per second. Pitch and roll stay physics-driven.
@export_range(0.0, 360.0, 1.0, "or_greater") var steering_speed_degrees: float = 120.0
## Steering response per second. Higher values turn toward the command faster.
## Smooths yaw acceleration and settles steering when input is released.
@export_range(0.0, 30.0, 0.1, "or_greater") var steering_response: float = 6.0

@export_group("Input Actions")
## Input Map action for moving toward the top of the camera view. Default: W.
@export var forward_action: StringName = &"boat_forward"
## Input Map action for moving toward the bottom of the camera view. Default: S.
@export var backward_action: StringName = &"boat_backward"
## Input Map action for moving toward the left of the camera view. Default: A.
@export var left_action: StringName = &"boat_left"
## Input Map action for moving toward the right of the camera view. Default: D.
@export var right_action: StringName = &"boat_right"


func _ready() -> void:
	if not _resolve_boat() or Engine.is_editor_hint():
		return
	if engine == null:
		engine = boat.get_node_or_null(^"Engine") as EngineComponent
	boat.control_step.connect(_integrate_input)


func _integrate_input(state: PhysicsDirectBodyState3D) -> void:
	if is_instance_valid(engine):
		engine.throttle = 0.0
	if not controls_enabled or boat.submerged_pontoon_count <= 0:
		return
	var input := Input.get_vector(left_action, right_action, forward_action, backward_action)
	var forward := boat.get_planar_forward(state)
	if forward.is_zero_approx():
		return
	var desired_direction := _get_control_direction(input)
	var desired_yaw_speed := 0.0
	if not desired_direction.is_zero_approx():
		var heading_error := forward.signed_angle_to(desired_direction, Vector3.UP)
		var speed_limit := deg_to_rad(maxf(0.0, steering_speed_degrees))
		desired_yaw_speed = clampf(heading_error * maxf(0.0, steering_response), -speed_limit, speed_limit)
	var steering_weight := 1.0 - exp(-maxf(0.0, steering_response) * state.step)
	var spin := state.angular_velocity
	spin.y = lerpf(spin.y, desired_yaw_speed, steering_weight)
	state.angular_velocity = spin
	if is_instance_valid(engine) and not desired_direction.is_zero_approx():
		engine.throttle = input.length() * maxf(0.0, forward.dot(desired_direction))


func _get_control_direction(input: Vector2) -> Vector3:
	if input.is_zero_approx():
		return Vector3.ZERO
	var camera := control_camera
	if not is_instance_valid(camera):
		camera = get_viewport().get_camera_3d()
	var view_forward := Vector3.FORWARD
	if is_instance_valid(camera):
		view_forward = -camera.global_transform.basis.z
		view_forward.y = 0.0
		if view_forward.length_squared() < 0.000001:
			view_forward = camera.global_transform.basis.y
			view_forward.y = 0.0
		view_forward = view_forward.normalized()
	var view_right := view_forward.cross(Vector3.UP).normalized()
	return (view_right * input.x - view_forward * input.y).normalized()
