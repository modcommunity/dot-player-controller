# dot-player-controller

Everything that drives a player: an abstract controller contract with a switch that hands one controller to the next, a first-person movement model (`fp/`, which was `dot-fps-controller`) built to be predicted and replayed, and a third-person controller with an orbit rig (`tp/`).

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to controllers. The reasoning is in [docs/](docs/README.md): open the file for what you are touching.

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/design.md](docs/design.md) | the base contract, the switch, the third-person half, anything outside `fp/` |
| [docs/motor.md](docs/motor.md) | `fp/motion/` or `fp/core/`: determinism, surf and hops, steps and slopes, jump reach, styles, statistics |
| [docs/collision.md](docs/collision.md) | `DotFpsBody`, `DotFpsPhysicsBody`, sweeps, embeds, ramps, ground checks |
| [docs/extending.md](docs/extending.md) | surfaces, modifiers, admin abilities, custom modes, swimming, slide/launch/dash, the plug-in table |
| [docs/wall-movement.md](docs/wall-movement.md) | wall running, wall jumping, the wall slide, their camera roll and their bits in `net_flags` |
| [docs/networking.md](docs/networking.md) | wiring a controller to dot-net, `DotFpsNetSync`, `net_flags`, `render_state` |
| [docs/testing.md](docs/testing.md) | adding a check, or believing a green run |
| [docs/history.md](docs/history.md) | a movement bug that "cannot be happening"; what each fix was and how it looked |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_player_controller/core/` | `DotPlayerIntent` (one tick of intent and its wire form), `DotPlayerLook`, `DotPlayerViewRules` (`mp_forceview`), `DotPlayerBodyRules` (`mp_solidplayers`) |
| `addons/dot_player_controller/nodes/` | `DotPlayerController` (abstract base, five methods), `DotPlayerControllerSwitch` |
| `addons/dot_player_controller/fp/core/` | data: `DotFpsTunables`, `DotFpsCvars` (binds the `sv_*` movement cvars of tunables, swim and ladder to a console and `DotGameMapConfig`), `DotFpsState`, `DotFpsCommand`, styles, surfaces, modifiers, admin modifiers, stats |
| `addons/dot_player_controller/fp/motion/` | the simulation: `DotFpsMotor`, `DotFpsBody` and its flat and physics implementations, `DotFpsMoveMode`, `DotFpsSwimMode`, `DotFpsLadderMode` (boxes as data; the game calls `update` each tick), `DotFpsSimulator` (a second motor a bot runs ahead) |
| `addons/dot_player_controller/fp/nodes/` | `DotFpsController`, `DotFpsSampler`, `DotFpsTouchSampler`, `DotFpsView`, `DotFpsViewMotion` (its motion cues without nodes) |
| `addons/dot_player_controller/fp/net/` | `DotFpsNetSync`: what replicates, at what precision |
| `addons/dot_player_controller/tp/` | `core/` (motor, state, tunables) and `nodes/` (controller, `DotTpsCameraRig` on dot-core's `DotCameraBoom` and `DotCameraFade`) |
| `addons/dot_player_controller/dot_player_controller_api.gd` | the API level (9; was 4 since the body pose on a wall) |
| `examples/` | seven self-test scenes, `sandbox.tscn` (a course to feel the movement out, not a test) |

## Running and testing

- The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)): `--import`, `--check-only` every script, then run every suite.
- **Run all seven suites**: `classic_selftest`, `controller_selftest`, `movement_selftest`, `surf_selftest`, `surf_physics_selftest`, `fps_controller_selftest`, `tps_selftest`. `controller_selftest` is the main scene and is the one a careless check runs alone. All exit non-zero on failure. [testing](docs/testing.md)
- `surf_selftest` and `surf_physics_selftest` are **not alternatives**: the first replaces the very component the worst bug was in. [testing](docs/testing.md#flat-body-and-physics-body)
- Run the check-only pass first: a scene whose script does not parse hangs instead of failing.
- A change to the motor is not done until the first-person games' suites agree too (game-playground, game-g2gfast, game-arena, mg-buses-from-hell, mg-smash-copter and the other `mg-*`).

## Rules that bite

Short forms; the reasoning is in the linked file.

**Structure**

- `fp/motion/` may not reference `fp/nodes/`; `tp/core/` may not reference `tp/nodes/`. That direction keeps each simulation testable without a scene. [design](docs/design.md#dependency-direction)
- Every `class_name` is public API (`DotFps*`, `DotTps*`): never rename one. A game may delete `fp/` or `tp/`; the plugin skips a missing type. [design](docs/design.md#it-was-three-addons)
- Name collisions already paid for: `Btn` not `Button`, `CONTROLLER_CHANNEL` not `CHANNEL`, `transform_3d()` not `transform()`. [design](docs/design.md#three-name-collisions)
- A switch carries position, velocity and view, nothing else. Activate, THEN `adopt_state`, or the reset wipes it. [design](docs/design.md#the-switch)
- Set a controller's `controller_id` before the switch enters the tree; read `active_id()` one frame later. [design](docs/design.md#the-switch)
- `input_enabled = false` still ticks with an empty intent; it is not deactivation. [design](docs/design.md#freezing-is-not-deactivating)

**The first-person simulation**

- The simulation is a pure function of (state, command, delta, world): no `Input`, no wall clock, no unseeded random, no node transform inside `fp/motion/`. [motor](docs/motor.md#the-one-idea)
- Everything read between ticks lives in `DotFpsState`, or a rewind does not restore it. Nothing is stored on a `DotFpsMoveMode` instance. [motor](docs/motor.md#the-one-idea)
- Collision goes through `DotFpsBody`, never `move_and_slide` (it keeps state a rewind does not restore). [collision](docs/collision.md#why-collision-goes-through-dotfpsbody)
- A face steeper than `max_slope_angle` never grounds; that is what surf is. [motor](docs/motor.md#surf-and-hops)
- A duplicate plane is satisfied, not stuck; a full plane list is a real corner; three or more planes still go along any crease that leaves the rest; a duplicate leg in a wedge goes along the crease of the named face and the one a rest query a skin off it finds (`_leave_crease`), before anything else is tried; a duplicate leg that still goes nowhere is split, vertical first (`_split_leg`). [motor](docs/motor.md#surf-and-hops)
- "Moving away" from the ground is measured along the floor normal (`LEAVING_SPEED`), not +Y. [motor](docs/motor.md#slopes-steps-and-kerbs)
- A step never lifts more than `step_height` above the floor it left; a kerb a centimetre over is a wall. [motor](docs/motor.md#slopes-steps-and-kerbs)
- `crest_launch_speed_scale` (1.25 x `max_speed`) is the line between being laid over a crest and thrown off it; 0 restores always-grounded. [motor](docs/motor.md#slopes-steps-and-kerbs)
- Ask `DotFpsTunables.jump_reach(rise)` / `climb_limit()` / `jump_airtime(rise)` (or the static `reach_for` / `airtime_for`) when sizing a gap; never write the airtime back to the height you left. [motor](docs/motor.md#how-far-a-jump-goes)
- `DotFpsStyle.apply_to` derives from the base tunables, never the previous style; `filter_command` runs on both machines, idempotently. [motor](docs/motor.md#styles)
- Statistics are counted per simulated tick and never during a replay. [motor](docs/motor.md#statistics)
- A simulator runs on copies: `copy_for_simulation()` of the body, a duplicate of the tunables; it never touches the live motor, body or controller, and does not follow a later style (build a new one). [motor](docs/motor.md#simulating-ahead)

**Collision**

- `cast_motion` ignores anything the shape already overlaps, misses a contact that ends exactly touching, and is imprecise in proportion to its length; every recovery in `DotFpsPhysicsBody` and the motor exists for one of those. Do not remove one because it looks redundant. [collision](docs/collision.md)
- A grounded player is kept a skin clear of the floor (`_keep_skin`); the ground snap runs only when the player has left the ground. [collision](docs/collision.md#skins-and-snaps)
- A downward graze is not a floor (`_downward_ray_fallback`); a steep hit is re-asked inside the footprint (`_quadrant_floor`). [collision](docs/collision.md#steep-faces-and-grazes)
- The end-of-tick ground check is skipped only on a proven fixed point (`_categorise_ground_settled`); never reuse a query answer across ticks, the world moves between them. [collision](docs/collision.md#what-a-tick-costs-and-the-one-repeat-it-skips)
- A rest normal pointing into the face is turned round only if the turned-round position is clear (`_turn_round_flipped`). [collision](docs/collision.md#a-normal-that-points-into-the-face)
- Set the collision mask with `DotFpsController.set_collision_mask(mask)`; a plain write to `tunables.collision_mask` reverts at the next style. [extending](docs/extending.md#the-collision-mask)
- Other players' hulls are a pass-out layer (`set_pass_out_layers`): stopped at, never held inside; the cast skips them while overlapping, every rest/overlap question always. [collision](docs/collision.md#other-players-a-layer-a-player-may-walk-out-of)

**Extending and the wire**

- `register_modifier` order is the wire contract: same order on every machine, in `_register_extensions`, never conditionally. The active set is sorted by index. [extending](docs/extending.md#modifiers)
- Admin abilities are modifiers, and `admin_abilities` must be on for every player on every machine. Never set `state.mode = NOCLIP` or a tunable from the server. [extending](docs/extending.md#admin-abilities)
- A custom mode goes in `DotFpsController.extra_modes`, which survives a style; one registered by hand on the motor does not. [extending](docs/extending.md#custom-modes-and-swimming)
- Water is a list of boxes the game hands over, never an `Area3D`. [extending](docs/extending.md#custom-modes-and-swimming)
- Slide, launch and dash are off by default; their timers ride in `net_flags`, and their signals are not emitted during a replay. [extending](docs/extending.md#slide-launch-and-dash)
- Wall run, wall jump and wall slide are off by default and probe nothing while off; a run never writes the horizontal velocity and eases the vertical, never sets it; a run keeps the wall beside its velocity over a nearer one behind. [wall-movement](docs/wall-movement.md)
- `net_flags` is full at 64 bits since the wall fields; anything else that must replicate needs a new property. [wall-movement](docs/wall-movement.md#what-the-wire-carries)
- dot-net is never named: `DotFpsCommand` and `DotFpsNetSync` reach it by method name. `_net_state_applied` restores the whole state; `delta` is the tick; compare `fingerprint()` at connect. [networking](docs/networking.md)
- `render_state()` needs the host to step once per physics frame at `tick_rate`; a connected client sets `render_clock` (dot-net's clock, by name) so a slip is drawn through; never call it for a `Drive.REMOTE` player. [networking](docs/networking.md#rendering-between-ticks)
- Forward EVERY input event to `DotFpsSampler.handle_event`, not only mouse motion: a wheel tick on jump reaches a command only through its latch. [networking](docs/networking.md#rendering-between-ticks)
- Draw the owner's view from `DotFpsSampler.look_now()` once a frame, not from the state's angles, or a frame with no tick in it does not turn. [networking](docs/networking.md#rendering-between-ticks)
- A camera cue on an event (a landing) kicks a velocity or eases toward a target, never sets the eye on that frame; the cues live in `DotFpsViewMotion`, which a game writing its own camera calls rather than copies. [history](docs/history.md)
- A field added to `DotFpsViewMotion` is also exported on `DotFpsView` and forwarded in `_sync_motion`; `fps_controller_selftest` checks every field by reflection. [extending](docs/extending.md)
- The rig's arm is dot-core's `DotCameraBoom`, placed by `follow()` (`auto_place` off), with the shoulder as the boom's `side_offset` so the sweep covers it; never a `SpringArm3D` again. `tps_selftest`'s "against a wall" section is the only one with a level; the rest still collides with nothing. [design](docs/design.md#the-third-person-half)

**Server rules a game binds**

- `DotPlayerBodyRules.pair_fn` (`(a, b) -> bool`, dot-team's `DotTeamBlockRules.blocks`) says which pairs stop at each other; `apply_exceptions(entries)` turns it into `DotFpsController.set_extra_excludes` on every machine, and again on `changed`. `mp_solidplayers` 0 overrules it. [collision](docs/collision.md#pairs-that-pass-through)

- `mp_forceview` (`DotPlayerViewRules`): 0 the player's choice, 1 first person only, 2 third person only; bound REPLICATED by the server module and followed by the client through its link; a client never decides it. [design](docs/design.md#the-view-and-solid-players)
- `mp_solidplayers` (`DotPlayerBodyRules`, 1 by default): apply it with `apply_to(controller, base, player_layers)` wherever a player's collision mask is set AND `apply_hull()` on the body (players carry no shape of their own, so a mask alone hits nothing), on every machine, or prediction disagrees with the server. [design](docs/design.md#the-view-and-solid-players)
