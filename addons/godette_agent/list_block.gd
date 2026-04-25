@tool
class_name GodetteListBlock
extends Control
#
# Route 3 PoC — single Control that owns N TextParagraph instances and
# self-draws a markdown list (ordered or unordered) without nesting any
# child Containers / TextBlocks.
#
# Replaces the current Path A list rendering, which builds:
#   list (VBox)
#   ├── item_outer (MarginContainer for indent)
#   │   └── item_row (HBox)
#   │       ├── marker_tb (TextBlock for "•" or "1.")
#   │       └── body_tb (TextBlock for item text)
#   ├── item_outer ...
#   └── ...
# i.e. ~5 Controls per item × N items, all participating in Container
# layout cascade — the source of the VirtualFeed measure-drift bugs.
#
# This block flattens to a SINGLE Control that:
#   - owns one TextParagraph per item (for shaped item text)
#   - draws bullet markers (• / 1. / 2. ...) directly via canvas_item draw
#   - reports a single, accurate `_get_minimum_size().y` based on the
#     summed paragraph heights + inter-item gaps
# No nested Containers means no layout signal cascade, so VirtualFeed's
# measure can't drift behind the actual rendered height.
#
# ---------------------------------------------------------------------------
# Scope of v0 (this file)
# ---------------------------------------------------------------------------
#   ✅ Visual rendering matching the current GodetteMarkdownRender output
#   ✅ Item text supports per-span styling (bold / italic / mono / link bg)
#   ✅ Width-aware re-shape on NOTIFICATION_RESIZED
#   ✅ Accurate minimum_size for VirtualFeed
#   ⏸ NO selection support yet — markdown_selection_manager bypasses this
#      block in v0; selection across list items lands in v1 once the visual
#      pattern is validated.
#   ⏸ NO right-click menu
#   ⏸ NO link click handling (cosmetic only — link spans render with
#      bg highlight but clicking is inert until we add hit-test routing)

# Layout constants — match GodetteMarkdownRender so visual parity is
# byte-close to the legacy renderer.
const MARKER_COL_EMS: float = 1.6
const MARKER_GAP_PX: float = 12.0
const ITEM_GAP_PX: float = 2.0


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


# Items: Array of Array of span Dictionaries. Each outer entry is one list
# item; each inner entry is a styled run with the same shape TextBlock.set_spans
# accepts (text, font, font_size, bg).
var _ordered: bool = false
var _items_spans: Array = []  # Array[Array[Dictionary]]

var _font: Font = null
var _font_bold: Font = null
var _font_italic: Font = null
var _font_bold_italic: Font = null
var _font_mono: Font = null
var _font_size: int = 0
var _color: Color = Color(1, 1, 1, 1)
var _line_spacing: float = 0.0

# Selection state. -1 means "no selection"; both anchor==focus means a
# collapsed caret (treated as no selection). Spans from
# (anchor_item, anchor_char) to (focus_item, focus_char) — order is
# whichever the user dragged in; `_normalized_selection()` returns
# them in document order.
var _sel_anchor_item: int = -1
var _sel_anchor_char: int = -1
var _sel_focus_item: int = -1
var _sel_focus_char: int = -1
var _selecting: bool = false
var _selection_color: Color = Color(0.28, 0.42, 0.78, 0.45)

# Multi-click detection (matches TextBlock).
const _MULTI_CLICK_WINDOW_SEC: float = 0.45
const _MULTI_CLICK_TOLERANCE_PX: float = 4.0
var _last_click_time_sec: float = -1.0
var _last_click_pos: Vector2 = Vector2.ZERO
var _click_run: int = 0

signal selection_changed()
signal right_clicked(local_pos: Vector2)
# Step 3 (cross-block) hook — emitted on plain left-click when a
# selection manager is registered. The manager takes over drag tracking
# from there. Until then this stays unused.
signal selection_drag_started(flat_char: int)


func set_items(items: Array, ordered: bool) -> void:
	_items_spans = items.duplicate(true)
	_ordered = ordered
	_dirty = true
	_sync_paragraphs()
	update_minimum_size()
	queue_redraw()


# Incremental item builder API. The markdown renderer streams items via
# Start/Text/End events; we accumulate spans for the current item in
# `_building_item`, then `end_item()` flushes it into `_items_spans` and
# triggers a re-shape. Mirrors the surface of TextBlock.append_span /
# .append_text so `markdown_render._handle_text` works unchanged.
func set_ordered(value: bool) -> void:
	if _ordered == value:
		return
	_ordered = value
	queue_redraw()


