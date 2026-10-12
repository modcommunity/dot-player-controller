extends RefCounted

## dot-player-controller's API level. The rule for bumping it is on dot-core's DotAddonApi.
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning.

# 1: everything before this file existed.
# 2: DotPlayerViewRules (mp_forceview) and DotPlayerBodyRules (mp_solidplayers);
#    DotTpsCameraRig's arm is a dot-core DotCameraBoom (same spring_length, margin,
#    collision_mask, add_excluded_object), fade_mask/set_fade_mask() and its fade.
const LEVEL := 2
const OLDEST := 1
