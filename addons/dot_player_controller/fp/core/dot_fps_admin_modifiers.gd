class_name DotFpsAdminModifiers
extends RefCounted

## What an administrator can do to how somebody moves: noclip, freeze, a speed and a
## gravity multiplier — as ordinary [DotFpsModifier]s, so every one of them is predicted.
##
## [codeblock]
## controller.admin_abilities = true           # on the server AND on the client
## ...
## DotFpsAdminModifiers.set_noclip(controller, true)     # server side
## DotFpsAdminModifiers.set_speed(controller, 2.0)
## [/codeblock]
##
## [b]Why modifiers, and not a flag or a tunable.[/b] Everything here is decided on the
## server and has to be simulated on the owning client too, because the client predicts its
## own movement. A server that changed a tunable, or set [member DotFpsState.mode] to NOCLIP,
## would be simulating a player the client is not: the client's replay runs its own tunables
## and its own noclip gate, disagrees on every tick, and is corrected on every snapshot —
## which is rubber-banding, the one symptom an admin tool must not have. The active modifier
## set is already in [DotFpsState], already replicated by [DotFpsNetSync] as a mask, and
## already restored by a rewind, so a modifier is the one shape that reaches the client's
## prediction with no new wire field at all.
##
## [b]The cost is that the values are a ladder, not a dial.[/b] A modifier's definition is
## configuration both machines hold and only its membership travels, so a multiplier the
## server made up at runtime is one the client has never heard of. [method set_speed] and
## [method set_gravity] therefore pick the nearest registered step and say which one they
## picked; an admin who typed 2.2 is told they got 2. Adding a step is adding a number to
## [constant SPEED_STEPS], on every machine at once — which a shipped build does anyway.
##
## [b]Registration is part of the wire contract.[/b] [method register] must run on every
## machine, in the same order relative to a game's own modifiers — which is why
## [member DotFpsController.admin_abilities] does it straight after
## [method DotFpsController._register_extensions], and why a game should turn it on for
## every player rather than only for the ones an admin has touched.

const NOCLIP := &"admin_noclip"
const FREEZE := &"admin_freeze"

## Speed multipliers an admin can put somebody on. 1.0 is "none" and is not a step.
##
## Each scales top speed and both accelerations together, so a player on 2× reaches their
## new top speed in the same time they reached the old one — scaling only the top speed
## makes a fast player feel like one who is sliding.
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


# --- Applying them ------------------------------------------------------------

## Holds a player in noclip, or lets them go.
##
## Letting go also puts them in AIR. Removing the modifier alone would leave a player whose
## tunables allow noclip still flying — see [member DotFpsModifier.forces_noclip] — and an
## admin who typed "noclip off" means off.
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


# --- Internals -----------------------------------------------------------------

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
