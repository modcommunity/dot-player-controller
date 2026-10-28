extends Node3D

## Shared fixtures, counters and assertions for the physics-body surf self-test.

const STEP := 1.0 / 128.0


var _passed := 0


var _failed := 0


var _failures := PackedStringArray()


var _entered := 0


var _completed := 0


var _t: DotFpsTunables


func _tunables() -> DotFpsTunables:
	var t := DotFpsTunables.with_profile("legacy")
	t.auto_hop = true
	t.bhop_speed_cap_scale = 0.0
	t.max_speed = 7.0
	t.air_accelerate = 100.0
	t.max_air_wish_speed = 1.0
	t.gravity = 20.0
	t.friction = 6.0
	t.max_slope_angle = 46.0
	return t


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)




func _normal_for(angle: float) -> Vector3:
	var r := deg_to_rad(angle)
	return (Vector3.UP * cos(r) + Vector3.FORWARD * sin(r)).normalized()


## A solid whose TOP face is the plane through the origin tilted [param angle].
## A real box, because this file uses the collision the games use and Godot has no half-space collider.
func _add_ramp(angle: float, size: float = 200.0) -> StaticBody3D:
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, size * 0.2, size)
	cs.shape = box
	sb.add_child(cs)
	sb.transform = Transform3D(
		Basis.from_euler(Vector3(-deg_to_rad(angle), 0.0, 0.0)),
		-_normal_for(angle) * (size * 0.1)
	)
	add_child(sb)
	return sb


func _add_floor(y: float) -> StaticBody3D:
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 10.0, 200.0)
	cs.shape = box
	sb.add_child(cs)
	sb.position = Vector3(0.0, y - 5.0, 0.0)
	add_child(sb)
	return sb


func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame


func _settle() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame


## Positive means the capsule's surface is PAST the ramp face by this many metres.
func _penetration(feet: Vector3, normal: Vector3) -> float:
	var centre := feet + Vector3.UP * (_t.stand_height * 0.5)
	return DotFpsBody.capsule_support(normal, _t.stand_height, _t.radius) - normal.dot(centre)


## A state placed clear of the ramp face by [param above] metres.
func _on_ramp(normal: Vector3, z: float, above: float) -> DotFpsState:
	var s := DotFpsState.new()
	var support := DotFpsBody.capsule_support(normal, _t.stand_height, _t.radius)
	# Solve for the feet height that puts the capsule `above` clear of the face.
	var centre_y := (support + above + normal.z * z * -1.0 * 0.0) / normal.y
	centre_y = (support + above - normal.z * z) / normal.y
	s.position = Vector3(0.0, centre_y - _t.stand_height * 0.5, z)
	s.mode = DotFpsState.Mode.AIR
	return s


## A slab like game-playground's long bank: 20 x 1 x 40 m, rolled [param roll] about its
## length so its +X edge is high, then pitched [param pitch] down toward -Z. Its top
## face's near edge runs through the origin. Returns the basis.
func _add_bank(roll: float, pitch: float, length: float) -> Basis:
	var basis := Basis(Vector3.RIGHT, -deg_to_rad(pitch)) * Basis(Vector3.BACK, deg_to_rad(roll))
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 1.0, length)
	cs.shape = box
	sb.add_child(cs)
	sb.transform = Transform3D(basis, basis * Vector3(0.0, -0.5, -length * 0.5))
	add_child(sb)
	return basis


## One rider down a bank and off its far end, holding into the face. Returns the worst
## single-tick speed loss as a fraction of the speed before it, and the speed 2 m past
## the edge (or -1 if the rider never got there).
func _ride_off_the_end(pitch: float, across: float, speed: float) -> Vector2:
	await _clear()
	var length := 40.0
	var basis := _add_bank(56.0, pitch, length)
	await _settle()

	var normal := basis * Vector3.UP
	var far_z := (basis * Vector3(0.0, 0.0, -length)).z
	var motor := DotFpsMotor.new(_tunables(), DotFpsPhysicsBody.for_node(self))
	var s := DotFpsState.new()
	var support := DotFpsBody.capsule_support(normal, _t.stand_height, _t.radius)
	var centre := basis * Vector3(across, 0.0, -5.0) + normal * (support + 0.03)
	s.position = centre - Vector3.UP * (_t.stand_height * 0.5)
	s.mode = DotFpsState.Mode.AIR
	s.velocity = (basis * Vector3.FORWARD) * speed

	var hold := DotFpsCommand.new()
	hold.move = Vector2(1.0, 0.0)

	var worst := 0.0
	var past := -1.0
	for _i in range(1024):
		var before := s.velocity.length()
		motor.simulate(s, hold, STEP)
		if before > 1.0:
			worst = maxf(worst, 1.0 - s.velocity.length() / before)
		if s.position.z < far_z - 2.0:
			past = s.velocity.length()
			break
	return Vector2(worst, past)


