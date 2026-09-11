@tool
class_name DotFpsSurfaceSet
extends Resource

## The surfaces a game has, and how a collider is mapped to one.
##
## [b]The hard part is not the table, it is the mapping.[/b] The obvious way to ask
## "what am I standing on" is to look up the collider the ground probe hit — but a
## collider's instance id is process-local, so the client and the server get different
## numbers for the same floor. Any mapping keyed on it produces two machines that
## disagree about the friction under a player, which is a divergence the prediction
## cannot reconcile and which only appears on some surfaces.
##
## So the mapping goes through something both machines load from the same scene:
## node metadata, or a group. See [method resolve_from_node].

## Surfaces by id.
@export var surfaces: Array[DotFpsSurface] = []

## Used when a collider names no surface, or names one that is not here.
##
## Never null after [method get_surface] — an unconfigured set behaves exactly like
## the tunables alone, which is what makes surfaces opt-in.
@export var fallback: DotFpsSurface = null

## Metadata key read from a collider node by [method resolve_from_node].
@export var metadata_key: StringName = &"dot_fps_surface"

## Also accept a group name matching this prefix, e.g. [code]surface_ice[/code].
##
## Groups are easier to apply to many nodes at once in the editor; metadata is easier
## to set per instance. Both work, and metadata wins when a node has both.
@export var group_prefix: String = "surface_"

var _by_id: Dictionary = {}
var _built: bool = false


func _build() -> void:
	_by_id.clear()

	for surface in surfaces:
		if surface == null:
			continue
		if _by_id.has(surface.id):
			DotLog.warn(
				"fps.surface",
				"duplicate surface id; the later one wins",
				{"id": String(surface.id)}
			)
		_by_id[surface.id] = surface

	if fallback == null:
		fallback = DotFpsSurface.make(&"default")

	_built = true


## The surface for an id, or the fallback. Never null.
func get_surface(id: StringName) -> DotFpsSurface:
	if not _built:
		_build()

	var found: Variant = _by_id.get(id)
	return found if found is DotFpsSurface else fallback


func has_surface(id: StringName) -> bool:
	if not _built:
		_build()
	return _by_id.has(id)


func add(surface: DotFpsSurface) -> DotFpsSurfaceSet:
	surfaces.append(surface)
	_built = false
	return self


## Rebuilds the index. Call after editing [member surfaces] at runtime.
func invalidate() -> void:
	_built = false


## Reads a surface id off a collider node.
##
## Metadata first, then a group whose name starts with [member group_prefix]. Both
## are properties of the scene, so a client and a server that loaded the same level
## resolve the same id for the same floor — which is the whole requirement.
##
## Returns [code]&""[/code] when the node names no surface, so a caller can tell
## "unmarked" from "marked as default".
static func resolve_from_node(
	node: Node,
	metadata: StringName = &"dot_fps_surface",
	prefix: String = "surface_"
) -> StringName:
	if node == null:
		return &""

	if node.has_meta(metadata):
		return StringName(str(node.get_meta(metadata)))

	if prefix != "":
		for group in node.get_groups():
			var name := String(group)
			if name.begins_with(prefix):
				return StringName(name.substr(prefix.length()))

	# A CollisionShape3D usually carries the shape while the body carries the
	# marking, so one step up is worth trying before giving up.
	var parent := node.get_parent()
	if parent != null and parent.has_meta(metadata):
		return StringName(str(parent.get_meta(metadata)))

	return &""


func describe() -> Dictionary:
	if not _built:
		_build()

	var names := PackedStringArray()
	for id in _by_id:
		names.append(String(id))

	return {
		"surfaces": Array(names),
		"fallback": String(fallback.id) if fallback != null else "<none>",
	}
