extends Node

## DotFpsLiftCycle: a car's height as a pure function of time, and carrying a rider on it.

var _passed := 0
var _failed := 0


func _ready() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: %s" % what)


func _run() -> void:
	print("dot-player-controller lift cycle self-test")
	var lift := DotFpsLiftCycle.new(3.0, 3.0)
	_check(is_equal_approx(lift.period(), 12.0), "period is two rests and two trips")
	_check(lift.fraction(0.0) == 0.0 and lift.fraction(2.9) == 0.0, "rests at the bottom")
	_check(is_equal_approx(lift.fraction(4.5), 0.5), "halfway up half way through the trip")
	_check(lift.fraction(6.0) == 1.0 and lift.fraction(8.9) == 1.0, "rests at the top")
	_check(is_equal_approx(lift.fraction(10.5), 0.5), "halfway down")
	_check(lift.fraction(12.0) == 0.0 and lift.fraction(1000.0 * 12.0 + 1.0) == 0.0, "repeats")
	_check(lift.fraction(4.2) == lift.fraction(4.2), "pure")
	_check(lift.at_stop(1.0) and lift.at_stop(7.0) and not lift.at_stop(4.0), "at_stop only while still")

	var ridden := 0.0
	var feet := 10.0

	for i in 360:
		var from := float(i) / 60.0
		var step := lift.carry(from, from + 1.0 / 60.0, 10.0, 4.0, feet)
		feet += step
		ridden += step

	_check(is_equal_approx(feet, 14.0), "a rider carried the whole way up ends at the top (%f)" % feet)
	_check(lift.carry(4.0, 4.1, 10.0, 4.0, 13.0) == 0.0, "a person beside the car is not carried")
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)
