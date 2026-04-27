@tool
class_name GodetteTextBlock
extends Control
#
# Lightweight text display control for the chat feed. Replaces RichTextLabel in
# contexts where we don't need BBCode / tables / URLs. Uses TextServer via
# TextParagraph for shape + draw, avoiding RichTextLabel's per-update reshape
# of the entire Control.
#
# Design notes:
# - Auto-wraps to the Control's width. Reports content height via
#   _get_minimum_size so parent Containers lay out correctly. Min width is 0
#   so the dock can shrink freely.
# - `set_text(full)` replaces content and reshapes.
# - `append_text(delta)` appends without reshaping existing spans — streaming
#   fast path.
# - Single-block mouse selection: click-drag highlights, `get_selected_text()`
#   returns the range, right-click emits `right_clicked`.
# - No keyboard navigation, no cross-block selection, no accessibility tree
#   integration yet.

signal right_clicked(local_pos: Vector2)
signal selection_changed()
# Fired when a left-button press should start a cross-block drag managed
# externally. A registered MarkdownSelectionManager listens for this and
# takes over drag tracking; when no manager is attached the TextBlock
# falls back to its own local drag handling and this signal is never
# emitted. `char_pos` is the hit-tested character index of the press.
signal selection_drag_started(char_pos: int)

var _paragraph: TextParagraph
var _text: String = ""
# Styled runs that compose `_text`. Each entry is a Dictionary as documented
# on `set_spans`. `_text` is the in-order concatenation of every span's text,
# kept as the source of truth for selection / hit-testing so per-span styling
# never shifts character offsets. Empty when content was set as plain text
# only (legacy single-style path).
var _spans: Array = []
var _font: Font
# _font_size = 0 means "inherit from theme" (same path Label takes). This
# ensures we pick up any editor scaling applied to the base font size,
# including HiDPI adjustments, so our text matches neighbouring Label
# widgets visually.
var _font_size: int = 0
var _color: Color = Color(1, 1, 1, 1)
var _line_spacing: float = 0.0
var _dirty: bool = true
var _current_width: float = 0.0

# Selection state. -1 means "no selection"; both equal means a collapsed caret
# (treated as no selection for our purposes).
var _selection_anchor: int = -1
var _selection_caret: int = -1
var _selecting: bool = false
var _selection_color: Color = Color(0.28, 0.42, 0.78, 0.45)
# Multi-click detection. Tracks timestamp and hit position of the last
# left-button press so we can recognise double-click (select word) and
# triple-click (select line) within the platform double-click window.
const MULTI_CLICK_WINDOW_SEC := 0.45
const MULTI_CLICK_TOLERANCE_PX := 4.0
var _last_click_time_sec: float = -1.0
var _last_click_pos: Vector2 = Vector2.ZERO
var _click_run: int = 0  # 1 = first click, 2 = double, 3 = triple
# Optional cross-block selection coordinator (a
# GodetteMarkdownSelectionManager Node). Set by the markdown renderer on
# every TextBlock it creates for a given assistant message; unset
# elsewhere (streaming TextBlocks, tool-call labels, plan task labels)
# so those fall back to their own local drag. Held as a direct Object
# reference — use `is_instance_valid` before touching because the manager
# gets freed with the root VBox.
var _selection_manager: Object = null


func _init() -> void:
	_paragraph = TextParagraph.new()
	mouse_default_cursor_shape = Control.CURSOR_IBEAM
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Both drag-tracking hooks start disabled. A left-button press flips
	# them on; `_end_drag` flips them off.
	#
	# Why both `_process` AND `_input`:
	#   `_process(delta)` polls `get_local_mouse_position()` every frame,
	#     which is the only way to guarantee we see motion while the
	#     mouse is outside our rect — Godot's `_gui_input` motion
	#     delivery stops once the cursor leaves the Control, and
	#     `_input` delivery for mouse motion on Controls is
	#     inconsistent across Godot 4.x versions. Polling is boring but
	#     reliable and costs one read per frame for the duration of a
	#     drag only.
	#   `_input(event)` stays on for the mouse-button-release detection
	#     so we can end the drag cleanly no matter where the user lets
	#     go — even outside our rect.
	set_process(false)
	set_process_input(false)


func set_text(text: String) -> void:
	var clean: String = _strip_nul(text)
	if _spans.is_empty() and clean == _text:
		return
	_text = clean
	_spans.clear()
	_dirty = true
	_clear_selection_internal()
	_sync_paragraph()
	update_minimum_size()
	queue_redraw()


# Replace the entire content with a list of styled runs. Each entry is a
# Dictionary:
#   text: String — required, the run's plain text
#   font: Font — optional, falls back to the TextBlock's set_font() value
#   font_size: int — optional (>0), falls back to _effective_font_size()
#   bg: Color — optional, painted as a background chip behind the run
# Per-run foreground color is intentionally NOT supported: TextParagraph.draw
# applies a single color to the whole paragraph, and per-glyph colored draws
# would require a glyph-by-glyph self-draw path. Stick to TextBlock-level
# `set_color` for v1.
func set_spans(spans: Array) -> void:
	var normalized := _normalize_spans(spans)
	var combined := _spans_to_text(normalized)
	if combined == _text and _spans_equal(_spans, normalized):
		return
	_text = combined
	_spans = normalized
	_dirty = true
	_clear_selection_internal()
	_sync_paragraph()
	update_minimum_size()
	queue_redraw()


