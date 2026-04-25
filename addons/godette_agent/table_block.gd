@tool
class_name GodetteTableBlock
extends Control
#
# Single Control that renders a markdown table — same Route 3 pattern as
# GodetteListBlock, applied to N×M cells.
#
# Replaces the legacy Path A table tree:
#
#   table  (PanelContainer + StyleBoxFlat outer border)
#   └── grid  (GridContainer)
#       ├── cell_bg  (PanelContainer + StyleBoxFlat per-cell border)  ─┐
#       │   └── cell_pad  (MarginContainer)                            │ × N×M
#       │       └── cell_tb  (GodetteTextBlock)                       ─┘
#
# That tree was 4 controls per cell × N×M cells + 2 outer = ~4·N·M+2
# Controls per table. A 4-column × 6-row table = 98 Controls all
# participating in Container layout cascade. With ListBlock now flattened,
# tables were the last big source of VirtualFeed measure-drift bugs.
#
# This block flattens to a SINGLE Control that:
#   - owns N×M TextParagraph instances (shape once per cell)
#   - self-draws cell borders, header bg, outer rounded panel
#   - applies GFM alignment markers (-1 left, 0 center, 1 right)
#   - reports a single accurate `_get_minimum_size().y` based on the
#     summed row heights + outer border + per-cell padding
#   - exposes the cross-block selection-manager protocol (flat-char
#     coordinate space: cells joined by '\t', rows joined by '\n')
#
# ---------------------------------------------------------------------------
# Public construction API
# ---------------------------------------------------------------------------
#
# Call once after construction:
#   set_columns(n, alignments)
#
# Then per row/cell during markdown event walk:
#   begin_row(is_header)
#     begin_cell()
#       append_span(text, opts)        # or append_text(delta)
#       ...
#     end_cell()
#     ...
#   end_row()
#
# Mirrors ListBlock's `begin_item / append_span / end_item` shape so
# `markdown_render._handle_text` can target a TableBlock the same way it
# targets a ListBlock — via duck-typed `has_method("append_span")`.

# Layout constants — match existing markdown_render values so visual
# parity is byte-close to the legacy renderer.
const CELL_PAD_X: float = 8.0
const CELL_PAD_Y: float = 4.0
const BORDER_W: float = 1.0
const OUTER_CORNER_RADIUS: int = 3

# GFM alignment values (match parser convention).
const ALIGN_LEFT: int = -1
const ALIGN_CENTER: int = 0
const ALIGN_RIGHT: int = 1


# ---------------------------------------------------------------------------
# Public state setters
# ---------------------------------------------------------------------------


var _columns: int = 0
var _alignments: PackedInt32Array = PackedInt32Array()
# Per-row cell span lists. Outer = rows, middle = cells in row, inner =
# spans in cell. Cells in a row may have len < _columns (parser quirk on
# malformed tables) — drawing iterates `_columns` and treats missing
# cells as empty.
var _rows_spans: Array = []
# 1 = header row, 0 = body row. Same length as _rows_spans.
var _row_is_header: PackedByteArray = PackedByteArray()


func set_columns(count: int, alignments: Array) -> void:
	_columns = max(1, count)
	_alignments.resize(_columns)
	# markdown.gd emits alignments as strings ("left"/"center"/"right"/
	# "none"), one per column. Map to our int convention (-1/0/1). "none"
	# = no GFM marker present → default to left (the GFM convention).
	# Earlier versions called `int(alignments[i])` which silently coerced
	# every string to 0, making every column render as ALIGN_CENTER —
	# that's why the test fixture all looked centred regardless of marker.
	for i in range(_columns):
		var a: int = ALIGN_LEFT
		if i < alignments.size():
			var raw = alignments[i]
			if raw is String:
				match raw:
					"center":
						a = ALIGN_CENTER
					"right":
						a = ALIGN_RIGHT
					_:
						a = ALIGN_LEFT
			else:
				a = int(raw)
		_alignments[i] = a
	_dirty = true
	_sync_layout()
	update_minimum_size()
	queue_redraw()


# Incremental builder API. Used by markdown_render to feed table_row /
# table_cell events directly into the block, so cells shape + measure
# as the parser walks them.
func begin_row(is_header: bool) -> void:
	_building_row_cells = []
	_building_row_is_header = is_header


func begin_cell() -> void:
	_building_cell_spans = []


func append_span(text: String, opts: Dictionary = {}) -> void:
	var clean: String = text
	if clean.is_empty():
		return
	var span: Dictionary = opts.duplicate()
	span["text"] = clean
	_building_cell_spans.append(span)


func append_text(delta: String) -> void:
	append_span(delta, {})


func end_cell() -> void:
	_building_row_cells.append(_building_cell_spans)
	_building_cell_spans = []


func end_row() -> void:
	_rows_spans.append(_building_row_cells)
	_row_is_header.append(1 if _building_row_is_header else 0)
	_building_row_cells = []
	_building_row_is_header = false
	_dirty = true
	_sync_layout()
	update_minimum_size()
	queue_redraw()


func set_color(value: Color) -> void:
	if value == _color:
		return
	_color = value
	queue_redraw()


