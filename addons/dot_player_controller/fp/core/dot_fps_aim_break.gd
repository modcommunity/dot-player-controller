class_name DotFpsAimBreak
extends RefCounted
## What a hit does to a player who is aiming. With `unscope_on_hit` it refuses the sights for a moment (the flinch-out mode); otherwise the sights stay and the view shakes and the aim wobbles for `hit_flinch_time`, scaled by the damage. The server feeds it damage and ignores the aim bit while [method blocked]; a client feeds it the confirmed hit so the picture agrees.

## A hit of this much damage is the "1x" hit when `hit_damage_scale` is 1.
const REFERENCE_DAMAGE := 25.0
## Stacked hits never grow the amplitude beyond this many times one hit's.
const MAX_STACK := 3.0

var _until: float = -INF
var _start: float = -INF
var _amp: float = 0.0
var _time: float = 0.0
var _hz: float = 9.0
var _wobble_deg: float = 0.0
var _shake_deg: float = 0.0
var _phase: float = 0.0


## Records a hit at [param now] (seconds). [param weapon_scale] is the held weapon's multiplier on the flinch (its profile).
func note_hit(now: float, tunables: DotFpsTunables, damage: float = 0.0, weapon_scale: float = 1.0) -> void:
	if tunables == null:
		return
	if tunables.unscope_on_hit:
		_until = maxf(_until, now + tunables.unscope_hit_time)
		return
	if tunables.hit_flinch_time <= 0.0:
		return
	var strength := lerpf(1.0, clampf(damage / REFERENCE_DAMAGE, 0.25, 3.0), tunables.hit_damage_scale) if damage > 0.0 else 1.0
	strength *= maxf(weapon_scale, 0.0)
	_amp = minf(_envelope(now) + strength, MAX_STACK * maxf(weapon_scale, 1.0))
	_start = now
	_time = tunables.hit_flinch_time
	_hz = tunables.hit_wobble_hz
	_wobble_deg = tunables.hit_wobble
	_shake_deg = tunables.hit_shake
	_phase = fmod(_phase + 2.1, TAU)


## Whether the sights are refused at [param now].
func blocked(now: float) -> bool:
	return now < _until


## Degrees to add to (yaw, pitch) at [param now]: the aim wobble, 0 once the flinch has run its time.
func wobble(now: float) -> Vector2:
	var k := _envelope(now) * _wobble_deg
	if k <= 0.0:
		return Vector2.ZERO
	var t := now - _start
	return Vector2(sin(TAU * _hz * t + _phase), cos(TAU * _hz * 1.31 * t + _phase)) * k


## The camera shake at [param now]: x is roll in degrees, yz a small offset in metres. Zero once the flinch is over.
func shake(now: float) -> Vector3:
	var k := _envelope(now) * _shake_deg
	if k <= 0.0:
		return Vector3.ZERO
	var t := now - _start
	var wave := sin(TAU * _hz * 1.7 * t + _phase)
	return Vector3(wave * k, cos(TAU * _hz * 1.3 * t) * k * 0.004, wave * k * 0.004)


## Whether any flinch is still running at [param now].
func flinching(now: float) -> bool:
	return _envelope(now) > 0.0


## Forgets any hit (respawn).
func clear() -> void:
	_until = -INF
	_start = -INF
	_amp = 0.0


# Quadratic fall-off: a hard start that settles, then exactly 0 at the end of the time.
func _envelope(now: float) -> float:
	if _amp <= 0.0 or _time <= 0.0:
		return 0.0
	var f := 1.0 - (now - _start) / _time
	return _amp * f * f if f > 0.0 else 0.0
