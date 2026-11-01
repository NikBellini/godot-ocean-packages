class_name BoatFollowCamera
extends Camera3D
## Smooth follow camera with right-mouse orbit around the boat.

## Boat or other Node3D to follow. Assign the controlled boat in the Inspector.
@export var target: Node3D
## Distance from the boat in meters, measured along the camera's viewing offset.
@export_range(1.0, 100.0, 0.1, "or_greater") var follow_distance: float = 14.0
## Height angle above the horizontal plane. Larger values give a more top-down view.
@export_range(5.0, 85.0, 1.0, "degrees") var elevation_degrees: float = 48.0
## World heading around the boat. Zero places the camera on the positive Z side.
## Mouse orbit changes this heading; hull rotation does not turn the camera.
@export_range(-180.0, 180.0, 1.0, "degrees") var azimuth_degrees: float = 0.0
## Horizontal position response per second. Lower values follow more gently; higher values catch up faster.
## Zero disables position smoothing and follows immediately.
@export_range(0.0, 30.0, 0.1, "or_greater") var position_smoothing: float = 4.0
## Height response per second. Lower positive values filter wave bobbing more strongly.
## Zero follows height immediately. Independent of horizontal Position Smoothing.
@export_range(0.0, 30.0, 0.1, "or_greater") var vertical_smoothing: float = 2.0
## Orbit response per second when the viewing angle or heading changes.
## Position and aim orbit together around the smoothed anchor, keeping the boat framed.
## Zero applies viewing-angle changes immediately.
@export_range(0.0, 30.0, 0.1, "or_greater") var aim_smoothing: float = 6.0
## Height in meters above the target origin to frame at the center of the view.
@export var look_height: float = 0.6

@export_group("Mouse Orbit")
## Hold the right mouse button and move the mouse to orbit the active camera.
@export var mouse_orbit_enabled: bool = true
## Orbit angle in degrees per screen pixel. Independent of frame rate and viewport stretch.
@export_range(0.01, 1.0, 0.01, "or_greater") var mouse_sensitivity: float = 0.18
## Reverse vertical mouse movement when orbiting.
@export var invert_mouse_y: bool = false

var _look_target := Vector3.ZERO
var _follow_position := Vector3.ZERO
var _orbit_azimuth := 0.0 # Smoothed orbit angles, in radians.
var _orbit_elevation := 0.0
var _orbiting := false
var _previous_mouse_mode := Input.MOUSE_MODE_VISIBLE


func _ready() -> void:
	if not is_instance_valid(target):
		push_error("Assign the boat to the follow camera's Target property.")
		set_process(false)
		return
	# This camera moves each rendered frame and must not be interpolated again.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	top_level = true
	# Frame the boat on the first frame; subsequent movement is always smoothed.
	_orbit_azimuth = deg_to_rad(azimuth_degrees)
	_orbit_elevation = deg_to_rad(clampf(elevation_degrees, 5.0, 85.0))
	_follow_position = target.get_global_transform_interpolated().origin
	global_position = _follow_position + _get_follow_offset()
	_look_target = _follow_position + Vector3.UP * look_height
	_update_aim()
	process_priority = 100
	get_window().focus_exited.connect(_release_mouse)


func _input(event: InputEvent) -> void:
	# Always end a drag on release, even if a GUI control would consume that event.
	if not _orbiting:
		return
	var released: bool = event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed
	if released or event.is_action_pressed(&"ui_cancel"):
		_release_mouse()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not mouse_orbit_enabled or not is_current() or not is_instance_valid(target):
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if not _orbiting:
			_previous_mouse_mode = Input.mouse_mode
			_orbiting = true
			# Capture only during the drag so the screen edge cannot stop an orbit.
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _orbiting:
		# Mouse motion already measures distance, so it must not be multiplied by delta.
		var motion: Vector2 = event.screen_relative * maxf(0.0, mouse_sensitivity)
		azimuth_degrees = wrapf(azimuth_degrees - motion.x, -180.0, 180.0)
		elevation_degrees = clampf(elevation_degrees + motion.y * (-1.0 if invert_mouse_y else 1.0), 5.0, 85.0)
		get_viewport().set_input_as_handled()


func _release_mouse() -> void:
	if not _orbiting:
		return
	_orbiting = false
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = _previous_mouse_mode


func _exit_tree() -> void:
	_release_mouse()


func _process(delta: float) -> void:
	if _orbiting and (not mouse_orbit_enabled or not is_current() or not is_instance_valid(target)):
		_release_mouse()
	if not is_instance_valid(target):
		return
	var target_position := target.get_global_transform_interpolated().origin
	var position_weight := _smoothing_weight(position_smoothing, delta)
	var height_weight := _smoothing_weight(vertical_smoothing, delta)
	_follow_position.x = lerpf(_follow_position.x, target_position.x, position_weight)
	_follow_position.z = lerpf(_follow_position.z, target_position.z, position_weight)
	_follow_position.y = lerpf(_follow_position.y, target_position.y, height_weight)
	var orbit_weight := _smoothing_weight(aim_smoothing, delta)
	_orbit_azimuth = lerp_angle(_orbit_azimuth, deg_to_rad(azimuth_degrees), orbit_weight)
	_orbit_elevation = lerpf(_orbit_elevation, deg_to_rad(clampf(elevation_degrees, 5.0, 85.0)), orbit_weight)
	global_position = _follow_position + _get_follow_offset()
	_look_target = _follow_position + Vector3.UP * look_height
	_update_aim()


func _get_follow_offset() -> Vector3:
	return Vector3(sin(_orbit_azimuth) * cos(_orbit_elevation), sin(_orbit_elevation), cos(_orbit_azimuth) * cos(_orbit_elevation)) * maxf(1.0, follow_distance)


func _smoothing_weight(response: float, delta: float) -> float:
	return 1.0 if response <= 0.0 else 1.0 - exp(-response * maxf(delta, 0.0))


func _update_aim() -> void:
	var view_direction := _look_target - global_position
	if view_direction.cross(Vector3.UP).length_squared() > 0.000001:
		global_basis = Basis.looking_at(view_direction, Vector3.UP)
