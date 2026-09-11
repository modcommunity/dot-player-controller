extends Node

## Exercises dot-player-controller with a stub controller, no physics and no input.
##
## The addon is abstract, so what is checkable is the part that is not: intent edges,
## the look arithmetic every project rewrites, and the switch — including the handover,
## which is the thing that is wrong in a way nobody reports as a handover bug. A stub
## controller stands in for a real one, which is also a worked example of the five
## methods a subclass overrides.
##
## [codeblock]
## godot --headless --path . res://examples/controller_selftest.tscn
## [/codeblock]

const SECTIONS := 6
const CHECKS := 106

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	_line("dot-player-controller self-test")
	_line("")

	_test_intent()
	_test_wire()
	_test_look()
	await _test_controller()
	await _test_switch()
	await _test_handover()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		_line(
			"ERROR: %d checks ran, %d expected. A section aborted part-way."
			% [_passed + _failed, CHECKS]
		)
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


## A worked example of what a controller subclass implements: five methods.
class StubController extends DotPlayerController:
	var position: Vector3 = Vector3.ZERO
	var vel: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	var pitch: float = 0.0
	var ticks: int = 0
	var resets: int = 0

	func _apply_intent(intent: DotPlayerIntent, delta: float) -> void:
		ticks += 1
		vel = Vector3(intent.move.x, 0.0, -intent.move.y) * 10.0 * speed_scale
		position += vel * delta
		yaw = intent.view_yaw
		pitch = intent.view_pitch

	func _read_transform() -> Transform3D:
		return Transform3D(Basis(Vector3.UP, yaw), position)

	func _write_transform(to: Transform3D) -> void:
		position = to.origin
		yaw = to.basis.get_euler().y

	func _read_velocity() -> Vector3:
		return vel

	func _write_velocity(v: Vector3) -> void:
		vel = v

	func _read_yaw() -> float:
		return yaw

	func _read_pitch() -> float:
		return pitch

	func _write_angles(p_yaw: float, p_pitch: float) -> void:
		yaw = p_yaw
		pitch = p_pitch

	func _on_activated() -> void:
		# A real controller resets its motor here. The test checks the switch hands the
		# state over AFTER this runs, or the reset would wipe it.
		resets += 1
		vel = Vector3.ZERO


func _player() -> DotPlayer:
	var p := DotPlayer.new()
	p.is_local = true
	add_child(p)
	return p


func _stub(id: StringName, under: Node) -> StubController:
	var c := StubController.new()
	c.controller_id = id
	under.add_child(c)
	return c


# --- Intent -----------------------------------------------------------------

func _test_intent() -> void:
	_section("intent")

	var i := DotPlayerIntent.make(Vector2(1, 1), DotPlayerIntent.Btn.JUMP, 7)
	_check(i.tick == 7, "carries a tick")
	_check(i.holding(DotPlayerIntent.Btn.JUMP), "and what is held")
	_check(not i.holding(DotPlayerIntent.Btn.CROUCH), "and what is not")
	_check(
		i.move == Vector2(1, 1),
		"and does not normalise the move vector — some movement models want the raw "
		+ "one, so the decision belongs to the controller"
	)
	_check(not i.is_idle(), "and is not idle")
	_check(DotPlayerIntent.new().is_idle(), "while an empty one is")

	i.diff_from(0)
	_check(i.just_pressed(DotPlayerIntent.Btn.JUMP), "a new button reads as pressed")
	_check(not i.just_released(DotPlayerIntent.Btn.JUMP), "and not as released")

	i.diff_from(DotPlayerIntent.Btn.JUMP)
	_check(
		not i.just_pressed(DotPlayerIntent.Btn.JUMP),
		"a held button is not pressed again — a jump is an edge and a sprint is a level"
	)

	var released := DotPlayerIntent.make(Vector2.ZERO, 0, 8)
	released.diff_from(DotPlayerIntent.Btn.JUMP)
	_check(released.just_released(DotPlayerIntent.Btn.JUMP), "and letting go reads as released")
	_check(not released.just_pressed(DotPlayerIntent.Btn.JUMP), "and not as pressed")

	i.buttons = DotPlayerIntent.Btn.ATTACK | DotPlayerIntent.Btn.SPRINT
	var names := i.button_names()
	_check(names.size() == 2, "the held buttons have names")
	_check(names.has("attack") and names.has("sprint"), "which are the right ones")
	_check(
		DotPlayerIntent.button_of("reload") == DotPlayerIntent.Btn.RELOAD,
		"and a name resolves back to a bit, which is what a rebinder needs"
	)
	_check(DotPlayerIntent.button_of("nonsense") == 0, "an unknown name resolves to none")

	var copy := i.copy_intent()
	copy.buttons = 0
	_check(i.buttons != 0, "a copy is a copy")
	_check(i.describe().contains("t"), "and an intent describes itself")