# Selection highlight color. Driven from markdown ctx so cross-block
# selection paints in the same blue across paragraphs / lists / tables.
func set_selection_color(value: Color) -> void:
	if value == _selection_color:
		return
	_selection_color = value
	queue_redraw()


# Outer panel + per-cell separator color.
func set_border_color(value: Color) -> void:
	if value == _border_color:
		return
	_border_color = value
	_outer_stylebox = null  # rebuild lazily
	queue_redraw()


# Header row background fill. Same color the legacy table used (the
# inline-code chip color, subdued).
func set_header_bg(value: Color) -> void:
	if value == _header_bg:
		return
	_header_bg = value
	queue_redraw()


# Inline span fonts — same shape as ListBlock.set_fonts. Plain-text spans
# use `_font`; bold/italic/code spans look up the matching slot via the
# span's `font` field set by markdown_render.
func set_fonts(plain: Font, bold: Font, italic: Font, bold_italic: Font, mono: Font) -> void:
	_font = plain
	_font_bold = bold
	_font_italic = italic
	_font_bold_italic = bold_italic
	_font_mono = mono
	_dirty = true
	_sync_layout()
	update_minimum_size()
	queue_redraw()


func set_font_size(value: int) -> void:
	if value == _font_size:
		return
	_font_size = value
	_dirty = true
	_sync_layout()
	update_minimum_size()
	queue_redraw()


func set_line_spacing(value: float) -> void:
	if is_equal_approx(value, _line_spacing):
		return
	_line_spacing = value
	_dirty = true
	_sync_layout()
	queue_redraw()


# ---------------------------------------------------------------------------
# Theme + state
# ---------------------------------------------------------------------------


var _font: Font = null
var _font_bold: Font = null
var _font_italic: Font = null
var _font_bold_italic: Font = null
var _font_mono: Font = null
var _font_size: int = 0
var _color: Color = Color(1, 1, 1, 1)
var _line_spacing: float = 0.0
var _border_color: Color = Color(1, 1, 1, 0.3)
var _header_bg: Color = Color(1, 1, 1, 0.05)
var _selection_color: Color = Color(0.28, 0.42, 0.78, 0.45)

# Building state — populated by begin_row/cell, drained by end_row/cell.
var _building_row_cells: Array = []
var _building_cell_spans: Array = []
var _building_row_is_header: bool = false

# Per-cell shaped paragraphs and computed layout. Rebuilt on dirty +
# width changes.
var _cell_paragraphs: Array = []  # Array[Array[TextParagraph]] [row][col]
var _col_widths: PackedFloat32Array = PackedFloat32Array()
var _row_heights: PackedFloat32Array = PackedFloat32Array()
var _row_y_tops: PackedFloat32Array = PackedFloat32Array()
var _dirty: bool = true
var _current_width: float = 0.0
var _outer_stylebox: StyleBoxFlat = null

# Selection state. (-1, -1, -1) means "no selection". Spans from anchor
# to focus in user-drag order; `_normalized_selection()` returns them
# in document order (top-to-bottom, then left-to-right within a row).
var _sel_anchor_row: int = -1
var _sel_anchor_col: int = -1
var _sel_anchor_char: int = -1
var _sel_focus_row: int = -1
var _sel_focus_col: int = -1
var _sel_focus_char: int = -1
var _selecting: bool = false
var _selection_manager: Object = null

# Multi-click detection (matches ListBlock / TextBlock).
const _MULTI_CLICK_WINDOW_SEC: float = 0.45
const _MULTI_CLICK_TOLERANCE_PX: float = 4.0
var _last_click_time_sec: float = -1.0
var _last_click_pos: Vector2 = Vector2.ZERO
var _click_run: int = 0

signal selection_changed()
signal right_clicked(local_pos: Vector2)
signal selection_drag_started(flat_char: int)


func _init() -> void:
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	mouse_filter = Control.MOUSE_FILTER_STOP


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			if not is_equal_approx(size.x, _current_width):
				_current_width = size.x
				_dirty = true
				_sync_layout()
				update_minimum_size()
				queue_redraw()
		NOTIFICATION_THEME_CHANGED, NOTIFICATION_ENTER_TREE:
			_dirty = true
			if is_inside_tree():
				_sync_layout()
				update_minimum_size()
				queue_redraw()


func _get_minimum_size() -> Vector2:
	if _rows_spans.is_empty() or _columns <= 0:
		return Vector2.ZERO
	_sync_layout()
	# Total height = outer top border + sum(row_heights) + outer bottom border
	var total: float = BORDER_W * 2.0
	for h in _row_heights:
		total += h
	return Vector2(0.0, total)


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------


