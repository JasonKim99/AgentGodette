@tool
extends PopupPanel
class_name GodetteSessionMenu

# Custom session picker with inline per-row delete, modeled on Zed's
# `ThreadHistoryView::render_history_entry` (vendor/zed/crates/agent_ui/
# src/thread_history_view.rs:475-491). Trash icon lives in the row's end
# slot and is visible only while the row is hovered.
#
# We need a custom popup because Godot's native PopupMenu can't host
# per-item hover buttons with their own click handlers.

signal session_chosen(session_index: int)
signal session_delete_requested(session_index: int)

const MIN_WIDTH: int = 360
const MAX_WIDTH: int = 900
const MAX_HEIGHT: int = 520
# Sum of every non-label horizontal element in a row (icon + the two HBox
# separations + delete button + the StyleBoxEmpty content margins). Used
# when converting the widest label's text width into the target popup
# width — bumping one raises the floor on required popup width.
const ROW_CHROME_PX: int = 78

var _scroll: ScrollContainer
var _list: VBoxContainer
# Labels collected during `populate` so we can measure their natural
# text widths after the popup is in-tree (theme font resolution needs
# tree context). Cleared every populate.
var _row_labels: Array = []


func _ready() -> void:
	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(MIN_WIDTH, 0)
	# Horizontal DISABLED — rows ellipsize instead of scrolling sideways.
	# Vertical AUTO so long thread lists still scroll.
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(_scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 0)
	_scroll.add_child(_list)


# groups: [ { "header": String, "indices": Array[int] }, ... ]
# context: {
#   "editor_theme":    Theme,
#   "agent_icon_for":  Callable(session_index: int) -> Texture2D,
#   "label_for":       Callable(session_index: int) -> String,
#   "tooltip_for":     Callable(session_index: int) -> String,
# }
func populate(groups: Array, context: Dictionary) -> void:
	_row_labels.clear()
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()

	var delete_icon: Texture2D = null
	var theme: Theme = context.get("editor_theme", null)
	if theme != null and theme.has_icon("Remove", "EditorIcons"):
		delete_icon = theme.get_icon("Remove", "EditorIcons")

	for group in groups:
		var header_text := str(group.get("header", ""))
		if not header_text.is_empty():
			_list.add_child(_build_header(header_text))
		var indices: Array = group.get("indices", [])
		for session_index_variant in indices:
			var session_index: int = int(session_index_variant)
			_list.add_child(_build_row(session_index, context, delete_icon))

	# Measure the widest label text directly via font metrics — labels
	# have clip_text enabled (so they ellipsize at the popup boundary),
	# which makes `get_combined_minimum_size().x` report 0 for them. We
	# bypass that by asking the theme font for each label's natural text
	# width and taking the max.
	var widest_text: float = 0.0
	for label_variant in _row_labels:
		var label: Label = label_variant
		var font: Font = label.get_theme_font("font", "Label")
		if font == null:
			continue
		var font_size: int = label.get_theme_font_size("font_size", "Label")
		if font_size <= 0:
			font_size = 14
		var w: float = font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
		if w > widest_text:
			widest_text = w

	var content_w: int = clamp(int(widest_text) + ROW_CHROME_PX, MIN_WIDTH, MAX_WIDTH)
	var content_h: int = min(MAX_HEIGHT, int(_list.get_combined_minimum_size().y) + 8)
	_scroll.custom_minimum_size = Vector2(content_w, content_h)


func popup_at_button(button: Control) -> void:
	if button == null:
		popup_centered()
		return
	var screen_pos := button.get_screen_position()
	var y_offset: int = int(button.size.y)
	popup(Rect2i(int(screen_pos.x), int(screen_pos.y) + y_offset, 0, 0))


func _build_header(text: String) -> Control:
	var lbl := Label.new()
	lbl.text = text
	lbl.modulate = Color(1, 1, 1, 0.55)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 2)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(lbl)
	return margin


