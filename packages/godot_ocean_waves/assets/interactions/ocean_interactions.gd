extends Node
## Ocean-owned foam and spray; every source is a collider or optional OceanInteractor.
## Physics samples detect contact and impacts. Render frames deposit interpolated movement
## into one shared coverage texture. The water shader shades it like breaking-wave foam.
## Each stamp keeps its world position and lifetime after its source stops or leaves water.
# Reading guide:
# - Contact = information about an object touching the water.
# - Stamp = one small piece of a foam trail left behind that object.
# - field = an invisible image: brighter red means more foam at that water position.
# - Physics checks whether the object is wet; rendering draws its trail smoothly.

const Interactor := preload("res://packages/godot_ocean_waves/assets/interactions/ocean_interactor.gd")
const STAMP_SHADER := preload("res://packages/godot_ocean_waves/assets/shaders/interaction_stamp.gdshader")
const INSTANCE_STRIDE := 12 # 2D transform (8 floats) followed by custom data (4 floats).
const CONTACT_INTERVAL := 1.0 / 20.0 # Limit CPU water-height queries to 20 Hz per source.
const TELEPORT_DISTANCE := 8.0 # Meters per contact sample; larger jumps must not draw a bridge.
const MAX_SPLASHES_PER_FRAME := 128 # Shared by all sources, independent of per-impact limits.
const MAP_RESOLUTION := 1024 # Internal rendering detail; no setup is needed on the ocean.
const MINIMUM_FIELD_SIZE := 96.0 # The map grows automatically to fit all live trails.
const MINIMUM_WAKE_SPEED := 0.2 # Ignore horizontal movement below this speed in m/s.

## Remainder of a distance-sampled trail. Anchor is the last emitted point in world space.
class FoamPath:
	var valid := false
	var anchor := Vector3.ZERO

## Cached geometry, motion, water-contact, and emission state for one source body.
class Contact:
	var body: Node3D
	var settings: Interactor
	var bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE) # Body-local collision bounds.
	var has_shape := false # Disabled/missing shapes must not generate phantom contact.
	var previous := Vector3.ZERO
	var initialized := false
	var wet := false
	var contact_blend := 0.0 # Smooth buildup on first contact, not an airborne emission timer.
	var velocity := Vector3.ZERO
	var height := 0.0
	var radius := 0.5
	var path := FoamPath.new()
	var impact_time := -INF
	var pending_impact := 0.0 # Closing speed in m/s, queued for the next rendered frame.
	var impact_position := Vector3.ZERO
	var previous_gap := 0.0 # Signed distance from collision bottom to water; positive is above it.
	var surface_sample_valid := false
	var render_position := Vector3.ZERO
	var spray_credit := 0.0 # Fractional particle count makes emission independent of frame rate.

## One small coverage segment. It stores no mesh and applies no physics force.
## Moving segments overlap; isolated gameplay patches use a round footprint instead.
class Stamp:
	var position := Vector2.ZERO
	var direction := Vector2.DOWN
	var radius := 1.0
	var length := 0.2
	var strength := 1.0
	var spot := false
	var created := 0.0
	var source_id := 0

var ocean: Node3D # Assigned by GodotOceanWaves before this manager enters the tree.
var water_material: ShaderMaterial # Local material instance, never a shared asset mutation.
var contacts: Dictionary = {} # Source instance ID -> Contact; avoids duplicate registration.
var stamps: Array[Stamp] = [] # Time-ordered live history, capped across all objects.
var field: SubViewport # GPU-generated red-channel coverage; no CPU texture rasterization.
var instances := MultiMesh.new()
var spray: GPUParticles3D
var clock := 0.0 # Render seconds, used consistently by every source and stamp.
var origin := Vector2.ZERO # Lower XZ corner of the active square, aligned to whole texels.
var area_size := MINIMUM_FIELD_SIZE # Automatically fitted to live foam, not a detection limit.
var max_stamps := 1024 # Internal history budget, shared by all objects.
var _instance_buffer := PackedFloat32Array()
var _stamp_material := ShaderMaterial.new()
var _bound_settings: Array = []
var _sample_delta := 0.0
var _rng := RandomNumberGenerator.new()
var _spray_material: ShaderMaterial
var _splash_budget := MAX_SPLASHES_PER_FRAME
var _empty_field: ImageTexture # Safe sampler while the viewport starts or is being removed.
var _field_ready := false


