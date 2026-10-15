# Testing

The family's method is in [game-dev/docs/testing.md](../../../docs/testing.md); this is what is specific here.

## The six suites

| Suite | What it is |
| --- | --- |
| `controller_selftest` | the base contract and the switch. The main scene, so the one a careless check runs alone |
| `movement_selftest` | the first-person motor: determinism, slopes, kerbs, steep faces, seams, jump reach, modifiers, admin, slide/launch/dash replays, wall run/jump/slide and their replays, the walls-off golden hash, swimming, the physics-body sweep sections, `FakeWire` |
| `surf_selftest` | surf and hop properties against `DotFpsFlatBody` |
| `surf_physics_selftest` | the same properties against real `StaticBody3D` geometry and `DotFpsPhysicsBody`, plus ramp ends and reversed normals |
| `fps_controller_selftest` | the node: drives, `render_state`, the collision mask, `extra_modes` surviving a style, the wall-run camera roll |
| `tps_selftest` | the third-person motor and rig (no physics world) |

All exit non-zero on failure. Run every one; then, for a motor change, the first-person games' own suites, which are where the motor meets real maps.

## Flat body and physics body

`surf_selftest` runs against `DotFpsFlatBody`: analytic geometry, one possible cause per failure, no scene, no physics step, and every one of those reasons is still good. It proved every surf property while the games were visibly broken, because the bug was never in the motor: it was in the one component that suite **replaces**. A suite that substitutes the component under suspicion cannot see a bug in it, and nothing about a green run tells you which component that is. `surf_physics_selftest` is the same properties against the collision backend the games run on. **Run both.** A collision bug is reproduced in the physics-body sections, with the geometry carried to the digits it was found at (rounding a displacement's triangles to five digits made one freeze disappear).

## Negative controls

Most sections here carry one: the determinism test replays with a deliberate divergence; the seam test turns `crease_slide` off; the admin section sets `state.mode = NOCLIP` naively and must fail to predict; the `net_flags` sections drop the field and must diverge; the recent fixes are "armed" (the section states what it measured with the fix reverted). A check that cannot fail proves nothing. When adding one, revert the fix and watch it fail.

## What measures what

- **Penetration, not speed**, for anything about a player inside geometry ([collision.md](collision.md#ramps-a-sweep-cannot-see)).
- **The simulation's own counters** (`embedded_ticks`, `lifted_ticks`, `depenetrated_ticks`, `flipped_normals`, `stuck_ticks`, `duplicate_plane_ticks`, `split_leg_ticks`, `crease_leg_ticks`), not an overlap test from outside, which reports most resting players as inside solid.
- **A rendered frame** for anything a player sees: the third-person rig and `render_state` jitter were both invisible to every assertion. See the family's note on simulation-to-screen bugs.

## GDScript traps hit here

Both are in [gdscript-hazards.md](../../../docs/gdscript-hazards.md) and both were hit again:

- `var x := arr[i].f()` on an untyped array is a **parse error**, not a warning. `Array.duplicate()` returns an untyped array.
- **Lambdas capture locals by value.** A counter incremented inside a signal handler stays zero outside it, so a test reports a failure for a signal that fired. Capture an `Array`.
