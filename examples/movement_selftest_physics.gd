extends "res://examples/movement_selftest_base.gd"

## The physics-server sections of the movement self-test.

## The real [DotFpsBody], against the real physics server.
##
## The walkable slope again, against real collision and a real capsule, with the crest a
## ramp has in a level: a wedge up to a plateau. The capsule's rounded bottom and Godot's
## sweep are what a game walks on; the flat body is a box and answers analytically.
func _test_physics_slope() -> void:
	_section("walkable slope, physics body")

	var world := Node3D.new()
	add_child(world)

	var length := 12.0
	var rise := length * tan(deg_to_rad(20.0))

	var add_static := func(shape: Shape3D, at: Vector3) -> void:
		var b := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		cs.shape = shape
		b.add_child(cs)
		b.position = at
		world.add_child(b)

	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(40.0, 1.0, 80.0)
	add_static.call(floor_box, Vector3(0.0, -0.5, 0.0))

	# Rises toward -z from z = 0 to z = -length.
	var wedge := ConvexPolygonShape3D.new()
	wedge.points = PackedVector3Array([
		Vector3(-4.0, 0.0, 0.0), Vector3(4.0, 0.0, 0.0),
		Vector3(-4.0, 0.0, -length), Vector3(4.0, 0.0, -length),
		Vector3(-4.0, rise, -length), Vector3(4.0, rise, -length),
	])
	add_static.call(wedge, Vector3.ZERO)

	var plateau := BoxShape3D.new()
	plateau.size = Vector3(8.0, rise, 10.0)
	add_static.call(plateau, Vector3(0.0, rise * 0.5, -length - 5.0))

	await get_tree().physics_frame
	await get_tree().physics_frame

	var body := DotFpsPhysicsBody.new()
	if not _check(body.bind(world).ok, "the physics body binds to the slope world"):
		world.queue_free()
		return

	var t := _tunables()
	var motor := DotFpsMotor.new(t, body)
	var s := DotFpsState.new()
	s.position = Vector3(0.0, 0.0, 2.0)
	s.mode = DotFpsState.Mode.GROUND
	for _i in range(4):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	var airborne := 0
	var above_plateau := 0.0

	for _i in range(150):
		motor.simulate(s, _command(1.0), STEP)
		if not s.is_grounded():
			airborne += 1
		if s.position.z < -length:
			above_plateau = maxf(above_plateau, s.position.y - rise)

	_check(
		s.position.z < -length - 2.0 and absf(s.position.y - rise) < 0.05,
		"a player walks up a real 20-degree ramp onto the plateau at its top",
		"at %s, plateau %.2f" % [s.position, rise]
	)
	_check(airborne <= 2, "grounded all the way", "%d airborne ticks of 150" % airborne)
	_check(
		above_plateau < 0.05,
		"and is not thrown off the crest",
		"%.3f m above the plateau" % above_plateau
	)

	world.queue_free()
	_done()


