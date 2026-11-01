@tool
class_name BoatEngine
extends "res://packages/boat_system/components/boat_component.gd"
## Optional engine component. A player or AI controller supplies its throttle.
## Position this node to choose the horizontal thrust application point.
## Base thrust acts at COM height; Acceleration Pitch controls bow rise.

## Enable this engine's force output. Does not disable the boat's buoyancy.
@export var engine_enabled: bool = true
## Require at least one submerged pontoon before this engine can apply thrust.
## Disable only for force sources intentionally allowed to operate out of water.
@export var require_water_contact: bool = true
## Maximum acceleration in meters per second squared before water resistance.
## Force scales with the boat's mass; larger values provide stronger acceleration.
@export_range(0.0, 100.0, 0.1, "or_greater") var engine_acceleration: float = 15.0
## Horizontal speed in meters per second at which engine thrust fades out.
## Water resistance can produce a lower cruising speed. Wave motion is not clamped.
@export_range(0.1, 50.0, 0.1, "or_greater") var max_engine_speed: float = 6.0
## Add a gentle bow-up torque while the engine accelerates the boat forward.
## Fades as acceleration ends, letting buoyancy settle the hull without rotation locks.
@export var acceleration_pitch_enabled: bool = true
## Bow-up torque gain per unit of forward acceleration and boat mass.
## Start around 0.1 to 0.3 for a subtle effect; larger hulls may need different tuning.
## Zero disables the effect. The resulting angle depends on hull inertia and buoyancy.
@export_range(0.0, 2.0, 0.01, "or_greater") var acceleration_pitch_strength: float = 0.2
## Response per second for building and fading the acceleration-pitch torque.
## Smaller positive values respond more gently; zero follows measured acceleration immediately.
@export_range(0.0, 30.0, 0.1, "or_greater") var acceleration_pitch_response: float = 6.0

## Signed engine command in [-1, 1]. Player input uses forward thrust after steering.
var throttle: float = 0.0
var last_force := Vector3.ZERO
# These last_* values are useful when inspecting what the engine applied this physics step.
var last_application_position := Vector3.ZERO
var last_acceleration_pitch_torque := Vector3.ZERO

var _previous_velocity := Vector3.ZERO
var _has_velocity_sample := false
var _pitch_acceleration := 0.0


func _ready() -> void:
	# The editor displays the boat but must not run the engine simulation.
	if not _resolve_boat() or Engine.is_editor_hint():
		return
	boat.propulsion_step.connect(_integrate_engine)
	# BoatSystem calls this phase after buoyancy and player/AI input have been updated.


func _integrate_engine(state: PhysicsDirectBodyState3D) -> void:
	# 1. Measure real forward acceleration, including the effect of water resistance.
	last_force = Vector3.ZERO
	last_acceleration_pitch_torque = Vector3.ZERO
	var forward := boat.get_planar_forward(state)
	var acceleration := 0.0
	if _has_velocity_sample and state.step > 0.0:
		# World velocity differences avoid mistaking a change of heading for acceleration.
		acceleration = (state.linear_velocity - _previous_velocity).dot(forward) / state.step
	_previous_velocity = state.linear_velocity
	# Remember velocity even when the engine is disabled, avoiding a jump when it restarts.
	_has_velocity_sample = true
	if not engine_enabled or (require_water_contact and boat.submerged_pontoon_count <= 0):
		_pitch_acceleration = 0.0
		return
	var command := clampf(throttle, -1.0, 1.0)
	# 2. Convert throttle into thrust. Negative commands reverse the engine force.
	if not is_zero_approx(command):
		var planar_speed := Vector3(state.linear_velocity.x, 0.0, state.linear_velocity.z).length()
		var speed_limit := maxf(0.1, max_engine_speed)
		var speed_factor := clampf((speed_limit - planar_speed) / (speed_limit * 0.2), 0.0, 1.0)
		# Keep full thrust below 80% of the speed limit, then reduce it smoothly to zero.
		# Multiplying acceleration by mass gives force: F = mass * acceleration.
		last_force = forward * maxf(0.0, engine_acceleration) * boat.mass * command * speed_factor
		# Base thrust stays pitch-neutral; the acceleration effect supplies bow-up torque.
		last_application_position = boat.apply_propulsion_force(state, last_force, self, true)
	var powered_forward := command > 0.0 and last_force.dot(forward) > 0.0
	# 3. Bow rise follows actual acceleration, rather than staying raised while throttle is held.
	_apply_acceleration_pitch(state, forward, acceleration if powered_forward else 0.0)


func _apply_acceleration_pitch(state: PhysicsDirectBodyState3D, forward: Vector3,
		acceleration: float) -> void:
	if not acceleration_pitch_enabled or acceleration_pitch_strength <= 0.0 or boat.submerged_pontoon_count <= 0:
		_pitch_acceleration = 0.0
		return
	# Limit collision/wave spikes to the engine's configured acceleration range.
	var target_acceleration := clampf(acceleration, 0.0, maxf(0.0, engine_acceleration))
	# Ignore braking/reverse acceleration and reduce sudden changes before applying torque.
	var weight := 1.0 if acceleration_pitch_response <= 0.0 else 1.0 - exp(-acceleration_pitch_response * state.step)
	_pitch_acceleration = lerpf(_pitch_acceleration, target_acceleration, weight)
	# The exponential response has the same feel at different physics tick rates.
	if _pitch_acceleration < 0.0001:
		_pitch_acceleration = 0.0
		return
	# Forward cross up rotates the bow upward for either model-forward convention.
	var pitch_axis := forward.cross(Vector3.UP).normalized()
	last_acceleration_pitch_torque = pitch_axis * boat.mass * acceleration_pitch_strength * _pitch_acceleration
	state.apply_torque(last_acceleration_pitch_torque)
	# Apply a turning force instead of setting the rotation directly, so waves can still rock it.
