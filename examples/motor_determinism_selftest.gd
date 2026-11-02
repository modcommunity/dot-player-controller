extends Node3D

## Records every tick of scripted input runs against real physics geometry and compares
## the digest with the one stored from before the motor's query-cost work (the goldens
## below), so a cheaper motor is proven to be the same motor.
##
## [codeblock]
## godot --headless --path . res://examples/motor_determinism_selftest.tscn [-- --print]
## [/codeblock]
## `--print` prints the digests to paste into [constant GOLDEN] after a change that is
## meant to alter movement; a pure speed-up must leave them alone.

const STEP := 1.0 / 128.0
const TICKS := 1500

## Scenario name -> final digest of position, velocity, mode, flags and ground, every tick.
const GOLDEN := {"floor_run": 1912112400, "floor_walk": 622660714, "ramps": 421802700, "turning": 1486014066, "wall_run": 4222990983, "surf_slab": 1514153479, "trimesh": 1126123275, "pillars": 1444773003, "stairs": 4117850496, "air_drop": 2619813238, "corner": 2626857896, "hull_walk": 1503924493}

var _passed := 0
var _failed := 0
var _completed := 0
var _print := false
var _digests := {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_print = "--print" in OS.get_cmdline_user_args()
	_run.call_deferred()


func _tunables() -> DotFpsTunables:
	var t := DotFpsTunables.new()
	t.slide_enabled = true
	t.wall_run_enabled = true
	return t


func _box(size: Vector3, xf: Transform3D, layer: int = 1) -> void:
	var sb := StaticBody3D.new()
	sb.collision_layer = layer
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	cs.shape = b
	sb.add_child(cs)
	sb.transform = xf
	add_child(sb)


## A trimesh wedge, as imported maps are: a ramp of [param angle] degrees.
func _trimesh_ramp(angle: float, at: Vector3) -> void:
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var s := ConcavePolygonShape3D.new()
	var run := 8.0
	var rise := tan(deg_to_rad(angle)) * run
	var w := 4.0
	var a := Vector3(-w, 0, 0)
	var b := Vector3(w, 0, 0)
	var c := Vector3(-w, rise, -run)
	var d := Vector3(w, rise, -run)
	var e := Vector3(-w, 0, -run)
	var f := Vector3(w, 0, -run)
	s.set_faces(PackedVector3Array([
		a, b, d, a, d, c,
		a, c, e, b, f, d, e, c, d, e, d, f,
		a, e, f, a, f, b,
	]))
	cs.shape = s
	sb.add_child(cs)
	sb.position = at
	add_child(sb)


func _build_world() -> void:
	_box(Vector3(120, 2, 120), Transform3D(Basis.IDENTITY, Vector3(0, -1, 0)))
	# Room walls for wall runs and corners.
	_box(Vector3(2, 8, 120), Transform3D(Basis.IDENTITY, Vector3(30, 4, 0)))
	_box(Vector3(2, 8, 120), Transform3D(Basis.IDENTITY, Vector3(-30, 4, 0)))
	_box(Vector3(120, 8, 2), Transform3D(Basis.IDENTITY, Vector3(0, 4, 30)))
	_box(Vector3(120, 8, 2), Transform3D(Basis.IDENTITY, Vector3(0, 4, -30)))
	# Ramps at several angles, plus a steep surf slab.
	for i in range(4):
		var ang: float = [12.0, 25.0, 38.0, 55.0][i]
		_box(Vector3(6, 0.5, 14), Transform3D(Basis.from_euler(Vector3(deg_to_rad(ang), 0, 0)), Vector3(-20 + i * 8, 1.5, -12)))
	_box(Vector3(10, 1, 24), Transform3D(Basis.from_euler(Vector3(0, 0, deg_to_rad(40))), Vector3(14, 3, 10)))
	_trimesh_ramp(20.0, Vector3(-8, 0, 20))
	_trimesh_ramp(48.0, Vector3(6, 0, 20))
	# Steps, crates, a pillar field.
	for i in range(5):
		_box(Vector3(6, 0.2 * (i + 1), 1.2), Transform3D(Basis.IDENTITY, Vector3(0, 0.1 * (i + 1), -4 - i * 1.2)))
	for i in range(6):
		_box(Vector3(1.5, 2.5, 1.5), Transform3D(Basis.IDENTITY, Vector3(-12 + i * 3.0, 1.25, 3 + (i % 2) * 1.8)))
	# A pass-out hull layer (other players), so the pass-out query runs.
	_box(Vector3(0.8, 1.8, 0.8), Transform3D(Basis.IDENTITY, Vector3(2, 0.9, 6)), 1 << 3)
	_box(Vector3(0.8, 1.8, 0.8), Transform3D(Basis.IDENTITY, Vector3(-3, 0.9, 8)), 1 << 3)


func _command_for(tick: int, seed: int, plan: int) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	var phase := tick / 64
	var h := hash([seed, phase, plan])
	c.move = Vector2(float((h >> 3) % 3 - 1), float((h >> 5) % 3 - 1))
	if plan >= 1:
		c.move.y = -1.0
	c.yaw = float((h >> 7) % 628) * 0.01 - 3.14 if plan != 2 else float(tick) * 0.004
	var b := 0
	if plan >= 1 and (h >> 9) % 3 != 0:
		b |= DotFpsCommand.BUTTON_SPRINT
	if (h >> 11) % 5 == 0 and tick % 64 < 24:
		b |= DotFpsCommand.BUTTON_CROUCH
	if (tick * 7 + seed) % 61 < 3 or (h >> 13) % 4 == 0 and tick % 32 < 2:
		b |= DotFpsCommand.BUTTON_JUMP
	c.buttons = b
	return c


func _scenario(name: String, start: Vector3, vel: Vector3, seed: int, plan: int) -> void:
	var body := DotFpsPhysicsBody.for_node(self)
	body.pass_out_mask = 1 << 3
	var t := _tunables()
	var motor := DotFpsMotor.new(t, body)
	var s := DotFpsState.new()
	s.position = start
	s.velocity = vel
	s.mode = DotFpsState.Mode.AIR
	var digest := 0
	var modes := {}
	var maxspeed := 0.0
	for tick in range(TICKS):
		motor.simulate(s, _command_for(tick, seed, plan), STEP)
		digest = hash([digest, s.position, s.velocity, s.mode, s.move_flags(), s.ground_normal, s.crouch_held, s.wall_jump_count])
		modes[str(s.mode) + ":" + str(s.move_flags())] = true
		maxspeed = maxf(maxspeed, s.velocity.length())
	_digests[name] = digest
	print("  %-14s digest %d  states %d  max speed %.1f  end %s  queries %d" % [name, digest, modes.size(), maxspeed, s.position, body.query_count])
	if not _print:
		_check(GOLDEN.get(name, -1) == digest, name + " matches the recorded digest")


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		print("  ok    " + what)
	else:
		_failed += 1
		print("  FAIL  " + what)


func _run() -> void:
	print("dot-player-controller motor determinism self-test")
	_build_world()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_scenario("floor_run", Vector3(0, 0.05, 0), Vector3.ZERO, 1, 1)
	_scenario("floor_walk", Vector3(5, 0.05, -15), Vector3.ZERO, 2, 0)
	_scenario("ramps", Vector3(-20, 0.05, -2), Vector3(0, 0, -6), 3, 1)
	_scenario("turning", Vector3(0, 0.05, 10), Vector3(0, 0, -8), 4, 2)
	_scenario("wall_run", Vector3(26, 1.5, 0), Vector3(0, 0, -10), 5, 1)
	_scenario("surf_slab", Vector3(14, 6, 2), Vector3(0, 0, 6), 6, 1)
	_scenario("trimesh", Vector3(-8, 0.05, 24), Vector3(0, 0, -5), 7, 1)
	_scenario("pillars", Vector3(-14, 0.05, 6), Vector3(4, 0, 0), 8, 1)
	_scenario("stairs", Vector3(0, 0.05, -2), Vector3(0, 0, -3), 9, 1)
	_scenario("air_drop", Vector3(0, 12, 0), Vector3(5, 0, 3), 10, 0)
	_scenario("corner", Vector3(27, 0.05, 27), Vector3(3, 0, 3), 11, 1)
	_scenario("hull_walk", Vector3(2, 0.05, 3), Vector3(0, 0, 4), 12, 1)
	_completed = 1
	if _print:
		print("GOLDEN := ", _digests)
		get_tree().quit(0)
		return
	print("%d passed, %d failed" % [_passed, _failed])
	print("%d of 1 sections ran to their last line" % _completed)
	if _passed + _failed != _digests.size():
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, _digests.size()])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)