func append_text(delta: String) -> void:
	append_span(delta, {})


# Streaming-friendly counterpart to set_spans: append one styled run without
# re-shaping prior content. `opts` accepts the same keys as a set_spans entry
# (minus `text`); pass an empty Dictionary for default style.
func append_span(text: String, opts: Dictionary = {}) -> void:
	var clean: String = _strip_nul(text)
	if clean.is_empty():
		return
	var span := opts.duplicate()
	span["text"] = clean
	span = _normalize_span(span)
	_text += clean
	_spans.append(span)
	_ensure_font()
	if _paragraph == null:
		_paragraph = TextParagraph.new()
	_paragraph.add_string(clean, _resolve_span_font(span), _resolve_span_font_size(span))
	_apply_width()
	update_minimum_size()
	queue_redraw()


func _strip_nul(text: String) -> String:
	# Embedded NULs (usually from JSON `\u0000` in tool output or terminal
	# reset shims) make Godot's C-string-bridged APIs log "Unexpected NUL
	# character" on every shape / draw pass, flooding the console. Our
	# text protocol has no use for NULs, so strip them defensively at the
	# renderer boundary. Uses codepoint iteration rather than contains /
	# replace — those fast paths occasionally miss embedded U+0000 depending
	# on which internal code path handles the search.
	if text.is_empty():
		return text
	var length: int = text.length()
	var first_nul: int = -1
	for i in range(length):
		if text.unicode_at(i) == 0:
			first_nul = i
			break
	if first_nul < 0:
		return text
	var out := text.substr(0, first_nul)
	for i in range(first_nul + 1, length):
		var cp: int = text.unicode_at(i)
		if cp != 0:
			out += String.chr(cp)
	return out


func get_text() -> String:
	return _text


func set_font(font: Font) -> void:
	if font == _font:
		return
	_font = font
	_dirty = true
	_sync_paragraph()
	update_minimum_size()
	queue_redraw()


func set_font_size(value: int) -> void:
	if value == _font_size:
		return
	_font_size = value
	_dirty = true
	_sync_paragraph()
	update_minimum_size()
	queue_redraw()


func set_color(value: Color) -> void:
	if value == _color:
		return
	_color = value
	queue_redraw()


func set_line_spacing(value: float) -> void:
	if is_equal_approx(value, _line_spacing):
		return
	_line_spacing = value
	if _paragraph != null:
		_paragraph.line_spacing = value
		update_minimum_size()
		queue_redraw()


func set_selection_color(value: Color) -> void:
	_selection_color = value
	if has_selection():
		queue_redraw()


func has_selection() -> bool:
	return _selection_anchor >= 0 and _selection_caret >= 0 and _selection_anchor != _selection_caret


func get_selected_text() -> String:
	if not has_selection():
		return ""
	var s: int = min(_selection_anchor, _selection_caret)
	var e: int = max(_selection_anchor, _selection_caret)
	s = clamp(s, 0, _text.length())
	e = clamp(e, 0, _text.length())
	if e <= s:
		return ""
	return _text.substr(s, e - s)


func clear_selection() -> void:
	if _selection_anchor == -1 and _selection_caret == -1:
		return
	_clear_selection_internal()
	queue_redraw()
	emit_signal("selection_changed")


# -----------------------------------------------------------------------------
# Public API for cross-block selection managers.
# -----------------------------------------------------------------------------
# The block itself is still the authority on its own selection rects + hit
# testing. The manager calls into these to set/clear selection without having
# to poke private fields. All of them clamp to [0, text.length] so the manager
# can pass negative / oversized values without having to carry the text length
# itself.


func register_selection_manager(manager: Object) -> void:
	# Nullable; passing null detaches. Stored as a plain Object so we can
	# keep manager as RefCounted/Node agnostic. Validity is checked on use.
	_selection_manager = manager


func select_range(a: int, b: int) -> void:
	# Explicit selection from char a to char b. a>b is allowed (matches the
	# anchor-before / caret-after convention used by the drag path).
	var length: int = _text.length()
	_selection_anchor = clampi(a, 0, length)
	_selection_caret = clampi(b, 0, length)
	queue_redraw()


func select_from_char(start_char: int) -> void:
	# Start of the partial selection for the block holding the drag
	# anchor (the drag began here, the caret moved to a block below).
	_selection_anchor = clampi(start_char, 0, _text.length())
	_selection_caret = _text.length()
	queue_redraw()


func select_to_char(end_char: int) -> void:
	# End of the partial selection for the block holding the drag focus
	# (caret landed here, anchor is in a block above).
	_selection_anchor = 0
	_selection_caret = clampi(end_char, 0, _text.length())
	queue_redraw()


