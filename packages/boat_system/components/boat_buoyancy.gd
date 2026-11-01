@tool
class_name BoatBuoyancy
extends "res://packages/boat_system/components/boat_component.gd"
## Reusable spherical-pontoon buoyancy, water resistance, and wave forces.
## Attach directly to the Pontoons node under a BoatSystem body.
## Its Node3D/Marker3D children define buoyancy points for boats and floating objects.

const BoatSystemDebugDraw := preload("res://packages/boat_system/utils/boat_system_debug_draw.gd")

## Shared ocean reference exposed on the parent BoatSystem, including runtime changes.
var ocean: Node3D:
	get:
		# Read the parent each time so an outside script can replace boat.ocean at runtime.
		return boat.ocean if is_instance_valid(boat) else null

@export_group("Pontoons")
## Radius of every spherical pontoon, in meters. Larger spheres provide more lift.
## Marker scale does not affect this radius; the debug preview shows its size.
@export_range(0.001, 10.0, 0.001, "or_greater") var radius: float = 0.5
## Height adjustment added to the sampled water surface, in meters.
## Positive values increase submersion and make the boat float higher.
## The preview shifts sphere centers downward in world Y to show this adjustment.
@export var offset: float = 0.0
## Lift in newtons per displaced cubic meter. Increase this for a heavier boat.
## Physical water uses density times gravity (about 9810); the boat's mass must match.
@export_range(0.0, 10000.0, 0.01, "or_greater") var coefficient: float = 50.0
## Maximum displaced-volume contribution per pontoon, before coefficient is applied.
## Despite the name, this is cubic meters: maximum lift is max_force * coefficient newtons.
@export_range(0.0, 100.0, 0.01, "or_greater") var max_force: float = 1.0

@export_group("Vertical Damping")
## Linear damping of an ascending pontoon: reduces displaced volume by this value times vertical speed in m/s.
## Increase to reduce bobbing. Descending pontoons receive no extra lift from damping.
@export_range(0.0, 10.0, 0.001, "or_greater") var damping_factor_1: float = 0.1
## Quadratic damping of an ascending pontoon: reduces displaced volume by this value times vertical speed squared.
## Increase to suppress fast upward motion more strongly than slow bobbing.
@export_range(0.0, 10.0, 0.001, "or_greater") var damping_factor_2: float = 0.01

@export_group("Water Drag")
## Linear horizontal water resistance per submerged pontoon, using speed in km/h.
## Increase to slow the boat's drift, especially at low speeds. Zero disables this term.
@export_range(0.0, 100.0, 0.001, "or_greater") var drag_coefficient: float = 0.05
## Quadratic horizontal water resistance per submerged pontoon, using speed in km/h.
## Increase to resist fast movement more strongly. Zero disables this term.
@export_range(0.0, 100.0, 0.001, "or_greater") var drag_coefficient_2: float = 0.01
## Maximum speed in km/h used for the clamped drag factor.
## The quadratic term still multiplies that factor by actual speed. Zero disables horizontal drag.
@export_range(0.0, 500.0, 0.1, "or_greater") var max_drag_speed: float = 100.0
## Angular deceleration per second when all pontoons are submerged.
## Scales with submerged pontoon count. Increase to reduce rocking and spin; zero disables it.
@export_range(0.0, 20.0, 0.01, "or_greater") var angular_drag: float = 2.0

## Apply horizontal wave forces and water drag at the center of mass's world height.
## Keeps their XZ lever arms for yaw resistance without adding pitch or roll.
## Disable to apply all water forces at the actual pontoon points for full physical torque.
@export var horizontal_forces_at_com_height: bool = true

@export_group("Wave Direction")
## Blend of the lift direction from world up (0) toward the sampled wave normal (1).
## Higher values let wave slopes redirect more lift sideways.
## Set this and Wave Push Strength to zero to skip the four normal height samples per pontoon.
@export_range(0.0, 1.0, 0.01) var apply_wave_normal: float = 0.2
## Additional horizontal push along the wave normal, scaled by each pontoon's lift.
## Increase to make the boat drift more with wave slopes. Zero disables this extra push.
## This setting does not change vertical lift, and flat water produces no extra push.
@export_range(0.0, 2.0, 0.01, "or_greater") var wave_push_strength: float = 0.2
## Distance in meters on either side of a pontoon used to estimate the wave normal.
## Smaller values follow finer surface detail; larger values smooth the sampled slope.
@export_range(0.001, 5.0, 0.001, "or_greater") var normal_sample_distance: float = 0.25

