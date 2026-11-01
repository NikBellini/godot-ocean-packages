@tool
class_name BoatComponent
extends Node3D
## Base for independent components placed directly under a BoatSystem body.

const BoatBody := preload("res://packages/boat_system/boat_system.gd")

var boat: BoatBody


func _resolve_boat() -> bool:
	# Components are direct children of the rigid body. Keeping this lookup here lets
	# buoyancy, engines, and custom force sources share the same parent without scene paths.
	boat = get_parent() as BoatBody
	if boat == null and not Engine.is_editor_hint():
		push_error("%s must be a direct child of a body using boat_system.gd." % name)
	return boat != null