func select_all() -> void:
	_selection_anchor = 0
	_selection_caret = _text.length()
	queue_redraw()


func clear_selection_silent() -> void:
	# Clear without emitting `selection_changed`. Used by the manager to
	# wipe dozens of blocks in one drag frame without N signal callbacks.
	if _selection_anchor == -1 and _selection_caret == -1:
		return
	_selection_anchor = -1
	_selection_caret = -1
	_selecting = false
	queue_redraw()


func hit_test_char(local_pos: Vector2) -> int:
	# Expose the existing private hit-test so the manager can translate a
	# global mouse position (mapped into a block's local space) into a
	# character offset. Keeps _hit_test_char private for other callers.
	return _hit_test_char(local_pos)


func get_selection_anchor() -> int:
	# Exposed for a selection manager that needs to read the block's
	# current anchor (e.g. after a local multi-click word/line select
	# populates the selection and we want to sync the manager's anchor
	# to the word boundary, not the click char).
	return _selection_anchor


func get_selection_caret() -> int:
	return _selection_caret


func _clear_selection_internal() -> void:
	_selection_anchor = -1
	_selection_caret = -1
	_selecting = false
	# Whoever cleared the selection wants a clean slate — stop the drag
	# tracking hooks too so the Control isn't polling mouse position or
	# listening to global input for a selection that no longer exists.
	set_process(false)
	set_process_input(false)


func _ensure_font() -> void:
	if _font != null:
		return
	_font = get_theme_default_font()
	if _font == null:
		_font = ThemeDB.fallback_font


func _sync_paragraph() -> void:
	if not _dirty:
		return
	_dirty = false
	_ensure_font()
	if _paragraph == null:
		_paragraph = TextParagraph.new()
	_paragraph.clear()
	_paragraph.line_spacing = _line_spacing
	if _spans.is_empty():
		if not _text.is_empty():
			_paragraph.add_string(_text, _font, _effective_font_size())
	else:
		for span_var in _spans:
			var span: Dictionary = span_var
			var span_text: String = span.get("text", "")
			if span_text.is_empty():
				continue
			_paragraph.add_string(span_text, _resolve_span_font(span), _resolve_span_font_size(span))
	_apply_width()


func _resolve_span_font(span: Dictionary) -> Font:
	var f = span.get("font", null)
	return f if f is Font else _font


func _resolve_span_font_size(span: Dictionary) -> int:
	var s := int(span.get("font_size", 0))
	return s if s > 0 else _effective_font_size()


func _normalize_span(span: Dictionary) -> Dictionary:
	var out := {}
	out["text"] = _strip_nul(str(span.get("text", "")))
	if span.get("font") is Font:
		out["font"] = span["font"]
	var fs := int(span.get("font_size", 0))
	if fs > 0:
		out["font_size"] = fs
	if span.get("bg") is Color:
		out["bg"] = span["bg"]
	# href is the only metadata key — kept under the same span dict so
	# the click resolver can walk spans the same way span-bg drawing does.
	var href := str(span.get("href", ""))
	if not href.is_empty():
		out["href"] = href
	return out


func _normalize_spans(spans: Array) -> Array:
	var out := []
	for s in spans:
		if not (s is Dictionary):
			continue
		var n := _normalize_span(s)
		var t: String = n.get("text", "")
		if t.is_empty():
			continue
		out.append(n)
	return out


func _spans_to_text(spans: Array) -> String:
	var parts := PackedStringArray()
	for s in spans:
		parts.append(s.get("text", ""))
	return "".join(parts)


func _spans_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		var sa: Dictionary = a[i]
		var sb: Dictionary = b[i]
		if sa.get("text", "") != sb.get("text", ""):
			return false
		if sa.get("font", null) != sb.get("font", null):
			return false
		if sa.get("font_size", 0) != sb.get("font_size", 0):
			return false
		if sa.get("bg", null) != sb.get("bg", null):
			return false
	return true


func _effective_font_size() -> int:
	if _font_size > 0:
		return _font_size
	# Inherit the size Labels in the same theme chain would use. This is
	# what Godot's editor ultimately scales on HiDPI — reading the raw
	# `interface/editor/main_font_size` setting bypasses that scaling.
	var inherited := get_theme_default_font_size()
	if inherited > 0:
		return inherited
	return 14


