extends DotFpsBody

## [DotFpsPhysicsBody]'s space binding, query parameters, cost accounting and the native (dot-sim) fast path.
## Split out of dot_fps_physics_body.gd for file size; nothing outside the body names this script.

const CHANNEL := "fps.body"

var _space: PhysicsDirectSpaceState3D = null
var _shape: CapsuleShape3D = CapsuleShape3D.new()

var _motion_params := PhysicsTestMotionParameters3D.new()
var _shape_params := PhysicsShapeQueryParameters3D.new()
var _ray_params := PhysicsRayQueryParameters3D.new()
var _ray_exclude: Array[RID] = []

## Queries run this tick. Reset by the controller; watched by the server operator. Counts the native body's too.
var query_count: int:
	get:
		return _queries + (_native.query_count() if _native != null else 0)
	set(value):
		_queries = value
		if _native != null:
			_native.set_query_count(0)

var _queries: int = 0

## dot-sim's native body ([code]DotSimFpsBody[/code], the [code]motor[/code] module): the same sweep, rest contact and
## overlap, rounded the same way, so its answers are this script's to the bit (dot-sim's motor parity suite proves it over
## recorded input streams). Used when the extension is loaded, [member native_enabled] is on and [member profile] is off;
## on the web, or with no library installed, this script answers. The motor's collide-and-slide runs there too ([method native_slide]).
const NATIVE_CLASS := &"DotSimFpsBody"

## Whether the native body is used when present (a game's cvar; a suite turns it off to compare).
static var native_enabled: bool = true

## This body's own switch beside [member native_enabled]: off, it answers in script whatever the game chose.
var use_native: bool = true

static var _native_known: int = -1
var _native: Object = null
var _native_space: PhysicsDirectSpaceState3D = null
var _native_exclude: Array[RID] = []


## Whether dot-sim's native body is loaded and enabled.
static func native_available() -> bool:
	if _native_known < 0:
		_native_known = 1 if ClassDB.class_exists(NATIVE_CLASS) else 0
	return native_enabled and _native_known == 1


## The native body to ask, synced to this one's space and exclusions; null to answer in script.
func _nat() -> Object:
	if profile or not use_native or ((_native_known != 1 or not native_enabled) and not native_available()):
		return null
	if _native == null:
		_native = ClassDB.instantiate(NATIVE_CLASS)
		_hull_world_sent = false
		_static_world_sent = false
		_native.set_perf_caches(perf_caches)
		if _in_tick:
			_native.begin_tick()
	if not _static_world_sent:
		_static_world_sent = true
		if _native.has_method(&"set_static_world"):
			_native.set_static_world(_static_world)
	if _native_space != _space:
		_native_space = _space
		_native.set_space(_space)
	if exclude != _native_exclude:
		_native.set_exclude(exclude)
		_native_exclude = exclude.duplicate()
	return _native


## Slides run natively in one call ([method native_slide]), for a suite's check.
static var native_slides: int = 0


func native_slide(
	from: Vector3, velocity: Vector3, motion: Vector3, height: float,
	mode: int, flag: bool, tun: PackedFloat64Array, has_hulls: bool = false, hulls: Array = []
) -> PackedFloat64Array:
	if _space == null and not revalidate():
		return PackedFloat64Array()
	var nat := _nat()
	if nat == null:
		return PackedFloat64Array()
	native_slides += 1
	var t := DotFrameCost.now()
	var before: int = nat.query_count() if t > 0 else 0
	var r: PackedFloat64Array = nat.move_slide(
		from, velocity, motion, height, mode, flag, tun, has_hulls, hulls, collision_mask, pass_out_mask
	)
	_charge_native(&"native_slide", t, before)
	return r


## Tick halves run natively ([method native_tick]), for a suite's check.
static var native_ticks: int = 0

## 1 when the loaded library has the motor tick ([code]motor_pre[/code]; dot-sim releases before it do not), 0 when not, -1 unknown.
static var _tick_known: int = -1

## 1 when the loaded library has the whole motor tick ([code]motor_tick[/code]), 0 when not, -1 unknown.
static var _full_known: int = -1


## Whether [method native_tick] can run: the native body is available and its library has the motor tick.
static func native_tick_available() -> bool:
	if _tick_known < 0:
		_tick_known = 1 if ClassDB.class_exists(NATIVE_CLASS) and ClassDB.class_has_method(NATIVE_CLASS, &"motor_pre") else 0
	return _tick_known == 1 and native_available()


## Whether [method native_tick] phase 2, the whole tick, can run.
static func native_full_available() -> bool:
	if _full_known < 0:
		_full_known = 1 if ClassDB.class_exists(NATIVE_CLASS) and ClassDB.class_has_method(NATIVE_CLASS, &"motor_tick") else 0
	return _full_known == 1 and native_tick_available()