## Create the shared field and reuse the ocean's existing native spray pool.
func _ready() -> void:
	process_priority = 60
	# The field is uploaded every render frame. Interpolating it a second time can
	# leave the 2D MultiMesh using stale GPU bindings when physics interpolation is on.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_create_field()
	# Use the ocean's original GPU particle pool, texture, dissolve, and animation shaders.
	if is_instance_valid(ocean.water):
		spray = ocean.water.get_node_or_null(^"WaterSprayEmitter") as GPUParticles3D
	if spray != null:
		spray.fixed_fps = 0
		spray.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		if spray.material_override is ShaderMaterial:
			_spray_material = spray.material_override.duplicate()
			spray.material_override = _spray_material
	get_tree().node_added.connect(_node_added)
	_scan(get_tree().root)
	_bind_field()
	# A ViewportTexture exists before its render target has been drawn. Keep the
	# water on a real black texture until that first draw has created its GPU data.
	RenderingServer.frame_post_draw.connect(_activate_field, CONNECT_ONE_SHOT)


func _activate_field() -> void:
	if not is_inside_tree():
		return
	_field_ready = true
	_bound_settings.clear()
	_bind_field()


## Discover sources already in the scene when this ocean starts.
func _scan(node: Node) -> void:
	if node is CollisionObject3D or node is Interactor:
		_register(node)
	for child in node.get_children():
		_scan(child)


## Defer registration until newly spawned bodies and their children are fully attached.
func _node_added(node: Node) -> void:
	if node is CollisionObject3D or node is CollisionShape3D or node is CollisionPolygon3D or node is Interactor:
		# A collider may be added to a body that has already entered the scene.
		if node is CollisionShape3D or node is CollisionPolygon3D:
			_register.call_deferred(node.get_parent())
			return
		_register.call_deferred(node)


## Track the collider without requiring a rigid body or an effects script.
## The same body is registered once even if both it and its interactor are discovered.
func _register(node: Node) -> void:
	if not is_instance_valid(node) or not node.is_inside_tree():
		return
	var settings := node as Interactor
	var body: Node3D = settings.get_parent() as Node3D if settings != null else node as Node3D
	if body == null:
		return
	if settings == null:
		for child in body.get_children():
			if child is Interactor:
				settings = child
				break
	var key := body.get_instance_id()
	if contacts.has(key):
		if settings != null:
			contacts[key].settings = settings
		return
	var contact := Contact.new()
	contact.body = body
	contact.settings = settings
	_refresh_bounds(contact)
	contacts[key] = contact
	# Start the visual interpolation pump before the first wake sample.
	body.get_global_transform_interpolated()


## Read the actual shape owners, which also includes CollisionPolygon3D and shapes
## created through code. Refresh at contact time so resizing/disabling a collider works.
func _refresh_bounds(contact: Contact) -> void:
	contact.has_shape = false
	var collider := contact.body as CollisionObject3D
	if collider == null:
		return # A marker-only interactor can deliberately work without a collider.
	for shape_owner_id in collider.get_shape_owners():
		if collider.is_shape_owner_disabled(shape_owner_id):
			continue
		var local_transform := collider.shape_owner_get_transform(shape_owner_id)
		for index in range(collider.shape_owner_get_shape_count(shape_owner_id)):
			var shape := collider.shape_owner_get_shape(shape_owner_id, index)
			var mesh := shape.get_debug_mesh()
			if mesh == null:
				continue
			var bounds: AABB = local_transform * mesh.get_aabb()
			contact.bounds = contact.bounds.merge(bounds) if contact.has_shape else bounds
			contact.has_shape = true


