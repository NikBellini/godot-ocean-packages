class_name OceanInteractor
extends Node3D
## Optional water-interaction settings for any object. Colliders work without this node.
## Add as a child of an object to override automatic sizing, or to support animated Node3Ds.
# This script does not create foam itself. The ocean finds it, reads these settings,
# and tracks the parent object's movement. Objects with colliders do not need this node.

## Ocean receiving this object's effects. Empty allows any nearby ocean to detect it.
@export var ocean: Node3D
## Disable this object's wakes and splashes, including automatic collider detection.
@export var interaction_enabled: bool = true
## Waterline radius in meters. Zero estimates the radius from the parent's collision shape.
@export_range(0.0, 20.0, 0.05, "or_greater") var radius: float = 0.0
## Multiplier for this object's foam, ripple, and spray intensity. Zero disables emission.
@export_range(0.0, 3.0, 0.05, "or_greater") var strength: float = 1.0
## Use this node's position as the water contact point instead of the parent's collision bounds.
## Useful for animated objects or a foot, paddle, or other small contact point.
@export var use_marker_position: bool = false
## Additional vertical distance from the water surface at which contact counts, in meters.
@export_range(0.0, 2.0, 0.05, "or_greater") var contact_margin: float = 0.35


## Group membership is available during tree discovery, before the parent body's ready call.
## This component only supplies detection settings; the ocean owns all rendering and history.
func _enter_tree() -> void:
	add_to_group(&"ocean_interactors")
