extends RefCounted

## dot-player-controller's API level; the bumping rule is on dot-core's DotAddonApi.
## LEVEL rises by one for anything new a game could call; OLDEST rises to LEVEL when
## something a game could have called is removed or changes meaning.

# One line per level, 1..13: docs/api-levels.md.
const LEVEL := 13
const OLDEST := 1
