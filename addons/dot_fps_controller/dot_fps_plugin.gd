@tool
extends EditorPlugin

## Editor entry point for dot-fps-controller. Registers inspector types only.
##
## No autoloads. A player controller is the clearest case for the family-wide rule:
## a singleton player makes split-screen, a spectator camera, a replay viewer and a
## server simulating thirty of these in one process all impossible, and every one of
## those is a thing a game built on this will eventually want.

const _ICON := "res://addons/dot_fps_controller/icon_placeholder.svg"

const _TYPES := [
	[
		"DotFpsController",
		"Node",
		"res://addons/dot_fps_controller/nodes/dot_fps_controller.gd",
	],
	[
		"DotFpsView",
		"Node",
		"res://addons/dot_fps_controller/nodes/dot_fps_view.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