## Explicit interactors can opt in when automatic detection is disabled or select one ocean.
func _enabled(contact: Contact) -> bool:
	if not ocean.interaction_enabled:
		return false
	if is_instance_valid(contact.settings):
		var settings := contact.settings
		return settings.interaction_enabled and settings.strength > 0.0 and (settings.ocean == null or settings.ocean == ocean)
	return ocean.auto_detect_colliders


## Contact queries need only a fixed low rate; visible trail movement is sampled every frame.
func _physics_process(delta: float) -> void:
	if not is_instance_valid(ocean):
		return
	_sample_delta += delta
	if _sample_delta < CONTACT_INTERVAL:
		return
	var step := _sample_delta
	_sample_delta = 0.0
	# Use the actual time since the last check, including any slow frames.
	# Otherwise the speed calculation below would exaggerate or underestimate impacts.
	for key in contacts.keys():
		var contact: Contact = contacts[key]
		if not is_instance_valid(contact.body):
			contacts.erase(key)
			continue
		_sample_contact(contact, step)


## Measure the body's waterline and relative entry speed, including a rising wave.
## Swept gap crossings catch fast objects even when both samples miss partial submersion.
func _sample_contact(contact: Contact, delta: float) -> void:
	var body := contact.body
	var settings := contact.settings if is_instance_valid(contact.settings) else null
	_refresh_bounds(contact)
	var bounds: AABB = body.global_transform * contact.bounds
	# Turn the local collision box into a world-space box before comparing it to water.
	var position := bounds.get_center()
	if settings != null and settings.use_marker_position:
		position = settings.global_position
	var previous_position := contact.previous
	var velocity := Vector3.ZERO
	# Distance divided by elapsed seconds gives velocity in meters per second.
	# The first check has no earlier position, so it starts with zero velocity.
	if contact.initialized:
		velocity = (position - contact.previous) / maxf(delta, 0.001)
	var teleported := contact.initialized and position.distance_to(contact.previous) > TELEPORT_DISTANCE
	# Remember the current position even when effects are off, so re-enabling them
	# does not mistake all the intervening movement for one enormous impact.
	contact.previous = position
	contact.initialized = true
	contact.velocity = velocity
	var has_contact_geometry := contact.has_shape or (settings != null and (settings.use_marker_position or not body is CollisionObject3D))
	if not _enabled(contact) or teleported or not ocean.enable_get_height or not has_contact_geometry:
		contact.wet = false
		contact.contact_blend = 0.0
		contact.path.valid = false
		contact.surface_sample_valid = false
		contact.pending_impact = 0.0
		return
	# There is no player-centered detection square. Any collider can touch the ocean;
	# the rendering map will fit the resulting trails afterward.
	contact.height = ocean.get_height(position)
	# An object touches water when the surface lies between its bottom and top.
	# The small margin prevents tiny wave changes from constantly toggling contact.
	var margin: float = settings.contact_margin if settings != null else 0.35
	contact.wet = bounds.position.y <= contact.height + margin and bounds.end.y >= contact.height - margin
	if settings != null and settings.use_marker_position:
		contact.wet = absf(position.y - contact.height) <= margin
	# Size follows the hull's local beam, rather than an AABB which grows when the hull yaws.
	var scale := body.global_basis.get_scale().abs()
	contact.radius = maxf(0.2, minf(contact.bounds.size.x * scale.x, contact.bounds.size.z * scale.z) * 0.5)
	if settings != null and settings.radius > 0.0:
		contact.radius = settings.radius
	var gap: float = position.y - contact.height if settings != null and settings.use_marker_position else bounds.position.y - contact.height
	# Examples: gap = +1 means the bottom is one meter above water;
	# gap = -1 means it is one meter below. A shrinking gap means water entry.
	if contact.surface_sample_valid:
		# A rising wave, hull rotation, and a descending object all close this gap.
		var closing_speed := (contact.previous_gap - gap) / maxf(delta, 0.001)
		var crossed := contact.previous_gap > 0.0 and gap <= 0.0
		# A large fall can move right through the surface between two checks.
		# Detect that crossing as well as objects currently intersecting the surface.
		if (contact.wet or crossed) and gap <= 0.0 and closing_speed >= ocean.interaction_impact_speed and clock - contact.impact_time >= ocean.interaction_impact_cooldown:
			contact.impact_time = clock
			contact.pending_impact = maxf(contact.pending_impact, closing_speed)
			var weight := clampf(contact.previous_gap / maxf(0.001, contact.previous_gap - gap), 0.0, 1.0) if crossed else 1.0
			# Estimate where the object crossed the surface, rather than spawning
			# its splash at the object's later, possibly underwater, position.
			contact.impact_position = previous_position.lerp(position, weight)
			contact.impact_position.y = contact.height
	contact.previous_gap = gap
	contact.surface_sample_valid = true