## Whether [method set_hull_world] can work: the loaded library has dot-sim's hull world.
static func native_hull_world_available() -> bool:
	if _world_known < 0:
		_world_known = 1 if ClassDB.class_exists(&"DotSimHullWorld") and ClassDB.class_has_method(NATIVE_CLASS, &"set_hull_world") else 0
	return _world_known == 1 and native_full_available()


static var _world_known: int = -1
var _hull_world: Object = null
var _hull_slot: int = -1
## [member _hull_world] has reached the current native body.
var _hull_world_sent: bool = false


## What [method set_static_world] was told; sent to the native body when it has the method.
var _static_world := false
var _static_world_sent := false


func set_static_world(on: bool) -> void:
	if on != _static_world:
		_static_world = on
		_static_world_sent = false


func set_hull_world(world: Object, slot: int) -> bool:
	if world != null and not native_hull_world_available():
		world = null
	if world != _hull_world or slot != _hull_slot:
		_hull_world = world
		_hull_slot = slot
		_hull_world_sent = false
	return world != null


func native_tick(
	phase: int, state: PackedFloat64Array, tun: PackedFloat64Array, hulls_mode: int = 0, hulls: Array = []
) -> PackedFloat64Array:
	# The answers once known, read here: the two checks are five script calls a player a tick.
	if _full_known != 1 or _tick_known != 1 or _native_known != 1 or not native_enabled:
		if not native_tick_available() or (phase == 2 and not native_full_available()):
			return PackedFloat64Array()
	if _space == null and not revalidate():
		return PackedFloat64Array()
	var nat := _nat()
	if nat == null:
		return PackedFloat64Array()
	if hulls_mode == 3:
		if _hull_world == null:
			return PackedFloat64Array()
		if not _hull_world_sent:
			nat.set_hull_world(_hull_world, _hull_slot)
			_hull_world_sent = true
	native_ticks += 1
	if phase == 0:
		return nat.motor_pre(state, tun, hulls_mode, hulls, collision_mask, pass_out_mask)
	if phase == 2:
		return nat.motor_tick(state, tun, hulls_mode, hulls, collision_mask, pass_out_mask)
	return nat.motor_post(state, tun, hulls_mode, hulls, collision_mask, pass_out_mask)


func native_batch(meta: PackedInt64Array, at: int, hulls_mode: int = 0) -> Object:
	if _full_known != 1 or _tick_known != 1 or _native_known != 1 or not native_enabled:
		if not native_full_available():
			return null
	if _space == null and not revalidate():
		return null
	var nat := _nat()
	if nat == null:
		return null
	if hulls_mode == 3:
		if _hull_world == null:
			return null
		if not _hull_world_sent:
			nat.set_hull_world(_hull_world, _hull_slot)
			_hull_world_sent = true
	meta[at] = hulls_mode
	meta[at + 1] = collision_mask
	meta[at + 2] = pass_out_mask
	return nat


func native_batch_done(_world_touches: int, _hull_blocks: int, _hull_stops: int) -> void:
	native_ticks += 1


## Whether this body's queries have gone to the native body (a suite's check).
func uses_native() -> bool:
	return _native != null


## A native answer as a [DotFpsBody.Hit]: empty for a miss, else fraction, normal, point, depth and the collider id in halves.
static func _hit_of(a: PackedFloat64Array) -> Hit:
	var h := Hit.new()
	if a.is_empty():
		return h
	h.hit = true
	h.fraction = a[0]
	h.normal = Vector3(a[1], a[2], a[3])
	h.point = Vector3(a[4], a[5], a[6])
	h.depth = a[7]
	h.collider_id = int(a[8]) | (int(a[9]) << 32)
	return h


func _perf_caches_changed() -> void:
	if _native != null:
		_native.set_perf_caches(perf_caches)

## Per engine query kind (cast, rest, overlap, ray): calls and microseconds, filled only while [member profile] is on.
static var profile: bool = false
static var prof := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0])
## The system queries are charged to in DotFrameCost (dot-profiler's query table) while it is enabled.
static var cost_system: StringName = &"p_controller"


func _q_cast() -> PackedFloat32Array:
	if not profile and not DotFrameCost.enabled:
		return _space.cast_motion(_shape_params)
	var t := Time.get_ticks_usec()
	var r := _space.cast_motion(_shape_params)
	_charge(0, DotSpaceQuery.CAST, t)
	return r


