# Rationale moved out of code comments

Long reasoning that used to sit above the code, kept here so the code carries one-line docs. Each section names the file it came from.

## DotPlayerBodyRules (core/dot_player_body_rules.gd)

Usage, on every machine: set the player's mask with `world.body_rules.mask(physics.collision_mask(&"player"), physics.layer_mask(&"player"))`, and once the body is built call `world.body_rules.apply_hull(player, tunables.stand_height, tunables.radius)`.

**Both halves, or nothing changes.** The family's player bodies carry no collision shape: the motor sweeps a capsule of its own and the hitboxes are analytic, so a mask with the player layer in it hits nothing. `apply_hull` gives the body a standing capsule on its own layer, which its own controller excludes (it excludes its body) and every other player's sweep stops at. It stays standing height when its owner crouches: a crouched player is not something to walk over.

**Why solid by default.** dot-physics' shooter layout leaves players out of each other's mask, which is the competitive genre's choice: nobody blocks a doorway. The first play test (2026-10-11) showed the other side of it in every game with bots: a bot walks into the player and its face fills the first-person screen, because nothing stops two bodies sharing one place. Solid bodies keep heads at least two radii apart; dot-core's `DotCameraFade` hides whatever still gets inside the near plane.

**It is part of the simulation, so it replicates.** A client predicts its own player against the others' capsules where it draws them, which can disagree with the server by a few centimetres when two players lean on each other; the reconcile corrects it. A server that wants the genre's pass-through sets 0.

Two bodies that start overlapping (a shared spawn, a teleport) are never stuck: the cast ignores what it starts inside, and `apply_to` tells the controller every other question ignores the players' layer, so they walk apart, or through, and are solid once clear. Without that second half both pushed into each other's hull and stood still.

## DotTpsCameraRig (tp/nodes/dot_tps_camera_rig.gd)

The camera is most of what makes third person work, and the shoulder offset is most of the camera: a camera on the character's centre line puts the character between the player and whatever they are shooting at; offsetting it sideways is why a third-person shooter can have a crosshair that means something. The rig is built in code because a scene is a thing a game has to merge when this addon changes, and the tree is five nodes:

```
DotTpsCameraRig          moved to the character, yaw applied here
  DotCameraBoom          pitch, the shoulder offset and collision (dot-core)
    Marker3D             where the boom put the camera
      Camera3D
        DotCameraFade    characters between the camera and the rig fade
```

