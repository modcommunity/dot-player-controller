class_name DotFpsNetSync
extends RefCounted

## What a networked player has to replicate, and how to get it in and out of a [DotFpsState].
## dot-net is not a dependency and is not imported here: a script that mentions a missing `class_name` fails to parse, so the thin `DotNetBehaviour` that joins the two lives in the host game.
##
## [codeblock]
## class_name PlayerNet extends DotNetBehaviour
##
## @export var controller: DotFpsController
##
## var net_position: Vector3
## var net_velocity: Vector3
## var net_yaw: float
## var net_pitch: float
## var net_crouch: float
## var net_flags: int
## var net_modifiers: int
##
## func _register_net_vars() -> void:
##     for spec in DotFpsNetSync.state_specs():
##         var declaration := replicate(spec.property, DotNetVar.Type[spec.type])
##         if spec.bits > 0:
##             declaration.bits(spec.bits)
##         if spec.interpolated:
##             declaration.interpolated()
##
## func _net_apply_input(input: DotNetInput, _tick: int) -> void:
##     controller.apply_command((input as PlayerInput).command)
##
## func _net_simulate(tick: int, delta: float) -> void:
##     controller.simulate_tick(tick, delta)
##     DotFpsNetSync.pull(controller.state, self)
##
## func _net_state_applied(_tick: int) -> void:
##     DotFpsNetSync.push(self, controller.state)
## [/codeblock]
##
## The full worked example is in docs/networking.md.

## Bits the movement mode occupies in the packed flags. See [method pack_flags].
## Wide enough for [constant DotFpsState.MAX_MODES]: the id travels, so a mode that did not fit would arrive as a different one.
const MODE_BITS := 4
const MODE_MASK := (1 << MODE_BITS) - 1

## Crouch is held, in the bit above the mode.
const FLAG_CROUCH_HELD := 1 << MODE_BITS

## The slide and launch timers, packed above the crouch bit, in sixty-fourths of a second.
## Replicated, unlike the jump timers: a rewind keeps the client's current cooldown, so a snapshot from before a predicted launch replayed the press with the cooldown running and refused it (3.2 m of drift measured).
## In the flags word, not a new property, so no game's net behaviour needs a new var.
const TIMER_SCALE := 64.0

## The scale in use: [constant TIMER_SCALE] at 64 Hz and above, so the wire is unchanged there, and
## the tick rate below it, so a timer counted down a tick at a time still quantises exactly.
## Set by [method set_tick_rate] (the simulator and the controller do), one value per process.
static var timer_scale: float = TIMER_SCALE
const LAUNCH_BITS := 12
const SLIDE_BITS := 7
const SLIDE_COOLDOWN_BITS := 7

## A slide_time of this many sixty-fourths means "not sliding".
const NOT_SLIDING := (1 << SLIDE_BITS) - 1

const LAUNCH_SHIFT := MODE_BITS + 1
const SLIDE_SHIFT := LAUNCH_SHIFT + LAUNCH_BITS
const SLIDE_COOLDOWN_SHIFT := SLIDE_SHIFT + SLIDE_BITS

## The buttons of the command the snapshot's tick applied, which every press is detected against ([member DotFpsState.previous_buttons]).
## Without it a rewind kept the current held buttons and the replayed press saw no edge.
const BUTTONS_SHIFT := SLIDE_COOLDOWN_SHIFT + SLIDE_COOLDOWN_BITS

## The dash's cooldown, the launch's reason and width.
const DASH_BITS := 12
const DASH_SHIFT := BUTTONS_SHIFT + DotFpsCommand.BUTTON_BITS

