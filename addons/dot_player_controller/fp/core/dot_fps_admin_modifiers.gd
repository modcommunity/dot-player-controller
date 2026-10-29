class_name DotFpsAdminModifiers
extends RefCounted

## What an administrator can do to how somebody moves (noclip, freeze, speed, gravity) as ordinary
## [DotFpsModifier]s, so the owning client predicts them and nothing rubber-bands. Values are a ladder of
## registered steps; [method register] must run in the same order on every machine. See docs/rationale.md.

const NOCLIP := &"admin_noclip"
const FREEZE := &"admin_freeze"

## Held by somebody allowed to toggle noclip with the key; see [method set_noclip_permit].
const NOCLIP_PERMIT := &"admin_noclip_permit"

## Speed multipliers an admin can put somebody on. 1.0 is "none" and is not a step.
## Each scales top speed and both accelerations together; scaling only top speed feels like sliding.
const SPEED_STEPS := [0.25, 0.5, 0.75, 1.5, 2.0, 3.0]

## Gravity multipliers. Zero is deliberately absent: a player on no gravity who jumps
## leaves the map for good, and [constant FREEZE] is the tool for holding somebody still.
const GRAVITY_STEPS := [0.25, 0.5, 0.75, 1.5, 2.0]


## Every definition, in the order [method register] registers them.
static func definitions() -> Array[DotFpsModifier]:
	var out: Array[DotFpsModifier] = []

	var noclip := DotFpsModifier.make(NOCLIP)
	noclip.forces_noclip = true
	out.append(noclip)

	# Frozen is: no input, no gravity, and stopped where they are. Gravity has to go too —
	# a player frozen mid-jump who then falls to the floor is a player who was not frozen,
	# and one frozen on a ledge edge slides off it.
	var freeze := DotFpsModifier.make(FREEZE)
	freeze.deny_move = true
	freeze.deny_jump = true
	freeze.deny_crouch = true
	freeze.max_speed_scale = 0.0
	freeze.gravity_scale = 0.0
	freeze.impulse_clears_velocity = true
	out.append(freeze)

	for step in SPEED_STEPS:
		var speed := DotFpsModifier.make(speed_id(float(step)))
		speed.max_speed_scale = float(step)
		speed.accelerate_scale = float(step)
		speed.air_accelerate_scale = float(step)
		out.append(speed)

	for step in GRAVITY_STEPS:
		var gravity := DotFpsModifier.make(gravity_id(float(step)))
		gravity.gravity_scale = float(step)
		out.append(gravity)

	# Last, so no earlier modifier's index moves.
	var permit := DotFpsModifier.make(NOCLIP_PERMIT)
	permit.grants_noclip = true
	out.append(permit)

	return out


## Registers every definition on [param motor]. Returns how many were registered.
static func register(motor: DotFpsMotor) -> int:
	if motor == null:
		return 0

	var count := 0

	for definition in definitions():
		if motor.register_modifier(definition) >= 0:
			count += 1

	return count


static func speed_id(step: float) -> StringName:
	return StringName("admin_speed_%d" % int(round(step * 100.0)))


static func gravity_id(step: float) -> StringName:
	return StringName("admin_gravity_%d" % int(round(step * 100.0)))


## The step in [param steps] closest to [param scale], or 1.0 when 1.0 is closer.
static func nearest(steps: Array, scale: float) -> float:
	var best := 1.0
	var best_distance := absf(scale - 1.0)

	for step in steps:
		var distance := absf(scale - float(step))
		if distance < best_distance:
			best = float(step)
			best_distance = distance

	return best


# Applying them

## Holds a player in noclip, or lets them go.
## Letting go also puts them in AIR: dropping the modifier alone leaves a player whose tunables allow
## noclip still flying (see [member DotFpsModifier.forces_noclip]).
static func set_noclip(controller: DotFpsController, on: bool) -> DotResult:
	var usable := _ready_on(controller)

	if not usable.ok:
		return usable

	if on:
		controller.add_modifier(NOCLIP)
		return DotResult.success(true)

	controller.remove_modifier(NOCLIP)

	if controller.state.mode == DotFpsState.Mode.NOCLIP:
		controller.state.mode = DotFpsState.Mode.AIR
		controller.state.velocity = Vector3.ZERO

	return DotResult.success(false)


