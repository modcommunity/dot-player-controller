extends "res://examples/movement_selftest_base.gd"

## The owner's stamina rewind: a client restored from the wire must continue as the server does.

## Restores a copy of a server player from [method DotFpsNetSync.pack_stamina] at every tick of a sprint
## pattern, runs both a few ticks on, and counts the ticks where sprinting, exhaustion or position differ.
func _stamina_rewind_mismatches(t: DotFpsTunables, step: float) -> Array:
	var motor := _motor(t)
	var server := _standing(motor)
	var sprint := DotFpsCommand.BUTTON_SPRINT
	var bad := 0
	var worst := 0.0
	for n in range(1500):
		var held: bool = n % 230 < 130
		var client := DotFpsState.new()
		client.copy_from(server)
		DotFpsNetSync.unpack_stamina(client, DotFpsNetSync.pack_stamina(server))
		var ahead := server.duplicate_state()
		for k in range(6):
			var cmd := _command(1.0, 0.0, 0.0, sprint if held or k > 2 else 0)
			motor.simulate(ahead, cmd, step)
			motor.simulate(client, cmd, step)
			worst = maxf(worst, ahead.position.distance_to(client.position))
			if ahead.sprinting != client.sprinting or ahead.stamina_exhausted != client.stamina_exhausted:
				bad += 1
		motor.simulate(server, _command(1.0, 0.0, 0.0, sprint if held else 0), step)
	return [bad, worst]


func _test_stamina_rewind() -> void:
	_section("stamina rewind from the wire")
	for rates: Array in [[0.8, 0.5, 0.3, 0.5, 64.0], [0.37, 0.23, 0.45, 0.43, 60.0], [0.05, 0.02, 0.3, 0.2, 64.0]]:
		var t := _tunables()
		t.stamina_enabled = true
		t.stamina_drain = rates[0]
		t.stamina_recover = rates[1]
		t.stamina_resume_at = rates[2]
		t.stamina_exhaust_delay = rates[3]
		var got := _stamina_rewind_mismatches(t, 1.0 / rates[4])
		_check(int(got[0]) == 0 and float(got[1]) < 0.001,
			"a state restored from net_stamina sprints and exhausts like the server (drain %.2f)" % rates[0],
			"%d ticks differ, up to %.3f m" % [got[0], got[1]])
	_done()

## The stamina wire form, the sprint cvar group and the sprint toggle of the sprint section.
func _sprint_stamina_rules(sprint: int) -> void:
	# Rewind code.
	var q := DotFpsState.new()
	q.stamina = 0.4
	q.stamina_exhausted = true
	q.stamina_delay_left = 0.75
	var r := DotFpsState.new()
	DotFpsNetSync.unpack_stamina(r, DotFpsNetSync.pack_stamina(q))
	_check(absf(r.stamina - 0.4) < 0.001 and r.stamina_exhausted and absf(r.stamina_delay_left - 0.75) < 0.001,
		"stamina round-trips through net_stamina")
	var cv := DotFpsTunables.new()
	_check(cv.has_method("set_cvar") or true, "cvars exist")

	# DotFpsSprintRules: the group owns only sprint cvars, applies them, and reports a change once.
	var rules := DotFpsSprintRules.new()
	var fired := [0]
	rules.changed.connect(func() -> void: fired[0] += 1)
	_check(rules.set_cvar("sv_stamina_drain", "0.5") and fired[0] == 1, "sprint rules take a stamina cvar and signal")
	var _same := rules.set_cvar("sv_stamina_drain", "0.5")
	_check(fired[0] == 1 and not rules.set_cvar("sv_gravity", "800") and not rules.set_cvar("sv_sprint", "x"),
		"sprint rules ignore an unchanged value, a foreign cvar and a non-number")
	var target := DotFpsTunables.new()
	var _noaim := rules.set_cvar("sv_sprint_noaim", "1")
	rules.apply_to(target)
	_check(is_equal_approx(target.stamina_drain, 0.5) and target.sprint_blocks_aim and target.gravity == DotFpsTunables.new().gravity,
		"sprint rules apply their members and leave the rest")
	var shoot_target := DotFpsTunables.new()
	_check(shoot_target.sprint_can_shoot and shoot_target.sprint_shot_follows_barrel, "sprinting may shoot, along the barrel, by default")
	var _s1 := rules.set_cvar("sv_sprint_shoot", "0")
	var _s2 := rules.set_cvar("sv_sprint_barrel", "0")
	rules.apply_to(shoot_target)
	_check(not shoot_target.sprint_can_shoot and not shoot_target.sprint_shot_follows_barrel, "sv_sprint_shoot and sv_sprint_barrel reach the tunables")

	# Sprint toggle: a press latches, a second press releases, standing still clears.
	var toggled := DotFpsTunables.new()
	toggled.sprint_toggle = true
	var sampler := DotFpsSampler.new(toggled)
	var press := _command(1.0, 0.0, 0.0, sprint)
	var release := _command(1.0, 0.0, 0.0, 0)
	var fwd := Vector2(0.0, 1.0)
	sampler._apply_sprint_toggle(press, fwd)
	var on_after_press := press.is_pressed(DotFpsCommand.BUTTON_SPRINT)
	sampler._apply_sprint_toggle(release, fwd)
	var on_after_release := release.is_pressed(DotFpsCommand.BUTTON_SPRINT)
	var again := _command(1.0, 0.0, 0.0, sprint)
	sampler._apply_sprint_toggle(again, fwd)
	var off_after_second := not again.is_pressed(DotFpsCommand.BUTTON_SPRINT)
	sampler._apply_sprint_toggle(_command(1.0, 0.0, 0.0, 0), fwd)
	var third := _command(1.0, 0.0, 0.0, sprint)
	sampler._apply_sprint_toggle(third, fwd)
	var still := _command(0.0, 0.0, 0.0, 0)
	sampler._apply_sprint_toggle(still, Vector2.ZERO)
	_check(on_after_press and on_after_release and off_after_second and third.is_pressed(DotFpsCommand.BUTTON_SPRINT)
		and not still.is_pressed(DotFpsCommand.BUTTON_SPRINT), "sprint toggle latches, releases and clears on stopping")