## Project the displayed body pose onto the sampled surface and paint only while in contact.
## Pending swept impacts are handled first because their source may already be underwater.
func _render_contact(contact: Contact, delta: float) -> void:
	if not is_instance_valid(contact.body):
		return
	if _enabled(contact) and contact.pending_impact > 0.0:
		# Physics queues one impact. Consume it here once, rather than every rendered frame.
		var multiplier: float = contact.settings.strength if is_instance_valid(contact.settings) else 1.0
		var impact_count := _get_impact_splash_count(contact.pending_impact, contact.radius, multiplier)
		_emit_spray(contact.impact_position, contact.velocity, contact.radius, impact_count, contact.pending_impact / ocean.interaction_impact_speed)
		contact.pending_impact = 0.0
	if not _enabled(contact) or not contact.wet:
		# End deposition immediately. Previously painted foam stays on the ocean and fades.
		contact.path.valid = false
		contact.contact_blend = 0.0
		contact.spray_credit = 0.0
		contact.pending_impact = 0.0
		return
	var settings := contact.settings if is_instance_valid(contact.settings) else null
	# Script-driven colliders already have their displayed transform. Physics-driven
	# bodies use the interpolated pose to keep the wake with the hull between ticks.
	var transform := contact.body.global_transform
	var physics_driven := contact.body is RigidBody3D or contact.body is CharacterBody3D
	if contact.body is AnimatableBody3D:
		physics_driven = contact.body.sync_to_physics
	if physics_driven:
		transform = contact.body.get_global_transform_interpolated()
	# Use the position currently shown on screen. Raw physics positions move in steps.
	var position := transform * contact.bounds.get_center()
	if settings != null and settings.use_marker_position:
		position = transform * (contact.body.global_transform.affine_inverse() * settings.global_position)
	position.y = contact.height
	# Foam is painted on the water surface, not at the center of the object above it.
	contact.render_position = position
	contact.contact_blend = move_toward(contact.contact_blend, 1.0, delta / 0.15)
	var strength: float = settings.strength if settings != null else 1.0
	var velocity := contact.velocity
	var speed := Vector2(velocity.x, velocity.z).length()
	if speed <= MINIMUM_WAKE_SPEED:
		contact.path.valid = false
		contact.spray_credit = 0.0
		return
	var intensity := clampf(speed / 4.0, 0.2, 1.0) * strength * contact.contact_blend
	# Faster motion makes a stronger trail; the user multiplier and contact fade
	# then scale it. This changes the appearance only, never the object's motion.
	_emit_path(contact.path, position, contact.radius, intensity, speed, contact.body.get_instance_id())
	contact.spray_credit += delta * ocean.interaction_splash_rate * clampf(speed / 4.0, 0.0, 1.0) * strength * contact.contact_blend
	# Keep fractions between frames: 0.4 + 0.4 + 0.4 eventually emits one particle.
	# Without this accumulator, low spray rates could round down to zero forever.
	var count := mini(6, int(contact.spray_credit))
	contact.spray_credit -= count
	if count > 0:
		var forward := Vector3(velocity.x, 0.0, velocity.z).normalized()
		var half_size := contact.bounds.size * 0.5
		# Estimate the front edge along the travel direction, so steady spray
		# starts near the leading side instead of underneath the object's center.
		var reach := absf(forward.dot(transform.basis.x)) * half_size.x + absf(forward.dot(transform.basis.z)) * half_size.z
		_emit_spray(position + forward * reach * 0.75, velocity, contact.radius, count)


