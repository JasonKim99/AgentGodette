@tool
class_name GodetteComposerChipOverlay
extends Control

signal chip_activated(key: String)
#
# Paints the inline chip panels that sit on top of GodetteComposerPromptInput.
# The prompt input reserves a run of characters per chip (anchor + NBSP
# padding); this overlay draws a styled panel + icon + label over that run
# so the reserved width reads as a single chip glyph.
#
# Overlay is a child of the prompt input with full-anchor sizing, which
# means our local coordinates already match `TextEdit.get_rect_at_line_column`
# output — no transform math needed.
#
# Mouse filter is PASS: we intercept left-clicks that land on a chip rect
# (emitting `chip_activated` so the dock can open the underlying file /
# scene / node) and let every other event propagate up to the parent
# TextEdit for normal caret/selection/drag handling.

var _prompt_input: GodetteComposerPromptInput = null
var _chip_style: StyleBoxFlat = null
var _font_color: Color = Color(1, 1, 1, 1)


func _init(prompt_input: GodetteComposerPromptInput) -> void:
	_prompt_input = prompt_input
	mouse_filter = Control.MOUSE_FILTER_PASS
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0
	_chip_style = _make_default_style()


func _ready() -> void:
	if _prompt_input == null:
		return
	# Redraws are deferred a frame because TextEdit's `text_changed` signal
	# fires BEFORE its internal glyph-position cache is rebuilt. Drawing
	# immediately would ask `get_rect_at_line_column` for positions that
	# still reflect the pre-edit layout, and the chip rect would land on
	# top of freshly typed characters — visually eating an input. Hopping
	# one idle frame lets TextEdit's relayout settle first.
	_prompt_input.text_changed.connect(_queue_redraw_deferred)
	_prompt_input.chips_changed.connect(_on_chips_changed)
	# Caret moves can scroll the viewport; repaint so the chip follows.
	# Caret math updates synchronously so this one is safe eager.
	_prompt_input.caret_changed.connect(queue_redraw)
	_prompt_input.resized.connect(_queue_redraw_deferred)
	var vbar := _prompt_input.get_v_scroll_bar()
	if vbar != null:
		vbar.value_changed.connect(_on_scroll_changed)
	var hbar := _prompt_input.get_h_scroll_bar()
	if hbar != null:
		hbar.value_changed.connect(_on_scroll_changed)


# --- Public configuration --------------------------------------------------

func set_chip_base_color(color: Color) -> void:
	if _chip_style.bg_color == color:
		return
	_chip_style.bg_color = color
	queue_redraw()


func set_font_color(color: Color) -> void:
	if _font_color == color:
		return
	_font_color = color
	queue_redraw()


# --- Drawing ---------------------------------------------------------------

func _draw() -> void:
	if _prompt_input == null:
		return
	var font := _prompt_input.get_theme_font("font")
	if font == null:
		font = ThemeDB.fallback_font
	var font_size := _prompt_input.get_theme_font_size("font_size")
	if font_size <= 0:
		font_size = ThemeDB.fallback_font_size

	for run_info in _prompt_input.get_chip_runs():
		var rect := _rect_for_run(run_info)
		if rect.size == Vector2.ZERO:
			continue
		var meta: Dictionary = run_info.get("meta", {})
		draw_style_box(_chip_style, rect)
		_draw_chip_contents(rect, meta, font, font_size)


