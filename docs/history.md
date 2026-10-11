# History

Bug narratives worth keeping: each could come back, and the story says how it looks when it does. The rule each one left is in [collision.md](collision.md), [motor.md](motor.md) or [extending.md](extending.md). Bug tags in backticks match the comments in the code.

## A player stuck in the floor

Reported as "I bhop and go through the floor and then get stuck". The embed branch of `_categorise_ground` kept an embedded player grounded, which stopped the fall out of the world and did nothing about being inside the floor: the probe started in geometry every tick, answered GROUND forever with a stale `ground_normal`, and `_snap_to_ground` (the only call that could lift them) runs only for a player who is not grounded. An absorbing state with no route out. `_lift_clear` was added. Two probes written from outside the simulation to count it produced large, plausible, monotonic numbers that measured nothing, which is why the counters live inside.

## Sinking through a surf ramp

The same engine behaviour on a ramp, invisible for longer. `cast_motion` treats a surface the capsule already overlaps as free space, and a surfer is always overlapping: 0.83 m of penetration in 96 ticks, 20 m over 256, with every stuck and embed counter at zero, because the floor recovery runs only for a player grounded last tick and a surfer never is. `surf_selftest` was green throughout because it replaces the physics body. Fixed with `rest_contact` and `_depenetrate`; found and proven by `surf_physics_selftest`.

## Late contacts on large walls (`[sweep-1]`)

On a 40 m wall `cast_motion`'s `safe` let a capsule 5 cm in; on a 164 m wall about one sideways sweep in a hundred saw nothing and ended 11 cm inside. Fixed by the late-contact back-off and `_end_overlap_fallback`.

## A surfer frozen on a bank

A duplicate plane used to break the slide loop with the rest of the tick unspent. A surfer pressed into a bank met the face again at fraction zero every tick: position fixed, velocity intact, not grounded, not stuck, only `duplicate_plane_ticks` rising (a game measured it on 39% of the ticks on one bank). Fixed by spending the rest of the tick along the lifted plane. Then `[arrive-3]`: on a displacement whose triangles were a fraction of a degree apart, that leg too went nowhere and a surf bot hung at speed for thousands of ticks; `_leave_face` was added. The test geometry has to keep nine digits; at five the freeze does not happen.

## Stopped dead by a fallback normal (`[bank-hang-1]`, `[fps-face-edge-stop]`)

When no rest query could name a contact, `sweep` used to answer with the reverse of the motion, which the motor clipped the velocity against: zero. It stopped surfers on a bank, and every rider leaving a pitched slab over its far end stopped dead in mid-air and fell from rest. The reverse-of-motion guess is now only a degenerate-normal guard.

## Climbing a crate stack (`[jumping-into-crate-1]`)

In mg-buses-from-hell a runner jumping beside a column of crates that had settled a few degrees off square was grounded at the apex by the top crate's corner 2 cm away (the downward graze's reverse-of-motion normal was straight up), jumped again, and climbed the stack a crate at a time. A plain box never did it because nothing stood proud of its face. Fixed with `_downward_ray_fallback`.

## Walkers climbing steep faces (`[steep-climb-1]`)

A walker pressed into a 70° face went to AIR at its foot (the rounded bottom touched the face first) and air acceleration crawled them 2.5 m up it, and over a 60° one. Fixed with `_quadrant_floor` and `MoveResult.met_steep_face`.

## Kerbs that were climbed