func begin_item() -> void:
	_building_item = []


func append_span(text: String, opts: Dictionary = {}) -> void:
	var clean: String = text
	if clean.is_empty():
		return
	var span: Dictionary = opts.duplicate()
	span["text"] = clean
	_building_item.append(span)


func append_text(delta: String) -> void:
	append_span(delta, {})


func end_item() -> void:
	if _building_item.is_empty():
		return
	_items_spans.append(_building_item)
	_building_item = []
	_dirty = true
	_sync_paragraphs()
	update_minimum_size()
	queue_redraw()


func set_color(value: Color) -> void:
	if value == _color:
		return
	_color = value
	queue_redraw()


# Inline span fonts come from the markdown context. Plain-text items use
# `_font`; bold/italic/code spans look up the corresponding slot on the
# block via the span's `font` field (set by the caller from the markdown
# context).
func set_fonts(plain: Font, bold: Font, italic: Font, bold_italic: Font, mono: Font) -> void:
	_font = plain
	_font_bold = bold
	_font_italic = italic
	_font_bold_italic = bold_italic
	_font_mono = mono
	_dirty = true
	_sync_paragraphs()
	update_minimum_size()
	queue_redraw()


func set_font_size(value: int) -> void:
	if value == _font_size:
		return
	_font_size = value
	_dirty = true
	_sync_paragraphs()
	update_minimum_size()
	queue_redraw()


func set_line_spacing(value: float) -> void:
	if is_equal_approx(value, _line_spacing):
		return
	_line_spacing = value
	_dirty = true
	_sync_paragraphs()
	queue_redraw()


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------


# Span list currently being accumulated by the incremental builder API
# (`begin_item` / `append_span` / `end_item`). Empty between items.
var _building_item: Array = []
# Per-item shaped paragraphs. Rebuilt on dirty + width changes.
var _item_paragraphs: Array = []  # Array[TextParagraph]
var _dirty: bool = true
var _current_width: float = 0.0
# Cached layout — y_top of each item's text and the bullet column width.
# Cleared and rebuilt by `_sync_paragraphs`; consumed by `_draw` and
# `_get_minimum_size`.
var _item_y_tops: PackedFloat32Array = PackedFloat32Array()
var _bullet_col_width: float = 0.0
var _content_x: float = 0.0
var _content_width: float = 0.0


func _init() -> void:
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	# STOP filter so wheel events get to us; we forward them to the
	# enclosing ScrollContainer manually (mirrors text_block.gd's
	# pattern). With IGNORE the wheel events bubbled to a parent
	# MarginContainer that swallowed them — visible symptom: the
	# transcript scrolled fine elsewhere but froze when the cursor was
	# over a list. Selection / hover stay no-op for now (v0 scope).
	mouse_filter = Control.MOUSE_FILTER_STOP


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			if not is_equal_approx(size.x, _current_width):
				_current_width = size.x
				_dirty = true
				_sync_paragraphs()
				update_minimum_size()
				queue_redraw()
		NOTIFICATION_THEME_CHANGED, NOTIFICATION_ENTER_TREE:
			_dirty = true
			if is_inside_tree():
				_sync_paragraphs()
				update_minimum_size()
				queue_redraw()


func _get_minimum_size() -> Vector2:
	if _items_spans.is_empty():
		return Vector2.ZERO
	_sync_paragraphs()
	# Sum item heights + inter-item gaps. The `_item_y_tops` cache from
	# `_sync_paragraphs` already encodes this; just return its tail (which
	# was recorded as the running total after the last item).
	var total: float = 0.0
	for p_var in _item_paragraphs:
		var p: TextParagraph = p_var
		total += p.get_size().y
	if _item_paragraphs.size() > 1:
		total += ITEM_GAP_PX * float(_item_paragraphs.size() - 1)
	return Vector2(0.0, total)


