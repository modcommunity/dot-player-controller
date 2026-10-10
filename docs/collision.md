# Collision: DotFpsBody and the swept query

Most of the bugs this addon has had came from one place: what a swept shape query does and does not report. Every recovery below exists for a specific failure; none is redundant, and removing one because it looks like belt and braces brings its bug back. The stories are in [history.md](history.md).

## Why collision goes through DotFpsBody

1. **Testing.** The determinism test needs thousands of ticks against known geometry. `DotFpsFlatBody` (analytic boxes, half-space planes, `add_ramp`) makes it arithmetic, and a failure has one possible cause.
2. **`move_and_slide` keeps state.** The floor normal and velocity it remembers between calls are not restored by a rewind, so the motor does its own collide-and-slide over a stateless query.
3. **A server needs no rendering physics world**, and a game whose collision is a heightfield or a BSP can implement `DotFpsBody` against that directly.

`DotFpsPhysicsBody` is the implementation the games run on. It is where the engine's behaviour leaks through, so it is where most of what follows lives.

## The swept-query traps

- **`cast_motion` reports no collision when a move ends exactly touching.** Correct in isolation (touching is not overlapping), fatal in practice: land with your feet at precisely the floor's height and every later downward sweep also reports nothing, so you are never grounded again and sink at a constant rate.
- **A swept query's precision is proportional to its length.** The binary search stops at roughly a percent of the motion, so a 35 cm ground probe can return a "safe" distance that overlaps by 3 mm.
- **`Vector3` components are 32-bit and GDScript arithmetic is 64-bit.** A player standing exactly on `y = 0` has feet at `-2.4e-8` once the centre has been through a `Vector3`. Any test of the form `feet >= floor_y` misses; every comparison against a surface needs an epsilon.
- **`cast_motion` ignores any collider the shape already overlaps.** A shape starting inside something has no first contact to report, so to the sweep a surface you are inside does not exist at any depth.
- **On a large convex `cast_motion` can be late, or miss entirely.** Its `safe` can be centimetres past the real contact on a very large wall, and occasionally a sideways sweep along one sees nothing and ends inside it.

`DotFpsMotor._sweep` answers the first two: every query sweeps a margin further than asked and gives the distance back, the margin being `max(skin_width, length * SWEEP_TOLERANCE)`.

## Skins and snaps

- **A grounded player is kept a skin clear of the floor** (`_keep_skin`). Every query stops a skin short, but a spawn at the floor's height puts a player exactly on it, and a player the ground check finds a floor under is never snapped. From exactly touching, `cast_motion` reports the floor as an obstacle to a horizontal move at fraction ~0 in about one position in five, and the slide meets that plane twice and stops every tick. `_keep_skin` lifts a grounded player whose floor is under half a skin away back to a skin, straight up.
- **The ground snap runs only when the player has actually left the ground.** Not an optimisation: running the longest, least precise query in the tick on a player already standing re-derives a correct position from the worst available measurement and moves them a fraction of a millimetre down each time.

## Embedded in a floor

A swept probe that starts in solid answers "no collision", which reads as "nothing below me", so a player embedded by a fraction of a millimetre looks airborne, falls, embeds further, and leaves the level. `_categorise_ground` asks the question a sweep cannot (`body.overlaps`) and keeps a player who was grounded last tick grounded.

That alone is an absorbing state: the probe still starts in geometry next tick, still answers GROUND forever, and `_move` runs `_snap_to_ground` only when the player is not grounded, so nothing lifts them out. `_lift_clear` is the other half: straight up, never further than a step, doubling the lift each try (about nine overlap queries rather than hundreds). It runs only when the probe saw nothing, because straight up is not out of a wall.

**`embedded_ticks` and `lifted_ticks` exist because nothing outside the simulation can count this.** An overlap test from outside reports most resting players "inside solid" (a capsule a millimetre above a floor overlaps it through the margins; standing is an overlap). The distinction that matters is the one this function makes: the probe found nothing **and** the player is in something. Two outside probes were written and both produced large, plausible numbers that measured nothing.

## Ramps a sweep cannot see

