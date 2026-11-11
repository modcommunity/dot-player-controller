class_name DotFpsSlidePreset
extends RefCounted

## The two slide setups games ship, as data over [DotFpsTunables]'s [code]slide_*[/code] numbers, so a game
## stops carrying its own copy. A slide stays off by default; a game calls one of these to turn it on.

## Crouch at any real run slides: a burst, then a long low-friction carry. The minimum is under a
## 5.74 m/s run, so a run slides and a crouch-walk never does (Arena's slide).
const RUN_MIN_SPEED := 4.1
const RUN_BOOST := 3.5
const RUN_MAX_SPEED := 14.0
const RUN_FRICTION := 0.9
const RUN_DURATION := 0.9
const RUN_COOLDOWN := 0.6

## Factor over [member DotFpsTunables.max_speed] a sprint slide needs: it sits above a plain run.
const SPRINT_MIN_FACTOR := 1.05


## Turns the slide on at the run preset: any run slides, no sprint needed.
static func apply_run(t: DotFpsTunables) -> void:
	t.slide_enabled = true
	t.slide_min_speed = RUN_MIN_SPEED
	t.slide_boost = RUN_BOOST
	t.slide_max_speed = RUN_MAX_SPEED
	t.slide_friction = RUN_FRICTION
	t.slide_duration = RUN_DURATION
	t.slide_cooldown = RUN_COOLDOWN


## Only a sprinter holding crouch slides (Zombie Zone's slide): [code]slide_requires_sprint[/code] wants the
## sprint button and the minimum speed is [constant SPRINT_MIN_FACTOR] over [member DotFpsTunables.max_speed],
## so set [code]max_speed[/code] first. [param p_enabled] is the game's switch; friction stays at the default.
static func apply_sprint(
	t: DotFpsTunables, p_enabled: bool, p_boost: float, p_max_speed: float, p_duration: float, p_cooldown: float
) -> void:
	t.slide_enabled = p_enabled
	t.slide_requires_sprint = true
	t.slide_min_speed = t.max_speed * SPRINT_MIN_FACTOR
	t.slide_boost = p_boost
	t.slide_max_speed = p_max_speed
	t.slide_duration = p_duration
	t.slide_cooldown = p_cooldown


## The operator cvars of a slide, by suffix: `suffix -> [tunables member, description]`. A game names them with its
## own prefix through [method cvar_table] (Arena: `arena_slide`, `arena_slide_boost`...), so the members and the
## words are written once.
const CVAR_SUFFIXES := {
	"": ["slide_enabled", "Crouch at a run slides (1) or only crouches (0)"],
	"_boost": ["slide_boost", "Speed a slide adds when it starts, m/s (0 for none)"],
	"_min_speed": ["slide_min_speed", "Speed needed to slide, m/s"],
	"_duration": ["slide_duration", "Longest a slide lasts, seconds"],
	"_friction": ["slide_friction", "Friction while sliding (lower carries further)"],
	"_cooldown": ["slide_cooldown", "Seconds between slides"],
}


## [constant CVAR_SUFFIXES] with [param prefix] in front: `cvar -> [member, description]`, in the order above.
static func cvar_table(prefix: String) -> Dictionary:
	var out := {}
	for suffix: String in CVAR_SUFFIXES:
		out[prefix + suffix] = CVAR_SUFFIXES[suffix]
	return out