func _draw_chip_contents(rect: Rect2, meta: Dictionary, font: Font, font_size: int) -> void:
	var icon: Texture2D = meta.get("icon", null)
	var cursor_x: float = rect.position.x + float(GodetteComposerPromptInput.CHIP_PAD_LEFT)
	var center_y: float = rect.position.y + rect.size.y * 0.5

	if icon != null:
		var icon_size := float(GodetteComposerPromptInput.CHIP_ICON_SIZE)
		var icon_rect := Rect2(
			Vector2(cursor_x, center_y - icon_size * 0.5),
			Vector2(icon_size, icon_size)
		)
		draw_texture_rect(icon, icon_rect, false)
		cursor_x += icon_size + float(GodetteComposerPromptInput.CHIP_ICON_GAP)

	var label := str(meta.get("label", ""))
	if label.is_empty():
		return
	# Vertical baseline: place text so its visual midline matches the chip's
	# midline. `get_ascent` + `get_descent` gives the metrics we need; the
	# baseline is at center_y + (ascent - descent) / 2.
	var ascent := font.get_ascent(font_size)
	var descent := font.get_descent(font_size)
	var baseline_y := center_y + (ascent - descent) * 0.5
	draw_string(
		font,
		Vector2(cursor_x, baseline_y),
		label,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		_font_color
	)


# --- Helpers ---------------------------------------------------------------

func _rect_for_run(run_info: Dictionary) -> Rect2:
	var line := int(run_info.get("line", 0))
	# Use the ANCHOR column for the visual left edge — the ZWNJ prefix at
	# run.start is zero-width and its rect is flaky to query. Visual end
	# is the right edge of the last NBSP (end - 1).
	var anchor_col := int(run_info.get("anchor", run_info.get("start", 0)))
	var end_col := int(run_info.get("end", 0))
	var last_char_col := end_col - 1
	if last_char_col < anchor_col:
		return Rect2()
	var start_rect: Rect2 = _prompt_input.get_rect_at_line_column(line, anchor_col)
	var last_rect: Rect2 = _prompt_input.get_rect_at_line_column(line, last_char_col)
	if start_rect.size == Vector2.ZERO or last_rect.size == Vector2.ZERO:
		return Rect2()
	var right_edge := last_rect.position.x + last_rect.size.x
	var width := right_edge - start_rect.position.x
	if width <= 0.0:
		return Rect2()
	return Rect2(start_rect.position, Vector2(width, start_rect.size.y))


func _make_default_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.22, 0.24, 0.28, 1.0)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	return style


func _on_chips_changed(_ordered_keys: Array) -> void:
	_queue_redraw_deferred()


func _on_scroll_changed(_value: float) -> void:
	queue_redraw()


func _queue_redraw_deferred() -> void:
	call_deferred("queue_redraw")


# --- Hover tooltip ---------------------------------------------------------
#
# Godot calls `_get_tooltip(pos)` to decide whether a tooltip should show
# at the hovered position; if it returns non-empty, the engine then calls
# `_make_custom_tooltip(for_text)` to build the popup Control. We use
# `for_text` as a sidecar: it carries the hovered chip's key so the
# tooltip builder can find the matching chip metadata and render a
# type-appropriate preview (image thumbnail for images, path label for
# files / scenes / nodes). Returning empty when the pointer is off every
# chip suppresses the tooltip on the bare text area.

const _TOOLTIP_IMAGE_MAX_SIZE := Vector2(360.0, 240.0)
const _TOOLTIP_PAD := 8


func _get_tooltip(at_position: Vector2) -> String:
	if _prompt_input == null:
		return ""
	for run_info in _prompt_input.get_chip_runs():
		var rect := _rect_for_run(run_info)
		if rect.size == Vector2.ZERO:
			continue
		if rect.has_point(at_position):
			var meta: Dictionary = run_info.get("meta", {})
			return str(meta.get("key", ""))
	return ""


func _make_custom_tooltip(for_text: String) -> Object:
	if for_text.is_empty() or _prompt_input == null:
		return null
	var meta := _find_meta_by_key(for_text)
	if meta.is_empty():
		return null
	return _build_tooltip_control(meta)


func _find_meta_by_key(key: String) -> Dictionary:
	for run_info in _prompt_input.get_chip_runs():
		var meta: Dictionary = run_info.get("meta", {})
		if str(meta.get("key", "")) == key:
			return meta
	return {}