## The crest launch threshold (`crest_launch_speed_scale`), both sides, on the same ramp:
## at the default, a player at running speed walks onto the plateau (the section above);
## with the threshold under their speed they are thrown off the top; at 0 never.
func _test_crest_launch() -> void:
	_section("a fast crest launches, a slow one does not")

	var world := Node3D.new()
	add_child(world)
	var length := 12.0
	var rise := length * tan(deg_to_rad(20.0))
	for spec in [
		[BoxShape3D.new(), Vector3(40.0, 1.0, 80.0), Vector3(0.0, -0.5, 0.0)],
		[BoxShape3D.new(), Vector3(8.0, rise, 10.0), Vector3(0.0, rise * 0.5, -length - 5.0)],
	]:
		var b := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		(spec[0] as BoxShape3D).size = spec[1]
		cs.shape = spec[0]
		b.add_child(cs)
		b.position = spec[2]
		world.add_child(b)
	var wedge := ConvexPolygonShape3D.new()
	wedge.points = PackedVector3Array([
		Vector3(-4.0, 0.0, 0.0), Vector3(4.0, 0.0, 0.0),
		Vector3(-4.0, 0.0, -length), Vector3(4.0, 0.0, -length),
		Vector3(-4.0, rise, -length), Vector3(4.0, rise, -length),
	])
	var wb := StaticBody3D.new()
	var wcs := CollisionShape3D.new()
	wcs.shape = wedge
	wb.add_child(wcs)
	world.add_child(wb)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var body := DotFpsPhysicsBody.new()
	if not _check(body.bind(world).ok, "the physics body binds to the ramp"):
		world.queue_free()
		return

	var thrown := {}
	for scale in [0.5, 0.0]:
		var t := _tunables()
		t.crest_launch_speed_scale = scale
		var motor := DotFpsMotor.new(t, body)
		var s := DotFpsState.new()
		s.position = Vector3(0.0, 0.0, 2.0)
		s.mode = DotFpsState.Mode.GROUND
		for _i in range(4):
			motor.simulate(s, DotFpsCommand.new(), STEP)
		var above := 0.0
		for _i in range(150):
			motor.simulate(s, _command(1.0), STEP)
			if s.position.z < -length:
				above = maxf(above, s.position.y - rise)
		thrown[scale] = above

	_check(float(thrown[0.5]) > 0.1, "with the threshold under their speed, the crest throws them",
		"%.3f m above the plateau" % float(thrown[0.5]))
	_check(float(thrown[0.0]) < 0.05, "and at 0, never", "%.3f m above the plateau" % float(thrown[0.0]))
	_check(is_equal_approx(DotFpsTunables.with_profile("legacy").crest_launch_speed_scale, 1.25), "the default launches only past running speed")

	world.queue_free()
	_done()


## Kerbs of [param heights], [param width] wide, on a 40 m floor, one lane each at x = 3 * index.
## `[kerb-lift-1]`: a kerb just under step_height is climbed whatever the walking pace,
## and a walker held against one just over it stays on the ground.
##
## [b]Both were found by pace, not by height.[/b] 0.40, 0.44 and 0.45 m kerbs were refused
## at exactly 3 m/s while 2.7 and 5 climbed. And a walker pressed against a wall-height
## kerb was lifted out of the ground by `_lift_clear` every six ticks or so, bouncing in
## AIR at the face. That was enough, at 2.7 m/s, to carry them over a 0.46 m kerb.
func _test_physics_kerb_press() -> void:
	_section("kerb climb does not depend on pace, and a wall is leaned on, physics body")

	# One world per height: a 10 m kerb, walked down its middle, which is where the
	# refusals were measured.
	var refused: Array[String] = []
	var bound := 0
	for height in [0.40, 0.44, 0.45]:
		var climb := _kerb_world([height] as Array[float], 10.0)
		add_child(climb)
		await get_tree().physics_frame
		await get_tree().physics_frame
		var body := DotFpsPhysicsBody.new()
		if body.bind(climb).ok:
			bound += 1
			for speed in [2.7, 3.0, 5.0, 7.0]:
				var walk := _walk_kerb(body, 0.0, speed)
				if walk.end_z > -4.0 or walk.on_top < height - 0.05:
					refused.append("%.2f m at %.1f m/s (got to z %.2f, highest over it %.3f)" % [
						height, speed, walk.end_z, walk.on_top])
		climb.queue_free()
	_check(bound == 3 and refused.is_empty(),
		"kerbs of 0.40, 0.44 and 0.45 m are climbed at 2.7, 3, 5 and 7 m/s (step_height 0.45)",
		", ".join(refused))

	var bounced: Array[String] = []
	var walls := 0
	for height in [0.46, 0.5]:
		var wall := _kerb_world([height] as Array[float], 10.0)
		add_child(wall)
		await get_tree().physics_frame
		await get_tree().physics_frame
		var wall_body := DotFpsPhysicsBody.new()
		if not wall_body.bind(wall).ok:
			wall.queue_free()
			continue
		walls += 1
		for speed in [2.7, 3.0, 7.0]:
			var t := _tunables()
			t.step_height = 0.45
			t.max_speed = speed
			var motor := DotFpsMotor.new(t, wall_body)
			var s := DotFpsState.new()
			s.position = Vector3(0.0, 0.0, 1.0)
			s.mode = DotFpsState.Mode.GROUND
			for _i in range(4):
				motor.simulate(s, DotFpsCommand.new(), STEP)
			var air := 0
			var peak := 0.0
			for i in range(360):
				motor.simulate(s, _command(1.0), STEP)
				# Counted once the walker has had two seconds to reach the face.
				if i >= 120:
					peak = maxf(peak, s.position.y)
					if s.mode != DotFpsState.Mode.GROUND:
						air += 1
			if air > 0 or peak > 0.05:
				bounced.append("%.2f m at %.1f m/s: %d of 240 ticks in the air, peak y %.3f, at z %.2f" % [
					height, speed, air, peak, s.position.z])
		wall.queue_free()
	_check(walls == 2 and bounced.is_empty(),
		"a walker held against a 0.46 or 0.5 m kerb for four seconds stays on the ground",
		"; ".join(bounced))
	_done()


