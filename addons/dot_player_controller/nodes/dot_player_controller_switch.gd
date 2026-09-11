class_name DotPlayerControllerSwitch
extends DotPlayerComponent

## Exactly one controller drives the player, and the handover carries what matters.
##
## [b]This is the component that makes having two controllers possible.[/b] Without it,
## a game with a first-person and a third-person controller has two nodes both reading
## input, both writing the body's transform, and the result depends on child order —
## which nobody will ever guess from the symptom.
##
## The other half is the handover. Switching controllers must not teleport the player,
## must not stop them dead in mid-air, and must not spin their view: position, velocity
## and look angles are carried across. The [i]state[/i] is not, and that is deliberate —
## getting out of a vehicle should not restore the air-strafe you were in the middle of.
##
## [codeblock]
## DotPlayer
##   DotPlayerControllerSwitch     default_controller = &"fp"
##   DotFpsController              controller_id = &"fp"
##   DotTpsController              controller_id = &"tp"
## [/codeblock]

## Not [code]CHANNEL[/code]. dot-player-controller's controller has had a
## [code]CHANNEL[/code] of its own since before this base existed, and a constant that
## shadows a parent's is a parse error rather than an override. The base gives up the
## obvious name so the leaf can keep it.
const CONTROLLER_CHANNEL := "player.controller"

## The active controller changed.
signal controller_changed(from: StringName, to: StringName)

## A switch was asked for and refused, with a reason.
signal switch_refused(to: StringName, why: String)

## Which controller takes over when the switch starts. Empty uses the first found.
@export var default_controller: StringName = &""

## Whether to look for controllers among this node's siblings as well as its children.
##
## On, because the scene above puts them side by side under the player, which reads
## better than nesting every controller inside the switch.
@export var include_siblings: bool = true

## Whether velocity is carried across a switch.
##
## On. A player switching from a first-person view to a third-person one mid-jump who
## stopped dead in the air would report it as the game freezing.
@export var carry_velocity: bool = true

## Whether look angles are carried across.
@export var carry_look: bool = true

var _controllers: Dictionary = {}
var _active: StringName = &""


func _ready() -> void:
	super()
	refresh()

	# Deferred: the sibling controllers' own _ready has not necessarily run when this
	# one does, so their controller_id may still be the scene's default. One frame
	# later every node in the subtree exists and has read its own exports.
	call_deferred("_activate_default")


# --- Collecting -------------------------------------------------------------

## Re-finds the controllers. Call after adding one at runtime.
func refresh() -> void:
	_controllers.clear()

	_collect(self)

	if include_siblings and get_parent() != null:
		_collect(get_parent())

	DotLog.debug(CONTROLLER_CHANNEL, "controllers", {"count": _controllers.size()})


func _collect(root: Node) -> void:
	for child in root.get_children():
		var c := child as DotPlayerController

		if c == null:
			continue

		var key := c.controller_id

		if key == &"":
			# An unnamed controller cannot be asked for, and silently ignoring it means
			# a game wondering why activate("tp") does nothing. Named after its class,
			# which is at least askable.
			key = StringName(c.component_name())
			DotLog.warn(CONTROLLER_CHANNEL, "controller has no id", {"node": c.name, "using": String(key)})

		if _controllers.has(key):
			DotLog.warn(CONTROLLER_CHANNEL, "two controllers share an id", {"id": String(key)})
			continue

		_controllers[key] = c


func _activate_default() -> void:
	if _active != &"":
		return

	if _controllers.is_empty():
		return

	var wanted := default_controller

	if wanted == &"" or not _controllers.has(wanted):
		wanted = available()[0]

	var _res := activate(wanted)


# --- Switching --------------------------------------------------------------