func _test_wire() -> void:
	_section("the wire form")

	var i := DotPlayerIntent.make(Vector2(0.5, -0.25), DotPlayerIntent.Btn.ATTACK, 99)
	i.view_yaw = 1.0
	i.view_pitch = -0.5
	i.look = Vector2(0.01, 0.02)

	var d := i.to_dict()
	var back := DotPlayerIntent.from_dict(d)

	_check(back.tick == 99, "a tick survives the wire")
	_check(back.move.is_equal_approx(i.move), "and the move vector")
	_check(back.buttons == i.buttons, "and the buttons")
	_check(is_equal_approx(back.view_yaw, 1.0), "and the view angles")
	_check(
		back.look.is_zero_approx(),
		"but not the look DELTA — a server that integrated a client's deltas would be "
		+ "reconstructing an angle the client already knows, one lost packet away from "
		+ "disagreeing about it forever"
	)
	_check(
		not d.has("look"),
		"so the delta is not even sent, rather than being sent and ignored"
	)
	_check(DotPlayerIntent.from_dict({}).tick == 0, "and an empty payload decodes to nothing")


# --- Look -------------------------------------------------------------------

func _test_look() -> void:
	_section("looking")

	var look := DotPlayerLook.new(1.0)
	_check(is_zero_approx(look.yaw), "starts level")

	look.apply(Vector2(0.0, 10.0))
	_check(
		look.pitch <= look.pitch_min + 0.001,
		"pitch clamps rather than wrapping — wrapping lets a player look through their "
		+ "own feet and come out of the top of their head"
	)

	look.apply(Vector2(0.0, -20.0))
	_check(look.pitch >= look.pitch_max - 0.001, "and clamps at the other end")

	look.set_angles(0.0, 0.0)
	look.apply(Vector2(100.0, 0.0))
	_check(
		look.yaw >= -PI and look.yaw <= PI,
		"yaw wraps rather than clamping — a clamped yaw stops the player turning round, "
		+ "and an unbounded one loses float precision over a long session"
	)

	look.set_angles(0.0, 0.0)
	look.sensitivity = 2.0
	look.apply(Vector2(0.1, 0.0))
	var fast := look.yaw
	look.set_angles(0.0, 0.0)
	look.sensitivity = 1.0
	look.apply(Vector2(0.1, 0.0))
	_check(
		absf(fast) > absf(look.yaw),
		"sensitivity multiplies the delta, not the angle — multiplying the angle snaps "
		+ "the view every time the setting changes"
	)

	look.set_angles(0.0, 0.0)
	look.zoomed = true
	look.apply(Vector2(0.1, 0.0))
	_check(absf(look.yaw) < absf(fast), "and zooming slows it further")
	look.zoomed = false

	look.set_angles(0.0, 0.0)
	look.apply(Vector2(0.0, 0.1))
	var normal_pitch := look.pitch
	look.set_angles(0.0, 0.0)
	look.invert_pitch = true
	look.apply(Vector2(0.0, 0.1))
	_check(
		signf(look.pitch) != signf(normal_pitch),
		"and inverting pitch inverts it"
	)
	look.invert_pitch = false

	look.set_angles(0.0, 0.0)
	_check(
		look.forward().is_equal_approx(Vector3(0, 0, -1)),
		"looking along zero is looking down -Z, which is Godot's forward"
	)
	_check(look.forward_flat().is_equal_approx(Vector3(0, 0, -1)), "flattened too")

	look.set_angles(0.0, -1.0)
	_check(
		look.forward().y < 0.0,
		"looking down points down"
	)
	_check(
		is_zero_approx(look.forward_flat().y),
		"but the flat forward stays flat, so a player looking at the floor still walks "
		+ "forwards rather than into it"
	)

	look.set_angles(PI * 0.5, 0.0)
	_check(
		look.forward_flat().is_equal_approx(Vector3(-1, 0, 0)),
		"a quarter turn faces -X"
	)
	_check(look.right_flat().is_equal_approx(Vector3(0, 0, -1)), "with right a quarter behind")

	look.set_angles(0.0, 0.0)
	var dir := look.move_direction(Vector2(0, 1))
	_check(
		dir.is_equal_approx(Vector3(0, 0, -1)),
		"forward intent goes forward — this arithmetic is here rather than in each "
		+ "controller precisely so the two cannot disagree about which is X"
	)
	_check(
		look.move_direction(Vector2(1, 0)).is_equal_approx(Vector3(1, 0, 0)),
		"and right intent goes right"
	)

	look.set_angles(0.0, 0.5)
	_check(
		look.basis().get_euler().x != 0.0,
		"the camera basis carries the pitch"
	)
	_check(
		is_zero_approx(look.body_basis().get_euler().x),
		"and the body basis does not, because a body that pitched would fall over"
	)

	look.set_angles(0.0, 0.0)
	_check(look.direction_2d().is_equal_approx(Vector2(1, 0)), "and 2D has its own direction")
	_check(
		is_equal_approx(DotPlayerLook.angle_to(Vector2.ZERO, Vector2(0, 1)), PI * 0.5),
		"with an angle-to helper that wraps to the same range a 3D yaw does"
	)

	var copy := look.copy_look()
	copy.yaw = 3.0
	_check(is_zero_approx(look.yaw), "a copy is a copy")
	_check(look.describe().contains("yaw"), "and it describes itself")


