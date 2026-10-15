# The first-person simulation

`fp/` is a movement model in the genre's tradition (ground and air acceleration, air-strafing, bunny-hopping, surf), rebuilt so a client can predict it and a server can correct it. What the original single-player controller got wrong is in [history.md](history.md#the-rewrite).

## The one idea

**The simulation is a pure function of (state, command, delta, world).**

It is what lets a client apply input immediately and a server correct it a round trip later without the two disagreeing, and it has to be designed in: nothing in GDScript enforces it and nothing in a single-player game reveals when it is broken.

- `DotFpsMotor` never reads the keyboard, the wall clock, an unseeded random stream, the frame rate, or a node's transform. Time comes from `delta`, intent from the command, the world from `DotFpsBody`.
- Every timer in `DotFpsState` counts simulated seconds (or ticks). `Time.get_ticks_msec()` appears nowhere in `fp/motion/`.
- `DotFpsState` holds everything the simulation reads between ticks. A field left on the controller node is not restored by a rewind, so the replay starts from a state the server never computed and the correction is measured against a fiction.
- Sampling lives in `DotFpsSampler`, separately, so a replay does not call `Input.is_action_pressed` and get what the player is holding now.

`movement_selftest.gd::_test_replay_determinism` guards it: 400 mixed commands, a snapshot at tick 250, a replay of the last 150 from the snapshot, the same endpoint required. That is exactly the shape of reconciliation, and it carries a negative control.

## Surf and hops

Surf is not a feature. It is what this movement model does on a face too steep to stand on, and the only question is whether the collide-and-slide gets out of the way.