func _draw() -> void:
	if _items_spans.is_empty():
		return
	_sync_paragraphs()
	var canvas := get_canvas_item()
	# Draw order:
	#   1. span backgrounds (chips behind inline code / link spans)
	#   2. selection rectangles (cover the chips so a selected chip
	#      visibly highlights — matches CodeEdit / TextBlock behaviour)
	#   3. paragraph glyphs (text on top of everything)
	#   4. marker glyphs (bullet in the gutter, drawn last so it sits
	#      atop any chip bg that might creep leftward)
	for i in range(_item_paragraphs.size()):
		var p: TextParagraph = _item_paragraphs[i]
		var y_top: float = _item_y_tops[i]
		_draw_item_span_backgrounds(p, _items_spans[i], y_top)
	if has_selection():
		_draw_selection_rects()
	for i in range(_item_paragraphs.size()):
		var p2: TextParagraph = _item_paragraphs[i]
		var y_top2: float = _item_y_tops[i]
		p2.draw(canvas, Vector2(_content_x, y_top2), _color)
		_draw_marker(canvas, i, y_top2)


# Walk the items in the selection range and paint a rect over the
# selected character span on each. Items between the start and end
# get their full content selected; the start and end items get a
# partial range from anchor_char / to focus_char respectively.
func _draw_selection_rects() -> void:
	var norm := _normalized_selection()
	var start_item: int = norm["start_item"]
	var start_char: int = norm["start_char"]
	var end_item: int = norm["end_item"]
	var end_char: int = norm["end_char"]
	for i in range(start_item, end_item + 1):
		if i < 0 or i >= _item_paragraphs.size():
			continue
		var p: TextParagraph = _item_paragraphs[i]
		var item_y: float = _item_y_tops[i]
		var span_start: int
		var span_end: int
		if i == start_item and i == end_item:
			span_start = start_char
			span_end = end_char
		elif i == start_item:
			span_start = start_char
			span_end = _item_full_text(i).length()
		elif i == end_item:
			span_start = 0
			span_end = end_char
		else:
			span_start = 0
			span_end = _item_full_text(i).length()
		if span_end <= span_start:
			continue
		_draw_paragraph_range_rect(p, span_start, span_end, _selection_color, item_y)


# ---------------------------------------------------------------------------
# Span backgrounds (chip-style fill behind inline code, link spans, etc.)
# ---------------------------------------------------------------------------


# For one item: walk its span list, accumulate character offsets, and
# for any span carrying a `bg` Color, draw a filled rect under that
# character range. Uses `_draw_paragraph_range_rect` which handles the
# multi-line-wrap case (a span that wraps onto N lines paints N
# stacked rects).
func _draw_item_span_backgrounds(paragraph: TextParagraph, spans: Array, item_y_top: float) -> void:
	if paragraph == null or spans.is_empty():
		return
	var char_cursor: int = 0
	for span_var in spans:
		var span: Dictionary = span_var
		var span_text: String = str(span.get("text", ""))
		var span_len: int = span_text.length()
		if span_len <= 0:
			continue
		var bg_variant = span.get("bg", null)
		if bg_variant is Color:
			_draw_paragraph_range_rect(paragraph, char_cursor, char_cursor + span_len, bg_variant as Color, item_y_top)
		char_cursor += span_len


# Filled rect over character range [s, e) within `paragraph`, anchored
# at (`_content_x`, `item_y_top`). Walks each line the range crosses
# and emits one rect per line — a span that wraps still gets a
# continuous-looking chip across the wrap boundary.
#
# Mirrors text_block.gd's `_draw_range_rect` algorithm. Kept inline
# rather than extracted to a shared module because the pixel-x machinery
# (`_line_char_x_local`) needs `_line_spacing` and the paragraph's
# per-line size, which are different per ListBlock item.
func _draw_paragraph_range_rect(paragraph: TextParagraph, s: int, e: int, color: Color, item_y_top: float) -> void:
	if e <= s:
		return
	var pad_x: float = 2.0
	var line_count: int = paragraph.get_line_count()
	var y_cursor: float = 0.0
	for line_idx in range(line_count):
		var line_range: Vector2i = paragraph.get_line_range(line_idx)
		var line_size: Vector2 = paragraph.get_line_size(line_idx)
		var row_advance: float = line_size.y + _line_spacing
		var line_start: int = line_range.x
		var line_end: int = line_range.y
		if line_end <= s or line_start >= e:
			y_cursor += row_advance
			continue
		var overlap_start: int = max(s, line_start)
		var overlap_end: int = min(e, line_end)
		var line_rid: RID = paragraph.get_line_rid(line_idx)
		var start_x: float
		if overlap_start == line_start:
			start_x = 0.0
		else:
			start_x = _line_char_x_local(line_rid, overlap_start - line_start, line_size.x, false)
		var end_x: float
		# Range continues onto the next line: extend to this line's
		# content right edge so the chip looks unbroken across the wrap.
		if e > line_end:
			end_x = line_size.x
		else:
			end_x = _line_char_x_local(line_rid, overlap_end - line_start, line_size.x, true)
		if end_x <= start_x:
			y_cursor += row_advance
			continue
		var rect := Rect2(
			Vector2(_content_x + start_x - pad_x, item_y_top + y_cursor),
			Vector2(end_x - start_x + pad_x * 2.0, line_size.y),
		)
		draw_rect(rect, color)
		y_cursor += row_advance


