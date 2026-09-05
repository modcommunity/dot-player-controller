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
## So dot-fps-controller compiles and runs with dot-core alone, and the thirty-line
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
## this project's CLAUDE.md.

## Bits the movement mode occupies in the packed flags. See [method pack_flags].
##
## Wide enough for [constant DotFpsState.MAX_MODES], because a game registers its own
## modes and the id is what travels — a mode that did not fit would be received as a
## different one, and the player would be swimming on the other machine.
const MODE_BITS := 4
const MODE_MASK := (1 << MODE_BITS) - 1

## Crouch is held, in the bit above the mode.
const FLAG_CROUCH_HELD := 1 << MODE_BITS

const FLAG_BITS := MODE_BITS + 1

## Most modifiers that can be active at once, and the width of the replicated mask.
const MODIFIER_BITS := 32


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
	# position 3x16 + velocity 3x12 + yaw 12 + pitch 9 + crouch 6 + flags + modifiers
	return 48 + 36 + 12 + 9 + 6 + FLAG_BITS + MODIFIER_BITS


static func pack_flags(state: DotFpsState) -> int:
	var flags := state.mode & MODE_MASK

	if state.crouch_held:
		flags |= FLAG_CROUCH_HELD

	return flags


static func unpack_flags(state: DotFpsState, flags: int) -> void:
	state.crouch_held = (flags & FLAG_CROUCH_HELD) != 0
	state.mode = flags & MODE_MASK


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
