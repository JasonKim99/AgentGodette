@tool
class_name GodetteDioramaMainScreen
extends Control

# M1 stub for the Diorama main-screen view. At this stage the Control is
# just a placeholder that proves the EditorPlugin main-screen plumbing
# works — show/hide via `_make_visible`, sized by the editor's main-screen
# container, branded so users can confirm the entry point landed.
#
# Real content (diorama camera, blocks, drag/drop, persistence) is wired in
# starting from M1's next task. See `design/diorama_mode.md` for the plan.

const EditorTheme = preload("res://addons/godette_agent/editor_theme.gd")


func _init() -> void:
	name = "GodetteDiorama"
	# Fill the editor main-screen container — the editor tells the
	# main-screen Control to expand by giving it the full rect.
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	_build_placeholder()


func _build_placeholder() -> void:
	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	add_child(center)

	var stack := VBoxContainer.new()
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_theme_constant_override("separation", 8)
	center.add_child(stack)

	var title := Label.new()
	title.text = "Godette Diorama"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var title_font := EditorTheme.font("main", 600, false)
	if title_font != null:
		title.add_theme_font_override("font", title_font)
	title.add_theme_font_size_override("font_size", EditorTheme.main_font_size() + 6)
	stack.add_child(title)

	var hint := Label.new()
	hint.text = "M1 stub — drag .tscn here once the diorama is wired up"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate = Color(1.0, 1.0, 1.0, 0.55)
	stack.add_child(hint)