## `[bank-hang-1]`: a sweep that grazes a surf bank reports the bank, not the motion's
## own reverse.
##
## [b]Replayed exactly from game-g2gfast[/b], where a bot riding `surf_g2g_intro` bonus
## 1's bank at 254 u/s stopped dead in mid-air and hung there for good. cast_motion
## found a contact at `unsafe`, `get_rest_info` there found none, and the body's
## fallback normal was `-motion`. The motor clips the velocity against it, and a
## velocity parallel to the motion clipped against its reverse is zero. One millimetre
## deeper, the same query reports the bank. The slab, capsule and sweep are that game's
## numbers (a 768 x 32 x 2048 u box banked 60 degrees, 0.01905 m per unit).
func _test_physics_graze_normal() -> void:
	_section("a sweep grazing a bank reports the bank, physics body")
	var world := Node3D.new()
	var slab := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(768.0, 32.0, 2048.0) * 0.01905
	cs.shape = box
	slab.add_child(cs)
	slab.transform = Transform3D(
		Basis(Vector3.FORWARD, deg_to_rad(-60.0)), Vector3(1792.0, 1848.0, -800.0) * 0.01905)
	world.add_child(slab)
	add_child(world)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var body := DotFpsPhysicsBody.new()
	var bank := slab.transform.basis * Vector3.UP
	if _check(body.bind(world).ok, "the physics body binds to the bank"):
		var motion := Vector3(0.004581437, 0.0040886872, -0.038811497)
		var hit := body.sweep(
			Vector3(31.288847, 31.872414, -5.454201), motion, 1.3716, 0.3048)
		_check(
			hit.hit and hit.normal.dot(bank) > 0.999,
			"a capsule grazing a 60-degree bank along its length is told the bank's normal",
			"hit %s, normal %s against the bank's %s (the motion's reverse is %s)" % [
				hit.hit, hit.normal, bank, -motion.normalized()]
		)
	world.queue_free()
	_done()


