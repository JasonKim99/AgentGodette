@tool
class_name GodetteComposerSlashPopup
extends PopupPanel

# Slash-command picker, two-pane layout matching Zed:
#
#   ┌─────────────┬──────────────────────────────────┐
#   │ /update-cfg │ Use this skill to configure the  │
#   │ /debug      │ Claude Code harness via          │
#   │ /simplify   │ settings.json. Automated…        │
#   │ …           │                                  │
#   └─────────────┴──────────────────────────────────┘
#
# Left pane: scrollable list of command names. Right pane: the full
# description of whichever command is currently selected. Selection
# follows mouse hover or keyboard navigation; the right pane updates
# live so the user can sweep the list and read each description without
# having to commit.
#
# Lifecycle (driven by dock):
#   - dock instantiates one popup, hooks `command_chosen` once
#   - dock observes its composer's text_changed; when the prompt starts
#     with `/`, dock calls `set_commands` + `show_filtered`
#   - keyboard nav (Up/Down/Enter/Esc) is forwarded via `handle_key`
#     so the composer keeps focus while the list is open

const POPUP_MIN_WIDTH := 720
# Popup height is fixed — doesn't grow / shrink with the command count.
# Long lists scroll inside the left pane; short lists leave space at the
# bottom of that pane. This keeps the popup's screen footprint
# predictable as the user filters down a list with typing.
const POPUP_HEIGHT := 320
const NAME_PANE_RATIO := 0.32
const NAME_ROW_PADDING_X := 10
const NAME_ROW_PADDING_Y := 4
const DESCRIPTION_PADDING := 16


# Emitted when the user picks a command. `name` is the command name
# without the leading slash; `argument_hint` is the adapter-supplied
# hint string (or "" when the command takes no args).
signal command_chosen(name: String, argument_hint: String)


var _commands: Array = []  # Array[{name, description, hint}]
var _filter: String = ""
var _selected_index: int = 0

var _name_scroll: ScrollContainer
var _name_list: VBoxContainer
var _description_label: Label
var _empty_label: Label


func _init() -> void:
	# We never take focus — composer keeps the caret while user navigates.
	exclusive = false
	transient = true


func _ready() -> void:
	# Lock the window size on both ends. Godot's Window normally uses
	# `max(min_size, contents_minimum_size)` for its effective minimum,
	# and the inner VBox's row-sum minimum can be hundreds of px tall;
	# without `max_size` clamping, the popup would grow to fit all rows
	# on first show, and keep growing as the description label re-wraps
	# longer text on hover.
	min_size = Vector2(POPUP_MIN_WIDTH, POPUP_HEIGHT)
	max_size = Vector2(8192, POPUP_HEIGHT)
	_build_ui()
	hide()


func _build_ui() -> void:
	var split := HBoxContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 0)
	add_child(split)

	# Left pane: scrollable name list. `clip_contents = true` so the
	# inner VBox's min height (sum of all rows) doesn't propagate up
	# and force the popup to grow. `custom_minimum_size.y = 0` keeps
	# ScrollContainer's own minimum off the popup height calculation.
	_name_scroll = ScrollContainer.new()
	_name_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_name_scroll.clip_contents = true
	_name_scroll.size_flags_horizontal = Control.SIZE_FILL
	_name_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_name_scroll.custom_minimum_size = Vector2(int(POPUP_MIN_WIDTH * NAME_PANE_RATIO), 0)
	split.add_child(_name_scroll)

	_name_list = VBoxContainer.new()
	_name_list.add_theme_constant_override("separation", 0)
	_name_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_scroll.add_child(_name_list)

	# Subtle vertical separator between panes — a 1-px ColorRect with
	# the editor's panel-border tone so the two panes read as distinct
	# without a heavy divider line.
	var divider := ColorRect.new()
	divider.color = Color(1.0, 1.0, 1.0, 0.06)
	divider.custom_minimum_size = Vector2(1, 0)
	divider.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(divider)

	# Right pane: description of the currently-selected command. Wraps
	# long text. SHRINK_CENTER vertically so short descriptions stay
	# aligned to the top of the available space.
	var desc_margin := MarginContainer.new()
	desc_margin.add_theme_constant_override("margin_left", DESCRIPTION_PADDING)
	desc_margin.add_theme_constant_override("margin_right", DESCRIPTION_PADDING)
	desc_margin.add_theme_constant_override("margin_top", DESCRIPTION_PADDING)
	desc_margin.add_theme_constant_override("margin_bottom", DESCRIPTION_PADDING)
	desc_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(desc_margin)

	_description_label = Label.new()
	_description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_description_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	# `clip_text = true` keeps an over-long description from reporting
	# a giant min_size that would push the popup taller. Together with
	# `max_size` on the window itself, this guarantees the popup
	# doesn't grow when the user hovers a row whose description is
	# longer than the visible area.
	_description_label.clip_text = true
	_description_label.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92, 0.95))
	_description_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_description_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	desc_margin.add_child(_description_label)

	# "No matching commands" overlay. Shown in place of the split when
	# the filter empties out the list. Positioned absolutely so we
	# don't have to retear the split layout.
	_empty_label = Label.new()
	_empty_label.text = "No matching commands"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_label.add_theme_color_override("font_color", Color(0.65, 0.66, 0.7, 0.85))
	_empty_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_empty_label)
	_empty_label.hide()