# --- The controller ---------------------------------------------------------

func _test_controller() -> void:
	_section("a controller")

	var player := _player()
	var c := _stub(&"fp", player)
	await get_tree().process_frame

	_check(c.is_bound(), "a controller is a component and binds by walking up")
	_check(not c.is_active(), "and starts idle")

	var driven := c.simulate(DotPlayerIntent.make(Vector2(0, 1), 0, 1), 0.1)
	_check(not driven, "an idle controller ignores intent")
	_check(c.ticks == 0, "entirely")

	c.activate()
	_check(c.is_active(), "activating takes over")
	_check(c.resets == 1, "and the subclass is told")

	_check(c.simulate(DotPlayerIntent.make(Vector2(0, 1), 0, 2), 0.1), "and then it drives")
	_check(c.ticks == 1, "one tick at a time")
	_check(c.position.z < 0.0, "moving the player forward")

	var before := c.position
	c.input_enabled = false
	var frozen := c.simulate(DotPlayerIntent.make(Vector2(0, 1), 0, 3), 0.1)
	_check(not frozen, "a frozen controller reports that it did not apply the intent")
	_check(
		c.ticks == 2,
		"but still ticks, so a frozen player keeps falling and keeps being pushed — a "
		+ "controller that skipped the tick would leave them hanging in mid-air"
	)
	_check(c.position.is_equal_approx(before), "without going anywhere")
	c.input_enabled = true

	c.speed_scale = 2.0
	c.position = Vector3.ZERO
	var _d := c.simulate(DotPlayerIntent.make(Vector2(0, 1), 0, 4), 0.1)
	_check(
		c.position.z < -0.19,
		"a speed multiplier reaches the movement, which is how a class changes it"
	)
	c.speed_scale = 1.0

	c.vel = Vector3(0, 0, -50)
	c.place(Transform3D(Basis.IDENTITY, Vector3(10, 0, 10)))
	_check(c.position.is_equal_approx(Vector3(10, 0, 10)), "a teleport puts the player there")
	_check(
		c.vel.is_zero_approx(),
		"and stops them, because a teleport that kept a velocity is a teleport that "
		+ "launches — which only shows up on the one map with a teleporter"
	)

	c.vel = Vector3(0, 0, -50)
	c.place(Transform3D(Basis.IDENTITY, Vector3.ZERO), true)
	_check(not c.vel.is_zero_approx(), "unless the caller wants the velocity kept")

	_check(c.transform_3d().origin.is_equal_approx(Vector3.ZERO), "a controller reports where")
	_check(c.speed() > 0.0, "and how fast")
	_check(c.eye_transform().origin.is_equal_approx(c.transform_3d().origin),
		"with an eye transform that defaults to the body")
	_check(c.last_intent() != null, "it remembers the last intent")
	_check(c.describe_lines().size() >= 2, "and describes itself")

	c.deactivate()
	_check(not c.is_active(), "and hands back")
	_check(not c.simulate(DotPlayerIntent.new(), 0.1), "driving nothing afterwards")

	player.queue_free()


