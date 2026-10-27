class_name DotFpsAimBreak
extends RefCounted
## Refuses the sights for a moment after a hit. The server feeds it damage and ignores the aim bit while [method blocked]; a client feeds it the confirmed hit so the picture agrees.

var _until: float = -INF


## Records a hit at [param now] (seconds); does nothing when the rule is off.
func note_hit(now: float, tunables: DotFpsTunables) -> void:
	if tunables == null or not tunables.unscope_on_hit:
		return
	_until = maxf(_until, now + tunables.unscope_hit_time)


## Whether the sights are refused at [param now].
func blocked(now: float) -> bool:
	return now < _until


## Forgets any hit (respawn).
func clear() -> void:
	_until = -INF
