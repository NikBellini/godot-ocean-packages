@tool
class_name BoatSystem
extends RigidBody3D
## Shared floating body for boats and simple objects such as crates and buoys.
## Child components supply buoyancy, controls, and propulsion as needed.
## Mass, inertia, collision, and the center of mass remain configured on this body.

## Runs first so water contact is available to controllers and propulsion sources.
signal buoyancy_step(state: PhysicsDirectBodyState3D)
## Runs after buoyancy to read player/AI commands before applying propulsion.
signal control_step(state: PhysicsDirectBodyState3D)
## Connect engine, sail, or other force-source components here.
signal propulsion_step(state: PhysicsDirectBodyState3D)

## Ocean used by this body's buoyancy components to sample water height.
## Assign it on the boat instance in the containing scene, or set boat.ocean from code.
## The ocean must expose get_height(world_position) with height queries enabled.
@export var ocean: Node3D

## Direction the bow faces in body-local coordinates.
## The included model faces +Z: (0, 0, 1). Use (0, 0, -1) for a -Z model.
@export var model_forward_axis: Vector3 = Vector3.BACK

## Total water-contact count reported by buoyancy components this physics step.
var submerged_pontoon_count: int = 0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	can_sleep = false
	# A sleeping rigid body would stop responding while the water moves underneath it.
	reset_physics_interpolation()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if Engine.is_editor_hint():
		return
	submerged_pontoon_count = 0
	# Rebuild contact information first, then choose controls, then apply propulsion.
	# Signals let independent child components share this one current physics state.
	buoyancy_step.emit(state)
	control_step.emit(state)
	propulsion_step.emit(state)


func get_planar_forward(state: PhysicsDirectBodyState3D) -> Vector3:
	# Convert the model's local bow direction into world space and remove its vertical tilt.
	# Steering and ordinary thrust therefore act along the water's horizontal XZ plane.
	var forward := state.transform.basis * model_forward_axis
	forward.y = 0.0
	return forward.normalized()


## Applies a world-space force at a component node, or through the COM if omitted.
## The point's position is used; its rotation does not affect the force direction.
## Returns the world application point.
## Both engine and custom sail components can use this during propulsion_step.
## Optional COM-height projection removes pitch/roll torque from horizontal forces.
## It defaults off so custom force sources, such as sails, retain physical torque.
func apply_propulsion_force(state: PhysicsDirectBodyState3D, world_force: Vector3,
		point: Node3D = null, at_com_height: bool = false) -> Vector3:
	var local_point := state.center_of_mass_local
	# An omitted point means "push through the center of mass", which produces no extra twist.
	if is_instance_valid(point):
		local_point = global_transform.affine_inverse() * point.global_position
	var force_offset := state.transform.basis * local_point
	# Godot expects the application offset in world axes, measured from the body origin.
	if at_com_height:
		# Keep the component's left/right and front/back placement, but use the center of
		# mass's current world height. Horizontal engine thrust then avoids pitching the hull.
		force_offset.y = (state.transform.basis * state.center_of_mass_local).y
	state.apply_force(world_force, force_offset)
	return state.transform.origin + force_offset