The floor recovery above runs only from the branch that requires the player to have been GROUNDED last tick, and **a player on a surf ramp is never grounded, by design**. Because surfing is a continuous overlap, `cast_motion` stops seeing the ramp at all once the capsule is touching or inside it (measured on 4.7.2 against a 60° face: 2 cm clear is reported correctly; touching, or 1 mm to 50 cm inside, is free space). Nothing clips the velocity, gravity keeps pulling, and the player accelerates through the inside of the level with every stuck and embed counter at zero.

- **`DotFpsBody.rest_contact`** asks what a sweep cannot: `get_rest_info` reports the resting surface's own normal and, measured against its contact point, the exact penetration. `DotFpsPhysicsBody.sweep` consults it when `cast_motion` sees nothing, and returns a fraction-0 hit **only when the motion goes into that surface**: a capsule inside something is usually also trying to leave it (after a push, a step up, a crouch under a lip), and blocking the way out pins a player against what they are escaping.
- **`_depenetrate`** is `_lift_clear` generalised. Straight up is right for a floor and wrong for a ramp, where the shortest way out is mostly sideways. It pushes along the contact normal by the measured depth plus a skin, **clamped to a step per tick**: the clamp is what makes a wrong answer survivable, since a bad normal that moves a player a centimetre is a glitch and the same normal unclamped against a deep embed throws them across the level. A deep embed converges over a few ticks because each is measured afresh. It costs one query per tick per player, worth it because the cheaper `overlaps` cannot tell resting from buried. `depenetrated_ticks` counts it.

The measurement that finds this class of bug is **penetration, not speed**: a player sinking through a ramp has a plausible speed, position and stuck count, and only a geometric test of the capsule against the face says otherwise.

## Late and missing contacts

`DotFpsPhysicsBody.sweep` checks for both:

- **Late**: it measures how deep `unsafe` is from the rest query it already makes there and, past `LATE_CONTACT_DEPTH` (0.5 mm), backs the fraction off by that depth over the rate of approach.
- **Missing**: after the resting check and the downward ray, `_end_overlap_fallback` asks for a rest contact at the END of the move and backs off the same way. One more query per unobstructed sweep.
- A first rest query that finds nothing at `unsafe` is retried 1, 2 and 4 mm deeper. **There is no `-motion` fallback normal any more**: it clipped the velocity to zero and stopped surfers dead on a bank and at the far edge of a pitched face, where the capsule grazes the edge it is leaving and no query along the motion can name it. A graze nothing can name is asked `_end_overlap_fallback`'s question instead: does the move end inside something it goes into.

## A normal that points into the face

`get_rest_info` sometimes reports a capsule resting on a face with that face's normal **reversed**: same contact point, normal into the solid, depth of nearly the whole capsule. It reproduces on a plain box at 52°, so it is the engine's, not a map's. `_depenetrate` then pushed the player a full step into the ramp and back next tick: a one-frame view jump, many times a ride ("the ramps are jumpy").

**The tell is that the capsule's centre is past the contact plane**, which a resting contact never is. A genuine embed of more than half the capsule looks the same, so `_turn_round_flipped` moves the capsule out along the reversed normal and believes the reversal only if it is clear there (`FLIP_CHECK_CLEARANCE`). No upper bound on depth: the flipped reports come out a few millimetres past the whole capsule, inside the margin. `rest_contact` and `sweep` both go through it; `flipped_normals` counts it.

## Steep faces and grazes

- **A walker pressed into a face too steep to stand on stays on the floor.** A capsule's rounded bottom touches a face that leans back before its feet leave the floor, so the ground probe reported the face and the walker went to AIR at its foot, then air-crawled up it. Both halves are needed: `_categorise_ground` and `_snap_to_ground` re-ask a steep hit with four half-radius capsules inside the player's footprint (`_quadrant_floor`, the quadrant ground test the genre's reference movement code uses), and a grounded non-jump `_move` drops the lift a steep face's slide added along the floor normal (`MoveResult.met_steep_face`). **An airborne player still ramp-crawls** a steep face at roughly the genre's rate; that is genre-correct and left alone.
- **A downward probe grazing a face is not a floor.** A capsule a hair from a vertical face, moving down, makes `cast_motion` report a contact no rest query can name, and the old last resort (the motion's reverse) was straight up: a perfect floor made of nothing, which let a runner climb a stack of slightly rotated crates by being grounded at each jump's apex. For a mostly-downward motion the last resort is `_downward_ray_fallback`: the floor under the axis, or a miss. Sideways sweeps no longer use a reverse-of-motion guess (see above).