# Translate a char offset within a line into an x pixel inside that
# line. Direct port of text_block.gd's `_line_char_x` — see that file
# for why we need the glyph-iterate fallback.
func _line_char_x_local(line_rid: RID, char_in_line: int, line_width: float, is_end: bool) -> float:
	if char_in_line <= 0:
		return 0.0
	var ts := TextServerManager.get_primary_interface()
	if ts == null:
		return 0.0 if not is_end else line_width
	var info: Dictionary = ts.shaped_text_get_carets(line_rid, char_in_line)
	if not info.is_empty():
		var preferred_key: String = "trailing_rect" if is_end else "leading_rect"
		var rect_variant = info.get(preferred_key, null)
		if not (rect_variant is Rect2):
			rect_variant = info.get("leading_rect", null)
		if rect_variant is Rect2:
			return clamp((rect_variant as Rect2).position.x, 0.0, line_width)
	var glyphs: Array = ts.shaped_text_get_glyphs(line_rid)
	var x_accum: float = 0.0
	for glyph_variant in glyphs:
		if typeof(glyph_variant) != TYPE_DICTIONARY:
			continue
		var glyph: Dictionary = glyph_variant
		var g_start: int = int(glyph.get("start", 0))
		if g_start >= char_in_line and not is_end:
			return clamp(x_accum, 0.0, line_width)
		var g_end: int = int(glyph.get("end", g_start + 1))
		if g_end >= char_in_line and is_end:
			return clamp(x_accum + float(glyph.get("advance", 0.0)), 0.0, line_width)
		x_accum += float(glyph.get("advance", 0.0))
	return clamp(x_accum, 0.0, line_width)


# ---------------------------------------------------------------------------
# Layout / shaping
# ---------------------------------------------------------------------------


# Rebuilds `_item_paragraphs` and the y-top cache from `_items_spans`. No-op
# when neither dirty flag nor a width change demands it. Always safe to
# call — it gates internally.
func _sync_paragraphs() -> void:
	if not _dirty and not _item_paragraphs.is_empty():
		# Even when not dirty, width may have shifted between calls. Apply
		# the current width to each paragraph; TextParagraph.width setter
		# is a no-op when value is unchanged.
		_apply_width_to_paragraphs()
		_recompute_y_tops()
		return
	_dirty = false
	_item_paragraphs.clear()
	if _items_spans.is_empty():
		_item_y_tops = PackedFloat32Array()
		return

	_resolve_columns()

	# Build one paragraph per item.
	for spans_var in _items_spans:
		var spans: Array = spans_var
		var p := TextParagraph.new()
		p.line_spacing = _line_spacing
		# Paragraph width = available content width. When `size.x` hasn't
		# been resolved yet (block not yet in the tree / not yet laid out),
		# fall back to a generous width so initial measurement returns
		# something sane; the real width will arrive via NOTIFICATION_RESIZED.
		if _content_width > 0.0:
			p.width = _content_width
		for span_var in spans:
			var span: Dictionary = span_var
			var span_text: String = str(span.get("text", ""))
			if span_text.is_empty():
				continue
			var font: Font = _resolve_span_font(span)
			var font_size: int = _resolve_span_font_size(span)
			p.add_string(span_text, font, font_size)
		_item_paragraphs.append(p)

	_recompute_y_tops()