func _draw() -> void:
	if _rows_spans.is_empty() or _columns <= 0:
		return
	_sync_layout()
	var canvas := get_canvas_item()
	# Draw order, mirrors how the legacy nested-Container path stacks:
	#   1. header bg fills (per-cell, header rows only)
	#   2. inline-span chip backgrounds inside cells (code/link bg)
	#   3. selection rectangles
	#   4. cell text glyphs
	#   5. inner cell borders (right + bottom edges, except outermost)
	#   6. outer rounded panel border on top — covers any sub-pixel
	#      bleeding from inner borders at the corners
	for r in range(_rows_spans.size()):
		if _row_is_header[r] != 0:
			for c in range(_columns):
				var rect := _cell_rect(r, c)
				draw_rect(rect, _header_bg)

	for r in range(_rows_spans.size()):
		for c in range(_columns):
			_draw_cell_span_backgrounds(r, c)

	if has_selection():
		_draw_selection_rects()

	for r in range(_rows_spans.size()):
		for c in range(_columns):
			var p: TextParagraph = _cell_paragraph(r, c)
			if p == null:
				continue
			var origin := _cell_text_origin(r, c, p)
			p.draw(canvas, origin, _color)

	# Inner cell borders. Only draw bottom edges if not last row, and
	# right edges if not last column — outer panel paints those.
	for r in range(_rows_spans.size()):
		for c in range(_columns):
			var cr := _cell_rect(r, c)
			if r < _rows_spans.size() - 1:
				draw_line(
					Vector2(cr.position.x, cr.position.y + cr.size.y),
					Vector2(cr.position.x + cr.size.x, cr.position.y + cr.size.y),
					_border_color, BORDER_W
				)
			if c < _columns - 1:
				draw_line(
					Vector2(cr.position.x + cr.size.x, cr.position.y),
					Vector2(cr.position.x + cr.size.x, cr.position.y + cr.size.y),
					_border_color, BORDER_W
				)

	# Outer rounded border. Cached StyleBoxFlat — rebuild only if
	# border color changed (set_border_color invalidates).
	if _outer_stylebox == null:
		_outer_stylebox = StyleBoxFlat.new()
		_outer_stylebox.bg_color = Color(0, 0, 0, 0)
		_outer_stylebox.border_color = _border_color
		_outer_stylebox.set_border_width_all(int(BORDER_W))
		_outer_stylebox.set_corner_radius_all(OUTER_CORNER_RADIUS)
	draw_style_box(_outer_stylebox, Rect2(Vector2.ZERO, Vector2(size.x, _get_minimum_size().y)))


# ---------------------------------------------------------------------------
# Cell geometry helpers
# ---------------------------------------------------------------------------


# Returns the OUTER rect of cell (r, c) in block-local coords — i.e. the
# full cell box including padding, with edges meeting neighbouring cells'
# edges. Drawing uses this for header bg and border lines.
func _cell_rect(r: int, c: int) -> Rect2:
	var x: float = BORDER_W
	for cc in range(c):
		x += _col_widths[cc]
	var y: float = BORDER_W + _row_y_tops[r]
	return Rect2(Vector2(x, y), Vector2(_col_widths[c], _row_heights[r]))


# Returns the (x, y) where TextParagraph.draw should land for cell (r, c)
# given its alignment. y respects vertical centering inside the row;
# x picks the alignment offset within the cell content area.
func _cell_text_origin(r: int, c: int, paragraph: TextParagraph) -> Vector2:
	var rect := _cell_rect(r, c)
	var content_x: float = rect.position.x + CELL_PAD_X
	var content_w: float = rect.size.x - CELL_PAD_X * 2.0
	var p_size: Vector2 = paragraph.get_size()
	var align: int = ALIGN_LEFT
	if c < _alignments.size():
		align = _alignments[c]
	var x_offset: float = 0.0
	match align:
		ALIGN_CENTER:
			x_offset = max(0.0, (content_w - p_size.x) * 0.5)
		ALIGN_RIGHT:
			x_offset = max(0.0, content_w - p_size.x)
		_:
			x_offset = 0.0
	# Vertical center inside the row (matches legacy SHRINK_CENTER cell
	# behaviour). Tall cells dominate the row's height, short cells get
	# centred whitespace top/bottom.
	var y_offset: float = max(0.0, (rect.size.y - p_size.y) * 0.5)
	return Vector2(content_x + x_offset, rect.position.y + y_offset)


func _cell_paragraph(r: int, c: int) -> TextParagraph:
	if r < 0 or r >= _cell_paragraphs.size():
		return null
	var row: Array = _cell_paragraphs[r]
	if c < 0 or c >= row.size():
		return null
	return row[c]


# Returns the cell's spans array, or empty if missing (parser quirk).
func _cell_spans(r: int, c: int) -> Array:
	if r < 0 or r >= _rows_spans.size():
		return []
	var row: Array = _rows_spans[r]
	if c < 0 or c >= row.size():
		return []
	return row[c]


func _cell_full_text(r: int, c: int) -> String:
	var spans := _cell_spans(r, c)
	if spans.is_empty():
		return ""
	var parts := PackedStringArray()
	for span_var in spans:
		parts.append(str(span_var.get("text", "")))
	return "".join(parts)


# ---------------------------------------------------------------------------
# Layout / shaping
# ---------------------------------------------------------------------------


