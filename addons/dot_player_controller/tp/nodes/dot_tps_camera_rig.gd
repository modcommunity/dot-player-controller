class_name DotTpsCameraRig
extends Node3D

## The orbit camera: a spring arm, a shoulder it can swap, and an aim blend.
##
## [b]The camera is most of what makes third person work, and the shoulder offset is
## most of the camera.[/b] A camera on the character's centre line puts the character
## between the player and whatever they are shooting at; offsetting it sideways is the
## entire reason a third-person shooter can have a crosshair that means something.
##
## Built in code rather than shipped as a scene, because a scene is a thing a game has
## to merge when this addon changes, and the tree is five nodes.
##
## [codeblock]
## DotTpsCameraRig          moved to the character, yaw applied here
##   SpringArm3D            pitch and collision
##     Marker3D             the shoulder offset
##       Camera3D
## [/codeblock]

const CHANNEL := "player.tps"

@export var tunables: DotTpsTunables = null

## Whether the camera becomes current when this rig is for the local player.
@export var make_current: bool = true

## Layers the spring arm collides with. Set from a dot-physics layout by the game.
@export_flags_3d_physics var collision_mask: int = 1

var arm: SpringArm3D = null
var pivot: Marker3D = null
var camera: Camera3D = null

var _aim: float = 0.0
var _base_fov: float = 75.0


func _ready() -> void:
	if tunables == null:
		tunables = DotTpsTunables.new()

	_build()


func _build() -> void:
	if arm != null:
		return

	arm = SpringArm3D.new()
	arm.name = "Arm"
	arm.spring_length = tunables.camera_distance
	arm.collision_mask = collision_mask
	# The margin keeps the camera off the surface it collided with: without it the near
	# plane sits exactly on the wall and the wall's far side is visible through it.
	arm.margin = 0.2
	add_child(arm)

	exclude_own_body()

	pivot = Marker3D.new()
	pivot.name = "Shoulder"
	arm.add_child(pivot)

	camera = Camera3D.new()
	camera.name = "Camera"
	pivot.add_child(camera)
	_base_fov = camera.fov


## Places the rig from a state. Called once a frame, not once a tick.
##
## [b]Once a frame is right and once a tick is wrong[/b], which is the reverse of every
## other "call this regularly" in the family: the camera is presentation, it is allowed
## to interpolate, and a camera that moved only on simulation ticks judders visibly at
## any frame rate that is not exactly the tick rate.
func follow(state: DotTpsState, feet: Vector3, delta: float) -> void:
	if state == null or arm == null:
		return

	var wanted := feet + Vector3.UP * tunables.camera_height
	var factor := DotTpsTunables.smoothing(tunables.camera_lag, delta)

	global_position = global_position.lerp(wanted, factor) if tunables.camera_lag > 0.0 else wanted

	# Angles are NOT smoothed. A camera that lags behind the mouse is a camera that
	# feels broken, and no amount of tuning makes it feel otherwise — the smoothing is
	# for the position, which the character drags around.
	rotation.y = state.yaw
	arm.rotation.x = state.pitch

	_blend_aim(state, delta)


func _blend_aim(state: DotTpsState, delta: float) -> void:
	var target := 1.0 if state.aiming else 0.0
	_aim = lerpf(_aim, target, DotTpsTunables.smoothing(tunables.aim_blend, delta))

	arm.spring_length = lerpf(tunables.camera_distance, tunables.aim_distance, _aim)

	var shoulder := lerpf(
		tunables.shoulder_offset, tunables.aim_shoulder_offset, _aim
	) * float(signi(state.shoulder) if state.shoulder != 0 else 1)

	pivot.position.x = shoulder

	if camera != null:
		camera.fov = lerpf(_base_fov, _base_fov * tunables.aim_fov_scale, _aim)


## Keeps the arm from colliding with the player it is attached to.
##
## [b]The rig hangs off the player, so the arm's cast STARTS inside the player's own
## collider.[/b] `SpringArm3D` does not exclude its own ancestors — it excludes nothing
## unless told — so on a third-person game where the player is a `CharacterBody3D` (which
## is every third-person game, and is what [DotTpsController] requires) the arm collides
## on its first millimetre and collapses to the margin. The camera then sits at the
## shoulder pivot: inside the character, looking at the inside of its own head, at every
## distance and every angle, with `camera_distance` and every other tunable reading
## exactly as configured.
##
## It went unnoticed because nothing in this family had a player body that was a collision
## object until game-playground's became one. `tps_selftest` builds no physics world, so
## its arm collides with nothing and reports the full length — the check passed for the
## one reason it could not fail.
##
## Walks up rather than taking the body as an argument, because the rig is built before
## the controller has resolved its player and the body can arrive later. Safe to call
## again; `SpringArm3D` ignores a duplicate exclusion.
func exclude_own_body() -> void:
	if arm == null:
		return

	var node: Node = get_parent()

	while node != null:
		var body := node as CollisionObject3D

		if body != null:
			arm.add_excluded_object(body.get_rid())

		node = node.get_parent()


## Swaps the shoulder the camera sits over.
##
## On the state rather than on the rig, because it is a choice a player made and a
## rewind must not undo it — and because a spectator mirroring somebody else's view
## needs to see the same side they are seeing.
func swap_shoulder(state: DotTpsState) -> void:
	if state != null:
		state.shoulder = -state.shoulder


## Whether this rig's camera is the active one.
func set_active(active: bool) -> void:
	if camera == null:
		return

	if active and make_current:
		camera.make_current()

	camera.visible = active


## Where the camera actually is, after the spring arm has pulled it in.
##
## What a shot should be traced from in a third-person shooter — and it is deliberately
## not the muzzle: a shot fired from the muzzle of a model standing behind cover hits
## the cover, while the player is looking straight at the target. Games resolve that by
## tracing from the camera and then correcting; this is the first half.
func camera_transform() -> Transform3D:
	return camera.global_transform if camera != null else global_transform


## Where the camera is looking, as a point far along its forward axis.
func aim_point(distance: float = 1000.0) -> Vector3:
	var t := camera_transform()
	return t.origin - t.basis.z * distance


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"tps camera: %.2f m arm, shoulder %+.2f, aim %.2f" % [
			arm.spring_length if arm != null else 0.0,
			pivot.position.x if pivot != null else 0.0,
			_aim,
		]
	])