## `[jumping-into-crate-1]`: a downward probe grazing the side of a box is not a floor.
##
## [b]The geometry is mg-buses-from-hell's, to nine digits.[/b] A column of three 1 m
## crates that had settled about 4 degrees off square, and a runner at the top of a jump
## beside it, 2 cm clear of the top crate's corner. cast_motion reports a contact to the
## ground probe that no rest query along the motion can name, and the sweep's guess for
## that -- the motion's reverse -- is straight UP for a probe going down. The motor
## grounded the runner on the crate's SIDE, they jumped again from there, and went up the
## stack a crate at a time, to 2.98 m of a 3 m face with a 1.15 m jump.
func _test_physics_crate_side() -> void:
	_section("a downward sweep grazing a crate's side is not a floor, physics body")
	var world := Node3D.new()
	# As the engine printed them (`var_to_str`), so they are the crates' exact transforms.
	var crates := [
		"Transform3D(0.99685496, 0.00086547446, 0.07924324, -0.00097104284, 0.99999875, 0.0012936823, -0.07924201, -0.001366562, 0.99685454, -2.0710263, 0.49463606, 19.999973)",
		"Transform3D(0.997621, -0.004241628, 0.06880767, 0.004158334, 0.99999046, 0.0013537237, -0.06881275, -0.0010643778, 0.99762905, -2.0690117, 1.4872793, 19.998213)",
		"Transform3D(0.9971799, -0.0067888154, 0.074740805, 0.0067166705, 0.99997675, 0.0012165847, -0.074747324, -0.0007111445, 0.9972023, -2.0828123, 2.4785988, 20.00043)",
	]
	for written: String in crates:
		var crate := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3.ONE
		cs.shape = box
		crate.add_child(cs)
		crate.transform = str_to_var(written)
		world.add_child(crate)
	add_child(world)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var body := DotFpsPhysicsBody.new()
	if _check(body.bind(world).ok, "the physics body binds to the crates"):
		var hit := body.sweep(
			Vector3(-2.9410343, 1.8324537, 19.915457), Vector3(0.0, -0.023, 0.0), 1.8, 0.35)
		_check(
			not hit.hit or hit.normal.y < 0.7,
			"a capsule beside a crate's side, probing down, is not told it is on a floor",
			"hit %s, normal %s, point %s" % [hit.hit, hit.normal, hit.point]
		)
	world.queue_free()
	_done()


## `[sweep-1]`: a capsule swept sideways into a large wall never ends up inside it.
##
## [b]The floor's problem, turned on its side.[/b] Seeded sweeps of 1 to 12 cm from 0
## to 6 mm off the face of a 4, 40 and 164 m wall. Measured on 4.7.2 against the body
## before this check: cast_motion reported the contact up to 5 cm late on the 40 m
## wall, and on the 164 m wall 33 of 3,000 sweeps saw no wall at all and ended 11 cm
## inside it. Either one is a player walking into a wall and, a few ticks later,
## through it.
func _test_physics_wall_sweep() -> void:
	_section("a sideways sweep never ends inside a large wall, physics body")
	var embedded: Array[String] = []
	var walls := 0
	for size: float in [4.0, 40.0, 164.0]:
		var world := Node3D.new()
		var wall := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(size, size, 1.0)
		cs.shape = box
		wall.add_child(cs)
		wall.position = Vector3(0.0, 0.0, -0.5)   # the face is z = 0
		world.add_child(wall)
		add_child(world)
		await get_tree().physics_frame
		await get_tree().physics_frame
		var body := DotFpsPhysicsBody.new()
		if body.bind(world).ok:
			walls += 1
			var radius := 0.4
			var height := 1.8
			var rng := RandomNumberGenerator.new()
			rng.seed = 11
			var count := 0
			var worst := 0.0
			for _i in range(1000):
				var gap := rng.randf_range(0.0, 0.006)
				var step := rng.randf_range(0.01, 0.12)
				var centre := Vector3(
					rng.randf_range(-size * 0.4, size * 0.4),
					rng.randf_range(-size * 0.4, size * 0.4),
					radius + gap)
				var motion := Vector3(rng.randf_range(-0.02, 0.02), 0.0, -step)
				var hit := body.sweep(centre, motion, height, radius)
				var into := step * (hit.fraction if hit.hit else 1.0) - gap
				if into > 0.0005:
					count += 1
					worst = maxf(worst, into)
			if count > 0:
				embedded.append("%.0f m wall: %d of 1000, up to %.3f m in" % [size, count, worst])
		world.queue_free()
	_check(walls == 3 and embedded.is_empty(),
		"1,000 sideways sweeps into a 4, 40 and 164 m wall each stop at its face",
		"; ".join(embedded))
	_done()