@export_group("Debug Draw")
## Show pontoon sphere outlines while editing the boat scene.
## Updates as markers, Radius, or Offset change; this preview does not simulate water.
@export var show_pontoons_in_editor: bool = true
## Show dry spheres in orange, submerged spheres in cyan, and force arrows in green during play.
## Arrows show the resultant lift plus wave push at each marker, excluding drag.
## Vertical lift acts at the marker. The horizontal-force height option controls horizontal forces.
@export var show_debug_in_game: bool = false
## Arrow length in meters per newton of lift plus wave push.
## Increase for more visible arrows; zero hides arrows. This setting does not affect boat physics.
@export_range(0.0, 10.0, 0.01, "or_greater") var debug_force_scale: float = 0.25
## Draw pontoon outlines and force arrows through the hull, water, and other objects.
## Disable to let scene geometry occlude the debug drawing normally.
@export var debug_draw_through_objects: bool = true

## Per-pontoon depth from sphere bottom, clamped to [0, 2 * radius].
var pontoon_depths: PackedFloat32Array = PackedFloat32Array()
## Actual world-space lift plus wave push from the last physics step (excluding drag).
var pontoon_forces: PackedVector3Array = PackedVector3Array()
var submerged_pontoon_count: int = 0

var _point_positions: Array[Vector3] = []
var _configured: bool = false
var _debug_draw: BoatSystemDebugDraw


func _ready() -> void:
	# Validate references once, then remember pontoon positions relative to the rigid body.
	# Their world positions will be rebuilt from the current physics pose on every step.
	if not _resolve_boat() or Engine.is_editor_hint():
		return
	if not is_instance_valid(ocean) or not ocean.has_method(&"get_height"):
		push_error("Assign an ocean with get_height(world_position) on the parent BoatSystem body.")
		return
	if ocean.get(&"enable_get_height") == false:
		push_error("Enable Get Height on the ocean to use boat buoyancy.")
		return
	var inverse_transform := boat.global_transform.affine_inverse()
	# The scripted node is the pontoon container. Internal debug helpers are excluded.
	for child in get_children():
		if child is Node3D:
			_point_positions.append(inverse_transform * child.global_position)
	if _point_positions.is_empty():
		push_error("BoatBuoyancy requires at least one Node3D or Marker3D child on its Pontoons node.")
		return
	pontoon_depths.resize(_point_positions.size())
	pontoon_forces.resize(_point_positions.size())
	_configured = true
	# The parent body owns the physics callback; this component contributes its forces first.
	boat.buoyancy_step.connect(_integrate_buoyancy)


func _process(_delta: float) -> void:
	# This function only draws helpers. It never changes forces or the boat's transform.
	if not is_instance_valid(boat) and not _resolve_boat():
		return
	var show_debug := show_pontoons_in_editor if Engine.is_editor_hint() else show_debug_in_game
	if not show_debug:
		if is_instance_valid(_debug_draw):
			_debug_draw.clear_debug()
		return
	if not is_instance_valid(_debug_draw):
		_debug_draw = get_node_or_null(^"_BoatBuoyancyDebug") as BoatSystemDebugDraw
		if _debug_draw == null:
			_debug_draw = BoatSystemDebugDraw.new()
			_debug_draw.name = "_BoatBuoyancyDebug"
			add_child(_debug_draw, false, Node.INTERNAL_MODE_BACK)
	var positions := PackedVector3Array()
	if Engine.is_editor_hint() or not _configured:
		for child in get_children():
			if child is Node3D:
				positions.append(child.global_position)
	else:
		var rendered_transform := boat.get_global_transform_interpolated()
		# Match the displayed hull between physics ticks, so debug spheres do not stutter.
		for point in _point_positions:
			positions.append(rendered_transform * point)
	_debug_draw.draw_debug(positions, pontoon_forces, pontoon_depths,
		radius, debug_force_scale, debug_draw_through_objects, offset)


