class_name DotFpsHullBody
extends DotFpsBody
## Wraps a world body and adds other players' hulls ([member hulls_fn], an Array of AABB) as solid boxes, for [member DotPlayerBodyRules.solid].
## The list is gathered once per motor tick (nobody else moves during it) and a sweep tests only the boxes its bounds touch, so cost does not grow with the square of the player count.

## First collider id reported for a hull; a hit on box n has id [constant HULL_ID_BASE] + n.
const HULL_ID_BASE := 1 << 24

## Sweeps stopped by a hull rather than the world, for tests and tuning.
static var hull_stops: int = 0

var inner: DotFpsBody = null
var hulls_fn: Callable = Callable()

## dot-sim's hull world the native tick gathers from instead of [member hulls_fn] ([method set_hull_world]), or null.
var hull_world: Object = null

var _boxes: Array = []
var _gathered: bool = false
var _in_tick: bool = false
## This tick's box list has reached the native body (a slide or a tick half), so the next tick half sends mode 2.
var _sent: bool = false
## Sent where the native tick reads no list (modes 2 and 3), instead of a new Array a player a tick; never written.
var _no_hulls: Array = []
var _near := DotFpsFlatBody.new()
var _near_index := PackedInt32Array()

## Per-tick candidate list (perf_caches): the hulls within [constant COARSE_REACH] of the first sweep of the tick, as indices into the gathered list in their order, and the region they were chosen for.
## A sweep whose bounds lie inside the region can only touch hulls that intersect the region, so it tests those instead of every hull; one that leaves the region (a launch, a long probe) rebuilds around itself.
## Same hulls, same order, same answers as testing all of them.
var _coarse_region := AABB()
var _coarse_valid: bool = false
var _coarse: PackedInt32Array = PackedInt32Array()

## How far around a sweep's bounds the per-tick candidate region reaches, in metres: a few ticks of any ordinary speed, so most of a tick's sweeps (slide legs, step probes, ground checks) fit in one region.
const COARSE_REACH := 6.0


func _init() -> void:
	_near.floor_y = -INF


## Below this many hulls a candidate list costs more than it saves.
const COARSE_MIN := 6


func _perf_caches_changed() -> void:
	if inner != null:
		inner.perf_caches = perf_caches


func wrap(map_body: DotFpsBody, hulls: Callable) -> DotFpsBody:
	inner = map_body
	if map_body != null:
		map_body.set_static_world(_static_world)
		map_body.perf_caches = perf_caches
	hulls_fn = hulls
	if map_body != null:
		collision_mask = map_body.collision_mask
		exclude = map_body.exclude
		pass_out_mask = map_body.pass_out_mask
	return self


var _static_world := false


func set_static_world(on: bool) -> void:
	_static_world = on
	if inner != null:
		inner.set_static_world(on)


func set_hull_world(world: Object, slot: int) -> bool:
	hull_world = world if inner != null and inner.set_hull_world(world, slot) else null
	return hull_world != null


func begin_tick() -> void:
	_in_tick = true
	_gathered = false
	_sent = false
	_coarse_valid = false
	if inner != null:
		inner.begin_tick()


func end_tick() -> void:
	_in_tick = false
	_gathered = false
	_sent = false
	_coarse_valid = false
	if inner != null:
		inner.end_tick()


func _sync() -> void:
	inner.collision_mask = collision_mask
	inner.exclude = exclude
	inner.pass_out_mask = pass_out_mask


func _hull_list() -> Array:
	if _in_tick and _gathered:
		return _boxes
	_boxes = hulls_fn.call() if hulls_fn.is_valid() else []
	_gathered = _in_tick
	_sent = false
	_coarse_valid = false
	return _boxes