## `[steep-climb-1]`: walking into a face too steep to stand on that leans back does not
## climb it.
##
## Measured on 4.7.2 with these tunables, holding forward into a 3 m block from 1.65 m
## away: at 70 degrees a walker went to AIR at the foot of the face and crawled 2.5 m up
## it, and at 60 went over the top. Two causes, both needed: the capsule's rounded
## bottom touching the face made the ground probe and the snap see the face instead of
## the floor (the quarter probes), and the slide's lift up the face read as leaving
## the ground (dropped on a grounded tick). A sheer face must stay a wall for a jump.
func _test_physics_steep_face_walk() -> void:
	_section("walking into a steep face does not climb it, physics body")
	var climbed: Array[String] = []
	var worlds := 0
	for angle: float in [60.0, 70.0, 80.0, 90.0]:
		var world := Node3D.new()
		var floor_body := StaticBody3D.new()
		var floor_shape := CollisionShape3D.new()
		var floor_box := BoxShape3D.new()
		floor_box.size = Vector3(40.0, 1.0, 40.0)
		floor_shape.shape = floor_box
		floor_body.add_child(floor_shape)
		floor_body.position = Vector3(0.0, -0.5, 0.0)
		world.add_child(floor_body)
		var block := StaticBody3D.new()
		var block_shape := CollisionShape3D.new()
		var block_box := BoxShape3D.new()
		block_box.size = Vector3(6.0, 8.0, 4.0)
		block_shape.shape = block_box
		block.add_child(block_shape)
		block.transform = Transform3D(
			Basis(Vector3.RIGHT, -deg_to_rad(90.0 - angle)), Vector3(0.0, 0.0, -4.0))
		world.add_child(block)
		add_child(world)
		await get_tree().physics_frame
		await get_tree().physics_frame
		var body := DotFpsPhysicsBody.new()
		if body.bind(world).ok:
			worlds += 1
			for jump in [false, true]:
				var motor := DotFpsMotor.new(_tunables(), body)
				var s := DotFpsState.new()
				s.mode = DotFpsState.Mode.GROUND
				for _i in range(4):
					motor.simulate(s, DotFpsCommand.new(), STEP)
				var peak := 0.0
				var airborne := 0
				for i in range(300):
					motor.simulate(s, _command(1.0, 0.0, 0.0,
						DotFpsCommand.BUTTON_JUMP if jump else 0), STEP)
					peak = maxf(peak, s.position.y)
					if not jump and i >= 120 and s.mode != DotFpsState.Mode.GROUND:
						airborne += 1
				var limit := 1.1 if jump else 0.05
				if peak > limit or airborne > 0:
					climbed.append("%.0f deg%s: peak %.2f m, %d ticks off the ground" % [
						angle, " jumping" if jump else "", peak, airborne])
		world.queue_free()
	_check(worlds == 4 and climbed.is_empty(),
		"held against a 60, 70, 80 or 90 degree face, a walker stays on the floor and a jump peaks at a jump",
		"; ".join(climbed))
	_done()


func _kerb_world(heights: Array[float], width: float = 2.5) -> Node3D:
	var world := Node3D.new()
	var specs: Array = [[Vector3(40.0, 1.0, 40.0), Vector3(0.0, -0.5, 0.0)]]
	for i in range(heights.size()):
		specs.append([Vector3(width, heights[i], 0.6), Vector3(i * 3.0, heights[i] * 0.5, -2.3)])

	for spec: Array in specs:
		var b := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = spec[0]
		cs.shape = box
		b.add_child(cs)
		b.position = spec[1]
		world.add_child(b)

	return world


