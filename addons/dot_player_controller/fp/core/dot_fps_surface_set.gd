@tool
class_name DotFpsSurfaceSet
extends Resource

## The surfaces a game has, and how a collider is mapped to one.
## The mapping goes through scene metadata or a group, never the collider's instance id, which is
## process-local and would make client and server disagree about friction. See [method resolve_from_node].

## Surfaces by id.
@export var surfaces: Array[DotFpsSurface] = []

## Used when a collider names no surface, or one not here.
## Never null after [method get_surface]: an unconfigured set behaves like the tunables alone.
@export var fallback: DotFpsSurface = null

## Metadata key read from a collider node by [method resolve_from_node].
@export var metadata_key: StringName = &"dot_fps_surface"

## Also accept a group name matching this prefix, e.g. [code]surface_ice[/code].
## Metadata wins when a node has both.
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


## Every surface of a dot-physics `DotPhysicsSurfaceSet` (anything with a `surfaces` array), through
## [method DotFpsSurface.from_physics]. Its fallback is the plain default, not the physics set's:
## an untagged floor is normal ground.
static func from_physics(physics_set: Object) -> DotFpsSurfaceSet:
	var out := DotFpsSurfaceSet.new()
	var list: Variant = physics_set.get("surfaces") if physics_set != null else null
	if list is Array:
		for each: Variant in list:
			if each is Object:
				var _added := out.add(DotFpsSurface.from_physics(each))
	return out


func add(surface: DotFpsSurface) -> DotFpsSurfaceSet:
	surfaces.append(surface)
	_built = false
	return self


## Rebuilds the index. Call after editing [member surfaces] at runtime.
func invalidate() -> void:
	_built = false


## Reads a surface id off a collider node: metadata first, then a group starting with [member group_prefix].
## Both are scene properties, so client and server agree. Returns [code]&""[/code] when unmarked,
## to tell it from "marked as default".
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