# Compute bullet column width and content x-offset based on the current
# font size. Mirrors GodetteMarkdownRender's LIST_INDENT (10) +
# LIST_MARKER_EMS (1.6) + LIST_MARKER_GAP (12).
func _resolve_columns() -> void:
	var font_size: float = float(_effective_font_size())
	_bullet_col_width = font_size * MARKER_COL_EMS
	# Note: the legacy path also has a 10px `LIST_INDENT` left margin via
	# MarginContainer. That margin lives outside the block's own size in
	# v0 — the markdown renderer wraps this ListBlock in a MarginContainer
	# at integration time. Keeping the indent external lets ListBlock be
	# anchored cleanly to its parent VBox without baking in margins it
	# can't introspect.
	_content_x = _bullet_col_width + MARKER_GAP_PX
	if size.x > 0.0:
		_content_width = max(0.0, size.x - _content_x)
	else:
		# Provisional width for the first measure. Real value comes via
		# NOTIFICATION_RESIZED.
		_content_width = 600.0


# Apply the current paragraph width to each cached paragraph. Cheap when
# width is unchanged.
func _apply_width_to_paragraphs() -> void:
	if _item_paragraphs.is_empty():
		return
	if size.x <= 0.0:
		return
	_resolve_columns()
	for p_var in _item_paragraphs:
		var p: TextParagraph = p_var
		if not is_equal_approx(p.width, _content_width):
			p.width = _content_width


# Walk the paragraphs to record the cumulative y-offset where each one
# starts. Used by both `_draw` and `_get_minimum_size`.
func _recompute_y_tops() -> void:
	_item_y_tops = PackedFloat32Array()
	_item_y_tops.resize(_item_paragraphs.size())
	var running: float = 0.0
	for i in range(_item_paragraphs.size()):
		_item_y_tops[i] = running
		var p: TextParagraph = _item_paragraphs[i]
		running += p.get_size().y
		if i < _item_paragraphs.size() - 1:
			running += ITEM_GAP_PX


# ---------------------------------------------------------------------------
# Marker rendering
# ---------------------------------------------------------------------------


func _draw_marker(canvas: RID, item_index: int, y_top: float) -> void:
	# Resolve marker font same way span text does: explicit `_font` →
	# theme-inherited default → Godot fallback.
	var font: Font = _font
	if font == null and is_inside_tree():
		font = get_theme_default_font()
	if font == null:
		font = ThemeDB.fallback_font
	if font == null:
		return
	var size_px: int = _effective_font_size()
	var marker_text: String = "•" if not _ordered else ("%d." % (item_index + 1))
	var line := TextLine.new()
	line.add_string(marker_text, font, size_px)
	# Right-align the marker within the bullet column so longer numbers
	# like "10." line up flush with shorter "1." in the same list.
	var marker_w: float = line.get_size().x
	var marker_x: float = max(0.0, _bullet_col_width - marker_w)
	# `TextLine.draw(pos)` and `TextParagraph.draw(pos)` both treat pos
	# as the TOP-LEFT of the rendered glyph box (not the baseline).
	# Passing `y_top` directly aligns the marker's top with the first
	# line of the paragraph drawn at the same `y_top`. An earlier
	# version added `line.get_line_ascent()` here on the (incorrect)
	# assumption pos was a baseline — that pushed the bullet down by
	# a full ascent, landing it midway through the first item's
	# wrapped lines.
	line.draw(canvas, Vector2(marker_x, y_top), _color)


# ---------------------------------------------------------------------------
# Span helpers
# ---------------------------------------------------------------------------


func _resolve_span_font(span: Dictionary) -> Font:
	# A caller-supplied `font` on the span wins (markdown renderer uses
	# this to inject bold/italic/mono per-span). Falls back to the block's
	# plain font slot, then to the theme-inherited default (matching what
	# Label / TextBlock pick up automatically), and finally to Godot's
	# global fallback as a last resort.
	var f = span.get("font", null)
	if f is Font:
		return f
	if _font != null:
		return _font
	if is_inside_tree():
		var theme_font := get_theme_default_font()
		if theme_font != null:
			return theme_font
	return ThemeDB.fallback_font


func _resolve_span_font_size(span: Dictionary) -> int:
	var s := int(span.get("font_size", 0))
	return s if s > 0 else _effective_font_size()


func _effective_font_size() -> int:
	if _font_size > 0:
		return _font_size
	# Inherit the font size Labels in the same theme chain would use, so
	# heading derivation + HiDPI scaling still apply. Mirrors TextBlock's
	# inheritance path.
	var inherited := get_theme_default_font_size()
	if inherited > 0:
		return inherited
	return 14


