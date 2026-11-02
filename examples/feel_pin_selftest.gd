extends Node3D

## Pins what the body size must not change: ground speeds, jump apex and time, air control and
## step climb, measured against real physics. [code]-- --record[/code] prints the numbers to paste
## into [constant PINS]; the body (stand height, crouch height, radius) is reported, not pinned.

const STEP := 1.0 / 128.0
const TOL := 0.02
const SECTIONS := 4
const CHECKS := 11

## name -> value measured on the old 1.8 m / 0.9 m / 0.35 m body.
const PINS := {"walk_speed": 4.7625, "run_speed": 4.7625, "crouch_speed": 1.6193, "jump_apex": 1.0635, "jump_time": 0.375, "air_speed": 0.5715, "climb_0": true, "climb_1": true, "climb_2": true, "climb_3": false, "climb_4": false}

var _passed := 0
var _failed := 0
var _completed := 0
var _record := false
var _got := {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_record = "--record" in OS.get_cmdline_user_args()
	_run.call_deferred()


func _box(size: Vector3, at: Vector3) -> void:
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	cs.shape = b
	sb.add_child(cs)
	sb.position = at
	add_child(sb)


func _motor() -> DotFpsMotor:
	return DotFpsMotor.new(DotFpsTunables.new(), DotFpsPhysicsBody.for_node(self))


func _state(at: Vector3) -> DotFpsState:
	var s := DotFpsState.new()
	s.position = at
	s.mode = DotFpsState.Mode.AIR
	return s


func _cmd(forward: float, buttons: int, yaw: float = 0.0) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = Vector2(0.0, -forward)
	c.buttons = buttons
	c.yaw = yaw
	return c


func _settle(m: DotFpsMotor, s: DotFpsState) -> void:
	for i in range(256):
		m.simulate(s, _cmd(0.0, 0), STEP)


func _top_speed(buttons: int) -> float:
	var m := _motor()
	var s := _state(Vector3(0, 0.05, 0))
	_settle(m, s)
	var top := 0.0
	for i in range(384):
		m.simulate(s, _cmd(1.0, buttons), STEP)
		top = maxf(top, Vector2(s.velocity.x, s.velocity.z).length())
	return top


## Returns [apex height above the floor, seconds to the apex].
func _jump() -> Array:
	var m := _motor()
	var s := _state(Vector3(0, 0.05, 0))
	_settle(m, s)
	var y0 := s.position.y
	var peak := 0.0
	var t_peak := 0.0
	for i in range(384):
		m.simulate(s, _cmd(0.0, DotFpsCommand.BUTTON_JUMP if i == 0 else 0), STEP)
		if s.position.y - y0 > peak:
			peak = s.position.y - y0
			t_peak = float(i + 1) * STEP
	return [peak, t_peak]


## Horizontal speed gained in half a second of air strafing from a standstill jump.
func _air_gain() -> float:
	var m := _motor()
	var s := _state(Vector3(0, 0.05, 0))
	_settle(m, s)
	m.simulate(s, _cmd(0.0, DotFpsCommand.BUTTON_JUMP), STEP)
	for i in range(64):
		m.simulate(s, _cmd(1.0, 0), STEP)
	return Vector2(s.velocity.x, s.velocity.z).length()




func _pin(name: String, value: float) -> void:
	_got[name] = value
	if _record:
		print("MEASURE %s %.4f" % [name, value])
		return
	var want: float = PINS.get(name, -1.0)
	var ok := absf(value - want) <= maxf(TOL, absf(want) * 0.02)
	_check(ok, "%s %.4f (pinned %.4f)" % [name, value, want])


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		print("  ok    " + what)
	else:
		_failed += 1
		print("  FAIL  " + what)


func _run() -> void:
	print("dot-player-controller feel pin self-test")
	_box(Vector3(600, 2, 600), Vector3(0, -1, 0))
	# A staircase of single boxes across -z, each its own height, spaced far apart.
	var heights := [0.2, 0.3, 0.34, 0.4, 0.5]
	for i in range(heights.size()):
		_box(Vector3(8, heights[i], 8), Vector3(0, heights[i] * 0.5, 40.0 * (i + 1) + 4.0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var t := DotFpsTunables.new()
	print("body: stand %.4f crouch %.4f radius %.4f step %.4f" % [t.stand_height, t.crouch_height, t.radius, t.step_height])
	if _record:
		print("MEASURE stand_height %.4f" % t.stand_height)
		print("MEASURE crouch_height %.4f" % t.crouch_height)
		print("MEASURE radius %.4f" % t.radius)
	_pin("walk_speed", _top_speed(0))
	_pin("run_speed", _top_speed(DotFpsCommand.BUTTON_SPRINT))
	_pin("crouch_speed", _top_speed(DotFpsCommand.BUTTON_CROUCH))
	_completed += 1
	var j := _jump()
	_pin("jump_apex", j[0])
	_pin("jump_time", j[1])
	_completed += 1
	_pin("air_speed", _air_gain())
	_completed += 1
	for i in range(heights.size()):
		var ok := _climb(heights[i], i)
		if _record:
			print("MEASURE climb_%d %s" % [i, ok])
		else:
			_check(ok == PINS.get("climb_%d" % i, false), "climb %.2f m = %s" % [heights[i], ok])
	_completed += 1
	if _record:
		get_tree().quit(0)
		return
	print("%d passed, %d failed" % [_passed, _failed])
	print("%d of %d sections ran to their last line" % [_completed, SECTIONS])
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _climb(h: float, i: int) -> bool:
	var m := _motor()
	var z := 40.0 * (i + 1) - 6.0
	var s := _state(Vector3(0, 0.05, z))
	_settle(m, s)
	for k in range(400):
		m.simulate(s, _cmd(1.0, 0), STEP)
	return s.position.y > h - 0.05