# --- The switch -------------------------------------------------------------

func _test_switch() -> void:
	_section("the switch")

	var player := _player()
	var fp := _stub(&"fp", player)
	var tp := _stub(&"tp", player)
	var sw := DotPlayerControllerSwitch.new()
	sw.default_controller = &"fp"
	player.add_child(sw)

	await get_tree().process_frame
	await get_tree().process_frame

	_check(sw.count() == 2, "a switch finds the controllers beside it")
	_check(sw.has_controller(&"tp"), "by name")
	_check(
		sw.active_id() == &"fp",
		"and starts on the declared default, one frame later — the siblings' own "
		+ "_ready has not run when the switch's does"
	)
	_check(fp.is_active() and not tp.is_active(), "with exactly one driving")

	var changes: Array = []
	sw.controller_changed.connect(func(from: StringName, to: StringName) -> void:
		changes.append([String(from), String(to)])
	)

	_check(sw.activate(&"tp").ok, "switching works")
	_check(tp.is_active(), "the new one drives")
	_check(
		not fp.is_active(),
		"and the old one stops — two controllers both writing the body's transform "
		+ "resolve by child order, which nobody would ever guess from the symptom"
	)
	_check(changes.size() == 1, "with a signal")

	_check(sw.activate(&"tp").ok, "switching to the current one is a no-op")
	_check(changes.size() == 1, "and fires nothing")

	var bad := sw.activate(&"nope")
	_check(not bad.ok, "an unknown controller is refused")
	_check(bad.error.message.contains("fp"), "listing the ones there are")

	_check(sw.cycle().ok, "cycling moves on")
	_check(sw.active_id() == &"fp", "to the next in declared order")
	_check(sw.cycle().ok, "and round")
	_check(sw.active_id() == &"tp", "again")

	sw.simulate(DotPlayerIntent.make(Vector2(0, 1), 0, 1), 0.1)
	_check(tp.ticks > 0, "the switch drives the active controller")
	_check(fp.ticks == 0, "and only that one")

	sw.set_input_enabled(false)
	_check(
		not fp.input_enabled and not tp.input_enabled,
		"freezing freezes every controller, not just the active one — a player who "
		+ "switches view while frozen must stay frozen"
	)
	sw.set_input_enabled(true)

	sw.set_scales(1.5, 2.0)
	_check(
		is_equal_approx(fp.speed_scale, 1.5) and is_equal_approx(tp.jump_scale, 2.0),
		"and a class's multipliers reach all of them"
	)

	sw.place(Transform3D(Basis.IDENTITY, Vector3(5, 0, 5)))
	_check(tp.position.is_equal_approx(Vector3(5, 0, 5)), "a teleport goes through the active one")

	_check(sw.controller(&"fp") == fp, "a controller can be fetched by name")
	_check(sw.available().size() == 2, "and they can all be listed")
	_check(sw.describe_lines().size() >= 3, "and the switch describes itself")

	var lone := _player()
	var only := _stub(&"only", lone)
	var sw2 := DotPlayerControllerSwitch.new()
	lone.add_child(sw2)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(
		sw2.active_id() == &"only",
		"a switch with no declared default takes the first it finds, rather than "
		+ "leaving the player driving nothing"
	)
	_check(not sw2.cycle().ok, "and one controller has nothing to cycle to")
	_check(only.is_active(), "while still driving")

	player.queue_free()
	lone.queue_free()