# Populate the popup's command list. Caller passes the raw
# `availableCommands` payload from ACP; we normalise to {name,
# description, hint} per entry.
func set_commands(raw_commands: Array) -> void:
	_commands.clear()
	for cmd_variant in raw_commands:
		if typeof(cmd_variant) != TYPE_DICTIONARY:
			continue
		var cmd: Dictionary = cmd_variant
		var name: String = str(cmd.get("name", "")).strip_edges()
		if name.is_empty():
			continue
		var description: String = str(cmd.get("description", "")).strip_edges()
		var hint: String = ""
		var input_variant = cmd.get("input", null)
		if typeof(input_variant) == TYPE_DICTIONARY:
			hint = str((input_variant as Dictionary).get("hint", "")).strip_edges()
		_commands.append({
			"name": name,
			"description": description,
			"hint": hint,
		})


# Show the popup with `filter` applied. Anchors above the composer if
# there's room, otherwise below.
func show_filtered(filter: String, anchor_position: Vector2, anchor_size: Vector2) -> void:
	_filter = filter
	_selected_index = 0
	_rebuild_rows()
	var filtered: Array = _filtered_commands()
	if filtered.is_empty():
		_empty_label.show()
		_name_scroll.hide()
		_description_label.hide()
	else:
		_empty_label.hide()
		_name_scroll.show()
		_description_label.show()
	# Width tracks the composer (so the popup looks anchored to the
	# input it's filtering for) but never below POPUP_MIN_WIDTH.
	var pop_width: int = int(max(anchor_size.x, POPUP_MIN_WIDTH))
	# Always anchor on the composer's upper edge — popup sits directly
	# above the input box, fixed height regardless of how many commands
	# are in the filtered list.
	var pop_y: int = int(anchor_position.y) - POPUP_HEIGHT
	popup(Rect2i(int(anchor_position.x), pop_y, pop_width, POPUP_HEIGHT))
	# Hard-set size after popup() — Godot's PopupPanel respects content
	# min_size, and a long ScrollContainer's child VBox can otherwise
	# push the window taller than POPUP_HEIGHT. Setting `size`
	# explicitly here clamps the window back to the configured value.
	size = Vector2i(pop_width, POPUP_HEIGHT)


func close_popup() -> void:
	if visible:
		hide()


func _filtered_commands() -> Array:
	if _filter.is_empty():
		return _commands
	var needle: String = _filter.to_lower()
	var out: Array = []
	for cmd in _commands:
		if str(cmd["name"]).to_lower().begins_with(needle):
			out.append(cmd)
	return out


func _rebuild_rows() -> void:
	for child in _name_list.get_children():
		child.queue_free()
	var filtered: Array = _filtered_commands()
	for i in range(filtered.size()):
		_name_list.add_child(_make_name_row(i, filtered[i]))
	_apply_selection()


func _make_name_row(index: int, cmd: Dictionary) -> Control:
	var row := PanelContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(_on_row_gui_input.bind(index))

	var inner := MarginContainer.new()
	inner.add_theme_constant_override("margin_left", NAME_ROW_PADDING_X)
	inner.add_theme_constant_override("margin_right", NAME_ROW_PADDING_X)
	inner.add_theme_constant_override("margin_top", NAME_ROW_PADDING_Y)
	inner.add_theme_constant_override("margin_bottom", NAME_ROW_PADDING_Y)
	row.add_child(inner)

	var name_label := Label.new()
	# Bare command name — slash prefix is implied by the popup context
	# (the user already typed `/`, the popup is a slash-command picker)
	# and showing it on every row is redundant.
	name_label.text = str(cmd["name"])
	name_label.add_theme_color_override("font_color", Color(0.92, 0.94, 0.97, 1.0))
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	inner.add_child(name_label)

	return row