func _sync_layout() -> void:
	if _columns <= 0 or _rows_spans.is_empty():
		_cell_paragraphs.clear()
		_col_widths = PackedFloat32Array()
		_row_heights = PackedFloat32Array()
		_row_y_tops = PackedFloat32Array()
		return
	# Recompute column widths every call — `size.x` may have changed
	# without dirty flag (e.g. during the resize cascade between frames).
	# Equal-width columns for v1; richer auto-fit (proportional to natural
	# content width) is a follow-up if needed.
	_resolve_column_widths()
	if _dirty or _cell_paragraphs.size() != _rows_spans.size():
		_rebuild_paragraphs()
		_dirty = false
	else:
		_apply_widths_to_paragraphs()
	_recompute_row_heights()


func _resolve_column_widths() -> void:
	# Total = size.x - 2*BORDER_W (outer left + right edges). When size.x
	# is 0 (block not yet laid out) fall back to a generous width so the
	# initial measure returns something sane; the real width will arrive
	# via NOTIFICATION_RESIZED.
	var total_w: float = size.x - BORDER_W * 2.0
	if total_w <= 0.0:
		total_w = 600.0
	_col_widths.resize(_columns)
	var per_col: float = total_w / float(_columns)
	for c in range(_columns):
		_col_widths[c] = per_col


func _rebuild_paragraphs() -> void:
	_cell_paragraphs.clear()
	for r in range(_rows_spans.size()):
		var row_spans: Array = _rows_spans[r]
		var row_paragraphs: Array = []
		var is_header: bool = _row_is_header[r] != 0
		for c in range(_columns):
			var spans: Array = []
			if c < row_spans.size():
				spans = row_spans[c]
			var p := TextParagraph.new()
			p.line_spacing = _line_spacing
			p.width = max(1.0, _col_widths[c] - CELL_PAD_X * 2.0)
			for span_var in spans:
				var span: Dictionary = span_var
				var span_text: String = str(span.get("text", ""))
				if span_text.is_empty():
					continue
				var font: Font = _resolve_span_font(span, is_header)
				var font_size: int = _resolve_span_font_size(span)
				p.add_string(span_text, font, font_size)
			row_paragraphs.append(p)
		_cell_paragraphs.append(row_paragraphs)


func _apply_widths_to_paragraphs() -> void:
	for r in range(_cell_paragraphs.size()):
		var row: Array = _cell_paragraphs[r]
		for c in range(row.size()):
			var p: TextParagraph = row[c]
			if p == null:
				continue
			var w: float = max(1.0, _col_widths[c] - CELL_PAD_X * 2.0)
			if not is_equal_approx(p.width, w):
				p.width = w


func _recompute_row_heights() -> void:
	_row_heights.resize(_cell_paragraphs.size())
	_row_y_tops.resize(_cell_paragraphs.size())
	var running: float = 0.0
	for r in range(_cell_paragraphs.size()):
		_row_y_tops[r] = running
		var max_p_h: float = 0.0
		var row: Array = _cell_paragraphs[r]
		for p_var in row:
			var p: TextParagraph = p_var
			if p == null:
				continue
			var ph: float = p.get_size().y
			if ph > max_p_h:
				max_p_h = ph
		var row_h: float = max_p_h + CELL_PAD_Y * 2.0
		_row_heights[r] = row_h
		running += row_h


# ---------------------------------------------------------------------------
# Span helpers
# ---------------------------------------------------------------------------


func _resolve_span_font(span: Dictionary, is_header: bool) -> Font:
	var f = span.get("font", null)
	if f is Font:
		return f
	# Header rows default to bold even for plain spans, matching the
	# legacy `if is_header: tb.set_font(ctx["font_bold"])` behaviour.
	if is_header and _font_bold != null:
		return _font_bold
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
	var inherited := get_theme_default_font_size()
	if inherited > 0:
		return inherited
	return 14


# ---------------------------------------------------------------------------
# Inline-span chip backgrounds inside one cell
# ---------------------------------------------------------------------------


func _draw_cell_span_backgrounds(r: int, c: int) -> void:
	var spans := _cell_spans(r, c)
	if spans.is_empty():
		return
	var p := _cell_paragraph(r, c)
	if p == null:
		return
	var origin := _cell_text_origin(r, c, p)
	var char_cursor: int = 0
	for span_var in spans:
		var span: Dictionary = span_var
		var span_text: String = str(span.get("text", ""))
		var span_len: int = span_text.length()
		if span_len <= 0:
			continue
		var bg_variant = span.get("bg", null)
		if bg_variant is Color:
			_draw_paragraph_range_rect(p, char_cursor, char_cursor + span_len, bg_variant as Color, origin, true)
		char_cursor += span_len


# ---------------------------------------------------------------------------
# Selection drawing
# ---------------------------------------------------------------------------