## The wall run and wall jump, the last fields in the word, so an older encoding reads as "not running, no wall jumps".
## The run field is one number: 0 ready, 1 spent this airborne stretch ([member DotFpsState.wall_run_spent]), 2 and up a run in progress (sixty-fourths plus two); 125 is the longest it holds ([constant DotFpsTunables.WALL_RUN_TIME_LIMIT]).
## The heading names the wall the per-wall counter counts, in eighths of a turn. The two jump counters share three bits: only seven pairs can occur, (0,0) (1,1) (2,1) (2,2) (3,1) (3,2) (3,3).
const WALL_RUN_BITS := 7
const WALL_RUN_READY := 0
const WALL_RUN_SPENT := 1
const WALL_RUN_FIRST_TIME := 2
const WALL_JUMP_COUNT_BITS := 3
const WALL_HEADING_BITS := 3

const WALL_RUN_SHIFT := DASH_SHIFT + DASH_BITS
const WALL_JUMP_COUNT_SHIFT := WALL_RUN_SHIFT + WALL_RUN_BITS
const WALL_HEADING_SHIFT := WALL_JUMP_COUNT_SHIFT + WALL_JUMP_COUNT_BITS

## 64: the word is full. dot-net's UINT takes up to 64 bits, and the top field's high
## bit makes the int negative in GDScript, which every read here masks off. A field
## after this one needs a second property, not a wider word.
const FLAG_BITS := WALL_HEADING_SHIFT + WALL_HEADING_BITS

## Most modifiers a motor can register, and the width of the replicated mask (dot-net's UINT takes up to 64).
const MODIFIER_BITS := 48


## What a networked player replicates.
## Types are named, not referenced, so this file never mentions [code]DotNetVar[/code]; a bridge resolves them with [code]DotNetVar.Type[spec.type][/code].
## Velocity is not redundant: it lets a receiver curve the path, extrapolate a late packet and place a late joiner without a stutter.
static func state_specs() -> Array[Dictionary]:
	return [
		{
			"property": &"net_position",
			"type": "VECTOR3_POSITION",
			"bits": 0,
			"interpolated": true,
			"source": "position",
		},
		{
			"property": &"net_velocity",
			"type": "VECTOR3_VELOCITY",
			"bits": 0,
			"interpolated": false,
			"source": "velocity",
		},
		{
			# 12 bits over 360° is about 0.09°, the same precision the command
			# carries. Replicating the view more precisely than it was sent is
			# paying for accuracy that was never there.
			"property": &"net_yaw",
			"type": "ANGLE",
			"bits": 12,
			"interpolated": true,
			"source": "yaw",
		},
		{
			"property": &"net_pitch",
			"type": "ANGLE",
			"bits": 9,
			"interpolated": true,
			"source": "pitch",
		},
		{
			# 6 bits over 0..1 is ~1.5% of the stand-to-crouch travel, well below
			# what is visible on a transition that takes a tenth of a second.
			"property": &"net_crouch",
			"type": "FLOAT_RANGE",
			"bits": 6,
			"interpolated": true,
			"source": "crouch_fraction",
		},
		{
			"property": &"net_flags",
			"type": "UINT",
			"bits": FLAG_BITS,
			"interpolated": false,
			"source": "flags",
		},
		{
			# A mask of active modifier indices: the definitions are configuration both machines hold, so only membership travels.
			# The expiry tick does not travel, so the client may hold a modifier up to one snapshot interval (50 ms at the default rate) past its end; the effect while active is predicted exactly.
			"property": &"net_modifiers",
			"type": "UINT",
			"bits": MODIFIER_BITS,
			"interpolated": false,
			"source": "modifiers",
		},
	]


## Bits one full state update costs, before dot-net's own framing.
static func estimated_state_bits() -> int:
	# position 3x16 + velocity 3x12 + yaw 12 + pitch 9 + crouch 6 + flags (mode, crouch,
	# the slide, launch and dash timers, buttons, the wall run and wall jumps) + modifiers
	return 48 + 36 + 12 + 9 + 6 + FLAG_BITS + MODIFIER_BITS