## Hands the player to a controller, carrying position, velocity and look.
func activate(id: StringName) -> DotResult:
	if not _controllers.has(id):
		var why := "There is no controller called '%s'. Known: %s." % [
			String(id), ", ".join(_names())
		]
		switch_refused.emit(id, why)
		return DotResult.fail(DotError.CODE_INVALID, why)

	if _active == id:
		return DotResult.success(id)

	var incoming: DotPlayerController = _controllers[id]
	var outgoing: DotPlayerController = _controllers.get(_active, null)
	var state: Dictionary = {}

	if outgoing != null and is_instance_valid(outgoing):
		state = outgoing.handover_state()
		outgoing.deactivate()

	var was := _active
	_active = id

	# Activated first, then given the state: a controller's _on_activated is where it
	# resets its own motor, and handing the state over before that would have it
	# overwritten by the reset. This ordering is the whole reason the two are separate
	# calls rather than one.
	incoming.activate()

	if not state.is_empty():
		var carried := state.duplicate()

		if not carry_velocity:
			carried.erase("velocity")

		if not carry_look:
			carried.erase("yaw")
			carried.erase("pitch")

		incoming.adopt_state(carried)

	DotLog.debug(CONTROLLER_CHANNEL, "controller changed", {"from": String(was), "to": String(id)})
	controller_changed.emit(was, id)
	return DotResult.success(id)


## The next controller in declared order. For a key that cycles the view.
func cycle() -> DotResult:
	var names := available()

	if names.size() < 2:
		return DotResult.fail(
			DotError.CODE_STATE, "There is nothing to cycle to."
		)

	var index := names.find(_active)
	return activate(names[(index + 1) % names.size()])


## Feeds the active controller. Once a tick. See [method DotPlayerController.simulate].
func simulate(intent: DotPlayerIntent, delta: float) -> bool:
	var c := active_controller()
	return c.simulate(intent, delta) if c != null else false


## Freezes or unfreezes every controller at once.
##
## Every one, not just the active one: a player who switches view while frozen must
## still be frozen, and a flag set on one node is a flag the other does not have.
func set_input_enabled(enabled: bool) -> void:
	for key: Variant in _controllers.keys():
		var c: DotPlayerController = _controllers[key]
		if is_instance_valid(c):
			c.input_enabled = enabled


## Applies a class's movement multipliers to every controller.
func set_scales(speed: float, jump: float) -> void:
	for key: Variant in _controllers.keys():
		var c: DotPlayerController = _controllers[key]
		if is_instance_valid(c):
			c.speed_scale = speed
			c.jump_scale = jump


## Moves the player, through whichever controller is driving. See [method DotPlayerController.place].
func place(to: Transform3D, keep_velocity: bool = false) -> void:
	var c := active_controller()

	if c != null:
		c.place(to, keep_velocity)


# --- Reading ----------------------------------------------------------------

func active_id() -> StringName:
	return _active


func active_controller() -> DotPlayerController:
	var c: DotPlayerController = _controllers.get(_active, null)
	return c if c != null and is_instance_valid(c) else null


func has_controller(id: StringName) -> bool:
	return _controllers.has(id)


func controller(id: StringName) -> DotPlayerController:
	return _controllers.get(id, null)


## Every controller id, in declared order.
##
## Declared order rather than dictionary order: a cycle key that visited the views in a
## different sequence on two machines is a small, maddening bug, and this is the only
## place the order is decided.
func available() -> Array[StringName]:
	var out: Array[StringName] = []

	for key: Variant in _controllers.keys():
		out.append(key as StringName)

	return out


func count() -> int:
	return _controllers.size()


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("controllers: %d, active '%s'" % [_controllers.size(), String(_active)])

	for id in available():
		var c: DotPlayerController = _controllers[id]
		if is_instance_valid(c):
			out.append_array(c.describe_lines())

	return out


func describe() -> String:
	return "DotPlayerControllerSwitch(%d, active '%s')" % [_controllers.size(), String(_active)]


func _names() -> PackedStringArray:
	var out := PackedStringArray()

	for id in available():
		out.append(String(id))

	return out