func _build_row(session_index: int, context: Dictionary, delete_icon: Texture2D) -> Control:
	var row := PanelContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var bg_normal := StyleBoxEmpty.new()
	bg_normal.content_margin_left = 8.0
	bg_normal.content_margin_right = 6.0
	bg_normal.content_margin_top = 4.0
	bg_normal.content_margin_bottom = 4.0

	var bg_hover := StyleBoxFlat.new()
	bg_hover.bg_color = Color(1, 1, 1, 0.06)
	bg_hover.corner_radius_top_left = 4
	bg_hover.corner_radius_top_right = 4
	bg_hover.corner_radius_bottom_left = 4
	bg_hover.corner_radius_bottom_right = 4
	bg_hover.content_margin_left = 8.0
	bg_hover.content_margin_right = 6.0
	bg_hover.content_margin_top = 4.0
	bg_hover.content_margin_bottom = 4.0

	row.add_theme_stylebox_override("panel", bg_normal)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hbox)

	var agent_icon_cb: Callable = context.get("agent_icon_for", Callable())
	var icon := TextureRect.new()
	# 22 × 22 — the underlying agent icon texture is rasterised at
	# THREAD_MENU_AGENT_ICON_SIZE (28), so at 22 we display ~80% of the
	# source bitmap without upscaling. 18 read too small next to the 14 px
	# label; 22 lines up with the row's visual weight. ROW_CHROME_PX also
	# reflects this bump so the popup width math stays in sync.
	icon.custom_minimum_size = Vector2(22, 22)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if agent_icon_cb.is_valid():
		icon.texture = agent_icon_cb.call(session_index)
	hbox.add_child(icon)

	var label_cb: Callable = context.get("label_for", Callable())
	var label := Label.new()
	label.text = label_cb.call(session_index) if label_cb.is_valid() else ""
	# Label EXPAND_FILLs to the row's available width; when that's less
	# than the text's natural width, clip_text + ellipsis truncates the
	# tail. The popup's width itself is driven by the widest-label
	# measurement in `populate`, so this only kicks in when a prompt
	# exceeds MAX_WIDTH.
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(label)
	_row_labels.append(label)

	var tooltip_cb: Callable = context.get("tooltip_for", Callable())
	if tooltip_cb.is_valid():
		row.tooltip_text = str(tooltip_cb.call(session_index))

	# Hover-only delete button in the end slot. MOUSE_FILTER_PASS is
	# important: with the default STOP, moving the cursor onto the button
	# fires `mouse_exited` on the row (because a STOP child interrupts the
	# parent's hover), which hides the button, which triggers
	# `mouse_entered` again — a flicker loop where the button keeps
	# appearing and vanishing and clicks never land. PASS keeps the row
	# continuously hovered while the button still receives its own
	# `pressed` signal. The price is that clicks on the button also
	# bubble to `row.gui_input`, so we do a rect check there to skip the
	# session-switch logic when the click lands on the trash.
	var delete_btn := Button.new()
	delete_btn.flat = true
	delete_btn.focus_mode = Control.FOCUS_NONE
	delete_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	delete_btn.mouse_filter = Control.MOUSE_FILTER_PASS
	delete_btn.custom_minimum_size = Vector2(22, 22)
	delete_btn.tooltip_text = GodetteI18n.t("Delete this thread")
	if delete_icon != null:
		delete_btn.icon = delete_icon
	delete_btn.visible = false
	delete_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(delete_btn)

	row.mouse_entered.connect(func() -> void:
		row.add_theme_stylebox_override("panel", bg_hover)
		delete_btn.visible = true
	)
	row.mouse_exited.connect(func() -> void:
		row.add_theme_stylebox_override("panel", bg_normal)
		delete_btn.visible = false
	)
	row.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb: InputEventMouseButton = event
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and not mb.is_echo():
				# Click bubbled up from the delete button (PASS) — let
				# that button's own `pressed` handler run, don't treat
				# this as a session switch.
				if delete_btn.visible and delete_btn.get_global_rect().has_point(mb.global_position):
					return
				session_chosen.emit(session_index)
				hide()
				row.accept_event()
	)
	delete_btn.pressed.connect(func() -> void:
		session_delete_requested.emit(session_index)
	)

	return row