## Emit evenly spaced segments along actual travel. This avoids a dotted 20 Hz trail.
## Preserve the unconsumed distance in path.anchor and cap catch-up work per source/frame.
func _emit_path(path: FoamPath, position: Vector3, radius: float, strength: float, speed: float, source_id: int) -> void:
	if not path.valid:
		path.anchor = position
		path.valid = true
	var displacement := (position - path.anchor) * Vector3(1, 0, 1)
	var distance := displacement.length()
	if distance > TELEPORT_DISTANCE:
		path.valid = false
		return
	var spacing := clampf(radius * 0.22, 0.12, 0.3)
	# Place foam by distance traveled, not by frame count. Slow and fast frames
	# therefore produce equally spaced pieces, and changing direction leaves a curved trail.
	var direction := displacement.normalized()
	for i in range(mini(24, int(distance / spacing))):
		var end := path.anchor + direction * spacing
		var stamp := Stamp.new()
		stamp.position = Vector2(path.anchor.x + end.x, path.anchor.z + end.z) * 0.5
		stamp.direction = Vector2(direction.x, direction.z)
		stamp.radius = radius
		stamp.length = spacing
		stamp.strength = strength
		stamp.source_id = source_id
		stamp.created = clock - maxf(0.0, distance - spacing * (i + 1)) / maxf(speed, 0.1)
		# Backdate each piece to when the object passed it. Several pieces created
		# during one catch-up frame should not all look equally new.
		stamps.append(stamp)
		path.anchor = end


## Paint an isolated foam patch from a paddle, explosion, or another gameplay event.
func add_disturbance(position: Vector3, radius: float, strength: float = 1.0, impact: bool = false) -> void:
	if not ocean.interaction_enabled or strength <= 0.0:
		return
	var stamp := Stamp.new()
	stamp.position = Vector2(position.x, position.z)
	stamp.radius = maxf(0.1, radius)
	stamp.strength = clampf(strength * (1.25 if impact else 1.0), 0.0, 3.0)
	stamp.spot = true
	stamp.created = clock
	stamps.append(stamp)
	_trim_stamps()


## Remove expired coverage and enforce the total history budget. Leaving water never clears it.
func _trim_stamps() -> void:
	while not stamps.is_empty() and clock - stamps[0].created >= ocean.interaction_foam_lifetime:
		stamps.pop_front()
	while stamps.size() > max_stamps:
		stamps.pop_front()


## Frame flow: align coverage map, update source footprints, expire history, upload, then bind.
func _process(delta: float) -> void:
	if not is_instance_valid(ocean):
		return
	clock += delta
	_splash_budget = MAX_SPLASHES_PER_FRAME
	if not ocean.interaction_enabled:
		stamps.clear()
	for contact in contacts.values():
		_render_contact(contact, delta)
	_trim_stamps()
	_fit_field()
	_upload_field()
	_bind_field()


## Fit every live trail, including foam left by a collider far from Player.
## Grow in powers of two and keep that size while foam survives, avoiding continual
## resolution changes. The texture remains an implementation detail, not a setup area.
func _fit_field() -> void:
	if stamps.is_empty():
		area_size = MINIMUM_FIELD_SIZE
		return
	var extent := Rect2(stamps[0].position, Vector2.ZERO)
	for stamp in stamps:
		var age := maxf(0.0, clock - stamp.created)
		var radius: float = stamp.radius * ocean.interaction_foam_width + age * ocean.interaction_spread + stamp.length
		extent = extent.expand(stamp.position - Vector2.ONE * radius)
		extent = extent.expand(stamp.position + Vector2.ONE * radius)
	# Leave a wide soft border outside the live foam, even as old sections spread.
	var required := maxf(extent.size.x, extent.size.y) * 1.25 + 4.0
	while area_size < required:
		area_size *= 2.0
	var texel := area_size / float(MAP_RESOLUTION)
	origin = ((extent.get_center() - Vector2.ONE * area_size * 0.5) / texel).floor() * texel