func _draw_selection_rects() -> void:
	var norm := _normalized_selection()
	var s_row: int = norm["start_row"]
	var s_col: int = norm["start_col"]
	var s_char: int = norm["start_char"]
	var e_row: int = norm["end_row"]
	var e_col: int = norm["end_col"]
	var e_char: int = norm["end_char"]
	# Iterate every cell in document order from (s_row, s_col) through
	# (e_row, e_col) inclusive. For each, paint either:
	#   - partial range (anchor or focus cell, or single-cell selection)
	#   - full cell text  (cells strictly between anchor and focus)
	for r in range(s_row, e_row + 1):
		var col_lo: int
		var col_hi: int
		if r == s_row and r == e_row:
			col_lo = s_col
			col_hi = e_col
		elif r == s_row:
			col_lo = s_col
			col_hi = _columns - 1
		elif r == e_row:
			col_lo = 0
			col_hi = e_col
		else:
			col_lo = 0
			col_hi = _columns - 1
		for c in range(col_lo, col_hi + 1):
			var p := _cell_paragraph(r, c)
			if p == null:
				continue
			var span_start: int
			var span_end: int
			var is_first := (r == s_row and c == s_col)
			var is_last := (r == e_row and c == e_col)
			if is_first and is_last:
				span_start = s_char
				span_end = e_char
			elif is_first:
				span_start = s_char
				span_end = _cell_full_text(r, c).length()
			elif is_last:
				span_start = 0
				span_end = e_char
			else:
				span_start = 0
				span_end = _cell_full_text(r, c).length()
			if span_end <= span_start:
				continue
			var origin := _cell_text_origin(r, c, p)
			_draw_paragraph_range_rect(p, span_start, span_end, _selection_color, origin, false)


# Paints a filled rect covering character range [s, e) within `paragraph`,
# anchored at `origin`. Walks each line the range crosses and emits one
# rect per line. `is_chip` toggles the chip-style 2px x-padding on
# (matches inline code chips); selection rendering passes false so its
# rects don't extend past the glyphs.
#
# Borrows from list_block.gd's twin function but in cell-coord space.
func _draw_paragraph_range_rect(
	paragraph: TextParagraph, s: int, e: int, color: Color, origin: Vector2, is_chip: bool
) -> void:
	if e <= s or paragraph == null:
		return
	var pad_x: float = 2.0 if is_chip else 0.0
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
		var continues_to_next_line: bool = e > line_end
		var start_x: float
		if overlap_start == line_start:
			start_x = 0.0
		else:
			start_x = _line_char_x_local(line_rid, overlap_start - line_start, line_size.x, false)
		var end_x: float
		# For selection rects: also snap to line_size.x when the range
		# ends exactly at line_end (degenerate caret rect workaround,
		# same as ListBlock's split). Chips don't get this since they
		# should hug the glyphs tightly.
		if continues_to_next_line or (not is_chip and overlap_end == line_end):
			end_x = line_size.x
		else:
			end_x = _line_char_x_local(line_rid, overlap_end - line_start, line_size.x, true)
		if end_x <= start_x:
			y_cursor += row_advance
			continue
		var rect_h: float
		if is_chip:
			rect_h = line_size.y
		else:
			# Inner wrap rows extend by row_advance so adjacent rects abut.
			rect_h = row_advance if line_idx < line_count - 1 else line_size.y
		var rect := Rect2(
			Vector2(origin.x + start_x - pad_x, origin.y + y_cursor),
			Vector2(end_x - start_x + pad_x * 2.0, rect_h),
		)
		draw_rect(rect, color)
		y_cursor += row_advance


func _line_char_x_local(line_rid: RID, char_in_line: int, line_width: float, is_end: bool) -> float:
	# Direct port of list_block.gd's twin helper — see that file for the
	# glyph-iterate fallback rationale.
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
# Selection — local API
# ---------------------------------------------------------------------------


func has_selection() -> bool:
	if _sel_anchor_row < 0 or _sel_focus_row < 0:
		return false
	return (
		_sel_anchor_row != _sel_focus_row
		or _sel_anchor_col != _sel_focus_col
		or _sel_anchor_char != _sel_focus_char
	)


func clear_selection() -> void:
	if _sel_anchor_row == -1 and _sel_focus_row == -1:
		return
	_sel_anchor_row = -1
	_sel_anchor_col = -1
	_sel_anchor_char = -1
	_sel_focus_row = -1
	_sel_focus_col = -1
	_sel_focus_char = -1
	_selecting = false
	set_process(false)
	set_process_input(false)
	queue_redraw()
	emit_signal("selection_changed")