func _integrate_buoyancy(state: PhysicsDirectBodyState3D) -> void:
	# Start a fresh set of depth/force values for this physics step and the debug display.
	submerged_pontoon_count = 0
	pontoon_depths.fill(0.0)
	pontoon_forces.fill(Vector3.ZERO)
	if not _configured or not is_instance_valid(ocean):
		return
	if radius <= 0.0 or ocean.get(&"enable_get_height") == false:
		return
	var center_of_mass_offset := state.transform.basis * state.center_of_mass_local
	for index in range(_point_positions.size()):
		# 1. Find this sphere on the moving boat and sample the water below it.
		var world_position: Vector3 = state.transform * _point_positions[index]
		var force_offset := world_position - state.transform.origin
		var water_height: float = ocean.call(&"get_height", world_position)
		if not is_finite(water_height):
			continue
		var depth := clampf(water_height - world_position.y + offset + radius, 0.0, 2.0 * radius)
		# Depth is measured from the sphere's bottom: zero is dry, two radii is fully submerged.
		pontoon_depths[index] = depth
		if depth <= 0.0:
			continue
		submerged_pontoon_count += 1
		var velocity := state.linear_velocity + state.angular_velocity.cross(force_offset - center_of_mass_offset)
		# A rotating boat moves its bow and stern at different speeds. Include that local
		# motion so damping responds correctly to rocking, not only whole-body movement.
		var lift := _get_lift(depth, velocity.y)
		# 2. Calculate upward lift, then optionally lean it toward the local wave normal.
		var direction := Vector3.UP
		var wave_normal := Vector3.UP
		if lift > 0.0 and (apply_wave_normal > 0.0 or wave_push_strength > 0.0):
			wave_normal = _get_wave_normal(world_position)
			if apply_wave_normal > 0.0:
				direction = Vector3.UP.slerp(wave_normal, clampf(apply_wave_normal, 0.0, 1.0))
		var wave_push := Vector3(wave_normal.x, 0.0, wave_normal.z) * lift * maxf(0.0, wave_push_strength)
		pontoon_forces[index] = direction * lift + wave_push
		var drag := _get_horizontal_drag(velocity)
		# 3. Apply lift and resistance at their configured points. Point placement changes
		# turning torque, which is why vertical and horizontal forces can use different heights.
		if horizontal_forces_at_com_height:
			# Vertical lift keeps its real pontoon lever arm and follows the water.
			state.apply_force(Vector3.UP * pontoon_forces[index].y, force_offset)
			# Keep distributed yaw resistance while removing pitch/roll from horizontal forces.
			var horizontal_offset := force_offset
			horizontal_offset.y = center_of_mass_offset.y
			var horizontal_force := Vector3(pontoon_forces[index].x, 0.0, pontoon_forces[index].z)
			state.apply_force(horizontal_force + drag, horizontal_offset)
		else:
			state.apply_force(pontoon_forces[index] + drag, force_offset)
	boat.submerged_pontoon_count += submerged_pontoon_count
	# Share contact with engines/controllers, then damp spin according to how many points are wet.
	if submerged_pontoon_count > 0 and angular_drag > 0.0:
		var wet_fraction := float(submerged_pontoon_count) / _point_positions.size()
		state.angular_velocity *= maxf(0.0, 1.0 - angular_drag * wet_fraction * state.step)


func _get_lift(depth: float, vertical_velocity: float) -> float:
	# More submerged sphere volume means more displaced water and therefore more lift.
	# Spherical cap volume: pi / 3 * h^2 * (3r - h).
	var submerged_volume := PI / 3.0 * depth * depth * (3.0 * radius - depth)
	var damping := maxf(0.0,
		# Reduce lift while rising to limit bobbing. The outer max keeps this blueprint
		# damping from adding extra lift while the point is moving down.
		damping_factor_1 * vertical_velocity
		+ damping_factor_2 * signf(vertical_velocity) * vertical_velocity * vertical_velocity
	)
	return clampf(submerged_volume - damping, 0.0, maxf(0.0, max_force)) * maxf(0.0, coefficient)


func _get_horizontal_drag(velocity: Vector3) -> Vector3:
	# Resistance acts opposite XZ motion. One term grows with speed and one with speed squared.
	# UE's cm/s * 0.036 becomes Godot's m/s * 3.6. Godot's horizontal plane is XZ.
	var planar_velocity := Vector3(velocity.x, 0.0, velocity.z) * 3.6
	var speed := planar_velocity.length()
	if speed <= 0.0001:
		return Vector3.ZERO
	var clamped_speed := minf(speed, maxf(0.0, max_drag_speed))
	var drag := clamped_speed * (
		maxf(0.0, drag_coefficient) + maxf(0.0, drag_coefficient_2) * speed
	)
	return -planar_velocity / speed * drag


func _get_wave_normal(world_position: Vector3) -> Vector3:
	# Compare water height on each side of the point. Unequal heights indicate a slope;
	# the returned unit vector points perpendicular to that slope, away from the water.
	# The ocean exposes heights, so reconstruct its normal with central differences.
	var distance := maxf(normal_sample_distance, 0.001)
	var dx := Vector3(distance, 0.0, 0.0)
	var dz := Vector3(0.0, 0.0, distance)
	var left: float = ocean.call(&"get_height", world_position - dx)
	var right: float = ocean.call(&"get_height", world_position + dx)
	var back: float = ocean.call(&"get_height", world_position - dz)
	var front: float = ocean.call(&"get_height", world_position + dz)
	if not (is_finite(left) and is_finite(right) and is_finite(back) and is_finite(front)):
		return Vector3.UP
	return Vector3(left - right, 2.0 * distance, back - front).normalized()