## Build one packed MultiMesh buffer for all coverage quads, keeping the CPU/GPU cost bounded.
## A row stores [m00,m01,0,x, m10,m11,0,y, normalized_age,strength,spot_flag,age_seconds].
## Its transverse axis grows with age; its longitudinal triangular weight joins neighbors.
func _upload_field() -> void:
	if instances.instance_count != max_stamps:
		instances.visible_instance_count = 0
		instances.instance_count = max_stamps
		_instance_buffer.resize(max_stamps * INSTANCE_STRIDE)
	var pixels: float = float(field.size.x) / area_size
	for i in range(stamps.size()):
		var stamp := stamps[i]
		var age := maxf(0.0, clock - stamp.created)
		var width: float = stamp.radius * ocean.interaction_foam_width + age * ocean.interaction_spread
		# Old foam spreads sideways. It does not stretch along the path, which
		# would make neighboring pieces overlap too much and form bright stripes.
		var length := width if stamp.spot else stamp.length
		var forward := stamp.direction
		var side := Vector2(-forward.y, forward.x)
		var position := (stamp.position - origin) * pixels
		var base := i * INSTANCE_STRIDE
		# First eight numbers: place and resize this invisible footprint quad.
		_instance_buffer[base] = side.x * width * pixels
		_instance_buffer[base + 1] = forward.x * length * pixels
		_instance_buffer[base + 2] = 0.0
		_instance_buffer[base + 3] = position.x
		_instance_buffer[base + 4] = side.y * width * pixels
		_instance_buffer[base + 5] = forward.y * length * pixels
		_instance_buffer[base + 6] = 0.0
		_instance_buffer[base + 7] = position.y
		# Last four numbers: tell the footprint shader its age, strength, and shape.
		_instance_buffer[base + 8] = age / maxf(0.1, ocean.interaction_foam_lifetime)
		_instance_buffer[base + 9] = stamp.strength
		_instance_buffer[base + 10] = 1.0 if stamp.spot else 0.0
		_instance_buffer[base + 11] = age
	# One GPU upload, instead of two RenderingServer commands for every segment each frame.
	instances.buffer = _instance_buffer
	# Only expose the instances after their full GPU buffer has been initialized.
	instances.visible_instance_count = stamps.size()


## Send changed Inspector settings only once. The map origin may move every rendered frame.
## The spray material is local to this ocean, so contact opacity does not affect other oceans.
func _bind_field() -> void:
	if water_material == null:
		return
	var settings: Array = [ocean.interaction_enabled, area_size,
		ocean.interaction_foam_amount, ocean.interaction_contact_foam,
		ocean.interaction_splash_opacity]
	if settings != _bound_settings:
		# Most Inspector values stay unchanged for many frames. Avoid uploading
		# the same shader settings repeatedly; only the moving origin always updates.
		_bound_settings = settings
		water_material.set_shader_parameter(&"interactions_enabled", ocean.interaction_enabled)
		var field_texture: Texture2D = _empty_field
		if _field_ready:
			field_texture = field.get_texture()
		water_material.set_shader_parameter(&"interaction_field", field_texture)
		water_material.set_shader_parameter(&"interaction_area_size", area_size)
		water_material.set_shader_parameter(&"interaction_foam_strength", ocean.interaction_foam_amount)
		water_material.set_shader_parameter(&"interaction_contact_foam", ocean.interaction_contact_foam)
		if _spray_material != null:
			_spray_material.set_shader_parameter(&"contact_spray_opacity", ocean.interaction_splash_opacity)
	water_material.set_shader_parameter(&"interaction_origin", origin)


## Render footprint quads into an isolated, floating-point 2D viewport.
## HDR preserves overlapping strengths; disabling interpolation prevents double smoothing.
func _create_field() -> void:
	field = SubViewport.new()
	field.name = "_InteractionField"
	field.size = Vector2i.ONE * MAP_RESOLUTION
	field.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var empty := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	empty.fill(Color(0, 0, 0, 0))
	_empty_field = ImageTexture.create_from_image(empty)
	field.disable_3d = true
	field.world_2d = World2D.new()
	field.transparent_bg = true
	field.use_hdr_2d = true
	field.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(field, false, Node.INTERNAL_MODE_BACK)
	instances.transform_format = MultiMesh.TRANSFORM_2D
	instances.use_custom_data = true
	instances.mesh = QuadMesh.new()
	instances.mesh.size = Vector2(2.0, 2.0)
	# Allocation happens on the first upload, including its packed CPU buffer.
	var canvas := MultiMeshInstance2D.new()
	canvas.multimesh = instances
	canvas.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_stamp_material.shader = STAMP_SHADER
	canvas.material = _stamp_material
	field.add_child(canvas)


