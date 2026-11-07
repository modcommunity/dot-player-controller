extends Node3D

## Micro-benchmark of the first-person controller tick: N controllers on a flat floor and in a collision world, each ticked TICKS times.
## Reports microseconds per controller per tick and physics queries per tick. Run: godot --headless --path . res://examples/motor_bench.tscn [-- --n=32 --ticks=1000 --legacy]
## --legacy turns off every cache the perf work added (DotFpsMotor.perf_caches), for before/after numbers from one tree.

const STEP := 1.0 / 66.0

var _n := 32
var _ticks := 1000
var _legacy := false
var _boxes_n := 40
var _motor_only := false


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--n="):
			_n = int(a.substr(4))
		elif a.begins_with("--ticks="):
			_ticks = int(a.substr(8))
		elif a == "--motor":
			_motor_only = true
		elif a == "--legacy":
			_legacy = true
	_run.call_deferred()


## A controller on analytic geometry with the other players' hulls solid, as the arena builds its bots (ArenaPlayer.HeadlessController).
class FlatController extends DotFpsController:
	var flat_body: DotFpsBody = null

	func _make_body() -> DotFpsBody:
		return flat_body


var _flat_boxes: Array[AABB] = []
var _flat_ctrls: Array = []


func _make_flat_boxes() -> void:
	_flat_boxes.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for sx in [-60.0, 60.0]:
		_flat_boxes.append(AABB(Vector3(sx - 1, 0, -120), Vector3(2, 8, 240)))
		_flat_boxes.append(AABB(Vector3(-120, 0, sx - 1), Vector3(240, 8, 2)))
	for i in range(_boxes_n):
		var p := Vector3(rng.randf_range(-55, 55), 0, rng.randf_range(-55, 55))
		_flat_boxes.append(AABB(p, Vector3(rng.randf_range(1, 5), rng.randf_range(0.2, 3.0), rng.randf_range(1, 5))))


func _hulls_for(i: int) -> Array:
	var out: Array = []
	for j in range(_flat_ctrls.size()):
		if j == i:
			continue
		var c: DotFpsController = _flat_ctrls[j]
		var feet: Vector3 = c.state.position
		out.append(AABB(feet - Vector3(0.35, 0.0, 0.35), Vector3(0.7, 1.8, 0.7)))
	return out


func _flat_body_for(i: int) -> DotFpsBody:
	var flat := DotFpsFlatBody.with_floor(0.0)
	for b in _flat_boxes:
		flat.add_box(b)
	return DotFpsHullBody.new().wrap(flat, _hulls_for.bind(i))


func _box(size: Vector3, xf: Transform3D) -> void:
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	cs.shape = b
	sb.add_child(cs)
	sb.transform = xf
	add_child(sb)


func _world(full: bool) -> void:
	_box(Vector3(400, 2, 400), Transform3D(Basis.IDENTITY, Vector3(0, -1, 0)))
	if not full:
		return
	for sx in [-60.0, 60.0]:
		_box(Vector3(2, 8, 240), Transform3D(Basis.IDENTITY, Vector3(sx, 4, 0)))
		_box(Vector3(240, 8, 2), Transform3D(Basis.IDENTITY, Vector3(0, 4, sx)))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in range(120):
		var p := Vector3(rng.randf_range(-55, 55), 0, rng.randf_range(-55, 55))
		var h := rng.randf_range(0.2, 3.0)
		_box(Vector3(rng.randf_range(1, 5), h, rng.randf_range(1, 5)), Transform3D(Basis.from_euler(Vector3(0, rng.randf() * 3.0, 0)), p + Vector3(0, h * 0.5, 0)))
	for i in range(10):
		_box(Vector3(6, 0.5, 14), Transform3D(Basis.from_euler(Vector3(deg_to_rad(10 + i * 5), 0, 0)), Vector3(-50 + i * 10, 1.5, -40)))


func _player(i: int, parent: Node, flat: bool = false) -> DotFpsController:
	var player := CharacterBody3D.new()
	player.name = "P%d" % i
	player.collision_layer = 0
	player.collision_mask = 0
	parent.add_child(player)
	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	collision.shape = CapsuleShape3D.new()
	player.add_child(collision)
	var head := Node3D.new()
	head.name = "Head"
	player.add_child(head)
	var camera := Camera3D.new()
	camera.name = "Camera"
	head.add_child(camera)
	var view := DotFpsView.new()
	view.name = "View"
	player.add_child(view)
	var c: DotFpsController
	if flat:
		var fc := FlatController.new()
		fc.flat_body = _flat_body_for(i)
		c = fc
	else:
		c = DotFpsController.new()
	c.name = "Controller"
	c.drive = DotFpsController.Drive.EXTERNAL
	c.register_default_actions = false
	c.register_service = false
	player.add_child(c)
	return c


## A bot-like command: runs forward, wanders its yaw, jumps now and then, strafes in bursts. [param idle] stands still.
static func command_for(tick: int, k: int, idle: bool) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	if idle:
		return c
	var h := hash([k, tick / 48])
	c.move = Vector2(float((h >> 3) % 3 - 1) * 0.5, -1.0)
	c.yaw = float(k) * 0.7 + sin(float(tick) * 0.01 + k) * 2.0
	var b := 0
	if (tick + k * 13) % 97 < 2:
		b |= DotFpsCommand.BUTTON_JUMP
	if (h >> 9) % 4 == 0:
		b |= DotFpsCommand.BUTTON_SPRINT
	c.buttons = b
	return c