func _apply_width() -> void:
	var target := size.x if size.x > 0.0 else _current_width
	if target <= 0.0:
		return
	if is_equal_approx(target, _current_width) and is_equal_approx(_paragraph.width, target):
		return
	_current_width = target
	_paragraph.width = target


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		if _paragraph == null:
			return
		if not is_equal_approx(size.x, _current_width):
			_current_width = size.x
			# Full reshape on width change. Setting `_paragraph.width` alone
			# updates TextParagraph's internal width but — at least on Godot
			# 4.x on Windows — `get_size()` can continue to report the
			# pre-resize height until the paragraph is re-shaped from its
			# spans. That bit us inside a VBoxContainer whose sort handed
			# every child its single-line min_size (~33 px) even though the
			# visible text wrapped to several lines; clicks on the wrapped
			# tails landed on the sibling below. Forcing `_dirty=true` so
			# `_sync_paragraph` re-adds each span is wasteful but correct,
			# and the added cost only fires on actual width changes
			# (gated by the is_equal_approx guard above).
			_dirty = true
			_sync_paragraph()
			# A paragraph that wraps to N lines after the new width needs
			# N lines' worth of height. Three layers, because one alone has
			# not been enough in practice:
			#   1. custom_minimum_size.y — floor for the container's next
			#      min_size query.
			#   2. size.y — force our OWN rect to match right now, so we
			#      don't briefly draw a 5-line paragraph into a 1-line
			#      Control while waiting for the parent VBox to re-sort
			#      (that 1-frame mismatch was the "adapter,看日志。 bleeds
			#      into item 2" visual bug).
			#   3. update_minimum_size — schedule the parent to re-sort so
			#      it'll honour the new floor on subsequent layouts.
			var needed_h: float = _paragraph.get_size().y
			custom_minimum_size.y = needed_h
			if needed_h > size.y:
				size.y = needed_h
			update_minimum_size()
			queue_redraw()
	elif what == NOTIFICATION_THEME_CHANGED or what == NOTIFICATION_ENTER_TREE:
		# Theme defaults (font + size) may only be available once we're in a
		# tree with resolved theme chain. Entering the tree invalidates the
		# paragraph so it re-shapes against the now-correct inherited values.
		_font = null
		_dirty = true
		if is_inside_tree():
			_sync_paragraph()
			update_minimum_size()
			queue_redraw()


func _get_minimum_size() -> Vector2:
	# Report only content height as the minimum size. Leaving min width at 0
	# lets the parent container shrink freely; wrapping is handled by
	# TextParagraph.width which follows size.x via NOTIFICATION_RESIZED.
	if _paragraph == null or _text.is_empty():
		return Vector2.ZERO
	_sync_paragraph()
	return Vector2(0.0, _paragraph.get_size().y)


func _draw() -> void:
	if _paragraph == null or _text.is_empty():
		return
	_sync_paragraph()
	# Order matters: span backgrounds first (under everything), then the
	# selection highlight (so an active selection visibly covers code chips),
	# finally the glyphs on top.
	if not _spans.is_empty():
		_draw_span_backgrounds()
	if has_selection():
		_draw_selection_rects()
	_paragraph.draw(get_canvas_item(), Vector2.ZERO, _color)


func _draw_span_backgrounds() -> void:
	var char_cursor: int = 0
	for span_var in _spans:
		var span: Dictionary = span_var
		var span_text: String = span.get("text", "")
		var span_len: int = span_text.length()
		if span_len <= 0:
			continue
		var bg_variant = span.get("bg", null)
		if bg_variant is Color:
			_draw_range_rect(char_cursor, char_cursor + span_len, bg_variant as Color)
		char_cursor += span_len


func _draw_range_rect(s: int, e: int, color: Color) -> void:
	# Filled rectangle covering character range [s, e) across every line it
	# touches. Reuses the same per-glyph x machinery as _draw_selection_rects
	# (via _line_char_x) so the chip aligns under the actual rendered text.
	# Includes a small horizontal pad so the chip extends slightly past the
	# first/last glyph — looks like a Markdown `code` chip rather than a
	# letter-tight band.
	if e <= s or _paragraph == null:
		return
	var pad_x: float = 2.0
	var line_count: int = _paragraph.get_line_count()
	var y_cursor: float = 0.0
	for line_idx in range(line_count):
		var line_range: Vector2i = _paragraph.get_line_range(line_idx)
		var line_size: Vector2 = _paragraph.get_line_size(line_idx)
		var row_advance: float = line_size.y + _line_spacing
		var line_start: int = line_range.x
		var line_end: int = line_range.y
		if line_end <= s or line_start >= e:
			y_cursor += row_advance
			continue
		var overlap_start: int = max(s, line_start)
		var overlap_end: int = min(e, line_end)
		var line_rid: RID = _paragraph.get_line_rid(line_idx)
		# Paragraph-global char indices: `paragraph.get_line_rid()` shares
		# the paragraph's shaped-text rid, so `shaped_text_get_carets` /
		# `shaped_text_hit_test_position` index into the full paragraph
		# while returning line-local x. Subtracting `line_start` would
		# query a different line's char and silently misplace rects on
		# wrapped continuation lines.
		var start_x: float
		if overlap_start == line_start:
			start_x = 0.0
		else:
			start_x = _line_char_x(line_rid, overlap_start, line_size.x, false)
		var end_x: float
		# Range continues onto the next line: extend to this line's content
		# right edge so the chip looks unbroken across the wrap. Same pattern
		# as selection rendering uses.
		if e > line_end:
			end_x = line_size.x
		else:
			end_x = _line_char_x(line_rid, overlap_end, line_size.x, true)
		if end_x <= start_x:
			y_cursor += row_advance
			continue
		var rect := Rect2(
			Vector2(start_x - pad_x, y_cursor),
			Vector2(end_x - start_x + pad_x * 2.0, line_size.y),
		)
		draw_rect(rect, color)
		y_cursor += row_advance