## Walks a standing player at [param speed] from [param z] toward -z along x = [param x],
## step_height 0.45. [code]on_top[/code] is the highest y while over the kerb's footprint
## (-1.0 if never there), [code]peak[/code] the highest y anywhere, [code]end_z[/code]
## where they got to.
func _walk_kerb(body: DotFpsBody, x: float, speed: float, z: float = 1.0) -> Dictionary:
	var t := _tunables()
	t.step_height = 0.45
	t.max_speed = speed
	var motor := DotFpsMotor.new(t, body)
	var s := DotFpsState.new()
	s.position = Vector3(x, 0.0, z)
	s.mode = DotFpsState.Mode.GROUND
	for _i in range(4):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	var on_top := -1.0
	var peak := 0.0
	for _i in range(240):
		motor.simulate(s, _command(1.0), STEP)
		peak = maxf(peak, s.position.y)
		if s.position.z < -2.1 and s.position.z > -2.5:
			on_top = maxf(on_top, s.position.y)
		if s.position.z < -4.0:
			break

	return {"on_top": on_top, "peak": peak, "end_z": s.position.z}


## `[arrive-3]`: a rider crossing a displacement's triangles, a fraction of a degree
## apart, does not hang there with its speed intact.
##
## The seven triangles, the two states and the tunables are game-g2gfast's surf_summit
## stage 3 (`tools/stage_ride.tscn -- surf_summit 3`), where the bot froze at
## (1773, -812, -300) u at 75 u/s for the rest of the ride. A grazing leg ends with the
## capsule exactly touching the face; every sweep from there, even one lifted a skin off
## it, is blocked at the first step of cast_motion's bisection, and the rest query names
## the face underneath, so the plane list sees a duplicate and nothing moves. The mesh is
## copied to nine digits because it is that sensitive: rounded to five, the same states
## ride straight across. Before the fix: 127 of 128 ticks frozen, 0 m covered.
func _test_physics_displacement_crease() -> void:
	_section("crossing a displacement crease, physics body")

	var world := Node3D.new()
	add_child(world)

	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var mesh := ConcavePolygonShape3D.new()
	mesh.set_faces(PackedVector3Array([
		Vector3(34.899600983, -16.444252014, -2.438400030), Vector3(32.994602203, -16.502010345, -4.876800060), Vector3(34.899600983, -14.179647446, -4.876800060),
		Vector3(34.899600983, -16.444252014, -2.438400030), Vector3(34.899600983, -14.179647446, -4.876800060), Vector3(36.804599762, -12.588292122, -2.438400030),
		Vector3(36.804599762, -12.588292122, -2.438400030), Vector3(34.899600983, -14.179647446, -4.876800060), Vector3(36.804599762, -11.991741180, -4.876800060),
		Vector3(32.994602203, -16.502010345, -4.876800060), Vector3(32.994602203, -16.750118256, -7.315199852), Vector3(34.899600983, -14.179647446, -4.876800060),
		Vector3(34.899600983, -14.179647446, -4.876800060), Vector3(32.994602203, -16.750118256, -7.315199852), Vector3(34.899600983, -14.410800934, -7.315199852),
		Vector3(34.899600983, -14.179647446, -4.876800060), Vector3(34.899600983, -14.410800934, -7.315199852), Vector3(36.804599762, -11.991741180, -4.876800060),
		Vector3(36.804599762, -11.991741180, -4.876800060), Vector3(34.899600983, -14.410800934, -7.315199852), Vector3(36.804599762, -13.151485443, -7.315199852),
	]))
	shape.shape = mesh
	ground.add_child(shape)
	world.add_child(ground)

	await get_tree().physics_frame
	await get_tree().physics_frame

	var body := DotFpsPhysicsBody.new()
	if not _check(body.bind(world).ok, "the physics body binds to the displacement"):
		world.queue_free()
		return

	var t := _tunables()
	t.can_noclip = false
	t.max_speed = 4.7625
	t.max_velocity = 66.675
	t.accelerate = 5.0
	t.friction = 4.0
	t.air_accelerate = 1000.0
	t.max_air_wish_speed = 0.5715
	t.gravity = 15.24
	t.stand_height = 1.3716
	t.crouch_height = 1.0287
	t.radius = 0.3048
	t.max_slope_angle = 45.57
	t.step_height = 0.3429
	var motor := DotFpsMotor.new(t, body)

	# The tick before the grazing leg that ends touching, and the tick after it.
	var delta := 1.0 / 128.0
	var frozen := 0
	var covered := 0.0
	for start: Vector3 in [
		Vector3(33.773784637, -15.460395813, -5.714473248),
		Vector3(33.774005890, -15.460265160, -5.714899540),
	]:
		var s := DotFpsState.new()
		s.position = start
		s.velocity = Vector3(0.538090825, 0.520951033, -1.327067018)
		s.mode = DotFpsState.Mode.AIR
		var last := s.position
		for _i in range(64):
			motor.simulate(s, _command(0.0, 1.0, -4.771088958), delta)
			if s.position.distance_to(last) < 1e-5 and s.velocity.length() > 0.1:
				frozen += 1
			last = s.position
		covered += s.position.distance_to(start)

	_check(frozen == 0, "a rider crossing a 0.2-degree crease never hangs with its speed intact",
		"%d of 128 ticks with the position fixed and the velocity not" % frozen)
	_check(covered > 1.0,
		"and gets on across it", "%.3f m covered in two runs of 64 ticks" % covered)

	world.queue_free()
	_done()