# ---------------------------------------------------------------------------
# Selection — public API
# ---------------------------------------------------------------------------


func has_selection() -> bool:
	if _sel_anchor_item < 0 or _sel_focus_item < 0:
		return false
	return _sel_anchor_item != _sel_focus_item or _sel_anchor_char != _sel_focus_char


func clear_selection() -> void:
	if _sel_anchor_item == -1 and _sel_focus_item == -1:
		return
	_sel_anchor_item = -1
	_sel_anchor_char = -1
	_sel_focus_item = -1
	_sel_focus_char = -1
	_selecting = false
	set_process(false)
	set_process_input(false)
	queue_redraw()
	emit_signal("selection_changed")


# Returns the selected text, joining items in the selection range with
# `\n`. Order follows document order regardless of drag direction.
func get_selected_text() -> String:
	if not has_selection():
		return ""
	var norm := _normalized_selection()
	var start_item: int = norm["start_item"]
	var start_char: int = norm["start_char"]
	var end_item: int = norm["end_item"]
	var end_char: int = norm["end_char"]
	if start_item == end_item:
		var full: String = _item_full_text(start_item)
		return full.substr(start_char, end_char - start_char)
	# Multi-item: head slice of start_item + full middle items + head slice of end_item, joined by \n
	var parts: PackedStringArray = PackedStringArray()
	var start_full: String = _item_full_text(start_item)
	parts.append(start_full.substr(start_char, start_full.length() - start_char))
	for i in range(start_item + 1, end_item):
		parts.append(_item_full_text(i))
	var end_full: String = _item_full_text(end_item)
	parts.append(end_full.substr(0, end_char))
	return "\n".join(parts)


# Walk the spans of an item to recover its concatenated text. Cheap —
# spans are already in memory.
func _item_full_text(item_idx: int) -> String:
	if item_idx < 0 or item_idx >= _items_spans.size():
		return ""
	var parts := PackedStringArray()
	for span_var in _items_spans[item_idx]:
		parts.append(str(span_var.get("text", "")))
	return "".join(parts)


# Returns selection in document order regardless of which way the user
# dragged. Caller should check has_selection() first.
func _normalized_selection() -> Dictionary:
	var ai: int = _sel_anchor_item
	var ac: int = _sel_anchor_char
	var fi: int = _sel_focus_item
	var fc: int = _sel_focus_char
	if ai < fi or (ai == fi and ac <= fc):
		return {"start_item": ai, "start_char": ac, "end_item": fi, "end_char": fc}
	return {"start_item": fi, "start_char": fc, "end_item": ai, "end_char": ac}


# ---------------------------------------------------------------------------
# Hit testing
# ---------------------------------------------------------------------------


# Translate a local mouse position into (item_index, char_offset).
# Returns empty Dictionary when the block has no items; otherwise always
# returns a valid (item, char) pair (clamped to nearest item / end of
# item if click was above / below / past the content).
func _hit_test_position(local_pos: Vector2) -> Dictionary:
	if _item_paragraphs.is_empty():
		return {}

	# Pick the item by y. Below last item → snap to last; above first → first.
	var n: int = _item_paragraphs.size()
	if local_pos.y <= _item_y_tops[0]:
		var p0: TextParagraph = _item_paragraphs[0]
		var c0: int = _hit_test_char_in_paragraph(p0, Vector2(local_pos.x - _content_x, 0.0))
		return {"item": 0, "char": c0}

	var target_item: int = n - 1
	for i in range(n):
		var p: TextParagraph = _item_paragraphs[i]
		var y_top: float = _item_y_tops[i]
		var y_bot: float = y_top + p.get_size().y
		if local_pos.y < y_bot:
			target_item = i
			break

	var p2: TextParagraph = _item_paragraphs[target_item]
	var item_y: float = _item_y_tops[target_item]
	var paragraph_local := Vector2(local_pos.x - _content_x, local_pos.y - item_y)
	var c: int = _hit_test_char_in_paragraph(p2, paragraph_local)
	return {"item": target_item, "char": c}


