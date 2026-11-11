class_name DotFpsLiftCycle
extends RefCounted

## A lift car's travel as a pure function of time: rest at the bottom, rise, rest at the top, descend, and again.
## Nothing is stored between ticks, so the server and a predicting client that agree on the tick agree on the car
## to the bit, and a replay reads the same height. The game poses its car (a kinematic body) from [method fraction]
## and carries riders by [method carry]; the motor itself does not move a person with the ground.

## Seconds the car waits at each stop.
var rest := 3.0
## Seconds a trip between the stops takes.
var travel := 3.0
## Offset in seconds, so two cars need not move together.
var phase := 0.0


func _init(p_rest: float = 3.0, p_travel: float = 3.0, p_phase: float = 0.0) -> void:
	rest = maxf(p_rest, 0.0)
	travel = maxf(p_travel, 0.01)
	phase = p_phase


func period() -> float:
	return 2.0 * (rest + travel)


## 0 at the bottom stop, 1 at the top, smoothly eased on the trips.
func fraction(seconds: float) -> float:
	var t := fposmod(seconds + phase, period())

	if t < rest:
		return 0.0

	t -= rest

	if t < travel:
		return _ease(t / travel)

	t -= travel

	if t < rest:
		return 1.0

	return 1.0 - _ease((t - rest) / travel)


## True while the car stands still at a stop (a rider may step on or off).
func at_stop(seconds: float) -> bool:
	var f := fraction(seconds)
	return f <= 0.0 or f >= 1.0


## Whether the landing at a stop is open: true only while the car stands at that stop ([param at_top] picks the top
## stop, false the bottom one). The game closes a barrier across the landing's edge while this is false, so a person
## cannot walk off a landing into an empty shaft (the car is at the other stop or on its way). Pure, like [method fraction],
## so every end agrees which tick the barrier is up.
func gate_open(seconds: float, at_top: bool) -> bool:
	return fraction(seconds) >= 1.0 if at_top else fraction(seconds) <= 0.0


## How far a rider moves up this tick: the car's rise between [param from_seconds] and [param to_seconds] times
## [param rise], when the rider's feet are on the car ([param feet_y] within [param tolerance] of the car's top at
## [param from_seconds]), and zero otherwise.
func carry(from_seconds: float, to_seconds: float, bottom_y: float, rise: float, feet_y: float, tolerance: float = 0.08) -> float:
	var top_before := bottom_y + fraction(from_seconds) * rise

	if absf(feet_y - top_before) > tolerance:
		return 0.0

	return (fraction(to_seconds) - fraction(from_seconds)) * rise


static func _ease(x: float) -> float:
	return x * x * (3.0 - 2.0 * x)
