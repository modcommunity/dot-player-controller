# Physics space queries and threads

With `physics/3d/run_on_separate_thread`, `PhysicsDirectSpaceState3D` is only reachable during the physics step, and `CharacterBody3D.move_and_slide` only belongs there too. The addon owns no tick on the server: a game calls `simulate` (third person) or `simulate_tick` (first person) from its own `_physics_process` chain. Design and measurements: `~/docs/server-threading.md`, nightly `server-physics-thread-1`.

| File | Query | Who must call it inside a physics step |
| --- | --- | --- |
| `fp/motion/dot_fps_physics_body.gd` | `cast_motion`, `intersect_shape`, `intersect_ray` (8-22 per player per tick) | `DotFpsMotor` through `DotFpsController.simulate_tick`. The controller calls it from its own `_physics_process` when `drive` is LOCAL; a server or replay driver must call `simulate_tick` from its tick |
| `fp/nodes/dot_fps_wall_probe.gd` | two `intersect_ray` for a remote player's wall | Client rendering of remote players only (game-arena `arena_player.gd`); the caller passes the space |
| `tp/nodes/dot_tps_controller.gd` | `move_and_slide` in `_apply_intent` | `simulate` only. Its `_process` only moves the camera rig and never reaches `_apply_intent` |

The `_process` of both controllers draws (camera rig, view); neither queries the space or ticks.

`controller_selftest` section "space-query audit" fails when the set of querying files differs from this table, when one gains an input, deferred or awaited entry point, or when a `_process` reaches a query or a tick.

Open: the camera rig's `DotCameraBoom` probe runs in `_process` (client only; a server never runs a rig), and the callers in games (mg-wipeout, game-arena server drivers) are audited under the nightly item.
