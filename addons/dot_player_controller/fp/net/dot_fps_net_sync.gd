class_name DotFpsNetSync
extends RefCounted

## What a networked player has to replicate, and how to get it in and out of a
## [DotFpsState].
##
## [b]dot-net is not a dependency and is not imported here.[/b] The family rule is
## that only dot-core is a hard dependency and everything else is discovered at
## runtime — and in GDScript that is not merely a preference: a script that
## [i]mentions[/i] a [code]class_name[/code] the project does not have fails to
## parse, and takes every other script that references it down with it. The same
## reason [code]DotTransportENet[/code] reaches ENet through [method ClassDB.instantiate]
## rather than by name, so that dot-core still compiles on a web export where the
## class does not exist.
##
## So dot-player-controller compiles and runs with dot-core alone, and the thirty-line
## [code]DotNetBehaviour[/code] that joins the two lives in the host game. This class
## is everything that bridge would otherwise have to work out for itself: which
## properties to replicate, how precisely, and how to move them between the wire and
## a [DotFpsState].
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
## The full worked example, including the [code]DotNetInput[/code] subclass, is in
## this project's docs/networking.md.

## Bits the movement mode occupies in the packed flags. See [method pack_flags].
##
## Wide enough for [constant DotFpsState.MAX_MODES], because a game registers its own
## modes and the id is what travels — a mode that did not fit would be received as a
## different one, and the player would be swimming on the other machine.
const MODE_BITS := 4
const MODE_MASK := (1 << MODE_BITS) - 1

## Crouch is held, in the bit above the mode.
const FLAG_CROUCH_HELD := 1 << MODE_BITS

## The slide and launch timers, packed above the crouch bit, in sixty-fourths of a second.
##
## [b]Replicated, unlike the jump timers, and the reason is measured.[/b] A rewind restores
## what the snapshot carries and replays from it, and everything else keeps the client's
## CURRENT value. For the launch that is fatal: the client predicts the launch and starts
## its cooldown, a snapshot from before the launch arrives, the replay reaches the press
## with the cooldown already running and refuses it — and the client sits on the ground
## while the server's player is four metres up. game-arena's net suite measured 3.2 m of
## it before these bits existed. A slide in progress is the same shape at lower stakes.
##
## [b]In the flags word rather than a new property[/b], because every game that wires this
## declares [code]net_flags[/code] already and reads its width from here; a new property
## would be a new [code]var[/code] in every game's net behaviour. 1/64 s is a tick at the
## family's usual rate, so a cooldown counted down a tick at a time quantises exactly.
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

## The buttons of the command the snapshot's tick applied, which is what every press is
## detected against ([member DotFpsState.previous_buttons]). [b]Not sending it was the
## second half of the same bug[/b]: a rewind kept the client's CURRENT buttons, so with the
## key still held the replayed press tick saw no edge at all and the launch (or a buffered
## jump, or a slide) never happened in the replay.
const BUTTONS_SHIFT := SLIDE_COOLDOWN_SHIFT + SLIDE_COOLDOWN_BITS

## The dash's cooldown, the launch's reason and width.
const DASH_BITS := 12
const DASH_SHIFT := BUTTONS_SHIFT + DotFpsCommand.BUTTON_BITS

## The wall run and wall jump, the last fields in the word (2026-10-10), so an encoding
## from before them reads as "not running, no wall jumps" rather than as garbage.
##
## [b]The run's field is one number with two sentinels[/b]: 0 is ready, 1 is a run spent
## this airborne stretch ([member DotFpsState.wall_run_spent]), and 2 and up is a run in
## progress, its time in sixty-fourths plus two. Zero has to mean the idle state, because
## zero is what every older encoding has there. 125 sixty-fourths is the longest run the
## field holds, which is where [constant DotFpsTunables.WALL_RUN_TIME_LIMIT] comes from.
##
## [b]Why these travel[/b]: a rewind that kept the client's own copies would replay the
## rest of a wall run as a fall (no run), or refuse a wall jump the server allowed because
## the client's counter had already counted it. The heading names which wall the per-wall
## counter counts, in eighths of a turn; the simulation keeps it quantised too, so the
## field is exact.
##
## [b]The two jump counters share three bits.[/b] Both run 0..3, and the per-wall one is
## never more than the airborne total and never 0 when the total is not (the last jump was
## off the last wall), so the pairs that can happen are seven: (0,0), (1,1), (2,1), (2,2),
## (3,1), (3,2), (3,3). Seven fit in three bits where two separate fields need four, and
## the word had thirteen bits left.
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
##
## Types are named rather than referenced so this file never mentions
## [code]DotNetVar[/code]. A bridge resolves them with
## [code]DotNetVar.Type[spec.type][/code], which is an ordinary dictionary lookup on
## the enum.
##
## [b]Velocity is on the list, and it is not redundant.[/b] Interpolation between two
## positions is a straight line; with velocity a receiver can curve the path and can
## extrapolate correctly when a packet is late. It is also what a late-joining
## observer needs to avoid seeing every moving player stutter into place.
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
			# A mask of active modifier indices, not the modifiers themselves: the
			# definitions are configuration both machines already hold, so only
			# membership has to travel.
			#
			# [b]The expiry tick does not travel[/b], and that is a deliberate
			# trade. Sending it would make the client predict the exact tick a boost
			# ends; without it the client holds the modifier until the next snapshot
			# says otherwise, so the end can be late by up to one snapshot interval
			# — 50 ms at the default rate. The effect while it is active is
			# predicted exactly, which is the part a player feels. Revisit if a game
			# ever has a modifier whose expiry frame matters.
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
##
## Expiries come back as "until removed" because they were not sent. The server drops
## the modifier when it ends and the next snapshot carries that; see the note on
## [code]net_modifiers[/code] in [method state_specs].
static func unpack_modifiers(state: DotFpsState, mask: int) -> void:
	state.modifiers.clear()

	# Ascending, which is the order DotFpsState.modifiers is required to be in — the
	# aggregate is a product, and floating-point multiplication is not associative.
	for index in range(MODIFIER_BITS):
		if mask & (1 << index):
			state.modifiers.append(Vector2i(index, -1))


## Copies a state onto a replicating object, ready to be sent.
##
## [param target] is typed [Variant] for the same reason as everything else here: it
## is a [code]DotNetBehaviour[/code] in practice and this file cannot say so.
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


## Copies received values back into a state.
##
## On a predicting client this runs as the rewind half of reconciliation: the server's
## answer is adopted wholesale and every unacknowledged command is replayed on top.
## [b]Everything the simulation reads has to be restored here[/b] — a field left
## behind makes the replay start from a state the server never computed, and the
## correction is then measured against a fiction. That is the whole reason
## [DotFpsState] is one object rather than fields spread across the controller.
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


# --- Configuration agreement ----------------------------------------------

## Whether two peers will simulate the same way.
##
## [b]Worth calling at connect time, every time.[/b] A client whose tunables differ
## from the server's diverges on every tick, and the symptom — small, constant
## corrections — is indistinguishable from packet loss. Teams lose weeks to this. One
## comparison at connect turns it into a log line.
static func agrees(mine: DotFpsTunables, theirs_fingerprint: String) -> bool:
	return mine != null and mine.fingerprint() == theirs_fingerprint


## Explains a fingerprint mismatch by naming the properties that differ.
##
## Cheap, and the difference between "movement config mismatch" and "the server has
## sv_airaccelerate 100 and you have 10".
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
