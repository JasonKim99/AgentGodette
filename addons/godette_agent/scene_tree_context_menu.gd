@tool
extends EditorContextMenuPlugin

var dock: Object


func _init(p_dock: Object) -> void:
	dock = p_dock


func _popup_menu(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return

	add_context_menu_item("Ask Agent About Nodes", Callable(self, "_on_context_selected"))


func _on_context_selected(nodes: Array) -> void:
	if dock == null:
		return

	dock.call("attach_nodes", nodes)
	dock.call_deferred("focus_prompt")