static func pack_flags(state: DotFpsState) -> int:
	var flags := state.mode & MODE_MASK

	if state.crouch_held:
		flags |= FLAG_CROUCH_HELD

	flags |= _quantise(state.launch_cooldown_left, LAUNCH_BITS) << LAUNCH_SHIFT
	var slide := NOT_SLIDING if not state.is_sliding() else mini(
		_quantise(state.slide_time, SLIDE_BITS), NOT_SLIDING - 1
	)
	flags |= slide << SLIDE_SHIFT
	flags |= _quantise(state.slide_cooldown_left, SLIDE_COOLDOWN_BITS) << SLIDE_COOLDOWN_SHIFT
	flags |= (state.previous_buttons & ((1 << DotFpsCommand.BUTTON_BITS) - 1)) << BUTTONS_SHIFT
	flags |= _quantise(state.dash_cooldown_left, DASH_BITS) << DASH_SHIFT

	var wall_run := WALL_RUN_READY
	if state.is_wall_running():
		wall_run = WALL_RUN_FIRST_TIME + mini(
			_quantise(state.wall_run_time, WALL_RUN_BITS),
			(1 << WALL_RUN_BITS) - 1 - WALL_RUN_FIRST_TIME
		)
	elif state.wall_run_spent:
		wall_run = WALL_RUN_SPENT
	flags |= wall_run << WALL_RUN_SHIFT
	flags |= wall_jump_code(state.wall_jumps_in_air, state.wall_jump_count) << WALL_JUMP_COUNT_SHIFT
	flags |= (state.wall_jump_heading & ((1 << WALL_HEADING_BITS) - 1)) << WALL_HEADING_SHIFT

	return flags


## Derives [member timer_scale] from the simulation's tick rate. Both ends must run the same rate.
static func set_tick_rate(rate: int) -> void:
	timer_scale = clampf(float(rate), 1.0, TIMER_SCALE)


static func unpack_flags(state: DotFpsState, flags: int) -> void:
	state.crouch_held = (flags & FLAG_CROUCH_HELD) != 0
	state.mode = flags & MODE_MASK

	state.launch_cooldown_left = _field(flags, LAUNCH_SHIFT, LAUNCH_BITS) / timer_scale
	var slide := _field(flags, SLIDE_SHIFT, SLIDE_BITS)
	state.slide_time = -1.0 if slide == NOT_SLIDING else slide / timer_scale
	state.slide_cooldown_left = (
		_field(flags, SLIDE_COOLDOWN_SHIFT, SLIDE_COOLDOWN_BITS) / timer_scale
	)
	state.previous_buttons = (flags >> BUTTONS_SHIFT) & ((1 << DotFpsCommand.BUTTON_BITS) - 1)
	state.dash_cooldown_left = _field(flags, DASH_SHIFT, DASH_BITS) / timer_scale

	var wall_run := int(_field(flags, WALL_RUN_SHIFT, WALL_RUN_BITS))
	state.wall_run_time = (
		(wall_run - WALL_RUN_FIRST_TIME) / timer_scale if wall_run >= WALL_RUN_FIRST_TIME
		else -1.0
	)
	state.wall_run_spent = wall_run == WALL_RUN_SPENT
	var counts := wall_jump_counts(int(_field(flags, WALL_JUMP_COUNT_SHIFT, WALL_JUMP_COUNT_BITS)))
	state.wall_jumps_in_air = counts.x
	state.wall_jump_count = counts.y
	state.wall_jump_heading = int(_field(flags, WALL_HEADING_SHIFT, WALL_HEADING_BITS))


## The airborne total and the per-wall count of wall jumps as one number, 0..6. See
## [constant WALL_RUN_BITS] for why they share a field.
static func wall_jump_code(in_air: int, same_wall: int) -> int:
	var total := clampi(in_air, 0, 3)
	if total == 0:
		return 0
	return ((total * (total - 1)) >> 1) + clampi(same_wall, 1, total)