func _draw_selection_rects() -> void:
	# Godot CodeEdit-style selection: full-width highlight on continued
	# lines (from start_x all the way to the line's right edge), and a
	# small indicator block on fully-selected empty lines. The previous
	# "tight around the character span" rendering felt anaemic next to
	# the editor's own selection and didn't communicate "this whole line
	# is selected" for wrapped / empty rows.
	var s: int = min(_selection_anchor, _selection_caret)
	var e: int = max(_selection_anchor, _selection_caret)
	s = clamp(s, 0, _text.length())
	e = clamp(e, 0, _text.length())
	if e <= s:
		return
	var line_count: int = _paragraph.get_line_count()
	var empty_line_width: float = max(8.0, _effective_font_size() * 0.5)
	var y_cursor: float = 0.0
	for line_idx in range(line_count):
		var line_range: Vector2i = _paragraph.get_line_range(line_idx)
		var line_size: Vector2 = _paragraph.get_line_size(line_idx)
		# `get_line_size(i).y` returns only the line's own height — it does
		# *not* include `_line_spacing`, but the paragraph's renderer
		# advances by that extra amount between lines. To line selection
		# rects up with the glyphs, our rects need to cover the same
		# height the renderer advances (`line_size.y + _line_spacing`),
		# so consecutive highlighted lines abut seamlessly instead of
		# leaving a thin unhighlighted gap at each row break. The gap
		# was what made long selections look "staggered" / misaligned
		# on multi-line wraps.
		var row_advance: float = line_size.y + _line_spacing
		var line_start: int = line_range.x
		var line_end: int = line_range.y  # exclusive (character count)
		if line_end <= s or line_start >= e:
			y_cursor += row_advance
			continue

		var overlap_start: int = max(s, line_start)
		var overlap_end: int = min(e, line_end)
		var line_rid: RID = _paragraph.get_line_rid(line_idx)

		# Whether this line's selection continues down past its end —
		# i.e., the selection extends into the next line. When it does,
		# the highlight should run to the line's right edge (looks like
		# one continuous selection across the wrap, matching CodeEdit).
		var continues_to_next_line: bool = e > line_end

		var start_x: float
		if overlap_start == line_start:
			# Selection covers this line from its very first character —
			# anchor the highlight to x=0 so it reads as "whole line".
			start_x = 0.0
		else:
			# Paragraph-global char index — see the chip-bg branch above.
			start_x = _line_char_x(line_rid, overlap_start, line_size.x, false)

		var end_x: float
		if continues_to_next_line or overlap_end == line_end:
			# Extend to the end of the rendered text on this line, NOT to
			# `paragraph.width` — the paragraph width is the wrap column
			# (effectively the TextBlock's full width), and filling up to
			# it would bleed the highlight into the empty right-side gap
			# past the last glyph. `line_size.x` is the content width
			# only, which matches how Godot's CodeEdit paints selection
			# for continued lines.
			#
			# Also covers the single-line "select entire block" case:
			# Godot's `shaped_text_get_carets` at position == line_end
			# returns a degenerate Rect2 at x=0 for some shaped paragraphs
			# (notably lines dominated by a single bold span, e.g.
			# `**根据 #2 结果决定**：`). When `_line_char_x` then returned 0
			# the `end_x <= start_x` check below nuked the highlight rect
			# entirely. Snapping to `line_size.x` bypasses that quirk.
			end_x = line_size.x
		else:
			end_x = _line_char_x(line_rid, overlap_end, line_size.x, true)

		# Empty selected line: line_size.x is 0 so there's nothing to
		# highlight via char positions. Draw a small marker block so the
		# user sees that this blank line is part of the selection.
		if line_size.x <= 0.5 and end_x <= start_x + 0.5:
			end_x = start_x + empty_line_width

		if end_x <= start_x:
			y_cursor += row_advance
			continue

		# Mid-paragraph lines stretch the rect to `row_advance` so adjacent
		# wrap lines abut (no unhighlighted hairline at each wrap). The
		# FINAL line of the paragraph has nothing below it inside this
		# Control — extending past `line_size.y` there would bleed into
		# the next block (VBoxContainer separation is measured from the
		# Control's bottom, not the paragraph's visual bottom). So cap
		# the last line at its natural height.
		var rect_h: float = row_advance if line_idx < line_count - 1 else line_size.y
		var rect := Rect2(Vector2(start_x, y_cursor), Vector2(end_x - start_x, rect_h))
		draw_rect(rect, _selection_color)
		y_cursor += row_advance