- **A ramp steeper than `max_slope_angle` must not ground the player.** `_categorise_ground` requires `_is_floor`, so the player stays in `Mode.AIR`, gets gravity and air acceleration, and the slide clips the velocity along the face. That is surf, in full.
- **The seam between two ramps.** Clipping against each contact normal in turn does not find a direction that satisfies both: at a seam the vector clipped against the first points into the second and back. The player arrives at 20 m/s and stops dead in the corner. `_resolve_planes` is the classic plane-list collide-and-slide: keep every plane touched this move, take the first clipped direction that re-enters none of the others, and when there is none go along a crease (the cross product of two normals, parallel to both faces by construction) that re-enters none of the rest. **Every pair is tried, not only with two planes**: the classic slide stops dead at three, and a body in a room's corner under a window (two faces of the window's boxes plus the side wall, with straight down leaving all three) hung in mid-air for good (`[hns-door-wedge-1]`). Zero only when no crease leaves the rest. `crease_slide` turns it off, which is what the negative control uses.
- **Touching the same plane twice must not zero the velocity.** A player who begins a tick a fraction of a millimetre inside a ramp (every spawn onto one, every prediction correction) would be stopped dead on a surface they should accelerate down. A duplicate plane has already been satisfied: keep the velocity. A **full** plane list is a real corner and does stop them.
- **And the rest of that tick is spent.** After a duplicate, the remainder of the tick goes into ONE leg along the plane lifted a skin off it, velocity untouched. Returning to the loop instead was tried and is worse: a real contact's near-copy normals fill the plane list and zero the velocity in a corner that is not there. **In a wedge, the crease first** (`_leave_crease`, `crease_leg_ticks`): when that leg stops short or goes nowhere, a rest query a skin or more off the named face looks for a second face, and if there is one the rest of the tick goes along the crease of the two, from where the capsule is if that is clear, else lifted off both faces at once; the velocity is laid along the crease too. In the V of two surf slabs the capsule is equally deep in both and the rest query names whichever the physics server picks, so without this a rider hung there with its speed for as long as it kept picking the same one, and when it let go depended on the absolute tick the ride began on ([history.md](history.md#frozen-in-the-crease-of-two-surf-slabs-g2gfast-surf-crease-hang-1)). If that leg also goes nowhere (a grazing leg that ends exactly touching a face, on a displacement whose triangles are a fraction of a degree apart), `_leave_face` lifts straight off the face by one, two, then four skins as its own leg and spends the rest from there; at most four millimetres. If that is blocked too, `_split_leg` spends the leg's vertical part alone, then its horizontal part (`split_leg_ticks`): beside two faces the rest query can name the one the motion only grazes, and straight down was clear all along ([history.md](history.md#hanging-in-the-corner-behind-an-open-door-hns-door-wedge-1)). See [history.md](history.md#a-surfer-frozen-on-a-bank).

`bhop_speed_cap_scale` is the landing speed cap the round-based competitive shooters added; off here, because a movement game that caps hop speed has no bunny-hopping. `edge_friction` is `sv_edgefriction`, off because it costs a query per grounded tick.

## Slopes, steps and kerbs

- **Walking up a slope is not leaving the ground.** `_categorise_ground`, `_try_jump` and `_snap_to_ground` measure "moving away" (`LEAVING_SPEED`) along the floor normal, not +Y. A jump still leaves: `_try_jump` sets AIR itself.
- **Landing on a slope while moving uphill.** The slide lays a landing velocity along the face, so walking pace onto a gentle slope is a small upward speed. An airborne player rising slower than **half a jump's launch** (`jump_velocity() * 0.5`) is probed and landed when the velocity lies in a walkable floor's plane. Above that line the query is skipped, and the line is load-bearing: without it a jump up a 40° ramp is landed on the tick it leaves. A game with no jump (`jump_height` 0) keeps the `LEAVING_SPEED` line.
- **A step's landing on a kerb's edge is judged by the kerb, not the capsule.** The rounded bottom on a corner reports the sphere's normal; `_floor_beyond_edge` asks a thin probe past the contact instead, and refuses a floor more than `step_height` above where the step started. The ground check asks it too, but only for a player moving onto the floor beyond (`_standable_normal`: horizontal velocity toward the contact). A player standing on a ledge, walking off one or running along one still gets the capsule's answer. Steep faces answer no to the probe, so surf is untouched.
- **A kerb a centimetre over `step_height` is a wall, at every speed.** The step measures the hover with one short down sweep and lifts only to `step_height` above the floor (a grounded player hovers up to the probe's 2 cm); every landing is refused whose contact is more than `step_height` above the floor it left; `_lift_clear` runs only when the probe saw nothing, because straight up is not out of a wall; and a step is taken only when it gains more than two skins, since the rounded bottom slides a millimetre past a corner the straight side could not. `DotFpsFlatBody`'s `Hit.point` is the box's support point against the normal, not the swept centre, so the height question works on it. See [history.md](history.md#kerbs-that-were-climbed).
- **A fast crest launches.** `_snap_to_ground` holds a player to the floor past a ramp's crest, which is right for a run up it and wrong for a hop over it. `DotFpsTunables.crest_launch_speed_scale` (1.25 x `max_speed`, Christian's pick) is the line: at or above it a player still carrying the climb is left in the air with all their speed; below it they are laid onto the floor. 0 restores always-grounded. game-g2gfast exposes it as `sv_crestlaunch`.

Steep faces and downward grazes are in [collision.md](collision.md#steep-faces-and-grazes).

## How far a jump goes

`DotFpsTunables` answers it: `jump_apex()`, `climb_limit(margin = CLIMB_MARGIN)` (nine tenths of the apex: the highest top face a standing player is asked to jump onto), `jump_airtime(rise)` and `jump_reach(rise, speed = max_speed)`, plus the static `airtime_for(gravity, jump_height, rise)` / `reach_for(speed, gravity, jump_height, rise)` for a map with no tunables in front of it.

**`rise` is the whole point.** The airtime everybody writes down is the time back to the height you left, and on a course that climbs it is about 30% too long, which is how two games shipped courses nobody could finish. It uses the descending root, holds ground speed through the air (holding forward adds nothing past `max_air_wish_speed`), and gives no credit for the capsule's radius. `movement_selftest`'s "jump reach" checks it against a running jump in the motor, not another copy of the formula. The games' own reach helpers (game-arena, game-playground, game-g2gfast, mg-buses-from-hell, mg-smash-copter) delegate to it; a new one should too.

## Styles

`DotFpsStyle` is what a timer server means by the word: sideways, half-sideways, backwards, low gravity, prebhop. `DotFpsController.set_style` does both of its jobs in order:

- `apply_to(base)` returns a **derived** `DotFpsTunables`, never mutating the base. The controller keeps `_base_tunables` and always derives from it, because deriving from the previous style's output compounds the scales (low gravity and back lands you in a quarter of it).
- `filter_command(cmd)` clears the keys the style forbids, **in place, on both machines, before the motor sees it, and idempotently**, because a prediction replay runs it again over stored commands. Filtering only on the server makes the client predict movement the server will not produce.

Scales rather than absolute values, for the reason surfaces use them: an absolute `max_speed` silently stops tracking the base the first time somebody retunes it. The exceptions are `air_accelerate` and `max_air_wish_speed`, where the pair is the style.

**`timescale` is not applied by `apply_to`.** Scaling the simulation means scaling `delta`, which is the host's tick loop's decision, and on a server it has to be the same for every player or the tick counter stops meaning anything.

The ranking half of a style (ranked, points multiplier, minimum time) is `DotTimerStyle` in dot-timer; a game pairs them by id.

## Statistics

`DotFpsStats` is the HUD line a hop player watches: jumps, strafes, sync, perfect hops, average and peak speed.

- **Counted per simulated tick, not per frame**, so two players on different monitors get the same sync for the same run.
- **Not observed during a prediction replay.** A replayed tick has already been seen; counting it again gives a client on a lossy link a jump count that climbs by itself. The server's copy is what a record is filed with.

`DotFpsState.ground_ticks` counts in **ticks**: a perfect hop leaves on the tick of the landing, and deriving that from a seconds timer scores the same run differently at 64 Hz and at 128 Hz.

## Simulating ahead

`DotFpsSimulator` (`controller.simulator()`) is a second `DotFpsMotor` over a copy of the player's body, with a duplicate of the tunables, the same modifiers and custom modes registered in the same order, and the same surfaces. A bot that surfs plans on it offline and checks its next second against it at run time (dot-bot's surf planner and pilot, which reach it by duck typing because dot-bot names no other addon).

- **A second motor, not a model.** The motor is a pure function of (state, command, delta, tunables, body), and every body only queries, so the copy is the game itself: game-g2gfast measured 0.0000 m between a simulated ride of 486 ticks and the live player given the same commands. A re-implementation of the clip and air-acceleration rule would drift, and a ride planned on it falls off the real ramp.
- **The body copies itself** (`DotFpsBody.copy_for_simulation`): a physics body binds to the same node with the same masks and exclusions, a flat body shares its boxes and planes. A copy, not the live body, because the physics body counts its queries and a game's body may cache per sweep, and a simulation run between two live ticks must not show in either. A game body that cannot copy itself returns null and the caller hands `setup` (or `simulator(body)`) one of its own; game-arena hands its map body without the other players' hulls.
- **The duplicate tunables** are because the controller re-gates abilities on its own every tick; nothing a simulation does may reach the live player's. So a simulator does not follow a later style or map change: build a new one.
- **What a game runs beside the motor is the caller's**: `mechanics` (a map's boosters, run after each tick) and `oracle` (what a position means: a goal, a pit, below the course). Both are callables, so this addon still knows nothing about maps.
- `steps` and `usec` are the compute cost; a tick on a physics body costs 75 to 97 us in GDScript.

## Deliberately not here

- **Ladders and vehicles.** `DotFpsMoveMode` is the hook; the modes are a game's decision about feel. The self-test's ladder is a worked example of the interface, not something to use. Swimming is here ([extending.md](extending.md#custom-modes-and-swimming)) because its hard part, determinism, is this addon's.
- **Weapons, health, hit detection.** dot-net's lag compensation rewinds positions; what to trace is a game's concern.
- **Camera shake, weapon sway, procedural lean.** `DotFpsView` has bob, a landing kick and strafe roll; the rest is cosmetic.
- **On-screen touch controls.** `DotFpsTouchSampler` turns fingers into commands and ships no art or layout; a game draws its own and calls `hold()`.
- **Moving platforms.** They need a velocity frame the player inherits, and doing that deterministically needs the platform in the replicated simulation, which is dot-net's problem.
- **A character mesh or animation.** The controller publishes position, yaw, pitch and crouch; driving an `AnimationTree` is a game's layer (or dot-player-char's).