## [method wall_jump_code] undone: (airborne total, per-wall count).
static func wall_jump_counts(code: int) -> Vector2i:
	for total in range(1, 4):
		var first := ((total * (total - 1)) >> 1) + 1
		if code >= first and code < first + total:
			return Vector2i(total, code - first + 1)
	return Vector2i.ZERO


## Seconds as sixty-fourths, clamped into [param bits]. A cooldown longer than the field
## holds is sent as the longest it can say: the client may then predict an ability a few
## ticks early, and the next snapshot takes it back.
static func _quantise(seconds: float, bits: int) -> int:
	return clampi(roundi(maxf(seconds, 0.0) * timer_scale), 0, (1 << bits) - 1)


static func _field(flags: int, shift: int, bits: int) -> float:
	return float((flags >> shift) & ((1 << bits) - 1))


## The active modifier set as a bit per registered index.
static func pack_modifiers(state: DotFpsState) -> int:
	var mask := 0

	for entry in state.modifiers:
		if entry.x >= 0 and entry.x < MODIFIER_BITS:
			mask |= 1 << entry.x

	return mask


## Rebuilds the active set from a mask, preserving order.
## Expiries come back as "until removed" because they were not sent; see [code]net_modifiers[/code] in [method state_specs].
static func unpack_modifiers(state: DotFpsState, mask: int) -> void:
	state.modifiers.clear()

	# Ascending, which is the order DotFpsState.modifiers is required to be in — the
	# aggregate is a product, and floating-point multiplication is not associative.
	for index in range(MODIFIER_BITS):
		if mask & (1 << index):
			state.modifiers.append(Vector2i(index, -1))


## Copies a state onto a replicating object, ready to be sent.
## [param target] is a [Variant] because it is a [code]DotNetBehaviour[/code] in practice and this file cannot name it.
static func pull(state: DotFpsState, target: Variant) -> void:
	target.set(&"net_position", state.position)
	target.set(&"net_velocity", state.velocity)
	target.set(&"net_yaw", state.yaw)
	target.set(&"net_pitch", state.pitch)
	target.set(&"net_crouch", state.crouch_fraction)
	target.set(&"net_flags", pack_flags(state))
	target.set(&"net_modifiers", pack_modifiers(state))
	if &"net_timers" in target:
		target.set(&"net_timers", pack_timers(state))
	if &"net_stamina" in target:
		target.set(&"net_stamina", pack_stamina(state))


## The jump timers (coyote, jump buffer, cooldown) in 1/7680 s, which is a whole number of
## codes per tick at 20 to 128 Hz. Code 0 is "longer than the field holds" (restored as 1000 s).
const JUMP_TIMER_SCALE := 7680.0
const JUMP_TIMER_BITS := 14
const TIMERS_BITS := 4 * JUMP_TIMER_BITS


## The owner-only property a predicting client rewinds the jump timers from. Opt in by
## declaring [code]var net_timers: int[/code] and replicating these; [method pull] and
## [method push] then carry it. See docs/networking.md, "The jump timers".
static func rewind_specs() -> Array[Dictionary]:
	return [{"property": &"net_timers", "type": "UINT", "bits": TIMERS_BITS,
		"interpolated": false, "owner_only": true, "source": "jump timers"}]


## Owner-only stamina for a predicting client's rewind: opt in with [code]var net_stamina: int[/code]
## and replicate [method stamina_specs]. 14 bits of stamina, 1 exhausted, 13 of the refill delay (1/2048 s).
## Coarser steps made a rewound client decide a sprint or an exhaustion a tick away from the server.
const STAMINA_BITS := 28


static func stamina_specs() -> Array[Dictionary]:
	return [{"property": &"net_stamina", "type": "UINT", "bits": STAMINA_BITS,
		"interpolated": false, "owner_only": true, "source": "stamina"}]