func get_selected_text() -> String:
	if not has_selection():
		return ""
	var norm := _normalized_selection()
	var s_row: int = norm["start_row"]
	var s_col: int = norm["start_col"]
	var s_char: int = norm["start_char"]
	var e_row: int = norm["end_row"]
	var e_col: int = norm["end_col"]
	var e_char: int = norm["end_char"]
	# Rows are joined by '\n', cells within a row by '\t'. Matches the
	# get_text() join convention so flat-char indexing stays consistent
	# between selection and full-text reads. '\t' between cells means the
	# clipboard output pastes cleanly into Excel / IDE table tools.
	var row_strs := PackedStringArray()
	for r in range(s_row, e_row + 1):
		var col_lo: int
		var col_hi: int
		if r == s_row and r == e_row:
			col_lo = s_col
			col_hi = e_col
		elif r == s_row:
			col_lo = s_col
			col_hi = _columns - 1
		elif r == e_row:
			col_lo = 0
			col_hi = e_col
		else:
			col_lo = 0
			col_hi = _columns - 1
		var cell_strs := PackedStringArray()
		for c in range(col_lo, col_hi + 1):
			var full := _cell_full_text(r, c)
			var span_start: int
			var span_end: int
			var is_first := (r == s_row and c == s_col)
			var is_last := (r == e_row and c == e_col)
			if is_first and is_last:
				span_start = s_char
				span_end = e_char
			elif is_first:
				span_start = s_char
				span_end = full.length()
			elif is_last:
				span_start = 0
				span_end = e_char
			else:
				span_start = 0
				span_end = full.length()
			cell_strs.append(full.substr(span_start, max(0, span_end - span_start)))
		# Pad with empty strings for skipped leading cells so '\t' positions
		# match the table layout (the clipboard text reflects which column
		# each substring came from). Pad trailing too so each row has the
		# same number of '\t' separators.
		var leading_pad := PackedStringArray()
		for _i in range(col_lo):
			leading_pad.append("")
		var trailing_pad := PackedStringArray()
		for _i in range(_columns - 1 - col_hi):
			trailing_pad.append("")
		var combined := PackedStringArray()
		combined.append_array(leading_pad)
		combined.append_array(cell_strs)
		combined.append_array(trailing_pad)
		row_strs.append("\t".join(combined))
	return "\n".join(row_strs)


func _normalized_selection() -> Dictionary:
	var ar := _sel_anchor_row
	var ac := _sel_anchor_col
	var ach := _sel_anchor_char
	var fr := _sel_focus_row
	var fc := _sel_focus_col
	var fch := _sel_focus_char
	# Document order = row-major: (row, col, char) lexicographic.
	var anchor_first: bool = (
		ar < fr
		or (ar == fr and ac < fc)
		or (ar == fr and ac == fc and ach <= fch)
	)
	if anchor_first:
		return {
			"start_row": ar, "start_col": ac, "start_char": ach,
			"end_row": fr, "end_col": fc, "end_char": fch,
		}
	return {
		"start_row": fr, "start_col": fc, "start_char": fch,
		"end_row": ar, "end_col": ac, "end_char": ach,
	}


# ---------------------------------------------------------------------------
# Hit testing
# ---------------------------------------------------------------------------


# Translate a local mouse position into (row, col, char_in_cell).
# Always returns a valid triple — clamped to the nearest cell when the
# point is outside the table proper (above / below / off to one side).
func _hit_test_position(local_pos: Vector2) -> Dictionary:
	if _rows_spans.is_empty() or _columns <= 0:
		return {}
	# Resolve row first.
	var n_rows: int = _rows_spans.size()
	var inner_y: float = local_pos.y - BORDER_W
	var target_row: int = n_rows - 1
	if inner_y <= 0.0:
		target_row = 0
	else:
		for r in range(n_rows):
			var top: float = _row_y_tops[r]
			var bot: float = top + _row_heights[r]
			if inner_y < bot:
				target_row = r
				break
	# Resolve column.
	var inner_x: float = local_pos.x - BORDER_W
	var target_col: int = _columns - 1
	var x_cursor: float = 0.0
	for c in range(_columns):
		var col_w: float = _col_widths[c]
		if inner_x < x_cursor + col_w:
			target_col = c
			break
		x_cursor += col_w
	if inner_x <= 0.0:
		target_col = 0
	# Resolve char inside the cell paragraph.
	var p := _cell_paragraph(target_row, target_col)
	if p == null:
		return {"row": target_row, "col": target_col, "char": 0}
	var origin := _cell_text_origin(target_row, target_col, p)
	var paragraph_local := Vector2(local_pos.x - origin.x, local_pos.y - origin.y)
	var char_in_cell: int = _hit_test_char_in_paragraph(p, paragraph_local)
	return {"row": target_row, "col": target_col, "char": char_in_cell}


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
	if line_count > 0:
		var last_range: Vector2i = paragraph.get_line_range(line_count - 1)
		return last_range.y
	return 0


# ---------------------------------------------------------------------------
# Word / line select
# ---------------------------------------------------------------------------


func _select_word_at(r: int, c: int, char_in_cell: int) -> void:
	var text := _cell_full_text(r, c)
	if text.is_empty():
		return
	var n: int = text.length()
	var s: int = clamp(char_in_cell, 0, n)
	var e: int = s
	while s > 0 and _is_word_char(text.unicode_at(s - 1)):
		s -= 1
	while e < n and _is_word_char(text.unicode_at(e)):
		e += 1
	if s == e:
		return
	_sel_anchor_row = r
	_sel_anchor_col = c
	_sel_anchor_char = s
	_sel_focus_row = r
	_sel_focus_col = c
	_sel_focus_char = e


# Triple-click: select the entire cell content (matches TextBlock /
# ListBlock pattern where triple-click selects the whole block).
func _select_line_at(r: int, c: int) -> void:
	var text_len: int = _cell_full_text(r, c).length()
	_sel_anchor_row = r
	_sel_anchor_col = c
	_sel_anchor_char = 0
	_sel_focus_row = r
	_sel_focus_col = c
	_sel_focus_char = text_len


