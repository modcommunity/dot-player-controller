# dot-player-controller docs

The reasoning behind the controllers, one subject per file. [CLAUDE.md](../CLAUDE.md) has the short rules; these say why.

| File | What it covers |
| --- | --- |
| [design.md](design.md) | The base contract and the switch, the dependency direction, the name collisions, freezing, what goes on the wire, what this addon does not do, and the third-person half |
| [motor.md](motor.md) | The first-person simulation: determinism, surf and hops, slopes, steps and kerbs, crests, jump reach, styles, statistics, simulating ahead (`DotFpsSimulator`), and what is deliberately not here |
| [collision.md](collision.md) | `DotFpsBody` and why it exists, the swept-query traps, embedded players, ramps a sweep cannot see, late and missing contacts, reversed normals, steep faces and grazes |
| [extending.md](extending.md) | Surfaces, modifiers, admin abilities, custom modes and swimming, slide/launch/dash, the collision mask, and the full "where a game plugs in" table |
| [wall-movement.md](wall-movement.md) | Wall running, wall jumping and the wall slide: entry and end, smoothness, the per-wall and per-air limits, the bits they take in `net_flags`, the camera roll |
| [networking.md](networking.md) | The dot-net bridge a game writes, what must be restored, what rides in `net_flags`, and rendering between ticks |
| [testing.md](testing.md) | The seven suites, why the flat-body and physics-body suites are both needed, negative controls, and the GDScript traps hit here |
| [history.md](history.md) | Bug narratives worth keeping, and the original rewrite |

Family-wide: [game-dev/docs/gdscript-hazards.md](../../../docs/gdscript-hazards.md), [testing.md](../../../docs/testing.md), [extension-points.md](../../../docs/extension-points.md), [bugs-found.md](../../../docs/bugs-found.md).
