extends Node3D
## Public ocean configuration. The Water child owns FFT waves; the internal interaction
## manager detects colliders and supplies foam/spray to the same ocean.

const OceanInteractions := preload("res://packages/godot_ocean_waves/assets/interactions/ocean_interactions.gd")

@export_group("Ocean Settings")
@onready var water := $Water
@onready var ocean_audio_player := $OceanAudioPlayer
@onready var wind_audio_player := $WindAudioPlayer
## The player node used to shift the water mesh when moving into a new tile.
## This is required for the ocean to move with the player, simulating an infinite ocean.
@export var player: Node3D;
## The color of the water. This is used to tint the water material and can be used to simulate different water 
## or for artistic purposes.
@export_color_no_alpha var water_color: Color = Color(0.1, 0.15, 0.18):
	set(value):
		water_color = value
		# Inspector values can be assigned before the Water child is ready.
		# Apply immediately during play; _ready() supplies the initial values later.
		if is_node_ready():
			water.water_color = value
## Shared color for wave foam, object trails, contact foam, and splashes.
@export_color_no_alpha var foam_color: Color = Color(0.73, 0.67, 0.62):
	set(value):
		foam_color = value
		if is_node_ready():
			water.foam_color = value
## The speed of the wind above the water in meters per second. Increasing makes waves steeper and more
## 'chaotic' and with more foam.
@export var wind_speed := 20.0:
	set(value):
		wind_speed = max(0.0001, value)
		if is_node_ready():
			for params in water.parameters:
				params.wind_speed = value
## The direction of the wind above the water in degrees. Increasing makes the waves to change direction.
## 0 degrees is along the positive X axis, 90 degrees is along the positive Z axis.
@export_range(-360, 360) var wind_direction := 0.0:
	set(value):
		wind_direction = value
		if is_node_ready():
			for params in water.parameters:
				params.wind_direction = value
## Whether or not to enable audio for the ocean and wind.
@export var enable_audio := true:
	set(value):
		enable_audio = value
		if is_node_ready():
			ocean_audio_player.stream_paused = not value
			wind_audio_player.stream_paused = not value
## Whether or not to enable the get_height() function. Disabling this can improve performance if you don't need
## to get the height of the water at a specific point. Disabling this will disable the GPU readback of the
## displacement texture, which is required for the get_height() function to work.
@export var enable_get_height := true:
	set(value):
		enable_get_height = value
		if is_node_ready():
			water.enable_get_height = value

var clipmap_tile_size := 1.0 # Not the smallest tile size, but one that reduces the amount of vertex jitter.
var previous_tile := Vector3i.MAX

@export_group("Object Interactions", "interaction_")
## Let objects touching the water leave foam and splashes. No effects script is needed.
@export var interaction_enabled: bool = true
## How visible the foam left by objects is. Zero hides these foam trails.
@export_range(0.0, 5.0, 0.05) var interaction_foam_amount: float = 1.8
## Width of foam trails. One matches the object's width; two makes trails twice as wide.
@export_range(0.1, 4.0, 0.05) var interaction_foam_width: float = 1.0
## How many seconds foam trails last before fading away.
@export_range(0.2, 15.0, 0.1, "or_greater", "suffix:s") var interaction_foam_lifetime: float = 5.0
## Let objects throw up splashes as they move through or land in the water.
@export var interaction_splashes_enabled: bool = true

# Advanced interaction tuning. Edit these defaults here when a project needs a
# different look or detection behavior; everyday controls stay in the Inspector above.
## Detect all CollisionObject3D nodes: static/animated bodies, rigid bodies, characters,
## and areas. Moving a collider by script or animation also leaves a trail.
## An OceanInteractor child is only needed for optional per-object overrides.
var auto_detect_colliders: bool = true
## Outward foam spread per side in meters per second as a trail ages.
var interaction_spread: float = 0.4
## Foam along visible water/geometry intersections, including static rocks and shorelines.
var interaction_contact_foam: float = 0.3
## Approximate spray patches per second for an object moving at four meters per second.
var interaction_splash_rate: float = 6.0
## Scale of interaction splashes relative to the object's waterline radius.
var interaction_splash_scale: float = 0.65
## Visibility of object splashes, independent of the ordinary ocean wave spray.
var interaction_splash_opacity: float = 0.65
## Speed closing against the moving water surface, in meters per second, needed for a burst.
var interaction_impact_speed: float = 1.2
## Splash patches at the impact threshold for a 0.6-meter waterline radius.
## Faster entries and wider objects produce progressively more patches.
var interaction_impact_splash_amount: int = 3
## Maximum patches in one impact burst, bounding work for very hard landings.
var interaction_max_impact_splashes: int = 48
## Minimum seconds between bursts from the same object.
var interaction_impact_cooldown: float = 0.5

## Runtime effect manager, owned by this ocean rather than by any boat or character.
var interactions: Node

## Build one local material and one shared interaction manager for this ocean instance.
func _ready() -> void:
	# The clipmap snaps on a world-aligned lattice. Interpolating these tile moves
	# slides the sampling grid between snaps and makes small crests/foam shimmer.
	water.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# Keep the interaction texture local to this ocean rather than mutating the shared asset.
	water.material_override = water.material_override.duplicate()
	# Give the manager its dependencies before add_child() triggers its _ready().
	interactions = OceanInteractions.new()
	interactions.name = "_ObjectInteractions"
	interactions.ocean = self
	interactions.water_material = water.material_override
	add_child(interactions, false, Node.INTERNAL_MODE_BACK)
	# Internal children are created at runtime and are not saved into the scene file.
	water.water_color = water_color
	water.foam_color = foam_color

	for params in water.parameters:
		params.wind_speed = wind_speed
		params.wind_direction = wind_direction

	ocean_audio_player.stream_paused = not enable_audio
	wind_audio_player.stream_paused = not enable_audio


## Keep the infinite mesh near Player and update wind-dependent audio gain.
func _physics_process(_delta: float) -> void:
	# Shift water mesh whenever player moves into a new tile
	if is_instance_valid(player):
		var tile := (Vector3(player.global_position.x, 0.0, player.global_position.z) / clipmap_tile_size).ceil()
		if not tile.is_equal_approx(previous_tile):
			# Reuse the same ocean mesh near the player instead of creating an enormous mesh.
			water.global_position = tile * clipmap_tile_size
			previous_tile = tile

	# Vary audio samples based on the wind speed if the audio is enabled
	if enable_audio:
		ocean_audio_player.volume_db = lerpf(-30.0, 15.0, minf(wind_speed/15.0, 1.0))
		wind_audio_player.volume_db = lerpf(5.0, -30.0, minf(wind_speed/15.0, 1.0))

## Query the FFT surface for buoyancy/contact detection. Visual foam does not add height.
func get_height(world_pos: Vector3) -> float:
	if not enable_get_height:
		push_error('"Enable Get Height" is disabled on the GodotOceanWaves node. Please enable it in the node to use this function.')
		return 0.0

	# Water reads the wave displacement; foam is visual and does not alter that height.
	return water.get_height(world_pos)


## Paint foam from custom gameplay, such as an explosion or paddle stroke.
func add_water_disturbance(world_position: Vector3, radius: float = 0.5, strength: float = 1.0, impact: bool = false) -> void:
	if is_instance_valid(interactions):
		interactions.add_disturbance(world_position, radius, strength, impact)