func _test_handover() -> void:
	_section("the handover")

	var player := _player()
	var fp := _stub(&"fp", player)
	var tp := _stub(&"tp", player)
	var sw := DotPlayerControllerSwitch.new()
	sw.default_controller = &"fp"
	player.add_child(sw)

	await get_tree().process_frame
	await get_tree().process_frame

	fp.position = Vector3(12, 3, -4)
	fp.vel = Vector3(0, 8, -20)
	fp.yaw = 1.25
	fp.pitch = -0.4

	var _res := sw.activate(&"tp")

	_check(
		tp.position.is_equal_approx(Vector3(12, 3, -4)),
		"position survives a switch — a view change that teleported the player would "
		+ "be reported as a netcode bug"
	)
	_check(
		tp.vel.is_equal_approx(Vector3(0, 8, -20)),
		"and so does velocity, so switching mid-jump does not stop the player dead in "
		+ "the air"
	)
	_check(is_equal_approx(tp.yaw, 1.25), "and the view angles")
	_check(is_equal_approx(tp.pitch, -0.4), "both of them")
	_check(
		tp.resets == 1,
		"and the incoming controller reset itself first — the state is handed over "
		+ "AFTER _on_activated, or the reset would wipe it"
	)

	sw.carry_velocity = false
	fp.vel = Vector3.ZERO
	tp.vel = Vector3(0, 0, -99)
	var _res2 := sw.activate(&"fp")
	_check(
		fp.vel.is_zero_approx(),
		"a game that would rather not carry velocity can say so"
	)

	# Pitch rather than yaw: a body's yaw travels inside the transform, which is
	# carried regardless, so turning carry_look off can only withhold the pitch. That
	# is the honest behaviour — a handover that moved the player without their body
	# facing the same way would be a spin, not a view change — and asserting on yaw
	# here would be asserting on something the flag was never going to control.
	sw.carry_look = false
	tp.pitch = 0.0
	fp.pitch = 1.0
	var _res3 := sw.activate(&"tp")
	_check(is_zero_approx(tp.pitch), "and the same for the pitch")

	# The state a handover deliberately does not carry.
	var state := fp.handover_state()
	_check(state.size() == 4, "the handover carries exactly four things")
	_check(
		state.has("transform") and state.has("velocity")
		and state.has("yaw") and state.has("pitch"),
		"and they are where, how fast and where you are looking — a motor's own state "
		+ "has no counterpart in another motor, and converting one would be a lie"
	)

	var fresh := _stub(&"fresh", player)
	fresh.adopt_state(state)
	_check(fresh.position.is_equal_approx(fp.position), "a state can be adopted directly")
	var untouched := fresh.position
	fresh.adopt_state({})
	_check(fresh.position.is_equal_approx(untouched), "and an empty one changes nothing")

	player.queue_free()


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