func sweep(from: Vector3, motion: Vector3, height: float, radius: float) -> Hit:
	if inner != null:
		_sync()
	var world: Hit = inner.sweep(from, motion, height, radius) if inner != null else Hit.miss()
	if world.hit:
		world_touches += 1
	var boxes := _hull_list()
	if boxes.is_empty():
		return world

	var half := Vector3(radius, height * 0.5, radius)
	var lo := from - half
	var hi := from + half
	var end := from + motion
	# A skin wider than the box test, so a hull the sweep only touches at its end still counts.
	var swept := AABB(lo.min(end - half) - Vector3.ONE * 1e-3, Vector3.ZERO)
	swept.end = hi.max(end + half) + Vector3.ONE * 1e-3

	_near.boxes.clear()
	_near_index.resize(0)
	if perf_caches and _in_tick and boxes.size() > COARSE_MIN:
		if not (_coarse_valid and _coarse_region.encloses(swept)):
			_coarse_region = swept.grow(COARSE_REACH)
			_coarse.resize(0)
			for i in range(boxes.size()):
				if (boxes[i] as AABB).intersects(_coarse_region):
					_coarse.append(i)
			_coarse_valid = true
		for k in range(_coarse.size()):
			var i := _coarse[k]
			var box: AABB = boxes[i]
			if box.intersects(swept):
				_near.boxes.append(box)
				_near_index.append(i)
	else:
		for i in range(boxes.size()):
			var box: AABB = boxes[i]
			if box.intersects(swept):
				_near.boxes.append(box)
				_near_index.append(i)
	if _near.boxes.is_empty():
		return world

	var other := _near.sweep(from, motion, height, radius)
	if not other.hit or (world.hit and world.fraction <= other.fraction):
		return world

	hull_stops += 1
	hull_blocks += 1
	other.collider_id = HULL_ID_BASE + _near_index[other.collider_id - DotFpsFlatBody.box_id(0)]
	return other


## The inner body's native slide with this tick's hulls as boxes; the counters come back to this body's.
func native_slide(
	from: Vector3, velocity: Vector3, motion: Vector3, height: float,
	mode: int, flag: bool, tun: PackedFloat64Array, has_hulls: bool = false, _hulls: Array = []
) -> PackedFloat64Array:
	# A hull body wrapping another one keeps the script path: one box list per call.
	if inner == null or has_hulls:
		return PackedFloat64Array()
	_sync()
	var r := inner.native_slide(from, velocity, motion, height, mode, flag, tun, true, _hull_list())
	if r.size() >= 13:
		_sent = _in_tick
		world_touches += int(r[10])
		hull_blocks += int(r[11])
		hull_stops += int(r[12])
	return r


## The inner body's native tick half with this tick's hulls; sent once a tick, then reused natively.
func native_tick(
	phase: int, state: PackedFloat64Array, tun: PackedFloat64Array, hulls_mode: int = 0, _hulls: Array = []
) -> PackedFloat64Array:
	if inner == null or hulls_mode != 0:
		return PackedFloat64Array()
	_sync()
	var r: PackedFloat64Array
	if _in_tick and _sent:
		r = inner.native_tick(phase, state, tun, 2, _no_hulls)
	else:
		# The hull world gathers natively while the game's players' loop runs; otherwise, or for a
		# lag-compensated mover, it answers empty and the script gathers.
		if hull_world != null and not (_in_tick and _gathered):
			r = inner.native_tick(phase, state, tun, 3, _no_hulls)
		if r.is_empty():
			r = inner.native_tick(phase, state, tun, 1, _hull_list())
	if r.size() >= 23:
		_sent = _in_tick
		world_touches += int(r[20])
		hull_blocks += int(r[21])
		hull_stops += int(r[22])
	return r


## Only with the hull world, which gathers natively: a script gather stays with [method native_tick].
func native_batch(meta: PackedInt64Array, at: int, hulls_mode: int = 0) -> Object:
	if inner == null or hulls_mode != 0 or hull_world == null or not _in_tick or _gathered or _sent:
		return null
	_sync()
	return inner.native_batch(meta, at, 3)


func native_batch_done(touches: int, blocks: int, stops: int) -> void:
	_sent = _in_tick
	world_touches += touches
	hull_blocks += blocks
	hull_stops += stops
	inner.native_batch_done(touches, blocks, stops)


func overlaps(at: Vector3, height: float, radius: float) -> bool:
	if inner == null:
		return false
	_sync()
	return inner.overlaps(at, height, radius)


func rest_contact(at: Vector3, height: float, radius: float) -> Hit:
	if inner == null:
		return Hit.miss()
	_sync()
	return inner.rest_contact(at, height, radius)


func describe() -> Dictionary:
	var out := {"implementation": "DotFpsHullBody", "hulls": _boxes.size()}
	if inner != null:
		out["inner"] = inner.describe()
	return out