static func pack_stamina(state: DotFpsState) -> int:
	return (roundi(clampf(state.stamina, 0.0, 1.0) * 16383.0)
		| (1 if state.stamina_exhausted else 0) << 14
		| clampi(roundi(state.stamina_delay_left * 2048.0), 0, 8191) << 15)


## Puts the state's stamina on the wire grid, so a state rewound from net_stamina is identical to the
## server's rather than close, which flips a sprint or exhaustion at the boundary.
static func snap_stamina(state: DotFpsState) -> void:
	unpack_stamina(state, pack_stamina(state))


static func unpack_stamina(state: DotFpsState, code: int) -> void:
	state.stamina = float(code & 16383) / 16383.0
	state.stamina_exhausted = (code >> 14) & 1 == 1
	state.stamina_delay_left = float((code >> 15) & 8191) / 2048.0


static func pack_timers(state: DotFpsState) -> int:
	return (_timer_code(state.time_since_grounded)
		| _timer_code(state.time_since_jump) << JUMP_TIMER_BITS
		| _timer_code(state.time_since_jump_pressed) << (2 * JUMP_TIMER_BITS)
		| _timer_code(state.wall_run_cooldown_left) << (3 * JUMP_TIMER_BITS))


static func unpack_timers(state: DotFpsState, code: int) -> void:
	state.time_since_grounded = _timer_value(code)
	state.time_since_jump = _timer_value(code >> JUMP_TIMER_BITS)
	state.time_since_jump_pressed = _timer_value(code >> (2 * JUMP_TIMER_BITS))
	# 1000 s is the field's "longer than it holds"; a cooldown that long is never set.
	state.wall_run_cooldown_left = minf(_timer_value(code >> (3 * JUMP_TIMER_BITS)), 10.0) if code >> (3 * JUMP_TIMER_BITS) != 0 else 0.0


static func _timer_code(seconds: float) -> int:
	var n := roundi(maxf(seconds, 0.0) * JUMP_TIMER_SCALE)
	return 0 if n >= (1 << JUMP_TIMER_BITS) - 2 else n + 1


static func _timer_value(code: int) -> float:
	var c := code & ((1 << JUMP_TIMER_BITS) - 1)
	return 1000.0 if c == 0 else float(c - 1) / JUMP_TIMER_SCALE


## Copies received values back into a state; on a predicting client this is the rewind half of reconciliation.
## Everything the simulation reads must be restored here, or the replay starts from a state the server never computed.
static func push(source: Variant, state: DotFpsState) -> void:
	state.position = source.get(&"net_position")
	state.velocity = source.get(&"net_velocity")
	state.yaw = source.get(&"net_yaw")
	state.pitch = source.get(&"net_pitch")
	state.crouch_fraction = source.get(&"net_crouch")
	unpack_flags(state, int(source.get(&"net_flags")))
	unpack_modifiers(state, int(source.get(&"net_modifiers")))
	var timers: Variant = source.get(&"net_timers")
	if timers != null:
		unpack_timers(state, int(timers))
	var stamina: Variant = source.get(&"net_stamina")
	if stamina != null:
		unpack_stamina(state, int(stamina))



## Whether two peers will simulate the same way.
## Call it at connect time: differing tunables show up as small constant corrections, indistinguishable from packet loss.
static func agrees(mine: DotFpsTunables, theirs_fingerprint: String) -> bool:
	return mine != null and mine.fingerprint() == theirs_fingerprint


## Explains a fingerprint mismatch by naming the properties that differ.
static func differences(
	mine: DotFpsTunables,
	theirs: DotFpsTunables
) -> PackedStringArray:
	var out := PackedStringArray()

	if mine == null or theirs == null:
		out.append("one side has no tunables at all")
		return out

	for key in mine.config_keys():
		if key.begins_with("mouse_") or key == "invert_look_y":
			continue

		var a: Variant = mine.get(key)
		var b: Variant = theirs.get(key)

		if a != b:
			out.append("%s: mine %s, theirs %s" % [key, str(a), str(b)])

	return out
