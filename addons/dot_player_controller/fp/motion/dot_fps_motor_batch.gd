class_name DotFpsMotorBatch
extends RefCounted
## Several players' motor ticks in runs of one native call (dot-sim's [code]DotSimMotorBatch[/code]), for a server's players' loop.
##
## The game first [method add]s every player in roster order (each motor runs the part of its tick no other player can change),
## then in the same order [method finish]es one, does its own work for that player and goes on. A run is the consecutive rows
## dot-sim can tick; it is ticked when its first row is finished, each row seeing the earlier ones where they came to rest, as
## the players' ticks one after another do. A player that ends its tick elsewhere (a teleport, a death) takes the rows after it
## back ([method moved_after]); they run again. The answers are [method DotFpsMotor.simulate]'s to the bit.

const NATIVE_CLASS := &"DotSimMotorBatch"
const _IN := 55
const _OUT := 45

## Rows ticked natively, native calls, rows taken back and rows found stale, since the game last cleared them.
var rows: int = 0
var runs: int = 0
var retakes: int = 0
var stale: int = 0

var _native: Object = null
var _delta: float = 0.0
var _count: int = 0
var _motors: Array[DotFpsMotor] = []
var _states: Array[DotFpsState] = []
var _commands: Array[DotFpsCommand] = []
var _bodies: Array = []
var _tuns: Array = []
var _stage := PackedByteArray()
var _meta := PackedInt64Array()
var _in := PackedFloat64Array()
var _sent_position := PackedVector3Array()
var _sent_velocity := PackedVector3Array()
var _out := PackedFloat64Array()
## [member _out] holds rows [member _out_from] up to [member _out_to].
var _out_from: int = 0
var _out_to: int = 0


## Whether the loaded dot-sim has the batch.
static func available() -> bool:
	return ClassDB.class_exists(NATIVE_CLASS)


## Starts a players' loop of ticks [param delta] long; false when dot-sim has no batch (the game ticks each player itself).
func start(delta: float) -> bool:
	if _native == null:
		if delta <= 0.0 or not ClassDB.class_exists(NATIVE_CLASS):
			return false
		_native = ClassDB.instantiate(NATIVE_CLASS)
	_delta = delta
	_count = 0
	_out_from = 0
	_out_to = 0
	_native.begin()
	return true


## Adds [param motor]'s tick and runs its start; the row to [method finish].
func add(motor: DotFpsMotor, state: DotFpsState, command: DotFpsCommand) -> int:
	var row := _count
	_count += 1
	if _stage.size() < _count:
		_motors.resize(_count)
		_states.resize(_count)
		_commands.resize(_count)
		_bodies.resize(_count)
		_tuns.resize(_count)
		_stage.resize(_count)
		_meta.resize(_count * 3)
		_in.resize(_count * _IN)
		_sent_position.resize(_count)
		_sent_velocity.resize(_count)
	_motors[row] = motor
	_states[row] = state
	_commands[row] = command
	var stage := motor.batch_prepare(state, command, _delta, _in, _meta, row)
	_stage[row] = stage
	if stage == DotFpsMotor.BATCH_READY:
		_bodies[row] = motor.batch_body
		_tuns[row] = motor.batch_tun
		_sent_position[row] = state.position
		_sent_velocity[row] = state.velocity
	return row


## Ends row [param row]'s motor tick. True when dot-sim's hull world already holds where the player came to rest; on false
## the game tells it ([method moved_after] is not needed then: no later row has run).
func finish(row: int) -> bool:
	var stage := _stage[row]
	if stage == DotFpsMotor.BATCH_DONE:
		return false
	var motor := _motors[row]
	var state := _states[row]
	if stage == DotFpsMotor.BATCH_READY:
		if state.position != _sent_position[row] or state.velocity != _sent_velocity[row]:
			# Something moved the player between add and its turn: the row and the ones after it are redone from here.
			stale += 1
			_take_back(row)
			motor.batch_refill(state, _commands[row], _delta, _in, row)
		if row >= _out_to or row < _out_from:
			_run(row)
		if row < _out_to:
			motor.batch_apply(state, _commands[row], _out, (row - _out_from) * _OUT)
			return _meta[row * 3] == 3
	motor.batch_resume(state, _commands[row], _delta)
	return false


## The player of row [param row] will not tick after all (it died since [method add]). The start of its tick stays run:
## the tick is counted and the stance moved, which the loop one player after another would not have done.
func skip(row: int) -> void:
	if _stage[row] == DotFpsMotor.BATCH_DONE:
		return
	_take_back(row)
	_stage[row] = DotFpsMotor.BATCH_DONE
	_motors[row].batch_cancel()


## The player of row [param row] ended its tick somewhere else than its motor left it, or died: the rows after it run again.
## The game tells the hull world where the player is now.
func moved_after(row: int) -> void:
	_take_back(row + 1)


## Drops what the loop holds (the motors and states of the last tick).
func clear() -> void:
	_count = 0
	_motors.clear()
	_states.clear()
	_commands.clear()
	_bodies.clear()
	_tuns.clear()
	_stage.clear()


func _take_back(row: int) -> void:
	if row >= _out_to or _out_to <= _out_from:
		return
	retakes += 1
	_native.rollback(row)
	_out_to = maxi(row, _out_from)


func _run(row: int) -> void:
	var to := row
	while to < _count and _stage[to] == DotFpsMotor.BATCH_READY:
		to += 1
		# A body outside the hull world does not tell it where it came to rest: the game does, before the next row.
		if _meta[(to - 1) * 3] != 3:
			break
	_out = _native.run(_bodies, _tuns, _meta, _in, row, to)
	_out_from = row
	_out_to = row + _out.size() / _OUT
	rows += _out_to - row
	runs += 1
