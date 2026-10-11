# Wall running, wall jumping and the wall slide

What the fast movement shooters do with a wall: run a few steps along it, jump off it, and ride it down. All three are in `DotFpsMotor`, all off by default, and all predicted and replayed like the rest of the motor. The code is the `# --- Walls` section of `fp/motion/dot_fps_motor.gd`; the knobs are the "Wall running" and "Wall jumping" groups of `DotFpsTunables`.

## Off by default, and how far "off" goes

`wall_run_enabled` and `wall_jump_enabled` are false and `wall_slide_speed` is 0. With all three off the motor does not even probe for a wall, and nothing it computes changes: `movement_selftest`'s "wall movement off is byte-identical to before it" hashes 600 ticks of steps, walls, crouches and jumps against the hash the motor produced before any of this was written. The new numbers are still in `fingerprint()`, because two peers that disagree about them disagree about where a player beside a wall goes.

## The wall is asked for, never remembered

`_wall_contact` sweeps the capsule `wall_reach` sideways each tick and takes the nearest face within `wall_max_angle_from_vertical` of vertical. Six directions: either side of the velocity (where a run keeps its wall) and the view's four flat directions (where a player touching a wall from a standstill has it). It runs only when something will use the answer: a run in progress, a run that could start, a buffered jump press, or a fall the wall slide could catch.

**A run keeps the wall beside it.** While running, a hit from the two sideways probes wins over a nearer one from the view's directions. A player who has just jumped off a ledge's end onto the wall beside it has that end face a hand behind them, and the uncrouch after a slide-jump drops the feet past its top; nearest-wins took that face, whose speed "along" is nothing, and the run ended four ticks in. `movement_selftest`'s "a run just past a ledge's end keeps the wall beside it" is that geometry.

Nothing about the wall is carried between ticks. "Is the wall still there" is a question about the world, which both machines answer the same way, and a normal kept from the last tick would be one more thing a rewind has to restore. `DotFpsState.wall_normal` is written from the answer every tick for the view and is neither replicated nor compared.

## The run

- **Entered only from the air**, with forward held (`wall_run_requires_forward`), at `wall_run_min_speed` or more measured along the wall, not falling faster than `wall_run_max_fall_speed`, not moving away from the wall, and with the velocity within `wall_run_max_approach_angle` of the wall's plane: running at a wall head-on is not a run. Measuring the speed along the wall rather than in total is what makes that last rule hold at any speed.
- **The horizontal velocity is never written.** The speed along the wall is exactly what the player arrived with, because nothing touches it: air acceleration and the collide-and-slide carry on as in any airborne tick. That is the "continuous across entry" property, and it costs nothing.
- **Gravity is scaled, and the vertical speed is eased away** (`wall_run_gravity_scale`, `wall_run_vertical_damping`), never set. A player who jumped onto the wall rises a little further and levels off; one who was falling is caught over a few ticks; a long run settles into a slow sink of `gravity * scale / damping` (about 0.6 m/s with the defaults). Zeroing the vertical speed on entry is the obvious version and is exactly the one-tick jolt this was built not to have: `movement_selftest` requires no tick of a run, its entry or its end to change the velocity by more than a tick of gravity.
- **It ends** on `wall_run_max_time`, on losing the wall, on slowing below `wall_run_end_speed`, on releasing forward, on landing, on any jump or launch, and on noclip or a custom mode taking over. An end other than a jump marks the run spent (`wall_run_spent`): no other run starts until the player lands or wall-jumps, or a run that timed out on a wall would start again on the next tick and the cap would mean nothing.
- Landing is reset in `_advance_timers` as well as in the run's own update, because a jump off the ground has already put the player in AIR by the time the run is updated, and that tick still started on the ground.

## The wall jump

- **On the press**, buffered by `jump_buffer_time` like a ground jump, never on the hold: with `auto_hop` on, holding jump would otherwise wall-jump the instant a wall came within reach. A ground jump (or coyote jump) takes the press first.
- **Off a wall the player is touching or running on.** The speed along the wall is kept, whatever was going into the wall is dropped, and `wall_jump_push_speed` is added along a direction that leans from the wall's normal toward the view by `wall_jump_look_blend`. The part of the look that points into the wall is removed before the blend, so the push always leaves the wall. The vertical speed is raised to `wall_jump_up_speed`, never lowered, like the launch.
- **Two limits, both refilled only by landing.** `wall_jump_max_per_wall` counts jumps off the same wall, the same wall being the same normal heading in eighths of a turn (within one eighth either way, so a wall whose normal rounds across a boundary is still one wall, and two walls at a right angle are always two). `wall_jump_max_per_air` is the budget across every wall in one airborne stretch. Together: a corridor can be climbed between its walls until the budget is spent, and one wall cannot be climbed alone.
- A jump ends a run and un-spends running, so a jump across a corridor can run on the facing wall.

## The wall slide

`wall_slide_speed` above 0: an airborne player falling beside a wall who is pushing into it (the wish within about 60 degrees of straight into it), or whose run has ended on it, falls no faster than that. A fall that reaches the cap stops gaining speed there; one that arrived faster is eased down to it at `wall_run_vertical_damping`. It is what a timed-out run decays into instead of a sudden fall, and it is independent of `wall_run_enabled`.

## What the wire carries

Everything the next replayed tick reads goes in `net_flags`, after the dash, so an encoding from before them reads as "ready, no wall jumps" (see [networking.md](networking.md#what-rides-in-net_flags)):

| Field | Bits | Meaning |
| --- | --- | --- |
| run | 7 | 0 ready, 1 spent, 2 + sixty-fourths into a run (at most 125: `WALL_RUN_TIME_LIMIT`, 1.9 s) |
| jump counts | 3 | the airborne total and the per-wall count as one of the seven pairs that can happen |
| heading | 3 | the wall the per-wall count counts, in eighths of a turn |

That fills the word to 64 bits. **A field after these needs a new property, not a wider word**: dot-net's `UINT` stops at 64, and the top bit already makes the int negative in GDScript, which every read masks off. The heading is kept quantised in the simulation itself, not only on the wire, so a restored value is the one the simulation made.

The negative controls in `movement_selftest`'s "wall movement replays" drop these fields from a mid-run snapshot and must diverge; the same section replays at 64 Hz through `pack_flags`/`unpack_flags` and must reproduce every position.

## The view

`DotFpsView.wall_run_roll` (6 degrees) rolls the camera away from the wall, toward the open side, while `is_wall_running()`, eased by its own `wall_run_roll_response` so it starts and ends without a snap. It is scaled by how square the view is to the wall, so looking along the wall gives the full roll and turning away blends toward none rather than flipping. View only: the simulation never reads it. `fps_controller_selftest`'s "wall-run camera roll" checks the side, the easing and that 0 turns it off; whether it looks right is still a rendered frame's question.

## Signals

`DotFpsController.wall_run_changed(running)` and `wall_jumped()`, not emitted during a prediction replay, like `slide_changed`: they are where a game hangs a footstep or a sound, and a replayed tick is one the player already heard. **The game marks the replay** (`begin_replay` / `end_replay` around each replayed tick); one that does not hears a run once per correction, which is how game-arena found it had never marked one.