func _is_word_char(c: int) -> bool:
	if c >= 0x30 and c <= 0x39:
		return true
	if c >= 0x41 and c <= 0x5a:
		return true
	if c >= 0x61 and c <= 0x7a:
		return true
	if c == 0x5f:
		return true
	return c >= 0x80


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


func _process(_delta: float) -> void:
	if not _selecting:
		return
	var local := get_local_mouse_position()
	var hit := _hit_test_position(local)
	if hit.is_empty():
		return
	var nr: int = hit["row"]
	var nc: int = hit["col"]
	var nch: int = hit["char"]
	if nr != _sel_focus_row or nc != _sel_focus_col or nch != _sel_focus_char:
		_sel_focus_row = nr
		_sel_focus_col = nc
		_sel_focus_char = nch
		queue_redraw()
		emit_signal("selection_changed")


func _input(event: InputEvent) -> void:
	if not _selecting:
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_end_drag()


# ---------------------------------------------------------------------------
# Mouse input
# ---------------------------------------------------------------------------


const _WHEEL_STEP_PX: float = 40.0


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb: InputEventMouseButton = event
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
			_sync_layout()
			var hit := _hit_test_position(mb.position)
			if hit.is_empty():
				return
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

			var has_manager: bool = (
				_selection_manager != null and is_instance_valid(_selection_manager)
			)

			if mb.shift_pressed and _sel_anchor_row >= 0:
				_sel_focus_row = hit["row"]
				_sel_focus_col = hit["col"]
				_sel_focus_char = hit["char"]
				_selecting = true
				_begin_drag_tracking()
				queue_redraw()
				emit_signal("selection_changed")
				return

			match _click_run:
				2:
					_select_word_at(hit["row"], hit["col"], hit["char"])
					_selecting = false
				3:
					_select_line_at(hit["row"], hit["col"])
					_selecting = false
				_:
					_sel_anchor_row = hit["row"]
					_sel_anchor_col = hit["col"]
					_sel_anchor_char = hit["char"]
					_sel_focus_row = hit["row"]
					_sel_focus_col = hit["col"]
					_sel_focus_char = hit["char"]
					if has_manager:
						_selecting = false
					else:
						_selecting = true
						_begin_drag_tracking()
			queue_redraw()
			emit_signal("selection_changed")
			emit_signal(
				"selection_drag_started",
				_flat_char_for(hit["row"], hit["col"], hit["char"])
			)
		else:
			# Mouse-up: link click (no-drag-on-link-span → OS.shell_open).
			# Same logic as ListBlock — see that file for rationale.
			var moved: bool = mb.position.distance_to(_last_click_pos) > _MULTI_CLICK_TOLERANCE_PX
			var has_sel: bool = (
				_sel_anchor_row != _sel_focus_row
				or _sel_anchor_col != _sel_focus_col
				or _sel_anchor_char != _sel_focus_char
			)
			_end_drag()
			if not moved and not has_sel:
				var release_hit := _hit_test_position(mb.position)
				if not release_hit.is_empty():
					var href: String = _link_at(
						release_hit["row"], release_hit["col"], release_hit["char"]
					)
					if not href.is_empty():
						if href.begins_with("http://") or href.begins_with("https://"):
							OS.shell_open(href)


# Walk one cell's spans to find the href at `char_in_cell`. Same shape
# as ListBlock._link_at scoped per cell.
func _link_at(r: int, c: int, char_in_cell: int) -> String:
	var spans := _cell_spans(r, c)
	if spans.is_empty() or char_in_cell < 0:
		return ""
	var cursor: int = 0
	for span_v in spans:
		var span: Dictionary = span_v
		var span_text: String = str(span.get("text", ""))
		var span_len: int = span_text.length()
		if span_len <= 0:
			continue
		if char_in_cell >= cursor and char_in_cell < cursor + span_len:
			return str(span.get("href", ""))
		cursor += span_len
	return ""


func _forward_wheel_to_scroll(mb: InputEventMouseButton) -> void:
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


# ---------------------------------------------------------------------------
# Selection — cross-block manager protocol
# ---------------------------------------------------------------------------
#
# Same protocol shape as ListBlock — flat int char positions. The flat
# space here joins cells in a row by '\t' and rows by '\n', matching
# get_text() / get_selected_text(). The manager doesn't need to know
# about the row/col grid; it only sees flat char positions and we
# decompose internally on every read/write.


func register_selection_manager(manager: Object) -> void:
	_selection_manager = manager


func clear_selection_silent() -> void:
	if _sel_anchor_row == -1 and _sel_focus_row == -1:
		return
	_sel_anchor_row = -1
	_sel_anchor_col = -1
	_sel_anchor_char = -1
	_sel_focus_row = -1
	_sel_focus_col = -1
	_sel_focus_char = -1
	_selecting = false
	queue_redraw()


func select_range(a: int, b: int) -> void:
	var pa: Dictionary = _flat_to_triple(a)
	var pb: Dictionary = _flat_to_triple(b)
	_sel_anchor_row = pa["row"]
	_sel_anchor_col = pa["col"]
	_sel_anchor_char = pa["char"]
	_sel_focus_row = pb["row"]
	_sel_focus_col = pb["col"]
	_sel_focus_char = pb["char"]
	queue_redraw()