Before the step-height rules, a 0.45 m `step_height` went over 0.5 m and 0.7 m kerbs, and at 15 m/s a 0.34 m kerb threw a runner to 1.07 m: the step left the capsule on the kerb's corner, the ground check read the corner's normal as AIR, and the next air slide turned the run into a climb. Then three ways a kerb a centimetre over `step_height` was still climbed at every speed (lift measured from a hovering player, landings on the corner at about 41°, `_lift_clear` lifting a walker out of a kerb's face). And a runner spawned exactly on a floor froze in front of every kerb, because exactly touching made `cast_motion` report the floor as a wall; that is why `_keep_skin` exists.

## Gliding up a slope, and nobody could walk up one

Before `LEAVING_SPEED` was measured along the floor normal, nothing in the family could walk up any slope under `max_slope`. After it, a player landing on a slope while moving uphill glided up it at air speed until a tick happened to end inside the probe (over a second in one game); the half-jump-launch line fixed that without landing a real jump on the tick it leaves.

## Jumpy ramps (`[ramp-pop-1]`)

On game-g2gfast's surf_mesa a rider resting on a ramp read clear one tick and deep the next: `get_rest_info` had reversed the normal, and `_depenetrate` pushed a full step into the ramp and back. One frame of the view jumping, many times a ride. It reproduced on a plain box (about one resting capsule in twelve), so it is the engine's. Fixed with `_turn_round_flipped`; game-g2gfast's `tools/ramp_bump_probe.tscn` measures a ride.

## The collision mask that never arrived

The body copied `tunables.collision_mask` once, in `_make_body`, and every game sets the mask after setup, so game-playground's players walked through every prop, NPC and vehicle with the tunables reading the right mask the whole time; found by a player standing on a platform for the first time and falling through it. Then a style threw the mask away on clients, which set a style straight after joining. Fixed by passing the mask every tick and by `set_collision_mask`.

## A fast crest (`[slope-crest-1]`)

After the walkable-slope fix, `_snap_to_ground` held every player to the floor past a ramp's crest, so nobody could hop over one. `crest_launch_speed_scale` is the line.

## The launch that a snapshot cancelled

The slide and launch timers first stayed out of the snapshot "like the jump timers". game-arena's net suite measured the cost: the client predicts a launch, an older snapshot arrives, the replay reaches the press with the client's current cooldown and buttons, no launch, 3.2 m between the ends. Fixed by packing the timers and `previous_buttons` into `net_flags`. The dash's first cooldown check strafed against the dash and read the air-control brake as a second dash.

## render_state was unreachable

`render_state()` interpolated between ticks from the day it was written, behind `if drive != Drive.LOCAL: return state`. LOCAL is the drive no networked game uses, so every client of every game drew the raw tick state (and the accumulator it blended with is advanced only by the LOCAL loop). In game-g2gfast's browser client at 60 frames against a 128-tick server the drawn position advanced 74 mm on six frames out of seven and 112 mm on the seventh: the whole of a "the game is very jittery in the browser" report, on a client whose every simulated number was right.

## The camera inside the character

`DotTpsCameraRig`'s `SpringArm3D` excluded nothing, so it collided with the player body on its first millimetre and sat inside the character. `tps_selftest` has no physics world and passed; a screenshot found it. In the same game, a controller whose `controller_id` was set after the switch entered the tree made the game open in the wrong view.

## Jump reach copied five times

Before `DotFpsTunables.jump_reach` existed, game-playground, game-arena, game-g2gfast, mg-buses-from-hell and mg-smash-copter each had their own copy of the arithmetic, and two of them sized courses with the airtime back to the height they left, which nobody could finish. They now delegate to the tunables.

## A wall run that ended four ticks in

game-arena's north gallery, over the wire (2026-10-10): a slide-jump off a ledge's end onto the wall beside it ran on the wall offline and, in `headless_net`, ran four ticks and fell. One lost crouch press moved the slide a tick; the uncrouch in the air then dropped the feet a few centimetres under the ledge's top while its end face was 10 cm behind the hull, nearer than the wall 16 cm beside it, and `_wall_contact` took the nearest wall. Its speed "along" was zero, under `wall_run_end_speed`, so the run ended, on both machines, agreeing perfectly. A run now prefers the sideways probes ([wall-movement](wall-movement.md#the-wall-is-asked-for-never-remembered)).

## The rewrite

`fp/` began as a single-player controller. What was wrong was not style:

| Was | Now |
| --- | --- |
| Movement ran in `_process`, so the simulation was frame-rate dependent | Fixed-tick, accumulated from frame time, bounded against stalls |
| `Input.is_action_pressed` read inside the controller | `DotFpsCommand`, sampled once per tick by `DotFpsSampler` |
| `vel = settings.max_velocity` assigned a float to a `Vector3` | `limit_length`, with a NaN check that logs and resets |
| Ground `accelerate` applied its increment three times in a loop | Once, as the model says |
| Air jump used `mul * max(0, vel.y)`, so it was zero at rest | One jump path, `sqrt(2 * g * h)` |
| One `speed_multiplier`, reset to 1 by whichever modifier was released | Derived from held buttons each tick; most restrictive wins |
| `is_crouched` was read but never assigned | `crouch_fraction` and `crouch_held`, both simulated |
| Crouch lerped a camera offset; the collider never changed | Collider resizes; standing up is refused without headroom |
| `snap` was computed and never used | Ground snapping, so slopes are not ice |
| No stair stepping | `step_height`, with the down-leg floor test |
| Yaw applied to the camera, so the body never turned | Yaw on the body, pitch on the camera |
| States loaded by building a path at runtime | Direct references |
| `class_name Player`, `Player_Input` | `Dot`-prefixed throughout |