# Walk the paragraph line-by-line to map a local-to-paragraph point to a
# character offset. Mirrors text_block.gd's `_hit_test_char` exactly —
# kept inline because that helper is private and depends on TextBlock-
# specific state (`_paragraph`, `_text`, `_line_spacing`).
func _hit_test_char_in_paragraph(paragraph: TextParagraph, local_pos: Vector2) -> int:
	if paragraph == null:
		return 0
	if local_pos.y <= 0.0:
		return 0
	var line_count: int = paragraph.get_line_count()
	var ts := TextServerManager.get_primary_interface()
	var y_cursor: float = 0.0
	for line_idx in range(line_count):
		var line_size: Vector2 = paragraph.get_line_size(line_idx)
		var row_advance: float = line_size.y + _line_spacing
		var line_bottom: float = y_cursor + row_advance
		if local_pos.y < line_bottom:
			var line_range: Vector2i = paragraph.get_line_range(line_idx)
			if ts == null:
				return line_range.x
			var line_rid: RID = paragraph.get_line_rid(line_idx)
			var char_in_line: int = ts.shaped_text_hit_test_position(line_rid, local_pos.x)
			var result: int = line_range.x + char_in_line
			return clamp(result, line_range.x, line_range.y)
		y_cursor = line_bottom
	# Past the last line — clamp to end of paragraph text length.
	if line_count > 0:
		var last_range: Vector2i = paragraph.get_line_range(line_count - 1)
		return last_range.y
	return 0


# ---------------------------------------------------------------------------
# Drag mechanics
# ---------------------------------------------------------------------------


func _begin_drag_tracking() -> void:
	set_process(true)
	set_process_input(true)


func _end_drag() -> void:
	if not _selecting:
		return
	_selecting = false
	set_process(false)
	set_process_input(false)


# Per-frame poll while a drag is in flight. _gui_input motion events
# stop arriving once the cursor leaves our rect, so we read the global
# mouse position directly to keep extending selection regardless.
# Mirrors TextBlock's pattern.
func _process(_delta: float) -> void:
	if not _selecting:
		return
	var local := get_local_mouse_position()
	var hit := _hit_test_position(local)
	if hit.is_empty():
		return
	var new_item: int = hit["item"]
	var new_char: int = hit["char"]
	if new_item != _sel_focus_item or new_char != _sel_focus_char:
		_sel_focus_item = new_item
		_sel_focus_char = new_char
		queue_redraw()
		emit_signal("selection_changed")


# Catches mouse-up that lands outside our rect. Without this a user who
# starts a drag inside the block but releases off the side would leave
# `_selecting=true` forever, with selection still extending each frame.
func _input(event: InputEvent) -> void:
	if not _selecting:
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_end_drag()


# ---------------------------------------------------------------------------
# Word / line select
# ---------------------------------------------------------------------------


# Select the whole word that contains `char_index` within item `item_idx`.
# Word boundaries: any non-letter, non-digit character.
func _select_word_at(item_idx: int, char_index: int) -> void:
	var text := _item_full_text(item_idx)
	if text.is_empty():
		return
	var n: int = text.length()
	var s: int = clamp(char_index, 0, n)
	var e: int = s
	while s > 0 and _is_word_char(text.unicode_at(s - 1)):
		s -= 1
	while e < n and _is_word_char(text.unicode_at(e)):
		e += 1
	if s == e:
		return
	_sel_anchor_item = item_idx
	_sel_anchor_char = s
	_sel_focus_item = item_idx
	_sel_focus_char = e


func _select_line_at(item_idx: int) -> void:
	# "Line" inside ListBlock = the whole item (we don't distinguish wrap
	# lines for triple-click; matches TextBlock's behaviour where
	# triple-click selects the full TextBlock).
	if item_idx < 0 or item_idx >= _items_spans.size():
		return
	var text_len: int = _item_full_text(item_idx).length()
	_sel_anchor_item = item_idx
	_sel_anchor_char = 0
	_sel_focus_item = item_idx
	_sel_focus_char = text_len


func _is_word_char(c: int) -> bool:
	# ASCII letters / digits + underscore + any non-ASCII (covers CJK,
	# accented Latin, etc.) — same coarse rule TextBlock uses.
	if c >= 0x30 and c <= 0x39:
		return true  # 0-9
	if c >= 0x41 and c <= 0x5a:
		return true  # A-Z
	if c >= 0x61 and c <= 0x7a:
		return true  # a-z
	if c == 0x5f:
		return true  # _
	return c >= 0x80


# ---------------------------------------------------------------------------
# Mouse wheel forwarding
# ---------------------------------------------------------------------------