func select_from_char(start_char: int) -> void:
	if _rows_spans.is_empty() or _columns <= 0:
		_sel_anchor_row = -1
		_sel_focus_row = -1
		return
	var p := _flat_to_triple(start_char)
	_sel_anchor_row = p["row"]
	_sel_anchor_col = p["col"]
	_sel_anchor_char = p["char"]
	var last_row: int = _rows_spans.size() - 1
	var last_col: int = _columns - 1
	_sel_focus_row = last_row
	_sel_focus_col = last_col
	_sel_focus_char = _cell_full_text(last_row, last_col).length()
	queue_redraw()


func select_to_char(end_char: int) -> void:
	if _rows_spans.is_empty() or _columns <= 0:
		_sel_anchor_row = -1
		_sel_focus_row = -1
		return
	_sel_anchor_row = 0
	_sel_anchor_col = 0
	_sel_anchor_char = 0
	var p := _flat_to_triple(end_char)
	_sel_focus_row = p["row"]
	_sel_focus_col = p["col"]
	_sel_focus_char = p["char"]
	queue_redraw()


func select_all() -> void:
	if _rows_spans.is_empty() or _columns <= 0:
		return
	_sel_anchor_row = 0
	_sel_anchor_col = 0
	_sel_anchor_char = 0
	var last_row: int = _rows_spans.size() - 1
	var last_col: int = _columns - 1
	_sel_focus_row = last_row
	_sel_focus_col = last_col
	_sel_focus_char = _cell_full_text(last_row, last_col).length()
	queue_redraw()


func get_selection_anchor() -> int:
	if _sel_anchor_row < 0:
		return -1
	return _flat_char_for(_sel_anchor_row, _sel_anchor_col, _sel_anchor_char)


func get_selection_caret() -> int:
	if _sel_focus_row < 0:
		return -1
	return _flat_char_for(_sel_focus_row, _sel_focus_col, _sel_focus_char)


func get_text() -> String:
	if _rows_spans.is_empty() or _columns <= 0:
		return ""
	var row_strs := PackedStringArray()
	for r in range(_rows_spans.size()):
		var cell_strs := PackedStringArray()
		for c in range(_columns):
			cell_strs.append(_cell_full_text(r, c))
		row_strs.append("\t".join(cell_strs))
	return "\n".join(row_strs)


func hit_test_char(local_pos: Vector2) -> int:
	var hit := _hit_test_position(local_pos)
	if hit.is_empty():
		return 0
	return _flat_char_for(hit["row"], hit["col"], hit["char"])


# ---------------------------------------------------------------------------
# Flat-char ↔ (row, col, char) bidirection
# ---------------------------------------------------------------------------


# Convert (row, col, char_in_cell) into a flat int char index across the
# whole table. Cells are joined by 1 imaginary '\t' each, rows by 1
# imaginary '\n'. The flat space matches `get_text()` / `get_selected_text()`
# byte-for-byte so the manager can treat the table as a flat buffer.
func _flat_char_for(r: int, c: int, char_in_cell: int) -> int:
	var total: int = 0
	for rr in range(r):
		for cc in range(_columns):
			total += _cell_full_text(rr, cc).length()
		# (cols - 1) tabs between cells + 1 newline at row end
		total += max(0, _columns - 1)
		total += 1  # \n
	# Within target row, count cells before col + tabs.
	for cc in range(c):
		total += _cell_full_text(r, cc).length()
	total += c  # one \t before each preceding cell after the first
	return total + char_in_cell


func _flat_to_triple(flat: int) -> Dictionary:
	if _rows_spans.is_empty() or _columns <= 0:
		return {"row": 0, "col": 0, "char": 0}
	var f: int = max(0, flat)
	var cursor: int = 0
	for r in range(_rows_spans.size()):
		# Length of this row in flat space = sum(cell lengths) + (cols-1) tabs.
		var row_len: int = 0
		for c in range(_columns):
			row_len += _cell_full_text(r, c).length()
		row_len += max(0, _columns - 1)
		if f <= cursor + row_len:
			# Row found — locate cell + char within row.
			var local_in_row: int = f - cursor
			var cell_cursor: int = 0
			for c in range(_columns):
				var cell_len: int = _cell_full_text(r, c).length()
				if local_in_row <= cell_cursor + cell_len:
					return {
						"row": r,
						"col": c,
						"char": clamp(local_in_row - cell_cursor, 0, cell_len),
					}
				cell_cursor += cell_len + 1  # +1 for '\t' between cells
			# Past every cell in this row — clamp to end of last cell.
			return {
				"row": r,
				"col": _columns - 1,
				"char": _cell_full_text(r, _columns - 1).length(),
			}
		cursor += row_len + 1  # +1 for '\n' between rows
	# Past every row.
	var last_r: int = _rows_spans.size() - 1
	var last_c: int = _columns - 1
	return {
		"row": last_r,
		"col": last_c,
		"char": _cell_full_text(last_r, last_c).length(),
	}