## Lets a player toggle noclip with the key (or takes it away, dropping them out of noclip).
static func set_noclip_permit(controller: DotFpsController, on: bool) -> DotResult:
	var usable := _ready_on(controller)

	if not usable.ok:
		return usable

	if on:
		controller.add_modifier(NOCLIP_PERMIT)
		return DotResult.success(true)

	controller.remove_modifier(NOCLIP_PERMIT)
	if controller.state.mode == DotFpsState.Mode.NOCLIP and not controller.has_modifier(NOCLIP):
		controller.state.mode = DotFpsState.Mode.AIR
		controller.state.velocity = Vector3.ZERO

	return DotResult.success(false)


static func has_noclip_permit(controller: DotFpsController) -> bool:
	return controller != null and controller.has_modifier(NOCLIP_PERMIT)


static func set_frozen(controller: DotFpsController, on: bool) -> DotResult:
	var usable := _ready_on(controller)

	if not usable.ok:
		return usable

	if on:
		controller.add_modifier(FREEZE)
		# The impulse flag zeroes velocity inside add_modifier; the motor's own state is
		# what replicates, so nothing else has to be told.
	else:
		controller.remove_modifier(FREEZE)

	return DotResult.success(on)


## Puts a player on the speed step nearest [param scale]. 1.0 clears it.
##
## Returns the multiplier actually applied, which is the one to tell the admin.
static func set_speed(controller: DotFpsController, scale: float) -> DotResult:
	return _set_step(controller, SPEED_STEPS, scale, true)


static func set_gravity(controller: DotFpsController, scale: float) -> DotResult:
	return _set_step(controller, GRAVITY_STEPS, scale, false)


static func is_noclipped(controller: DotFpsController) -> bool:
	return controller != null and controller.has_modifier(NOCLIP)


static func is_frozen(controller: DotFpsController) -> bool:
	return controller != null and controller.has_modifier(FREEZE)


static func speed_of(controller: DotFpsController) -> float:
	return _step_of(controller, SPEED_STEPS, true)


static func gravity_of(controller: DotFpsController) -> float:
	return _step_of(controller, GRAVITY_STEPS, false)


## Takes every admin modifier off. For a respawn that should arrive clean.
static func clear(controller: DotFpsController) -> void:
	if controller == null or controller.motor == null:
		return

	var _n := set_noclip(controller, false)
	controller.remove_modifier(FREEZE)

	for step in SPEED_STEPS:
		controller.remove_modifier(speed_id(float(step)))

	for step in GRAVITY_STEPS:
		controller.remove_modifier(gravity_id(float(step)))


# Internals

static func _set_step(
	controller: DotFpsController, steps: Array, scale: float, speed: bool
) -> DotResult:
	var usable := _ready_on(controller)

	if not usable.ok:
		return usable

	if scale <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A multiplier has to be above zero.",
			"use freeze to hold somebody still"
		)

	var chosen := nearest(steps, scale)

	# One step at a time. Two would multiply, and 2x on top of 1.5x is a 3x nobody typed.
	for step in steps:
		controller.remove_modifier(speed_id(float(step)) if speed else gravity_id(float(step)))

	if not is_equal_approx(chosen, 1.0):
		controller.add_modifier(speed_id(chosen) if speed else gravity_id(chosen))

	return DotResult.success(chosen)


static func _step_of(controller: DotFpsController, steps: Array, speed: bool) -> float:
	if controller == null:
		return 1.0

	# No modifier at all is the usual case, and every step's id is built as a string and
	# looked up only to be found absent. Per player per tick, from a game's timer.
	if controller.state.modifiers.is_empty():
		return 1.0

	for step in steps:
		if controller.has_modifier(speed_id(float(step)) if speed else gravity_id(float(step))):
			return float(step)

	return 1.0


static func _ready_on(controller: DotFpsController) -> DotResult:
	if controller == null or controller.motor == null:
		return DotResult.fail(DotError.CODE_STATE, "That player has no movement to change.")

	if controller.motor.modifier_index(NOCLIP) < 0:
		# Refused rather than registered on the spot: registering here, on the server only,
		# gives the two machines different modifier indices, and the client would then
		# apply some OTHER modifier every time this one is on.
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"This player's controller was built without admin abilities.",
			"set DotFpsController.admin_abilities on every machine"
		)

	return DotResult.success(null)
