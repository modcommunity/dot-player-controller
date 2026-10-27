class_name DotFpsLegSlow
extends Node
## Slows a controller for a few seconds when something breaks the player's legs (dot-combat's `DotFallDamage.legs_broken(seconds, speed_scale)`, or any source of the same shape).
##
## It is a [DotFpsModifier] added through the controller, so the slowdown is part of the replicated modifier set and survives prediction. Off by default: with no [member source] nothing is added, and a game that never sets fall damage never emits the signal. Register the definition on every machine ([method register], from `_ready`), add it on the server only.

const CHANNEL := "player.legslow"
const MODIFIER_ID := &"legs_broken"

## The controller to slow.
@export var controller: DotNodeRef = DotNodeRef.new()
## Anything with a `legs_broken(seconds, speed_scale)` signal; optional, a host may call [method on_legs_broken] itself.
@export var source: DotNodeRef = DotNodeRef.new()
## Definition used by [method register] before a signal supplies its own numbers.
@export_range(0.1, 60.0, 0.1) var seconds: float = 4.0
@export_range(0.0, 1.0, 0.01) var speed_scale: float = 0.6

var _controller: Node = null
var breaks: int = 0


func _ready() -> void:
	var _ok := attach()


## Resolves both refs and connects. False when there is no controller; a missing source is fine.
func attach() -> bool:
	_controller = controller.resolve_or_null(self, CHANNEL)
	if _controller == null or not _controller.has_method(&"add_modifier"):
		DotLog.debug(CHANNEL, "no controller; leg slowdown is inert", {})
		_controller = null
		return false
	var motor: Variant = _controller.get(&"motor")
	if motor != null:
		var _i := register(seconds, speed_scale)
	var src := source.resolve_or_null(self, CHANNEL)
	if src != null and src.has_signal(&"legs_broken") and not src.is_connected(&"legs_broken", on_legs_broken):
		src.connect(&"legs_broken", on_legs_broken)
	return true


## Registers (or updates) the modifier on the controller's motor. -1 without a motor.
func register(p_seconds: float, p_scale: float) -> int:
	var motor: Variant = _controller.get(&"motor") if _controller != null else null
	if motor == null:
		return -1
	var m := DotFpsModifier.make(MODIFIER_ID)
	m.duration_sec = p_seconds
	m.max_speed_scale = p_scale
	m.refreshable = true
	return int((motor as Object).call(&"register_modifier", m))


## The legs broke: slow the player for [param p_seconds] at [param p_scale] of normal speed. Authority side only.
func on_legs_broken(p_seconds: float, p_scale: float) -> bool:
	if _controller == null or p_seconds <= 0.0:
		return false
	var _i := register(p_seconds, p_scale)
	breaks += 1
	return bool(_controller.call(&"add_modifier", MODIFIER_ID))


func describe() -> Dictionary:
	return {"attached": _controller != null, "breaks": breaks, "seconds": seconds, "speed_scale": speed_scale}