func _build_tooltip_control(meta: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var kind := str(meta.get("kind", ""))
	var payload_variant = meta.get("payload", {})
	var payload: Dictionary = payload_variant if typeof(payload_variant) == TYPE_DICTIONARY else {}

	match kind:
		"image":
			var path := str(payload.get("path", ""))
			var texture := _load_texture_from_path(path)
			if texture != null:
				var preview := TextureRect.new()
				preview.texture = texture
				preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				preview.custom_minimum_size = _fit_within(texture.get_size(), _TOOLTIP_IMAGE_MAX_SIZE)
				vbox.add_child(preview)
			var caption := str(meta.get("label", ""))
			if not caption.is_empty():
				vbox.add_child(_dim_label(caption))
		"file":
			vbox.add_child(_path_label(str(payload.get("path", meta.get("label", "")))))
		"scene":
			var scene_path := str(payload.get("scene_path", ""))
			if scene_path.is_empty():
				scene_path = str(meta.get("label", ""))
			vbox.add_child(_dim_label("Scene"))
			vbox.add_child(_path_label(scene_path))
		"node":
			var relative_path := str(payload.get("relative_node_path", ""))
			var scene_parent := str(payload.get("scene_path", ""))
			if not relative_path.is_empty():
				vbox.add_child(_dim_label("Node"))
				vbox.add_child(_path_label(relative_path))
			if not scene_parent.is_empty():
				vbox.add_child(_dim_label("in %s" % scene_parent))
		_:
			var fallback := str(meta.get("tooltip", meta.get("label", "")))
			if not fallback.is_empty():
				vbox.add_child(_path_label(fallback))

	# Padding around the content. Using content_margin on the style box
	# keeps the hit area tight while visually breathing.
	var style := StyleBoxFlat.new()
	style.bg_color = _chip_style.bg_color.darkened(0.1)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = _TOOLTIP_PAD
	style.content_margin_right = _TOOLTIP_PAD
	style.content_margin_top = _TOOLTIP_PAD
	style.content_margin_bottom = _TOOLTIP_PAD
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _load_texture_from_path(path: String) -> Texture2D:
	if path.is_empty():
		return null
	var absolute := path
	if path.begins_with("res://") or path.begins_with("user://"):
		# Image.load needs a filesystem path. Chip images are saved under
		# res://.godette-attachments/ and drag-drop paths are editor res://,
		# both of which ProjectSettings.globalize_path resolves.
		absolute = ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(absolute) and not FileAccess.file_exists(path):
		return null
	var image := Image.new()
	var err := image.load(absolute)
	if err != OK and path != absolute:
		err = image.load(path)
	if err != OK or image.is_empty():
		return null
	return ImageTexture.create_from_image(image)


func _fit_within(natural: Vector2, max_size: Vector2) -> Vector2:
	if natural.x <= 0.0 or natural.y <= 0.0:
		return max_size
	var scale := min(1.0, min(max_size.x / natural.x, max_size.y / natural.y))
	return natural * scale


func _path_label(content: String) -> Label:
	var label := Label.new()
	label.text = content
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	# Cap the tooltip width so long paths wrap instead of pushing the
	# popup off-screen.
	label.custom_minimum_size = Vector2(360, 0)
	return label


func _dim_label(content: String) -> Label:
	var label := Label.new()
	label.text = content
	label.modulate = Color(1.0, 1.0, 1.0, 0.65)
	return label


# --- Click handling --------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if _prompt_input == null:
		return
	if not (event is InputEventMouseButton):
		return
	var mb: InputEventMouseButton = event
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	for run_info in _prompt_input.get_chip_runs():
		var rect := _rect_for_run(run_info)
		if rect.size == Vector2.ZERO:
			continue
		if rect.has_point(mb.position):
			var meta: Dictionary = run_info.get("meta", {})
			var key := str(meta.get("key", ""))
			if key.is_empty():
				return
			emit_signal("chip_activated", key)
			accept_event()
			return
	# Untouched: event propagates to parent TextEdit via MOUSE_FILTER_PASS,
	# giving normal caret placement and drag-select behaviour for clicks
	# that missed a chip.
