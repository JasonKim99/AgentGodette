@tool
extends EditorPlugin

const AgentDockScript = preload("res://addons/godette_agent/agent_dock.gd")
const FileSystemContextMenuScript = preload("res://addons/godette_agent/filesystem_context_menu.gd")
const SceneTreeContextMenuScript = preload("res://addons/godette_agent/scene_tree_context_menu.gd")
const SessionStateScript = preload("res://addons/godette_agent/session_state.gd")
const DioramaMainScreenScript = preload("res://addons/godette_agent/diorama/diorama_main_screen.gd")
const DIORAMA_ICON = preload("res://addons/godette_agent/icons/lucide--layout-dashboard.svg")

# Single shared GodetteState owned by the plugin. AgentDock and (later)
# AgentMainScreen both reference this instance via `bind(state)`. The
# state lives as a child of the plugin so its Timer + lifecycle hooks
# work; freed automatically when the plugin disables.
var state: GodetteState
var dock: Control
var diorama_main_screen: Control
var filesystem_context_menu: EditorContextMenuPlugin
var scene_tree_context_menu: EditorContextMenuPlugin

# Distraction-free mode is per-editor global state. Capture the user's
# setting on entry to Diorama and restore on exit so toggling between
# Diorama and 2D/3D/Script doesn't permanently flip their preference.
# `_diorama_was_visible` guards the symmetric case (`_make_visible(false)`
# fires on every main-screen switch including ones we never showed for).
var _diorama_was_visible: bool = false
var _distraction_free_before_diorama: bool = false


func _enter_tree() -> void:
	state = SessionStateScript.new()
	state.name = "GodetteState"
	state.configure(get_editor_interface())
	add_child(state)
	# Restore on-disk sessions BEFORE building any view — dock / main
	# screen rebuild their UI off the populated state during their first
	# frame, so loading lazily would leave them blank until an explicit
	# refresh.
	state.restore_from_disk()

	dock = AgentDockScript.new()
	dock.name = "Agent Godette"
	dock.configure(get_editor_interface())
	if dock.has_method("bind"):
		dock.call("bind", state)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)

	# Canvas main-screen entry — appears in the top toolbar alongside
	# 2D / 3D / Script. Hidden by default; the editor calls
	# `_make_visible(true)` when the user clicks the Canvas tab.
	diorama_main_screen = DioramaMainScreenScript.new()
	diorama_main_screen.hide()
	EditorInterface.get_editor_main_screen().add_child(diorama_main_screen)

	filesystem_context_menu = FileSystemContextMenuScript.new(dock)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, filesystem_context_menu)

	scene_tree_context_menu = SceneTreeContextMenuScript.new(dock)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, scene_tree_context_menu)

	add_tool_menu_item(GodetteI18n.t("Agent Godette: Focus Dock"), Callable(self, "_focus_agent_dock"))


func _exit_tree() -> void:
	# Must use the same string that was registered — localize identically.
	remove_tool_menu_item(GodetteI18n.t("Agent Godette: Focus Dock"))

	if filesystem_context_menu != null:
		remove_context_menu_plugin(filesystem_context_menu)
		filesystem_context_menu = null

	if scene_tree_context_menu != null:
		remove_context_menu_plugin(scene_tree_context_menu)
		scene_tree_context_menu = null

	if dock != null:
		if dock.has_method("shutdown"):
			dock.call("shutdown")
		remove_control_from_docks(dock)
		dock.queue_free()
		dock = null

	if diorama_main_screen != null:
		diorama_main_screen.queue_free()
		diorama_main_screen = null

	# If the plugin disables while Canvas is the active main screen,
	# put distraction-free back to where it was so the user doesn't
	# wake up with all docks hidden in 2D/3D/Script.
	if _diorama_was_visible:
		EditorInterface.set_distraction_free_mode(_distraction_free_before_canvas)
		_diorama_was_visible = false


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "Canvas"


func _get_plugin_icon() -> Texture2D:
	return CANVAS_ICON


func _make_visible(visible: bool) -> void:
	if diorama_main_screen != null:
		diorama_main_screen.visible = visible

	# Auto-enter distraction-free when entering Canvas; restore the user's
	# previous setting when leaving. This is the official equivalent of
	# the top-right maximize button (Ctrl+Shift+F11), so it cleanly hides
	# all docks + bottom panel without the dock-tree-walking hack we'd
	# otherwise need.
	var ei := EditorInterface
	if visible and not _diorama_was_visible:
		_distraction_free_before_canvas = ei.is_distraction_free_mode_enabled()
		ei.set_distraction_free_mode(true)
	elif not visible and _diorama_was_visible:
		ei.set_distraction_free_mode(_distraction_free_before_canvas)
	_diorama_was_visible = visible


func _focus_agent_dock() -> void:
	if dock != null and dock.has_method("focus_prompt"):
		dock.show()
		dock.call_deferred("focus_prompt")