func _line_char_x(line_rid: RID, char_in_line: int, line_width: float, is_end: bool) -> float:
	# Translate a char offset within a line into an x pixel inside that line.
	# Primary path uses TextServer caret info; the glyph-iterate fallback
	# kicks in when `shaped_text_get_carets` comes back empty — that
	# happens more often than you'd think, and the old "just return 0 or
	# line_width" fallback manifested as selection rects always spanning
	# the whole line (and flickering as caret changed between line_start
	# / line_end-ish values each frame).
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
			# Some scripts (notably LTR text where leading and trailing
			# collapse to the same caret) only populate `leading_rect`.
			rect_variant = info.get("leading_rect", null)
		if rect_variant is Rect2:
			var r: Rect2 = rect_variant as Rect2
			# Degenerate result guard: when shaped_text_get_carets returns
			# x=0 for char_in_line > 0 (CJK + bold + wrap shaping edge
			# cases), fall through to the glyph-iteration branch below.
			# Without this, partial selection on wrapped continuation
			# lines collapses to zero width and disappears.
			if r.position.x > 0.0 or r.size.x > 0.0:
				return clamp(r.position.x, 0.0, line_width)

	# Fallback: sum glyph advances up to `char_in_line`. Each glyph dict
	# carries `start` (char index in the shaped text) and `advance`
	# (pixel width contributed). We stop at the first glyph whose start
	# is >= target, returning the cumulative x up to that point. This
	# is less precise than the caret API (doesn't handle cluster splits
	# for complex scripts perfectly) but always yields a real in-line
	# coordinate, preventing the whole-line artefact.
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


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		# Wheel events: we're MOUSE_FILTER_STOP so Godot won't propagate on
		# its own. Can't call `ScrollContainer._gui_input(event)` directly —
		# it's a virtual callback in C++, not a public method (doing so logs
		# "Nonexistent function '_gui_input' in base 'ScrollContainer'"
		# once per wheel tick). Instead drive `scroll_vertical` /
		# `scroll_horizontal` ourselves; ScrollContainer clamps them, so
		# over-scrolling past either edge just stays put rather than
		# erroring.
		if (
			mb.button_index == MOUSE_BUTTON_WHEEL_UP
			or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN
			or mb.button_index == MOUSE_BUTTON_WHEEL_LEFT
			or mb.button_index == MOUSE_BUTTON_WHEEL_RIGHT
		):
			_forward_wheel_to_scroll(mb)
			return
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			accept_event()
			emit_signal("right_clicked", mb.position)
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			accept_event()
			if mb.pressed:
				_sync_paragraph()
				var pos := _hit_test_char(mb.position)
				# Cross-block mode: when a selection manager is attached,
				# the *plain* left-click case is fully delegated — the
				# manager will set our anchor via select_range() as the
				# drag progresses, and also owns motion polling. Shift-
				# click and multi-click stay local because they're
				# within-block operations; after they run we still tell
				# the manager so it can reset its multi-block state.
				var has_manager: bool = _selection_manager != null and is_instance_valid(_selection_manager)
				if has_manager and not mb.shift_pressed:
					# Multi-click detection still matters so a double-click
					# inside a manager-tracked block does a word select and
					# doesn't also start a drag. Compute run count first.
					var mgr_now: float = Time.get_ticks_msec() / 1000.0
					var mgr_within: bool = (
						_last_click_time_sec >= 0.0
						and mgr_now - _last_click_time_sec <= MULTI_CLICK_WINDOW_SEC
						and mb.position.distance_to(_last_click_pos) <= MULTI_CLICK_TOLERANCE_PX
					)
					var mgr_run: int = _click_run + 1 if mgr_within else 1
					if mgr_run > 3:
						mgr_run = 1
					_click_run = mgr_run
					_last_click_time_sec = mgr_now
					_last_click_pos = mb.position
					if mgr_run == 1:
						# Plain click: collapse our own selection to a caret
						# at the click position BEFORE notifying the manager.
						# Without this, a residual selection from a prior
						# drag (we never cleared it on release) still reads
						# as has_selection()=true, and the manager's
						# multi-click-preserve branch would keep that stale
						# range as the new anchor instead of the click char.
						_selection_anchor = pos
						_selection_caret = pos
						_selecting = false
						queue_redraw()
						emit_signal("selection_drag_started", pos)
						return
					# Word / line select stays local, then notify manager.
					if mgr_run == 2:
						_select_word_at(pos)
					else:
						_select_line_at(pos)
					_selecting = false
					queue_redraw()
					emit_signal("selection_changed")
					emit_signal("selection_drag_started", _selection_anchor)
					return
				# Shift-click: keep the existing anchor, move caret to the
				# click position so the selection extends. Don't arm drag
				# so a plain shift-click stays a one-shot extension.
				if mb.shift_pressed and _selection_anchor >= 0:
					_selection_caret = pos
					_selecting = true
					_begin_drag_tracking()
					queue_redraw()
					emit_signal("selection_changed")
					return
				# Multi-click detection: same approximate pixel, within the
				# double-click window, run counter increments. Cap at 3
				# (triple = select line); 4th click starts fresh.
				var now: float = Time.get_ticks_msec() / 1000.0
				var within_window: bool = (
					_last_click_time_sec >= 0.0
					and now - _last_click_time_sec <= MULTI_CLICK_WINDOW_SEC
					and mb.position.distance_to(_last_click_pos) <= MULTI_CLICK_TOLERANCE_PX
				)
				_click_run = _click_run + 1 if within_window else 1
				if _click_run > 3:
					_click_run = 1
				_last_click_time_sec = now
				_last_click_pos = mb.position

				match _click_run:
					2:
						_select_word_at(pos)
						_selecting = false
					3:
						_select_line_at(pos)
						_selecting = false
					_:
						_selection_anchor = pos
						_selection_caret = pos
						_selecting = true
				# Drag-select arming: turn on per-frame polling so motion
				# is tracked even when the pointer leaves our rect.
				if _selecting:
					_begin_drag_tracking()
				queue_redraw()
				emit_signal("selection_changed")
			else:
				# Mouse-up: detect a "click without drag" on a link span
				# and route to OS.shell_open. The conditions:
				#   - cursor didn't move past the multi-click tolerance
				#     (any larger move = user dragged → selection mode,
				#      not a link click)
				#   - no extended selection at this point (anchor==caret
				#     means we're still on the original collapse-caret
				#     state from the press; double/triple click and shift
				#     extension both leave anchor != caret here)
				# Any movement OR any selection blocks the link open, so
				# dragging *over* a link still works as text selection.
				var moved: bool = mb.position.distance_to(_last_click_pos) > MULTI_CLICK_TOLERANCE_PX
				var still_caret: bool = _selection_anchor == _selection_caret
				_end_drag()
				if not moved and still_caret:
					var release_char: int = _hit_test_char(mb.position)
					var href: String = _link_at_char(release_char)
					if not href.is_empty():
						if href.begins_with("http://") or href.begins_with("https://"):
							OS.shell_open(href)
			return


