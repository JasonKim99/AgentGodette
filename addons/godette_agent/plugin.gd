@tool
extends EditorPlugin

const AgentDockScript = preload("res://addons/godette_agent/agent_dock.gd")
const FileSystemContextMenuScript = preload("res://addons/godette_agent/filesystem_context_menu.gd")
const SceneTreeContextMenuScript = preload("res://addons/godette_agent/scene_tree_context_menu.gd")
const SessionStateScript = preload("res://addons/godette_agent/session_state.gd")

# Single shared GodetteState owned by the plugin. AgentDock and (later)
# AgentMainScreen both reference this instance via `bind(state)`. The
# state lives as a child of the plugin so its Timer + lifecycle hooks
# work; freed automatically when the plugin disables.
var state: GodetteState
var dock: Control
var filesystem_context_menu: EditorContextMenuPlugin
var scene_tree_context_menu: EditorContextMenuPlugin


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


func _focus_agent_dock() -> void:
	if dock != null and dock.has_method("focus_prompt"):
		dock.show()
		dock.call_deferred("focus_prompt")