## Everything above tests the motor. This tests the query layer the motor asks, which
## is the other half and cannot be exercised without a physics world and a frame for
## it to settle.
func _test_physics_body() -> void:
	_section("physics body")

	var world := Node3D.new()
	add_child(world)

	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(40.0, 1.0, 40.0)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	world.add_child(floor_body)

	var wall := StaticBody3D.new()
	var wall_shape := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3(10.0, 4.0, 1.0)
	wall_shape.shape = wall_box
	wall.add_child(wall_shape)
	wall.position = Vector3(0.0, 2.0, -6.0)
	world.add_child(wall)

	# Two physics frames: one for the bodies to enter the space, one for it to build.
	await get_tree().physics_frame
	await get_tree().physics_frame

	var body := DotFpsPhysicsBody.new()
	var bound := body.bind(world)

	if not _check(bound.ok, "the physics body binds to a world"):
		world.queue_free()
		return

	var t := _tunables()
	var motor := DotFpsMotor.new(t, body)

	var s := DotFpsState.new()
	s.position = Vector3(0.0, 3.0, 0.0)
	s.mode = DotFpsState.Mode.AIR

	for _i in range(180):
		motor.simulate(s, DotFpsCommand.new(), STEP)

	_check(s.is_grounded(), "a player falls onto real collision geometry")
	_check_near(s.position.y, 0.0, 0.05, "and rests on its surface")

	for _i in range(240):
		motor.simulate(s, _command(1.0), STEP)

	_check(
		s.position.z > -6.0,
		"and is stopped by a real wall",
		"z = %.3f" % s.position.z
	)
	_check(
		motor.stuck_ticks == 0,
		"without the slide running out of iterations",
		"%d stuck ticks" % motor.stuck_ticks
	)

	# The overlap query, which is what the standing-up test uses.
	var inside := body.overlaps(
		Vector3(0.0, 2.0, -6.0), t.stand_height, t.radius
	)
	var clear := body.overlaps(
		Vector3(0.0, 2.0, 6.0), t.stand_height, t.radius
	)

	_check(inside, "overlaps() finds geometry the capsule is inside")
	_check(not clear, "and reports clear space as clear")

	world.queue_free()
	_done()
