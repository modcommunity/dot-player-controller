class_name DotTpsCameraRig
extends Node3D

## The orbit camera: a boom that stays out of the level, a shoulder it can swap, and an aim blend.
## Built in code, not a scene (a scene is something a game must merge). The arm is a dot-core
## [DotCameraBoom], not a SpringArm3D, and the shoulder is part of its swept line. Tree: docs/rationale.md.

# No log channel: a camera following a state it is handed every frame. It has nothing
# outside the process to fail against, and a line from it would be a line per frame.

@export var tunables: DotTpsTunables = null

## Whether the camera becomes current when this rig is for the local player.
@export var make_current: bool = true

## Layers the boom stops against. Set from a dot-physics layout by the game.
@export_flags_3d_physics var collision_mask: int = 1

## Layers whose bodies fade when they come between the camera and the character (other
## players, NPCs). Zero fades nothing.
@export_flags_3d_physics var fade_mask: int = 0

var arm: DotCameraBoom = null
var fade: DotCameraFade = null
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

	arm = DotCameraBoom.new()
	arm.name = "Arm"
	arm.spring_length = tunables.camera_distance
	arm.collision_mask = collision_mask
	# The margin keeps the camera off the surface it collided with: without it the near
	# plane sits exactly on the wall and the wall's far side is visible through it.
	arm.margin = 0.2
	# Placed by follow(), after the rig itself has moved, rather than on the boom's own
	# frame: one placement per frame, from this frame's pivot.
	arm.auto_place = false
	add_child(arm)

	exclude_own_body()

	pivot = Marker3D.new()
	pivot.name = "Shoulder"
	arm.add_child(pivot)

	camera = Camera3D.new()
	camera.name = "Camera"
	pivot.add_child(camera)
	_base_fov = camera.fov

	fade = DotCameraFade.new()
	fade.name = "Fade"
	fade.collision_mask = fade_mask
	fade.focus = self
	camera.add_child(fade)


## Sets which layers fade between the camera and the character, after the rig is built.
func set_fade_mask(mask: int) -> void:
	fade_mask = mask
	if fade != null:
		fade.collision_mask = mask


## Places the rig from a state. Called once a frame, not once a tick: the camera is
## presentation and a camera moved only on ticks judders.
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

	arm.side_offset = shoulder
	arm.place(delta)

	if camera != null:
		camera.fov = lerpf(_base_fov, _base_fov * tunables.aim_fov_scale, _aim)


## Keeps the arm from colliding with, and the fade from fading, the player it is attached to.
## Walks up from the rig because it is built before the controller resolves its player.
## Safe to call again; a duplicate exclusion is ignored. Why it matters: docs/rationale.md.
func exclude_own_body() -> void:
	if arm == null:
		return

	var node: Node = get_parent()

	while node != null:
		var body := node as CollisionObject3D

		if body != null:
			arm.add_excluded_object(body.get_rid())

			if fade != null:
				fade.add_excluded_object(body.get_rid())

		node = node.get_parent()


## Swaps the shoulder the camera sits over.
## On the state so a rewind does not undo a player's choice and a spectator sees the same side.
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


## Where the camera actually is, after the boom has pulled it in.
## What a shot should be traced from, not the muzzle (which can be behind cover while the player
## looks at the target); games then correct from there.
func camera_transform() -> Transform3D:
	return camera.global_transform if camera != null else global_transform


## Where the camera is looking, as a point far along its forward axis.
func aim_point(distance: float = 1000.0) -> Vector3:
	var t := camera_transform()
	return t.origin - t.basis.z * distance


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"tps camera: %.2f of %.2f m arm, shoulder %+.2f, aim %.2f" % [
			arm.get_hit_length() if arm != null else 0.0,
			arm.spring_length if arm != null else 0.0,
			arm.side_offset if arm != null else 0.0,
			_aim,
		]
	])
