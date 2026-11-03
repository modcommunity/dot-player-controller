class_name DotFpsCommand
extends RefCounted

## One tick of player intent, never outcome: the server applies it through the same [DotFpsMotor] and reaches the authoritative answer itself.
## Nothing here reads the keyboard ([DotFpsSampler] does), so replays, bots and network packets produce commands too.
## Usage: [code]motor.simulate(state, cmd, tick_delta)[/code]; [code]cmd.set_button(DotFpsCommand.BUTTON_JUMP, true)[/code].

## Buttons as a bitfield: 8 bits on the wire, and a game adds actions ([constant BUTTON_USER_0]) without changing the packet layout.
const BUTTON_JUMP := 1 << 0
const BUTTON_CROUCH := 1 << 1
const BUTTON_SPRINT := 1 << 2
const BUTTON_WALK := 1 << 3
const BUTTON_NOCLIP := 1 << 4

## Free bits for the host game (fire, use, reload); the motor ignores them and the wire carries them in the same command.
const BUTTON_USER_0 := 1 << 5
const BUTTON_USER_1 := 1 << 6
const BUTTON_USER_2 := 1 << 7

const BUTTON_BITS := 8

## Movement intent in the player's local frame: [code]x[/code] strafes right, [code]y[/code] moves forward.
## Length is clamped to 1 by [method sanitise]; an unclamped diagonal is a speed hack.
var move: Vector2 = Vector2.ZERO

## Absolute view angles in degrees, not deltas: a replay must reproduce the exact view, and deltas would let one dropped packet desync aim forever.
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


## Buttons pressed in this command but not in [param previous].
## Derived from the previous command rather than stored, so replaying out of a buffer gives the same answer as sampling live.
func pressed_since(previous: DotFpsCommand) -> int:
	var before := previous.buttons if previous != null else 0
	return buttons & ~before


func just_pressed(button: int, previous: DotFpsCommand) -> bool:
	return (pressed_since(previous) & button) != 0


## Stands still, releases every button and keeps the view angles (the default of
## `DotNetInput._neutralise`, for a silent or blacked-out player).
func neutralise() -> void:
	move = Vector2.ZERO
	buttons = 0


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



## Clamps every field into a legal range. [b]Call this on the server, always.[/b]
## Quantisation bounds each field alone; it cannot stop a move vector of length 40.
## [param pitch_min] / [param pitch_max] come from the tunables.
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



## Writes the command into a bit writer (8 bits buttons, 20 movement, 21 view).
## [param writer] is [Variant] because a script that mentions a missing [code]DotNetWriter[/code] class fails to parse
## in a project without dot-net.
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