**A DotCameraBoom, not a SpringArm3D.** The spring arm cast a ray and snapped to its hit; the boom sweeps a sphere along the line to the shoulder point and eases in ahead of an obstacle (dot-core's docs/camera.md). The shoulder is part of that line: a Marker3D offset sideways after the arm's cast put the camera through any wall the shoulder was against.

**exclude_own_body.** The rig hangs off the player, so the arm's cast starts inside the player's own collider. The boom's sweeps ignore a shape they start in, so today this is belt and braces for the arm; it is what keeps the player's own body off the fade's list. A `SpringArm3D` excludes nothing unless told, so on a third-person game whose player is a `CharacterBody3D` the arm collides on its first millimetre and collapses to the margin: the camera sits inside the character's head at every distance with every tunable reading as configured. It went unnoticed because `tps_selftest` builds no physics world, so its arm collides with nothing and reports the full length. It walks up rather than taking the body as an argument because the rig is built before the controller has resolved its player.

## DotFpsSurface.push (fp/core/dot_fps_surface.gd)

It competes with friction, and friction wins by default. Ground friction is applied as though the player were moving at least `DotFpsTunables.stop_speed`, so a push below `stop_speed * friction * friction_scale` (24 m/s² with the shipped defaults) cannot move a standing player at all, and one just above it produces a crawl. A conveyor that visibly moves someone wants a value several times that, or a low `friction_scale` to go with it. The equilibrium speed is `push / (friction * friction_scale)` once that speed exceeds `stop_speed`.

`from_physics`: the top speed comes down with `dampening`, the extra velocity a material takes off on contact: 1 - 0.15 per unit, never under 0.4 (mud 2.5 -> 0.63, sand 1.2 -> 0.82, snow 0.8 -> 0.88). Ice keeps its top speed, which is what makes it ice and not mud. `jump_scale` carries over (rubber 1.8, mud 0.8).

## DotFpsAdminModifiers (fp/core/dot_fps_admin_modifiers.gd)

Usage: `controller.admin_abilities = true` on the server and the client, then `DotFpsAdminModifiers.set_noclip(controller, true)` / `set_speed(controller, 2.0)` server side.

**Why modifiers, and not a flag or a tunable.** Everything here is decided on the server and has to be simulated on the owning client too, because the client predicts its own movement. A server that changed a tunable, or set `DotFpsState.mode` to NOCLIP, would be simulating a player the client is not: the client's replay runs its own tunables and its own noclip gate, disagrees on every tick, and is corrected on every snapshot, which is rubber-banding. The active modifier set is already in `DotFpsState`, already replicated by `DotFpsNetSync` as a mask, and already restored by a rewind, so a modifier reaches the client's prediction with no new wire field.

**The values are a ladder, not a dial.** A modifier's definition is configuration both machines hold and only its membership travels, so a multiplier the server made up at runtime is one the client has never heard of. `set_speed` and `set_gravity` pick the nearest registered step and say which one; an admin who typed 2.2 is told they got 2. Adding a step is adding a number to `SPEED_STEPS` on every machine at once.

**Registration is part of the wire contract.** `register` must run on every machine, in the same order relative to a game's own modifiers, which is why `DotFpsController.admin_abilities` does it straight after `_register_extensions`, and why a game should turn it on for every player rather than only for the ones an admin has touched.

## DotFpsMoveMode (fp/motion/dot_fps_move_mode.gd)

Ground, air and noclip are built into `DotFpsMotor` because every first-person game has them and they are what the tunables describe. Everything else is a game's own decision about feel, and the previous answer, "fork the motor", was the wrong one.

```gdscript
class LadderMode extends DotFpsMoveMode:
    func _name() -> StringName:
        return &"ladder"

    func _simulate(state, command, delta, motor) -> void:
        var up := command.move.y * motor.tunables.max_speed * 0.6
        state.velocity = Vector3(0.0, up, 0.0)
        motor.move_and_slide(state, delta)
        if not still_on_ladder(state):
            motor.set_mode(state, DotFpsState.Mode.AIR)

var ladder := motor.register_mode(LadderMode.new())
motor.set_mode(state, ladder)
```

**The determinism contract applies exactly as it does to the motor.** A mode runs inside client-side prediction and the server's authoritative tick, and a replay re-runs it. It may not read the keyboard, the wall clock, an unseeded random stream or a node's transform; anything it needs to remember between ticks belongs in `DotFpsState`, not on the mode object, which every player using it shares and a rewind does not restore. `DotFpsMotor` exposes `accelerate`, `move_and_slide`, `probe` and the surface and modifier aggregates.

## DotFpsSwimMode (fp/motion/dot_fps_swim_mode.gd)

**Water is data, not an area.** `volumes` is a list of axis-aligned boxes the game hands over (from its map), and every question is a containment test against it: an `Area3D`'s overlap signals arrive after the physics step, on the main loop, and a client replaying ten ticks of prediction cannot ask an area where it WAS. A box list can be asked anything, any number of times, and gives both ends the same answer. Entering is the game's call, once a tick (`update`); leaving is the mode's own: the moment the waist is out of every volume it hands the player to AIR. Both read only `volumes` and the state.

```gdscript
var swim := DotFpsSwimMode.new()
swim.volumes = map.water_boxes()
swim_id = controller.motor.register_mode(swim)
# every tick, after the move:
swim.update(controller.motor, controller.state)
```

`idle_sink_speed` above 0 is what the competitive shooters' water does (60 units/s) and what a timer map built for them expects.