func _on_row_gui_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseMotion:
		if _selected_index != index:
			_selected_index = index
			_apply_selection()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_selected_index = index
			_emit_chosen()


# Apply selection paint + update the description pane. Called from
# every flow that changes `_selected_index` (mouse hover, keyboard nav,
# initial show, list rebuild).
func _apply_selection() -> void:
	var filtered: Array = _filtered_commands()
	for i in range(_name_list.get_child_count()):
		var row: PanelContainer = _name_list.get_child(i) as PanelContainer
		if row == null:
			continue
		if i == _selected_index:
			# Subtle selection highlight — translucent accent fill.
			# Content margins explicitly zeroed because StyleBoxFlat
			# defaults to non-zero padding, which would change the
			# row's effective size and shift unselected rows up/down
			# as the user hovers across the list. Same width for
			# every state means rows stay put.
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.34, 0.40, 0.56, 0.55)
			sb.corner_radius_top_left = 3
			sb.corner_radius_top_right = 3
			sb.corner_radius_bottom_left = 3
			sb.corner_radius_bottom_right = 3
			sb.content_margin_left = 0
			sb.content_margin_right = 0
			sb.content_margin_top = 0
			sb.content_margin_bottom = 0
			row.add_theme_stylebox_override("panel", sb)
		else:
			# Empty stylebox keeps an unselected row the SAME size as
			# a selected one — switching between override-on and
			# override-off would otherwise jiggle layout.
			var empty := StyleBoxEmpty.new()
			empty.content_margin_left = 0
			empty.content_margin_right = 0
			empty.content_margin_top = 0
			empty.content_margin_bottom = 0
			row.add_theme_stylebox_override("panel", empty)
	# Mirror the selected command's description into the right pane.
	# Argument hint is intentionally NOT rendered — felt like noise
	# above the description in practice. Hint is still passed through
	# `command_chosen` so future iterations can use it (placeholder
	# text after insert, autocomplete, …).
	if _selected_index >= 0 and _selected_index < filtered.size():
		var cmd: Dictionary = filtered[_selected_index]
		_description_label.text = str(cmd.get("description", ""))
	else:
		_description_label.text = ""


func _emit_chosen() -> void:
	var filtered: Array = _filtered_commands()
	if _selected_index < 0 or _selected_index >= filtered.size():
		return
	var cmd: Dictionary = filtered[_selected_index]
	command_chosen.emit(str(cmd["name"]), str(cmd.get("hint", "")))
	hide()


# Keyboard navigation forwarded by the dock from its composer's input
# pipeline. Returns true if the popup consumed the event.
func handle_key(event: InputEventKey) -> bool:
	if not visible:
		return false
	if not event.pressed:
		return false
	# Up / Down auto-repeat is allowed (so holding either key scrolls);
	# everything else only on the initial press.
	if event.echo and event.keycode != KEY_DOWN and event.keycode != KEY_UP:
		return false
	var filtered: Array = _filtered_commands()
	match event.keycode:
		KEY_DOWN:
			if filtered.is_empty():
				return true
			_selected_index = (_selected_index + 1) % filtered.size()
			_apply_selection()
			_scroll_selected_into_view()
			return true
		KEY_UP:
			if filtered.is_empty():
				return true
			_selected_index = (_selected_index - 1 + filtered.size()) % filtered.size()
			_apply_selection()
			_scroll_selected_into_view()
			return true
		KEY_ENTER, KEY_KP_ENTER, KEY_TAB:
			if filtered.is_empty():
				return false
			_emit_chosen()
			return true
		KEY_ESCAPE:
			hide()
			return true
	return false


# Keep the keyboard-selected row visible inside the scroll viewport.
# Without this the user can hold Down past the bottom and the popup
# silently scrolls them off the visible area.
func _scroll_selected_into_view() -> void:
	if _name_scroll == null or _selected_index < 0:
		return
	var row: Control = _name_list.get_child(_selected_index) as Control
	if row == null:
		return
	var row_top: float = row.position.y
	var row_bottom: float = row_top + row.size.y
	var view_top: float = _name_scroll.scroll_vertical
	var view_bottom: float = view_top + _name_scroll.size.y
	if row_top < view_top:
		_name_scroll.scroll_vertical = int(row_top)
	elif row_bottom > view_bottom:
		_name_scroll.scroll_vertical = int(row_bottom - _name_scroll.size.y)