## Convert closing speed and waterline size to particle count, with a per-impact ceiling.
## A superlinear speed response separates gentle entries from hard landings; the cap bounds work.
func _get_impact_splash_count(speed: float, radius: float, strength: float = 1.0) -> int:
	var ratio: float = maxf(1.0, speed / maxf(0.1, ocean.interaction_impact_speed))
	# Ratio 1 is the minimum splash speed. Larger ratios request more particles;
	# wider objects get a size bonus, and the final clamp prevents huge bursts.
	var footprint := clampf(sqrt(maxf(0.1, radius) / 0.6), 0.5, 2.0)
	return clampi(ceili(ocean.interaction_impact_splash_amount * pow(ratio, 1.25) * footprint * maxf(0.0, strength)), 1, ocean.interaction_max_impact_splashes)


## Inject randomized contact spray into the original ocean emitter, never a boat-owned emitter.
## Small emissions use the two sides of the hull; larger bursts spread around the contact.
## CUSTOM carries energy, lifetime, random dissolve seed, and a contact marker for the shaders.
func _emit_spray(position: Vector3, velocity: Vector3, radius: float, count: int, impact_strength: float = 1.0) -> void:
	if not ocean.interaction_splashes_enabled or not is_instance_valid(spray):
		return
	var direction := Vector3(velocity.x, 0.0, velocity.z).normalized()
	var right := direction.cross(Vector3.UP)
	if right.is_zero_approx():
		right = Vector3.RIGHT
	var energy := sqrt(clampf(impact_strength, 0.4, 4.0))
	var size: float = maxf(0.15, radius) * ocean.interaction_splash_scale
	var amount := mini(count, _splash_budget)
	# All objects share this frame's remaining allowance. A large group landing
	# at once cannot create an unbounded number of particles in a single frame.
	_splash_budget -= amount
	for i in range(amount):
		var angle := _rng.randf() * TAU
		var radial := Vector3(cos(angle), 0.0, sin(angle)) if count > 6 else right * (-1.0 if _rng.randf() < 0.5 else 1.0)
		var at := position + radial * radius * _rng.randf_range(0.65, 1.2) + Vector3.UP * 0.08
		var patch_size := size * _rng.randf_range(0.65, 1.1) * lerpf(1.0, 1.35, (energy - 1.0))
		var transform := Transform3D(Basis.from_scale(Vector3(2.0, 1.2, 2.0) * patch_size), at)
		var launch := radial * _rng.randf_range(0.6, 1.4) * energy + Vector3(velocity.x, 0.0, velocity.z) * 0.12
		launch.y = _rng.randf_range(1.8, 2.8) * energy
		var custom := Color(energy, _rng.randf_range(0.7, 1.05), _rng.randf(), 1.0)
		# Color is used here as four data slots, not as a visible tint:
		# R = energy, G = lifetime, B = random fade pattern, A = "object splash" flag.
		spray.emit_particle(transform, launch, Color.WHITE, custom, GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_ROTATION_SCALE | GPUParticles3D.EMIT_FLAG_VELOCITY | GPUParticles3D.EMIT_FLAG_CUSTOM)


## Clear material bindings before the viewport texture is destroyed.
func _exit_tree() -> void:
	if is_instance_valid(water_material):
		water_material.set_shader_parameter(&"interactions_enabled", false)
		# Never leave a sampler bound to a freed viewport (or a null texture) while
		# an outgoing ocean can still appear in a queued render frame.
		water_material.set_shader_parameter(&"interaction_field", _empty_field)
