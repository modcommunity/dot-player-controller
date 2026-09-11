class_name DotTpsController
extends DotPlayerController

## Third-person movement, as a [DotPlayerController] the switch can hand a player to.
##
## Five overrides and a camera. The movement is [DotTpsMotor]'s, the camera is
## [DotTpsCameraRig]'s, and what this adds is the binding: the body, the state, and the
## handover that lets a player change from first person to third without stopping dead
## in mid-air.

const TPS_CHANNEL := "player.tps"

## The character left the ground, or landed. For an animation driver that wants an edge.
signal grounded_changed(on_floor: bool)

@export var tunables: DotTpsTunables = null

## Whether to build and drive a camera rig. Off on a server, and for a remote player.
@export var owns_camera: bool = true

## Whether the body's rotation follows the state's facing.
##
## On. Off for a game whose visual model is a separate node that rotates itself — which
## is the usual arrangement once there is an animation blend tree in the way.
@export var rotate_body: bool = true

var state: DotTpsState = null

var rig: DotTpsCameraRig = null

var _body: CharacterBody3D = null
var _was_on_floor: bool = true


func _ready() -> void:
	if tunables == null:
		tunables = DotTpsTunables.new()

	if state == null:
		state = DotTpsState.new()

	if controller_id == &"":
		controller_id = &"tp"

	super()


func _on_activated() -> void:
	_ensure_rig()

	if rig != null:
		rig.set_active(true)


func _on_deactivated() -> void:
	if rig != null:
		rig.set_active(false)


func _process(delta: float) -> void:
	if not active or rig == null:
		return

	rig.follow(state, _read_transform().origin, delta)


# --- The simulation ---------------------------------------------------------

func _apply_intent(intent: DotPlayerIntent, delta: float) -> void:
	var body := character_body()

	if body == null:
		return

	if intent != null:
		# The look delta is applied here rather than by a sampler, so that a replayed
		# command produces the same camera angles as the live one did. See the note on
		# rewinds in DotTpsState.
		DotTpsMotor.look(state, intent.look, tunables)

		if intent.just_pressed(DotPlayerIntent.Btn.ABILITY_3) and rig != null:
			rig.swap_shoulder(state)

	var on_floor := body.is_on_floor()
	body.velocity = DotTpsMotor.step(state, intent, tunables, delta, on_floor)
	body.move_and_slide()
	state.velocity = body.velocity

	var grounded := body.is_on_floor()

	if grounded != _was_on_floor:
		_was_on_floor = grounded
		grounded_changed.emit(grounded)

	if rotate_body:
		body.rotation.y = state.facing


# --- The DotPlayerController contract ---------------------------------------

func _read_transform() -> Transform3D:
	var body := character_body()
	return body.global_transform if body != null else Transform3D.IDENTITY


func _write_transform(to: Transform3D) -> void:
	var body := character_body()

	if body == null:
		return

	body.global_transform = to
	state.facing = to.basis.get_euler().y
	state.target_facing = state.facing


func _read_velocity() -> Vector3:
	return state.velocity


func _write_velocity(v: Vector3) -> void:
	state.velocity = v

	var body := character_body()

	if body != null:
		body.velocity = v


func _read_yaw() -> float:
	return state.yaw


func _read_pitch() -> float:
	return state.pitch


func _write_angles(yaw: float, pitch: float) -> void:
	state.yaw = wrapf(yaw, -PI, PI)
	state.pitch = clampf(
		pitch, tunables.pitch_min_radians(), tunables.pitch_max_radians()
	)


func eye_transform() -> Transform3D:
	# The camera, when there is one: in third person the player's viewpoint is not
	# anywhere near their head, and a weapon or a trace that used the head would point
	# somewhere the player is not looking.
	if rig != null:
		return rig.camera_transform()

	return _read_transform()


# --- Reading ----------------------------------------------------------------

func character_body() -> CharacterBody3D:
	if _body != null and is_instance_valid(_body):
		return _body

	if not is_bound():
		return null

	_body = player().body() as CharacterBody3D

	if _body == null:
		DotLog.warn(TPS_CHANNEL, "no CharacterBody3D for this player", {
			"player": player().player_key,
		})

	return _body


func is_on_floor() -> bool:
	return state.on_floor


func speed() -> float:
	return state.speed()


## The motion description an animation driver wants, without it needing to know this
## controller exists.
func motion() -> Dictionary:
	return {
		"speed": state.speed(),
		"vertical": state.velocity.y,
		"on_floor": state.on_floor,
		"crouched": state.crouched,
		"facing": state.facing,
		"alive": player().is_alive() if is_bound() else true,
	}


func describe_lines() -> PackedStringArray:
	var out := super()
	out.append("  " + state.describe())

	if rig != null:
		out.append_array(rig.describe_lines())

	return out


func _ensure_rig() -> void:
	if not owns_camera or rig != null:
		return

	if is_bound() and not player().is_local:
		# A server holding thirty players does not want thirty cameras, and neither
		# does a client watching twenty-nine other people.
		return

	rig = DotTpsCameraRig.new()
	rig.name = "CameraRig"
	rig.tunables = tunables
	add_child(rig)