func _process(_delta: float) -> void:
	# Poll while a drag is active. Running every frame is cheap (one
	# mouse-position read + one hit-test) and, unlike `_input`, is
	# guaranteed to fire regardless of cursor position or event
	# ordering — that was the bit making mid-drag selection freeze on
	# previous iterations.
	if not _selecting:
		return
	var local_pos := get_local_mouse_position()
	var pos := _hit_test_char(local_pos)
	if pos != _selection_caret:
		_selection_caret = pos
		queue_redraw()
		emit_signal("selection_changed")


func _input(event: InputEvent) -> void:
	# Only concerned with mouse-button *release* here: the user might
	# let go anywhere on screen, possibly outside our rect. `_gui_input`
	# wouldn't see that release; `_input` does because it runs on every
	# input event when `set_process_input(true)` is on.
	if not _selecting:
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_end_drag()


func _begin_drag_tracking() -> void:
	set_process(true)
	set_process_input(true)


func _end_drag() -> void:
	_selecting = false
	set_process(false)
	set_process_input(false)
	if _selection_anchor == _selection_caret:
		_clear_selection_internal()
		queue_redraw()
	emit_signal("selection_changed")


func _select_word_at(char_index: int) -> void:
	# Double-click: select the word containing char_index. Word boundaries
	# are whitespace or punctuation. For CJK text (no spaces) this still
	# works — consecutive ideographs are treated as one "word" block,
	# which matches what most editors do for Chinese / Japanese.
	if _text.is_empty():
		return
	var length: int = _text.length()
	var idx: int = clamp(char_index, 0, length - 1)
	var is_word_char := func(cp: int) -> bool:
		if cp == 0:
			return false
		# Whitespace / ASCII punctuation / common symbols → not word.
		if cp <= 0x20:
			return false
		var punct := " \t\n\r\f\"'`,.;:!?()[]{}<>/\\|@#$%^&*-=+~"
		for pc in punct:
			if cp == pc.unicode_at(0):
				return false
		return true
	if not is_word_char.call(_text.unicode_at(idx)):
		# Click landed on a separator — select just that character so the
		# user still gets SOMETHING to copy (e.g., double-clicking a lone
		# punctuation mark).
		_selection_anchor = idx
		_selection_caret = min(idx + 1, length)
		return
	var start: int = idx
	while start > 0 and is_word_char.call(_text.unicode_at(start - 1)):
		start -= 1
	var end: int = idx
	while end < length and is_word_char.call(_text.unicode_at(end)):
		end += 1
	_selection_anchor = start
	_selection_caret = end


func _select_line_at(char_index: int) -> void:
	# Triple-click: select the visual line at char_index. Uses the
	# paragraph's own line segmentation (already computed for wrap
	# rendering), so what gets selected matches what the user sees on
	# that row of text.
	if _paragraph == null or _text.is_empty():
		return
	_sync_paragraph()
	var line_count: int = _paragraph.get_line_count()
	for line_idx in range(line_count):
		var line_range: Vector2i = _paragraph.get_line_range(line_idx)
		var line_start: int = line_range.x
		var line_end: int = line_range.y
		if char_index >= line_start and char_index < line_end:
			_selection_anchor = line_start
			_selection_caret = line_end
			return
	# Fallback: select the final line if hit_test returned end-of-text.
	if line_count > 0:
		var last_range: Vector2i = _paragraph.get_line_range(line_count - 1)
		_selection_anchor = last_range.x
		_selection_caret = last_range.y