func _variant(full: bool, idle_fraction: float, legacy: bool, motor_only: bool, flat: bool = false) -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	var ctrls: Array[DotFpsController] = []
	if flat:
		_make_flat_boxes()
		_flat_ctrls = ctrls
	else:
		_world_into(root, full)
	for i in range(_n):
		ctrls.append(_player(i, root, flat))
	await get_tree().physics_frame
	await get_tree().physics_frame
	for i in range(_n):
		var c := ctrls[i]
		if not c._started:
			c.setup()
		c.teleport(Vector3(-40.0 + float(i % 8) * 10.0, 0.05, -30.0 + float(i / 8) * 10.0))
		c.motor.perf_caches = not legacy
	DotFpsPhysicsBody.profile = false
	var spent := 0
	var digest := 0
	for tick in range(_ticks):
		for i in range(_n):
			var idle := float(i) < float(_n) * idle_fraction
			ctrls[i].apply_command(command_for(tick, i, idle))
			var t := Time.get_ticks_usec()
			if motor_only:
				ctrls[i].motor.simulate(ctrls[i].state, ctrls[i].current_command, STEP)
			else:
				ctrls[i].simulate_tick(tick, STEP)
			spent += Time.get_ticks_usec() - t
	for i in range(_n):
		digest = hash([digest, ctrls[i].state.position, ctrls[i].state.velocity])
	var q := 0
	for i in range(_n):
		q += (ctrls[i].body as DotFpsPhysicsBody).query_count if not flat else 0
	# A second, shorter pass with the phase counters on (their timers cost a little, so the headline figure above is taken without).
	var out := {"us": float(spent) / float(_n * _ticks), "q": float(q) / float(_n * _ticks), "digest": digest}
	root.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	return out


func _phases(full: bool, idle_fraction: float, flat: bool = false) -> void:
	var root := Node3D.new()
	add_child(root)
	var ctrls: Array[DotFpsController] = []
	if flat:
		_make_flat_boxes()
		_flat_ctrls = ctrls
	else:
		_world_into(root, full)
	for i in range(_n):
		ctrls.append(_player(i, root, flat))
	await get_tree().physics_frame
	await get_tree().physics_frame
	for i in range(_n):
		if not ctrls[i]._started:
			ctrls[i].setup()
		ctrls[i].teleport(Vector3(-40.0 + float(i % 8) * 10.0, 0.05, -30.0 + float(i / 8) * 10.0))
	DotFpsPhysicsBody.profile = true
	DotFpsPhysicsBody.prof.fill(0)
	DotFpsMotor.profile = true
	DotFpsMotor.phase_us.fill(0)
	DotFpsController.phase_us.fill(0)
	for tick in range(_ticks):
		for i in range(_n):
			ctrls[i].apply_command(command_for(tick, i, float(i) < float(_n) * idle_fraction))
			ctrls[i].simulate_tick(tick, STEP)
	var p := DotFpsPhysicsBody.prof
	var ph := ""
	for k in range(9):
		ph += " %s %.1f" % [DotFpsMotor.PHASES[k], float(DotFpsMotor.phase_us[k]) / float(_n * _ticks)]
	print("   engine calls/tick cast %.2f rest %.2f ray %.2f; engine us/tick cast %.1f rest %.1f ray %.1f" % [
		float(p[0]) / (_n * _ticks), float(p[2]) / (_n * _ticks), float(p[6]) / (_n * _ticks),
		float(p[1]) / (_n * _ticks), float(p[3]) / (_n * _ticks), float(p[7]) / (_n * _ticks)])
	print("   motor phases us/tick:" + ph)
	var cp := ""
	var names := ["pre", "pre-motor", "motor", "publish", "report", "stats+post", "signal", "(global_position set)"]
	for k in range(8):
		cp += " %s %.1f" % [names[k], float(DotFpsController.phase_us[k]) / float(_n * _ticks)]
	print("   controller phases us/tick:" + cp)
	DotFpsMotor.profile = false
	DotFpsPhysicsBody.profile = false
	root.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame


func _scenario(label: String, full: bool, idle_fraction: float, flat: bool = false) -> void:
	# Interleaved twice so a loaded machine biases neither side.
	var res := {}
	for key in ["legacy", "new", "legacy-motor", "new-motor"]:
		res[key] = []
	for rep in range(2):
		for key in ["legacy", "new", "legacy-motor", "new-motor"]:
			res[key].append(await _variant(full, idle_fraction, key.begins_with("legacy"), key.ends_with("motor"), flat))
	var line := "%-20s" % label
	for key in ["legacy", "new", "legacy-motor", "new-motor"]:
		var us := minf(res[key][0]["us"], res[key][1]["us"])
		line += "  %s %.1f" % [key, us]
	line += "  | queries/tick legacy %.2f new %.2f" % [res["legacy"][0]["q"], res["new"][0]["q"]]
	var same: bool = res["legacy"][0]["digest"] == res["new"][0]["digest"] and res["legacy"][1]["digest"] == res["new"][1]["digest"]
	line += "  identical=%s" % same
	print(line)
	await _phases(full, idle_fraction, flat)


func _world_into(parent: Node3D, full: bool) -> void:
	var before := get_child_count()
	_world(full)
	var moved: Array[Node] = []
	for i in range(before, get_child_count()):
		moved.append(get_child(i))
	for n in moved:
		remove_child(n)
		parent.add_child(n)


func _run() -> void:
	print("motor bench: n=%d ticks=%d legacy=%s" % [_n, _ticks, _legacy])
	await get_tree().physics_frame
	await _scenario("arena-like flat+hulls", false, 0.0, true)
	await _scenario("flat, all moving", false, 0.0)
	await _scenario("world, all moving", true, 0.0)
	await _scenario("world, 50% idle", true, 0.5)
	get_tree().quit(0)
