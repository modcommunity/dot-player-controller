class_name DotFpsHullBody
extends DotFpsBody
## Wraps a world body and adds other players' hulls as solid boxes, for [member DotPlayerBodyRules.solid].
##
## [member hulls_fn] returns an Array of AABB. Inside a motor tick the list is gathered once, because nobody else moves
## during one player's tick; a sweep then tests only the boxes its swept bounds can touch. Gathering per sweep and
## sweeping every box made the cost of a tick grow with the square of the player count.

## First collider id reported for a hull; a hit on box n has id [constant HULL_ID_BASE] + n.
const HULL_ID_BASE := 1 << 24

## Sweeps stopped by a hull rather than the world, for tests and tuning.
static var hull_stops: int = 0

var inner: DotFpsBody = null
var hulls_fn: Callable = Callable()

var _boxes: Array = []
var _gathered: bool = false
var _in_tick: bool = false
var _near := DotFpsFlatBody.new()
var _near_index := PackedInt32Array()


func _init() -> void:
	_near.floor_y = -INF


func wrap(map_body: DotFpsBody, hulls: Callable) -> DotFpsBody:
	inner = map_body
	hulls_fn = hulls
	if map_body != null:
		collision_mask = map_body.collision_mask
		exclude = map_body.exclude
		pass_out_mask = map_body.pass_out_mask
	return self


func begin_tick() -> void:
	_in_tick = true
	_gathered = false
	if inner != null:
		inner.begin_tick()


func end_tick() -> void:
	_in_tick = false
	_gathered = false
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
	return _boxes


func sweep(from: Vector3, motion: Vector3, height: float, radius: float) -> Hit:
	if inner != null:
		_sync()
	var world: Hit = inner.sweep(from, motion, height, radius) if inner != null else Hit.miss()
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
	other.collider_id = HULL_ID_BASE + _near_index[other.collider_id - DotFpsFlatBody.box_id(0)]
	return other


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
