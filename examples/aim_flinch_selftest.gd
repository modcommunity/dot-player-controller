extends Node

## What a hit does to a player who is aiming: by default the sights stay and the view shakes and the aim wobbles for a short time; `unscope_on_hit` restores the flinch out of the sights.

const CHECKS := 17
const SECTIONS := 4

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _run() -> void:
	print("dot-player-controller aim flinch self-test")
	_test_default_keeps_aiming()
	_test_legacy_drops_aiming()
	_test_decay_and_scaling()
	_test_cvars()
	print("%d passed, %d failed" % [_passed, _failed])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered, %d completed, %d expected." % [_entered, _completed, SECTIONS])
		get_tree().quit(1)
		return
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print(title)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s %s" % [what, detail])


## Largest wobble magnitude over [param from] to [param to] seconds, sampled at 240 Hz.
func _peak(b: DotFpsAimBreak, from: float, to: float) -> float:
	var peak := 0.0
	var t := from
	while t <= to:
		peak = maxf(peak, b.wobble(t).length())
		t += 1.0 / 240.0
	return peak


func _test_default_keeps_aiming() -> void:
	_section("default: a hit does not stop aiming")
	var t := DotFpsTunables.new()
	var b := DotFpsAimBreak.new()
	_check(not t.unscope_on_hit, "unscope_on_hit is off by default")
	b.note_hit(10.0, t, 25.0)
	_check(not b.blocked(10.01), "the sights are not refused after a hit")
	_check(b.flinching(10.05), "the hit flinches")
	_check(_peak(b, 10.0, 10.2) > 0.05, "the aim wobbles just after the hit")
	_check(b.shake(10.02).length() > 0.0, "the view shakes just after the hit")
	_completed += 1


func _test_legacy_drops_aiming() -> void:
	_section("legacy: a hit flinches out of the sights")
	var t := DotFpsTunables.new()
	t.unscope_on_hit = true
	var b := DotFpsAimBreak.new()
	b.note_hit(10.0, t, 25.0)
	_check(b.blocked(10.1), "the sights are refused just after the hit")
	_check(not b.blocked(10.0 + t.unscope_hit_time + 0.01), "and allowed again after unscope_hit_time")
	_check(not b.flinching(10.05), "no wobble in the legacy mode")
	_completed += 1


func _test_decay_and_scaling() -> void:
	_section("the wobble decays after its time and scales with damage")
	var t := DotFpsTunables.new()
	var b := DotFpsAimBreak.new()
	b.note_hit(5.0, t, 25.0)
	var early := _peak(b, 5.0, 5.15)
	var late := _peak(b, 5.0 + t.hit_flinch_time * 0.6, 5.0 + t.hit_flinch_time * 0.8)
	_check(late < early * 0.5, "the wobble is weaker late in the flinch", "early %.3f late %.3f" % [early, late])
	_check(b.wobble(5.0 + t.hit_flinch_time + 0.01) == Vector2.ZERO, "no wobble after hit_flinch_time")
	_check(b.shake(5.0 + t.hit_flinch_time + 0.01) == Vector3.ZERO, "no shake after hit_flinch_time")
	_check(not b.flinching(5.0 + t.hit_flinch_time + 0.01), "the flinch is over")
	var small := DotFpsAimBreak.new()
	small.note_hit(1.0, t, 10.0)
	var big := DotFpsAimBreak.new()
	big.note_hit(1.0, t, 75.0)
	_check(_peak(big, 1.0, 1.2) > _peak(small, 1.0, 1.2) * 1.5, "more damage wobbles more")
	t.hit_damage_scale = 0.0
	var flat_a := DotFpsAimBreak.new()
	flat_a.note_hit(1.0, t, 10.0)
	var flat_b := DotFpsAimBreak.new()
	flat_b.note_hit(1.0, t, 75.0)
	_check(is_equal_approx(_peak(flat_a, 1.0, 1.2), _peak(flat_b, 1.0, 1.2)), "hit_damage_scale 0 flinches every hit alike")
	var steady := DotFpsAimBreak.new()
	steady.note_hit(1.0, t, 25.0, 0.0)
	_check(not steady.flinching(1.05), "a weapon multiplier of 0 is steady")
	t.hit_wobble = 0.0
	var no_wobble := DotFpsAimBreak.new()
	no_wobble.note_hit(1.0, t, 25.0)
	_check(_peak(no_wobble, 1.0, 1.2) == 0.0 and no_wobble.shake(1.02).length() > 0.0, "hit_wobble 0 leaves only the shake")
	_completed += 1


func _test_cvars() -> void:
	_section("every flinch number is a server cvar")
	var t := DotFpsTunables.new()
	var members := {}
	for spec in t.cvar_specs():
		members[spec.get("member", "")] = true
	var missing := PackedStringArray()
	for m in ["unscope_on_hit", "hit_shake", "hit_wobble", "hit_wobble_hz", "hit_flinch_time", "hit_damage_scale"]:
		if not members.has(m):
			missing.append(m)
	_check(missing.is_empty(), "cvars for all six flinch members", str(missing))
	_completed += 1