## Capsules resting a hair off a 52 degree slab, at the spots the engine answers wrongly.
func _resting_on_slab(normal: Vector3, support: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in 400:
		var gap := (i % 20) * 0.0001 - 0.0005
		var p := Vector3((i / 20) * 0.37 - 3.0, 0.0, ((i * 7) % 13) * 0.3 - 2.0)
		p -= normal * normal.dot(p)
		out.append(p + normal * (support + gap))
	return out


## A wall whose face is z = 0 (solid behind, z < 0), and a door panel 6 cm thick hinged in
## the wall's middle and swung 100 degrees, so the panel and the wall's face meet at 80
## degrees: the shape of game-hide-n-seek's school fire door left open.
func _add_wall_and_open_door() -> void:
	_add_floor(0.0)
	var wall := StaticBody3D.new()
	var wall_shape := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3(10.0, 3.0, 0.3)
	wall_shape.shape = wall_box
	wall.add_child(wall_shape)
	wall.position = Vector3(-5.0, 1.5, -0.15)
	add_child(wall)

	var panel := StaticBody3D.new()
	var panel_shape := CollisionShape3D.new()
	var panel_box := BoxShape3D.new()
	panel_box.size = Vector3(1.37, 2.282, 0.06)
	panel_shape.shape = panel_box
	panel.add_child(panel_shape)
	var turn := Basis(Vector3.UP, deg_to_rad(-100.0))
	panel.transform = Transform3D(turn, Vector3(0.0, 1.15, -0.15) + turn.x * 0.685)
	add_child(panel)


## Two slabs leaning 40 degrees from upright, so each broad face is a 50 degree surf
## face, crossing to make a V whose crease runs level along Z at x = [param x0]: the
## geometry of game-g2gfast's stages bonus, in metres.
func _add_crease(x0: float) -> void:
	var unit := 0.01905
	for side: float in [1.0, -1.0]:
		var sb := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(64.0, 1536.0, 2560.0) * unit
		cs.shape = box
		sb.add_child(cs)
		sb.transform = Transform3D(
			Basis(Vector3.FORWARD, deg_to_rad(side * 40.0)),
			Vector3(x0 + side * 384.0 * unit, 320.0 * unit, 0.0)
		)
		add_child(sb)


func _crease_tunables() -> DotFpsTunables:
	var t := DotFpsTunables.with_profile("legacy")
	t.max_speed = 4.7625
	t.air_accelerate = 1000.0
	t.max_air_wish_speed = 0.5715
	t.gravity = 15.24
	t.auto_hop = true
	t.stand_height = 1.3716
	t.radius = 0.3048
	t.step_height = 0.3429
	t.max_slope_angle = 45.57
	return t


## Rides the crease from [param start] for [param ticks] ticks and returns
## [distance along -Z, longest run of ticks frozen with speed, crease legs].
func _ride_crease(start: DotFpsState, ticks: int) -> Array:
	var motor := DotFpsMotor.new(_crease_tunables(), DotFpsPhysicsBody.for_node(self))
	var s := start.duplicate_state()
	var command := DotFpsCommand.new()
	command.move = Vector2(0.0, 1.0)
	var frozen := 0
	var longest := 0
	for _i in range(ticks):
		var before := s.position
		motor.simulate(s, command, STEP)
		if s.position.distance_to(before) < 1e-6 and s.velocity.length() > 1.0:
			frozen += 1
			longest = maxi(longest, frozen)
		else:
			frozen = 0
	return [start.position.z - s.position.z, longest, motor.crease_leg_ticks]


## Replays one recorded input log (walk, strafe, turn, jump, crouch) over a steep ramp beside a floor,
## once as the motor always answers and once with [member DotFpsMotor.static_world] reusing probes.
## The two must end on the same bits every tick, and the second must ask the physics server fewer questions.
func _replay_log(static_world: bool) -> Array:
	var body := DotFpsPhysicsBody.for_node(self)
	var motor := DotFpsMotor.new(_tunables(), body)
	motor.static_world = static_world
	var s := _on_ramp(_normal_for(60.0), 6.0, 0.05)
	s.velocity = Vector3(6.0, 0.0, 0.0)
	var seed := 12345
	var command := DotFpsCommand.new()
	var digest := 0
	for tick in range(1200):
		seed = (seed * 1103515245 + 12345) & 0x7fffffff
		if tick % 8 == 0:
			command.move = Vector2(float((seed >> 3) % 3 - 1), float((seed >> 5) % 3 - 1))
			command.yaw = float((seed >> 7) % 628) * 0.01 - 3.14
		command.set_button(DotFpsCommand.BUTTON_JUMP, (seed >> 11) % 40 == 0)
		motor.simulate(s, command, STEP)
		digest = hash([digest, s.position, s.velocity, s.mode, s.ground_normal])
	return [s.position, s.velocity, s.mode, digest, body.query_count]
