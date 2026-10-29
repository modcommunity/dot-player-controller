class_name DotTpsSampler
extends Node

## Devices to [DotPlayerIntent]. The only node in this addon that reads input, kept apart from the
## controller so a replay cannot pick up what the player is holding now.
## Action names are exported because dot-ui owns rebinding.

const CHANNEL := "player.tps"

@export_group("Actions")

@export var move_forward: StringName = &"move_forward"
@export var move_back: StringName = &"move_back"
@export var move_left: StringName = &"move_left"
@export var move_right: StringName = &"move_right"
@export var jump: StringName = &"jump"
@export var crouch: StringName = &"crouch"
@export var sprint: StringName = &"sprint"
@export var aim: StringName = &"aim"
@export var attack: StringName = &"attack"
@export var use_action: StringName = &"use"
@export var swap_shoulder: StringName = &"swap_shoulder"

@export_group("Look")

## Radians per pixel of mouse movement.
@export_range(0.0001, 0.05, 0.0001) var mouse_sensitivity: float = 0.0022

## Radians per second at full stick.
@export_range(0.1, 20.0, 0.1) var stick_sensitivity: float = 3.0

@export var look_left: StringName = &"look_left"
@export var look_right: StringName = &"look_right"
@export var look_up: StringName = &"look_up"
@export var look_down: StringName = &"look_down"

@export var invert_pitch: bool = false

## Whether to read the mouse at all. Off for a controller-only build.
@export var use_mouse: bool = true

var _mouse: Vector2 = Vector2.ZERO
var _last_buttons: int = 0
var _missing: Dictionary = {}


func _ready() -> void:
	set_process_unhandled_input(use_mouse)


func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion

	if motion == null:
		return

	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		# Not captured means a menu is open or the window is not focused, and a camera
		# that kept turning because the pointer crossed it is the classic "my view spun
		# when I alt-tabbed" bug.
		return

	_mouse += motion.relative


## One tick of intent. Call once per simulated tick, on the machine with the player.
func sample(tick: int, delta: float) -> DotPlayerIntent:
	var intent := DotPlayerIntent.new()
	intent.tick = tick

	intent.move = Vector2(
		_strength(move_right) - _strength(move_left),
		_strength(move_forward) - _strength(move_back)
	)

	var buttons := 0

	if _pressed(jump):
		buttons |= DotPlayerIntent.Btn.JUMP

	if _pressed(crouch):
		buttons |= DotPlayerIntent.Btn.CROUCH

	if _pressed(sprint):
		buttons |= DotPlayerIntent.Btn.SPRINT

	if _pressed(aim):
		buttons |= DotPlayerIntent.Btn.ZOOM

	if _pressed(attack):
		buttons |= DotPlayerIntent.Btn.ATTACK

	if _pressed(use_action):
		buttons |= DotPlayerIntent.Btn.USE

	if _pressed(swap_shoulder):
		buttons |= DotPlayerIntent.Btn.ABILITY_3

	intent.buttons = buttons
	intent.diff_from(_last_buttons)
	_last_buttons = buttons

	# Mouse deltas accumulate between ticks and are consumed whole. Reading
	# `relative` inside the tick instead would drop every event that arrived in a frame
	# the tick did not land on, which is most of them at a high frame rate.
	var look := _mouse * mouse_sensitivity
	_mouse = Vector2.ZERO

	var stick := Vector2(
		_strength(look_right) - _strength(look_left),
		_strength(look_down) - _strength(look_up)
	)

	look += stick * stick_sensitivity * delta

	if invert_pitch:
		look.y = -look.y

	intent.look = look
	return intent


## An action's strength, or zero for one this project has not defined.
## Guarded because Input.get_action_strength errors on a missing action, three times per tick per player;
## warned once each.
func _strength(action: StringName) -> float:
	if not InputMap.has_action(action):
		_note_missing(action)
		return 0.0

	return Input.get_action_strength(action)


func _pressed(action: StringName) -> bool:
	if not InputMap.has_action(action):
		_note_missing(action)
		return false

	return Input.is_action_pressed(action)


func _note_missing(action: StringName) -> void:
	if _missing.has(action):
		return

	_missing[action] = true
	DotLog.debug(CHANNEL, "no such input action", {"action": String(action)})


## Which actions this project has not defined. For a settings screen or a bug report.
func missing_actions() -> PackedStringArray:
	var out := PackedStringArray()

	for key: Variant in _missing.keys():
		out.append(String(key))

	out.sort()
	return out


## Clears the accumulated mouse movement. Call when a menu opens, or it arrives in one lump on close.
func discard_pending() -> void:
	_mouse = Vector2.ZERO


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"tps sampler: mouse %s, pending (%.1f, %.1f)" % [
			"on" if use_mouse else "off", _mouse.x, _mouse.y
		]
	])
