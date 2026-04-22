@tool
extends EditorPlugin

const AgentDockScript = preload("res://addons/godette_agent/agent_dock.gd")
const FileSystemContextMenuScript = preload("res://addons/godette_agent/filesystem_context_menu.gd")
const SceneTreeContextMenuScript = preload("res://addons/godette_agent/scene_tree_context_menu.gd")

var dock: Control
var filesystem_context_menu: EditorContextMenuPlugin
var scene_tree_context_menu: EditorContextMenuPlugin


func _enter_tree() -> void:
	dock = AgentDockScript.new()
	dock.name = "Agent Godette"
	dock.configure(get_editor_interface())
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)

	filesystem_context_menu = FileSystemContextMenuScript.new(dock)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, filesystem_context_menu)

	scene_tree_context_menu = SceneTreeContextMenuScript.new(dock)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, scene_tree_context_menu)

	add_tool_menu_item("Agent Godette: Focus Dock", Callable(self, "_focus_agent_dock"))


func _exit_tree() -> void:
	remove_tool_menu_item("Agent Godette: Focus Dock")

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