func _find_ancestor_scroll() -> ScrollContainer:
	var node := get_parent()
	while node != null:
		if node is ScrollContainer:
			return node
		node = node.get_parent()
	return null


const WHEEL_STEP_PX := 40.0

func _forward_wheel_to_scroll(mb: InputEventMouseButton) -> void:
	# Wheel events come as paired pressed=true / pressed=false ticks on
	# most platforms. Only react to the "down stroke" so one physical
	# notch produces one scroll step rather than double-counting.
	if not mb.pressed:
		return
	var scroll := _find_ancestor_scroll()
	if scroll == null:
		return
	# `factor` reflects fractional wheel precision on high-res trackpads
	# (often 0.1–1.0 per event). Clamp to ≥1 so a regular mouse wheel
	# notch always produces a full step even when the OS reports factor=0.
	var factor: float = mb.factor if mb.factor > 0.0 else 1.0
	var step: int = int(WHEEL_STEP_PX * max(factor, 1.0))
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			scroll.scroll_vertical = scroll.scroll_vertical - step
		MOUSE_BUTTON_WHEEL_DOWN:
			scroll.scroll_vertical = scroll.scroll_vertical + step
		MOUSE_BUTTON_WHEEL_LEFT:
			scroll.scroll_horizontal = scroll.scroll_horizontal - step
		MOUSE_BUTTON_WHEEL_RIGHT:
			scroll.scroll_horizontal = scroll.scroll_horizontal + step


# Walks the span list to find which span contains `char_idx` and returns
# its `href` field if any. Returns empty string for non-link characters
# (the fallback the click handler interprets as "not a link"). Same
# linear-walk pattern `_draw_span_backgrounds` uses for chip drawing —
# span counts per block are small (single digits) so the cost is
# negligible per click.
func _link_at_char(char_idx: int) -> String:
	if char_idx < 0:
		return ""
	var cursor: int = 0
	for span_v in _spans:
		var span: Dictionary = span_v
		var span_text: String = str(span.get("text", ""))
		var span_len: int = span_text.length()
		if span_len <= 0:
			continue
		if char_idx >= cursor and char_idx < cursor + span_len:
			return str(span.get("href", ""))
		cursor += span_len
	return ""


func _hit_test_char(local_pos: Vector2) -> int:
	# Line-aware hit test. Walking the paragraph line-by-line using the
	# same `row_advance = line_size.y + _line_spacing` the renderer uses
	# means our y-to-line mapping matches exactly what the user sees on
	# screen. Inside the line, `shaped_text_hit_test_position` turns a
	# pixel x into a character offset, which is more reliable than
	# `TextParagraph.hit_test(Vector2)` — the latter occasionally reports
	# -1 for positions that are clearly inside the text (the reason
	# partial-within-line selection was snapping to line boundaries and
	# flickering between them).
	if _paragraph == null or _text.is_empty():
		return 0
	if local_pos.y <= 0.0:
		return 0

	var line_count: int = _paragraph.get_line_count()
	var ts := TextServerManager.get_primary_interface()
	var y_cursor: float = 0.0
	for line_idx in range(line_count):
		var line_size: Vector2 = _paragraph.get_line_size(line_idx)
		var row_advance: float = line_size.y + _line_spacing
		var line_bottom: float = y_cursor + row_advance
		if local_pos.y < line_bottom:
			var line_range: Vector2i = _paragraph.get_line_range(line_idx)
			if ts == null:
				return line_range.x
			var line_rid: RID = _paragraph.get_line_rid(line_idx)
			# `shaped_text_hit_test_position` on a wrapped line's RID
			# returns a PARAGRAPH-global char index (not line-local), so
			# we use the result directly. The previous
			# `line_range.x + char_in_line` double-counted the line
			# offset; on wrapped continuation lines this collapsed every
			# drag focus to the line's last char (= entire-line / entire-
			# paragraph selection on partial drags).
			var result: int = ts.shaped_text_hit_test_position(line_rid, local_pos.x)
			return clamp(result, line_range.x, line_range.y)
		y_cursor = line_bottom

	# Past the last line. Don't blanket-return _text.length() — a drag
	# whose y dipped a few pixels into the block's bottom padding (line
	# spacing, container-expanded height, separation gap) would then
	# snap selection to the final character even when x is clearly over
	# a specific glyph. Instead, treat this as "on the last line, use
	# the cursor's x" so the result still tracks horizontal position.
	# x past the rendered text on that line still clamps to line end
	# (standard editor behavior), but x within it resolves correctly.
	if line_count > 0 and ts != null:
		var last_idx: int = line_count - 1
		var last_range: Vector2i = _paragraph.get_line_range(last_idx)
		var last_rid: RID = _paragraph.get_line_rid(last_idx)
		# Already paragraph-global — see comment in the in-loop branch.
		var last_result: int = ts.shaped_text_hit_test_position(last_rid, local_pos.x)
		return clamp(last_result, last_range.x, last_range.y)
	return _text.length()
