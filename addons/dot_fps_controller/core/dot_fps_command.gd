class_name DotFpsCommand
extends RefCounted

## One tick of player intent. The only thing that drives the simulation.
##
## [b]Intent, never outcome.[/b] A command says "hold forward, look here, jump" — it
## never says where the player ended up. That distinction is what makes the
## controller usable over a network at all: the server applies the same command
## through the same [DotFpsMotor] and reaches the authoritative answer itself, so a
## modified client can lie about which buttons it pressed but not about where that
## puts it. It is also what makes client-side prediction converge, because replaying
## a stored command reproduces the tick exactly.
##
## [b]Nothing here reads the keyboard.[/b] Sampling is [DotFpsSampler]'s job, and it
## is deliberately a separate object: a replay, a bot, a demo playback and a server
## applying a network packet all produce commands without any input device involved.
##
## [codeblock]
## var cmd := DotFpsCommand.new()
## cmd.move = Vector2(0.0, 1.0)   # x = strafe right, y = forward
## cmd.yaw = 90.0
## cmd.set_button(DotFpsCommand.BUTTON_JUMP, true)
## motor.simulate(state, cmd, tick_delta)
## [/codeblock]

## Buttons, as a bitfield.
##
## A bitfield rather than one bool per action because the whole set costs 8 bits on
## the wire and because a game adding its own action should not have to change the
## packet layout — see [constant BUTTON_USER_0].
const BUTTON_JUMP := 1 << 0
const BUTTON_CROUCH := 1 << 1
const BUTTON_SPRINT := 1 << 2
const BUTTON_WALK := 1 << 3
const BUTTON_NOCLIP := 1 << 4

## Free bits for the host game — fire, use, reload, whatever it has.
##
## The motor ignores them and the wire format carries them, so a game can put its own
## actions in the same command it already sends rather than inventing a second one
## that then has to be kept in tick order with this one.
const BUTTON_USER_0 := 1 << 5
const BUTTON_USER_1 := 1 << 6
const BUTTON_USER_2 := 1 << 7

const BUTTON_BITS := 8

## Movement intent in the player's local frame, before any speed scaling.
##
## [code]x[/code] strafes right, [code]y[/code] moves forward. Length is clamped to 1
## by [method sanitise]: an unclamped diagonal would be √2 times faster, which is the
## original "strafe-running" bug and, from a modified client, a straightforward speed
## hack.
var move: Vector2 = Vector2.ZERO

## Absolute view angles in degrees, not deltas.
##
## Absolute because a replay has to reproduce the exact view the tick was simulated
## with. Sending deltas would make the replayed yaw depend on every earlier packet
## arriving, so a single dropped input would leave the client and server aiming in
## different directions forever.
var yaw: float = 0.0
var pitch: float = 0.0

var buttons: int = 0


func is_pressed(button: int) -> bool:
	return (buttons & button) != 0


func set_button(button: int, pressed: bool) -> void:
	if pressed:
		buttons |= button
	else:
		buttons &= ~button


## Buttons pressed in this command that were not pressed in [param previous].
##
## The motor needs edges, not levels, for anything that should fire once per press —
## jump without auto-hop, the noclip toggle. Deriving them from the previous command
## rather than storing them keeps the command a pure description of one instant, so
## replaying it out of a buffer gives the same answer as sampling it live.
func pressed_since(previous: DotFpsCommand) -> int:
	var before := previous.buttons if previous != null else 0
	return buttons & ~before


func just_pressed(button: int, previous: DotFpsCommand) -> bool:
	return (pressed_since(previous) & button) != 0


func duplicate_command() -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = move
	c.yaw = yaw
	c.pitch = pitch
	c.buttons = buttons
	return c


func equals(other: DotFpsCommand) -> bool:
	if other == null:
		return false
	return (
		buttons == other.buttons
		and move.is_equal_approx(other.move)
		and is_equal_approx(yaw, other.yaw)
		and is_equal_approx(pitch, other.pitch)
	)


# --- Validation ------------------------------------------------------------

## Clamps every field into a legal range. [b]Call this on the server, always.[/b]
##
## Everything on a command that arrived over a network is whatever the sender chose
## to put in it. Quantisation bounds each field individually — it cannot stop a
## move vector of length 40, because the vector's length is a relationship between
## two fields that are each in range.
##
## [param pitch_min] / [param pitch_max] come from the tunables so a game that allows
## a different look range does not have to re-implement this.
func sanitise(pitch_min: float = -89.0, pitch_max: float = 89.0) -> void:
	# NaN survives every comparison, so a NaN move vector would pass a naive clamp
	# and then poison the position for the rest of the session. Checked explicitly
	# because `is_finite` is the only thing that catches it.
	if not (is_finite(move.x) and is_finite(move.y)):
		move = Vector2.ZERO
	move = move.limit_length(1.0)

	yaw = wrapf(yaw, -180.0, 180.0) if is_finite(yaw) else 0.0
	pitch = clampf(pitch, pitch_min, pitch_max) if is_finite(pitch) else 0.0

	buttons &= (1 << BUTTON_BITS) - 1


# --- Wire format -----------------------------------------------------------

## Writes the command into a bit writer.
##
## [param writer] is typed [Variant] on purpose. It is a [code]DotNetWriter[/code] in
## practice, but dot-fps-controller must compile in a project that does not have
## dot-net installed, and a script that so much as [i]mentions[/i] a missing
## [code]class_name[/code] fails to parse. The family already does this for ENet on
## web builds; the same reasoning applies here.
##
## 8 bits of buttons, 20 of movement, 21 of view — 49 bits, under 7 bytes per tick.
func write(writer: Variant) -> void:
	writer.write_float_range(move.x, -1.0, 1.0, 10)
	writer.write_float_range(move.y, -1.0, 1.0, 10)
	# 12 bits over 360° is ~0.09°, well under what a player can perceive or a mouse
	# can reliably produce, and it is the number hit registration is traced against.
	writer.write_angle(yaw, 12)
	writer.write_float_range(pitch, -90.0, 90.0, 9)
	writer.write_uint(buttons, BUTTON_BITS)


func read(reader: Variant) -> void:
	move.x = reader.read_float_range(-1.0, 1.0, 10)
	move.y = reader.read_float_range(-1.0, 1.0, 10)
	yaw = reader.read_angle(12)
	pitch = reader.read_float_range(-90.0, 90.0, 9)
	buttons = reader.read_uint(BUTTON_BITS)


## Bits [method write] costs. For a bandwidth budget.
static func estimated_bits() -> int:
	return 10 + 10 + 12 + 9 + BUTTON_BITS


# --- Diagnostics -----------------------------------------------------------

static func button_names(mask: int) -> PackedStringArray:
	var out := PackedStringArray()
	if mask & BUTTON_JUMP: out.append("jump")
	if mask & BUTTON_CROUCH: out.append("crouch")
	if mask & BUTTON_SPRINT: out.append("sprint")
	if mask & BUTTON_WALK: out.append("walk")
	if mask & BUTTON_NOCLIP: out.append("noclip")
	if mask & BUTTON_USER_0: out.append("user0")
	if mask & BUTTON_USER_1: out.append("user1")
	if mask & BUTTON_USER_2: out.append("user2")
	return out


func describe() -> Dictionary:
	return {
		"move": "(%.2f, %.2f)" % [move.x, move.y],
		"yaw": "%.1f" % yaw,
		"pitch": "%.1f" % pitch,
		"buttons": ", ".join(button_names(buttons)),
	}


func _to_string() -> String:
	return "DotFpsCommand(%s)" % str(describe())