func _q_rest() -> Dictionary:
	if not profile and not DotFrameCost.enabled:
		return _space.get_rest_info(_shape_params)
	var t := Time.get_ticks_usec()
	var r := _space.get_rest_info(_shape_params)
	_charge(2, DotSpaceQuery.REST, t)
	return r


func _q_overlap() -> Array[Dictionary]:
	if not profile and not DotFrameCost.enabled:
		return _space.intersect_shape(_shape_params, 1)
	var t := Time.get_ticks_usec()
	var r := _space.intersect_shape(_shape_params, 1)
	_charge(4, DotSpaceQuery.SHAPE, t)
	return r


func _q_ray(query: PhysicsRayQueryParameters3D) -> Dictionary:
	if not profile and not DotFrameCost.enabled:
		return _space.intersect_ray(query)
	var t := Time.get_ticks_usec()
	var r := _space.intersect_ray(query)
	_charge(6, DotSpaceQuery.RAY, t)
	return r


## Times one script-path query into [member prof] and DotFrameCost, whichever is on.
static func _charge(i: int, kind: StringName, t: int) -> void:
	if profile:
		prof[i] += 1
		prof[i + 1] += Time.get_ticks_usec() - t
	DotFrameCost.add_query(cost_system, kind, t)


## Charges a native call to DotFrameCost as [param kind], counting the engine queries it ran; a no-op while off.
func _charge_native(kind: StringName, t: int, before: int) -> void:
	if t > 0:
		DotFrameCost.add_query(cost_system, kind, t, maxi(_native.query_count() - before, 1))


## Binds to the physics space [param node] lives in. A scene change invalidates the handle, so [method is_bound] is checked before use.
func bind(node: Node3D) -> DotResult:
	if node == null or not node.is_inside_tree():
		return DotResult.fail(
			DotError.CODE_STATE,
			"DotFpsPhysicsBody needs a node inside the tree."
		)

	_owner = node
	_space = node.get_world_3d().direct_space_state

	if _space == null:
		return DotResult.fail(
			DotError.CODE_STATE, "No physics space is available yet."
		)

	_shape_params.shape = _shape
	_shape_params.collide_with_bodies = true
	_shape_params.collide_with_areas = false

	return DotResult.success(null)


func is_bound() -> bool:
	return _space != null


func _configure(height: float, radius: float) -> void:
	# Writing a shape's size re-sends it to the physics server and emits `changed` even when unchanged, and a tick asks a dozen
	# questions with two or three sizes, so touch the shape only when a size or the exclusion list differs. The mask is set always:
	# [method sweep] overwrites it per query.
	var total := maxf(height, radius * 2.0)
	if radius != _cfg_radius:
		_shape.radius = radius
		_cfg_radius = radius
	# Godot's capsule height includes both caps and clamps to 2 * radius; DotFpsTunables.validate() rejects configurations
	# that would hit the clamp, since a collider of the wrong size is unfindable from the symptom.
	if total != _cfg_height:
		_shape.height = total
		_cfg_height = total

	# Everything but the sweep's own cast and the contact it found asks about what the
	# capsule is already in, and a layer it may walk out of is not part of that answer.
	_set_mask(collision_mask & ~pass_out_mask)
	# The setter rebuilds the engine's set from the array each time. A copy is kept, not
	# the array itself, so an in-place edit of [member exclude] is seen.
	if exclude != _cfg_exclude:
		_shape_params.exclude = exclude
		_cfg_exclude = exclude.duplicate()
		_rm_valid = false


## [member PhysicsShapeQueryParameters3D.collision_mask], written only when it changes: a
## property write on an engine object costs a call, and most queries ask for the mask the
## last one left.
func _set_mask(mask: int) -> void:
	if mask != _cfg_mask:
		_shape_params.collision_mask = mask
		_cfg_mask = mask


var _cfg_mask: int = -1


## What [method _configure] last wrote to the shape; NAN until the first write.
var _cfg_radius: float = NAN
var _cfg_height: float = NAN
var _cfg_exclude: Array[RID] = []


## The node this body was bound to, so a stale space can be recovered.
var _owner: Node3D = null


## Re-binds to the node's current space. Returns whether a space is available.
## The handle is cached but does not survive a scene change, and a dead one answers every query "nothing there", which looks like falling through a loaded level.
func revalidate() -> bool:
	if _owner == null or not _owner.is_inside_tree():
		return false

	var space := _owner.get_world_3d().direct_space_state

	if space == null:
		return false

	if space != _space:
		_space = space
		_rm_valid = false
		_shape_params.shape = _shape
		DotLog.debug(CHANNEL, "re-bound to a new physics space")

	return true


var _in_tick: bool = false
var _rm_valid: bool = false