# Same pattern text_block.gd uses: with mouse_filter STOP we eat wheel
# events that would otherwise reach the enclosing ScrollContainer, so
# manually drive its scroll_vertical / scroll_horizontal. Without this
# the transcript scroll freezes whenever the cursor sits on a list.
const _WHEEL_STEP_PX: float = 40.0


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb: InputEventMouseButton = event
	# Wheel events first — they have to forward regardless of any other
	# state, otherwise the transcript scroll freezes when the cursor sits
	# on a list.
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT:
			_forward_wheel_to_scroll(mb)
			return

	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		accept_event()
		emit_signal("right_clicked", mb.position)
		return

	if mb.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		if mb.pressed:
			_sync_paragraphs()
			var hit := _hit_test_position(mb.position)
			if hit.is_empty():
				return

			# Multi-click detection: same approximate pixel + within
			# the platform double-click window.
			var now: float = Time.get_ticks_msec() / 1000.0
			var within_window: bool = (
				_last_click_time_sec >= 0.0
				and now - _last_click_time_sec <= _MULTI_CLICK_WINDOW_SEC
				and mb.position.distance_to(_last_click_pos) <= _MULTI_CLICK_TOLERANCE_PX
			)
			_click_run = _click_run + 1 if within_window else 1
			if _click_run > 3:
				_click_run = 1
			_last_click_time_sec = now
			_last_click_pos = mb.position

			if mb.shift_pressed and _sel_anchor_item >= 0:
				# Shift-click: keep existing anchor, move focus to the click.
				_sel_focus_item = hit["item"]
				_sel_focus_char = hit["char"]
				_selecting = true
				_begin_drag_tracking()
				queue_redraw()
				emit_signal("selection_changed")
				return

			match _click_run:
				2:
					_select_word_at(hit["item"], hit["char"])
					_selecting = false
				3:
					_select_line_at(hit["item"])
					_selecting = false
				_:
					# Plain click: collapse to a caret at the click position
					# and arm drag tracking.
					_sel_anchor_item = hit["item"]
					_sel_anchor_char = hit["char"]
					_sel_focus_item = hit["item"]
					_sel_focus_char = hit["char"]
					_selecting = true
					_begin_drag_tracking()
			queue_redraw()
			emit_signal("selection_changed")
			# Hook for cross-block selection manager (Step 3). Emit the
			# anchor as a flat char index so the manager can coordinate
			# with sibling blocks. Computing the flat index now avoids
			# the manager having to know about ListBlock's per-item
			# layout.
			emit_signal("selection_drag_started", _flat_char_for(hit["item"], hit["char"]))
		else:
			_end_drag()


# Convert (item, char_in_item) into a single flat char index across the
# whole block. Items are joined by 1 imaginary newline char each, so
# the manager-facing char space is `len(item_0) + 1 + len(item_1) + 1 +
# ... + len(item_N)`. Matches `get_selected_text()`'s join behaviour.
func _flat_char_for(item_idx: int, char_in_item: int) -> int:
	var total: int = 0
	for i in range(item_idx):
		total += _item_full_text(i).length() + 1  # +1 for the joining \n
	return total + char_in_item


func _forward_wheel_to_scroll(mb: InputEventMouseButton) -> void:
	# Wheel events come as paired pressed=true / pressed=false ticks on
	# most platforms. Only react to the "down stroke" so one physical
	# notch produces one scroll step.
	if not mb.pressed:
		return
	var scroll := _find_ancestor_scroll_container()
	if scroll == null:
		return
	var factor: float = mb.factor if mb.factor > 0.0 else 1.0
	var step: int = int(_WHEEL_STEP_PX * max(factor, 1.0))
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			scroll.scroll_vertical = scroll.scroll_vertical - step
		MOUSE_BUTTON_WHEEL_DOWN:
			scroll.scroll_vertical = scroll.scroll_vertical + step
		MOUSE_BUTTON_WHEEL_LEFT:
			scroll.scroll_horizontal = scroll.scroll_horizontal - step
		MOUSE_BUTTON_WHEEL_RIGHT:
			scroll.scroll_horizontal = scroll.scroll_horizontal + step


func _find_ancestor_scroll_container() -> ScrollContainer:
	var node := get_parent()
	while node != null:
		if node is ScrollContainer:
			return node
		node = node.get_parent()
	return null
