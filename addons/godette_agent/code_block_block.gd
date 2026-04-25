@tool
class_name GodetteCodeBlockBlock
extends Control
#
# Route 3 self-drawn fenced code block. Replaces the legacy
#   PanelContainer (bg + corners)
#   └── MarginContainer (CODE_PAD_X / Y)
#       └── GodetteTextBlock (mono font, plain text)
# tree (3 controls per code block) with a single Control that:
#   - tokenises GDScript via Godot's built-in `GDScriptSyntaxHighlighter`
#     (so colours track the user's editor theme automatically)
#   - shapes one `TextLine` per (line, token) — `TextLine.draw` is
#     monochrome, so per-token colour requires per-token shaping
#   - lays tokens out left-to-right inside their line, top-to-bottom
#     across lines, no word-wrap (fenced code in editors is canonically
#     horizontal-scroll, not wrapped)
#   - self-draws bg + rounded border via `draw_style_box`
#   - tracks `_scroll_x` for the horizontal-scroll behaviour, draws a
#     thin self-painted thumb at the bottom when content overflows
#
# Tokenisation runs once in `set_code()` — called from
# `markdown_render._handle_end("code_block")` once the fence is closed
# and the content is final. Streaming continues to use the plain
# TextBlock path; the swap happens via _update_entry_in_feed (same
# pattern as list / table finalisation).
#
# Languages: only `gdscript` (and unmarked fences) get highlighting in
# v1. Other languages render as plain mono using the default text
# colour. The block's `set_language` rejects anything else by setting a
# null highlighter.
#
# ---------------------------------------------------------------------------
# Public API (mirrors ListBlock / TableBlock for the streaming consumer)
# ---------------------------------------------------------------------------
#   append_text(delta)            — concat to internal buffer (markdown
#                                     emits text events as the parser
#                                     walks fence content)
#   append_span(text, opts)       — same as append_text; opts ignored
#                                     (fenced code is plain by spec)
#   finalize()                    — tokenise + build TextLines; called by
#                                     markdown_render at end-of-fence
#   set_language(lang: String)    — set the language token from fence
#                                     info string (`gdscript`, `python`, …)
#   set_color(c: Color)           — default text colour (chars not
#                                     covered by the highlighter dict)
#   set_font(f: Font)             — mono font (must be monospace)
#   set_font_size(n: int)
#   set_bg_color(c: Color)        — code panel fill colour
#   set_selection_color(c: Color)

const CODE_PAD_X: float = 10.0
const CODE_PAD_Y: float = 8.0
const CORNER_RADIUS: int = 4
# Bottom horizontal scrollbar geometry (visible only on overflow).
const HSCROLL_BAR_HEIGHT: float = 4.0
const HSCROLL_BAR_INSET: float = 2.0
# Copy button at top-right. 14 px base icon + 4 px hit-pad on each
# side (so the click target reads ~22 px even though the icon is 14).
# COPY_INSET keeps the icon clear of the panel's rounded corner.
const COPY_ICON_SIZE: float = 14.0
const COPY_HIT_PAD: float = 4.0
const COPY_INSET: float = 6.0

const ICON_COPY: Texture2D = preload(
	"res://addons/godette_agent/icons/lucide--copy.svg"
)
# "Copied!" feedback duration. Matches `agent_dock.COPIED_STATE_SECONDS`
# so the two copy paths feel identical when the user clicks one then
# the other in the same message.
const COPY_FEEDBACK_SECONDS: float = 2.0
# Same green agent_dock uses for its copy button success state.
const COPY_FEEDBACK_COLOR: Color = Color(0.72, 0.94, 0.78, 1.0)


# ---------------------------------------------------------------------------
# Public state setters
# ---------------------------------------------------------------------------


# Buffer for streaming-style append calls. `finalize` consumes it.
var _code: String = ""
var _language: String = ""


func append_text(delta: String) -> void:
	if delta.is_empty():
		return
	_code += delta
	# Keep `_lines` empty until finalize so we don't waste shaping work
	# on intermediate states; markdown_render emits all text events
	# before the matching `end` event.


func append_span(text: String, _opts: Dictionary = {}) -> void:
	# Fenced code is plain text per CommonMark — opts (font/bg/href) are
	# ignored. We still accept the call so the block conforms to the
	# duck-typed text_target protocol that ListBlock / TableBlock use.
	append_text(text)


func set_language(lang: String) -> void:
	_language = lang.strip_edges().to_lower()


# Called once after all append_text calls land. Builds the per-line
# TextLine sequence with token colours.
func finalize() -> void:
	# Tab → 4 spaces. TextLine shapes `\t` as a zero-advance glyph in
	# most fonts (no built-in tab-stop concept), which collapses every
	# indented line flush-left visually. Expanding to a fixed 4-space
	# width matches the editor's default `text_editor/behavior/indent/
	# size` and keeps selection / get_text consistent (we lose tab
	# fidelity on paste — pasting back into a tab-using editor will
	# need the user's editor to convert 4-space → tab, which all
	# editors handle).
	_code = _code.replace("\t", "    ")
	_rebuild_lines()
	update_minimum_size()
	queue_redraw()


# Direct setter for callers that have the full code at construction time
# (e.g. tests, future copy/paste paths). Equivalent to clearing buffer +
# appending + finalising in one shot.
func set_code(code: String, language: String = "") -> void:
	_code = code
	_language = language.strip_edges().to_lower()
	finalize()


func set_color(value: Color) -> void:
	if value == _color:
		return
	_color = value
	queue_redraw()


func set_font(value: Font) -> void:
	if value == _font:
		return
	_font = value
	# Re-shape on font change. Token colours don't change but glyph
	# metrics do, so widths / heights need refresh.
	if not _code.is_empty():
		_rebuild_lines()
	update_minimum_size()
	queue_redraw()


func set_font_size(value: int) -> void:
	if value == _font_size:
		return
	_font_size = value
	if not _code.is_empty():
		_rebuild_lines()
	update_minimum_size()
	queue_redraw()


func set_bg_color(value: Color) -> void:
	if value == _bg_color:
		return
	_bg_color = value
	_panel_stylebox = null  # rebuild on next draw
	queue_redraw()


func set_selection_color(value: Color) -> void:
	if value == _selection_color:
		return
	_selection_color = value
	queue_redraw()


# ---------------------------------------------------------------------------
# Theme + state
# ---------------------------------------------------------------------------


var _font: Font = null
var _font_size: int = 0
var _color: Color = Color(1, 1, 1, 0.95)
var _bg_color: Color = Color(0, 0, 0, 0.25)
var _selection_color: Color = Color(0.28, 0.42, 0.78, 0.45)
var _panel_stylebox: StyleBoxFlat = null

# Copy-feedback flag — true for ~2 seconds after the user clicks the
# copy button. Drives a green tint on the icon (mirrors the same
# success state agent_dock paints on its tool-card copy buttons).
var _copy_feedback_active: bool = false

# Tokenised content. Each entry is one logical (newline-separated) line:
#   {
#     "text": String,          # raw line text
#     "tokens": Array[Dict],   # [{start: int, end: int, color: Color, line: TextLine}]
#     "width": float,          # sum of token widths
#   }
# Empty when `_code` is empty or `finalize` hasn't run yet.
var _lines: Array = []
# Pre-computed dimensions used by min_size and drawing.
var _content_width: float = 0.0
var _line_height: float = 0.0
var _ascent: float = 0.0

# Horizontal scroll state. Non-zero only when `_content_width >
# inner_viewport_w`. Updated by shift+wheel and (eventually) thumb-drag.
var _scroll_x: float = 0.0
# Thumb interaction state.
var _hscroll_dragging: bool = false
var _hscroll_drag_offset_x: float = 0.0

# Selection state — flat char index into `_code` (cells joined by '\n').
# `\n` chars are part of the flat index space (so a selection can include
# newlines). -1 means no selection.
var _sel_anchor: int = -1
var _sel_focus: int = -1
var _selecting: bool = false
var _selection_manager: Object = null

# Multi-click detection (matches the other blocks).
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
	clip_contents = true  # horizontal scroll requires clipping overflow


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			# Width change doesn't trigger reshape (no wrap). But it does
			# affect the scroll clamp — overflow shifts when the viewport
			# resizes.
			_clamp_scroll()
			queue_redraw()
		NOTIFICATION_THEME_CHANGED, NOTIFICATION_ENTER_TREE:
			if is_inside_tree() and not _code.is_empty():
				_rebuild_lines()
				update_minimum_size()
				queue_redraw()


func _get_minimum_size() -> Vector2:
	if _lines.is_empty():
		return Vector2(0, CODE_PAD_Y * 2.0)
	# Pure Zed-style: always render every line. No height clamp, no
	# fold UI — block grows to whatever the code actually needs and the
	# transcript scroll handles long content (matches Zed's
	# `code_block_overflow_x_scroll = true` + uncapped vertical layout).
	var total_h: float = float(_lines.size()) * _line_height + CODE_PAD_Y * 2.0
	# Bottom-bar reservation when overflowing — one bar height + tiny
	# inset so the thumb doesn't touch the panel border.
	if _has_horizontal_overflow():
		total_h += HSCROLL_BAR_HEIGHT + HSCROLL_BAR_INSET
	return Vector2(0, total_h)


# ---------------------------------------------------------------------------
# Tokenisation + line shaping
# ---------------------------------------------------------------------------


func _rebuild_lines() -> void:
	_lines.clear()
	_content_width = 0.0
	_line_height = 0.0
	_ascent = 0.0
	if _code.is_empty():
		return

	var font: Font = _resolve_font()
	if font == null:
		return
	var fsize: int = _resolve_font_size()
	_ascent = font.get_ascent(fsize)
	# Base line height from font metrics. Use ascent + descent + 2px
	# leading so adjacent lines have a hairline of breathing room
	# (matches the editor's default leading more closely than ascent
	# alone).
	_line_height = font.get_ascent(fsize) + font.get_descent(fsize) + 2.0

	# Build the per-line color regions via Godot's built-in
	# GDScriptSyntaxHighlighter — only when the language is GDScript
	# (or the fence had no info string, which we treat as gdscript by
	# default since this is a Godot tool). Other languages get one
	# default-colour token per line.
	var highlight: Array = _compute_highlight_regions()

	var raw_lines: PackedStringArray = _code.split("\n")
	# `split("\n")` defaults to allow_empty=true so blank lines in the
	# fence body are preserved as empty entries — the original call
	# passed `false` here, which silently dropped every blank line and
	# made `func` definitions visually mash up against each other.
	# Trailing newline produces an empty final element; we keep it as
	# an empty visual line, matching the editor.
	for i in range(raw_lines.size()):
		var line_text: String = raw_lines[i]
		# `highlight[i]` is now always a Dictionary (filled in
		# `_compute_highlight_regions`), but stay defensive in case a
		# future caller invokes `_rebuild_lines` with a stale array.
		var info_v: Variant = highlight[i] if i < highlight.size() else null
		var line_info: Dictionary = info_v if info_v is Dictionary else {}
		var tokens: Array = _segment_line(line_text, line_info, font, fsize)
		var line_w: float = 0.0
		for tok in tokens:
			line_w += (tok as Dictionary).get("width", 0.0)
		_lines.append({"text": line_text, "tokens": tokens, "width": line_w})
		if line_w > _content_width:
			_content_width = line_w


func _resolve_font() -> Font:
	if _font != null:
		return _font
	if is_inside_tree():
		var tf := get_theme_default_font()
		if tf != null:
			return tf
	return ThemeDB.fallback_font


func _resolve_font_size() -> int:
	if _font_size > 0:
		return _font_size
	var inh := get_theme_default_font_size()
	return inh if inh > 0 else 14


# Returns Array[Dictionary], one entry per line. Each entry is the
# `{column: {color: Color, ...}}` dict the SyntaxHighlighter API exposes.
# Empty dict for non-GDScript languages.
func _compute_highlight_regions() -> Array:
	var out: Array = []
	if _language != "" and _language != "gdscript" and _language != "gd":
		# Non-GDScript: skip highlighter, default-colour everything.
		# Fill with empty dicts (rather than leaving null entries from
		# `Array.resize`) so the consumer can treat every slot as a
		# real Dictionary without null-guards.
		var line_count: int = _code.count("\n") + 1
		out.resize(line_count)
		for i in range(line_count):
			out[i] = {}
		return out

	# Standalone TextEdit + GDScriptSyntaxHighlighter. The TextEdit
	# doesn't need to be in the scene tree for the highlighter to run;
	# `get_line_syntax_highlighting` walks the highlighter against the
	# TextEdit's text on demand. We build it once per finalize call and
	# free it immediately after extracting the colour data.
	var te := TextEdit.new()
	te.text = _code
	var hl := GDScriptSyntaxHighlighter.new()
	te.syntax_highlighter = hl
	var line_count: int = te.get_line_count()
	out.resize(line_count)
	for i in range(line_count):
		# Untyped `info` so the `null` return on edge cases (line out of
		# range, highlighter not yet wired up) doesn't trip the strict
		# `Dictionary` type-check on assignment — coerce to {} below.
		var info = hl.get_line_syntax_highlighting(i)
		out[i] = info if info is Dictionary else {}
	te.queue_free()
	return out


# Convert one line's `{column: {color: Color}}` dict into ordered
# `[{start, end, color, text, width, line: TextLine}]` tokens. Each
# token gets its own shaped TextLine because TextLine.draw is monochrome
# — separate lines is the only way to colour subsequences differently.
func _segment_line(
	line_text: String, info: Dictionary, font: Font, fsize: int
) -> Array:
	var tokens: Array = []
	if line_text.is_empty():
		return tokens
	# Build break points from the highlighter's column keys plus the
	# line length sentinel. Sorted ascending. Adjacent equal keys are
	# de-duplicated implicitly by the dict.
	var break_points: PackedInt32Array = PackedInt32Array()
	if info.is_empty():
		break_points.append(0)
	else:
		var keys: Array = info.keys()
		keys.sort()
		for k in keys:
			break_points.append(int(k))
		if break_points.is_empty() or break_points[0] > 0:
			# Synthesise a leading default-colour token if the first key
			# isn't 0 (rare but defensive).
			break_points.insert(0, 0)
	break_points.append(line_text.length())
	# Emit one token per [break_points[i], break_points[i+1]) range.
	for i in range(break_points.size() - 1):
		var s: int = break_points[i]
		var e: int = break_points[i + 1]
		if e <= s:
			continue
		var token_text: String = line_text.substr(s, e - s)
		if token_text.is_empty():
			continue
		var color: Color = _color
		var key_dict_v = info.get(s, null)
		if key_dict_v is Dictionary:
			var c_v = (key_dict_v as Dictionary).get("color", null)
			if c_v is Color:
				color = c_v
		var tl := TextLine.new()
		tl.add_string(token_text, font, fsize)
		tokens.append({
			"start": s,
			"end": e,
			"color": color,
			"text": token_text,
			"width": tl.get_size().x,
			"line": tl,
		})
	return tokens


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------


func _draw() -> void:
	# Outer panel bg + rounded border.
	if _panel_stylebox == null:
		_panel_stylebox = StyleBoxFlat.new()
		_panel_stylebox.bg_color = _bg_color
		_panel_stylebox.set_corner_radius_all(CORNER_RADIUS)
	# Draw against `size.y` (the Control's actual rendered height after
	# layout) rather than `_get_minimum_size().y` (what we'd LIKE to be).
	# When the user toggles the clamp, our min_size changes synchronously
	# but the parent's layout cascade (and VirtualFeed's measure pipeline)
	# only catches up on the next deferred phase. During that one-frame
	# gap, drawing chrome at the new min height while clip_contents still
	# clamps to the old size left the footer painted *outside* the
	# visible rect — the user saw the chevron disappear after every
	# expand/collapse until something else (scroll, resize) re-fired
	# layout. Painting against `size.y` keeps chrome inside the rendered
	# rect always, with at most a one-frame visual lag where the panel
	# is briefly the old height with new content (the layout cascade
	# resolves it on the next tick).
	var panel_h: float = size.y
	draw_style_box(_panel_stylebox, Rect2(Vector2.ZERO, Vector2(size.x, panel_h)))
	if _lines.is_empty():
		return

	# Selection rects under the text so they read as "behind" the
	# glyphs rather than a tinted overlay.
	if has_selection():
		_draw_selection()

	# Tokens. Scroll x shifts the inner content; clip_contents=true on
	# this Control makes anything beyond the panel rect get cut off.
	var inner_left: float = CODE_PAD_X - _scroll_x
	var inner_top: float = CODE_PAD_Y
	for i in range(_lines.size()):
		var line: Dictionary = _lines[i]
		var x_cursor: float = inner_left
		var y: float = inner_top + float(i) * _line_height
		for tok_v in line["tokens"]:
			var tok: Dictionary = tok_v
			var tl: TextLine = tok["line"]
			var color: Color = tok["color"]
			tl.draw(get_canvas_item(), Vector2(x_cursor, y), color)
			x_cursor += float(tok["width"])

	# Self-drawn horizontal scrollbar (visible only on overflow). Just a
	# thin thumb at the bottom of the panel — no track behind it (the
	# editor's own h-scroll thumb is similarly understated).
	if _has_horizontal_overflow():
		_draw_hscroll_thumb()

	# Top-right copy button. Always drawn (any code is copyable). Sits
	# clear of the panel's rounded corner via COPY_INSET.
	_draw_copy_button()



# Top-right copy button. Lucide copy glyph, tinted with the block's
# text colour at slightly lower alpha. Click → entire `_code` to the
# clipboard (no formatting / colours, just the raw text).
func _draw_copy_button() -> void:
	var rect := _copy_rect()
	var col: Color
	if _copy_feedback_active:
		col = COPY_FEEDBACK_COLOR
	else:
		col = Color(_color)
		col.a = max(0.7, _color.a * 0.85)
	draw_texture_rect(ICON_COPY, rect, false, col)


# Called by the SceneTreeTimer scheduled in the copy-button click path.
# Idempotent — if the user spam-clicks copy, multiple timers fire but
# each just turns the flag off again.
func _clear_copy_feedback() -> void:
	if not _copy_feedback_active:
		return
	_copy_feedback_active = false
	queue_redraw()


func _copy_rect() -> Rect2:
	var sz: float = COPY_ICON_SIZE * _ui_scale()
	var inset: float = COPY_INSET * _ui_scale()
	return Rect2(
		Vector2(size.x - inset - sz, inset),
		Vector2(sz, sz),
	)


func _copy_hit_rect() -> Rect2:
	var r := _copy_rect()
	var pad: float = COPY_HIT_PAD * _ui_scale()
	return Rect2(
		r.position - Vector2(pad, pad),
		r.size + Vector2(pad * 2.0, pad * 2.0),
	)


func _ui_scale() -> float:
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_scale()
	return 1.0


func _draw_hscroll_thumb() -> void:
	var viewport_w: float = max(0.0, size.x - CODE_PAD_X * 2.0)
	if viewport_w <= 0.0:
		return
	var ratio: float = viewport_w / _content_width
	var thumb_w: float = max(20.0, viewport_w * ratio)
	var max_scroll: float = max(0.0, _content_width - viewport_w)
	var t: float = (_scroll_x / max_scroll) if max_scroll > 0.0 else 0.0
	var thumb_x: float = CODE_PAD_X + (viewport_w - thumb_w) * t
	var bar_y: float = size.y - HSCROLL_BAR_HEIGHT - HSCROLL_BAR_INSET
	# Track (faint) — drawn behind the thumb.
	var track_color := Color(_color)
	track_color.a = 0.08
	draw_rect(
		Rect2(Vector2(CODE_PAD_X, bar_y), Vector2(viewport_w, HSCROLL_BAR_HEIGHT)),
		track_color,
		true,
	)
	# Thumb.
	var thumb_color := Color(_color)
	thumb_color.a = 0.4 if not _hscroll_dragging else 0.7
	draw_rect(
		Rect2(Vector2(thumb_x, bar_y), Vector2(thumb_w, HSCROLL_BAR_HEIGHT)),
		thumb_color,
		true,
	)


func _draw_selection() -> void:
	var lo: int = min(_sel_anchor, _sel_focus)
	var hi: int = max(_sel_anchor, _sel_focus)
	if hi <= lo:
		return
	# Decompose flat range into per-line spans.
	var inner_left: float = CODE_PAD_X - _scroll_x
	var inner_top: float = CODE_PAD_Y
	var line_offset: int = 0
	for i in range(_lines.size()):
		var line: Dictionary = _lines[i]
		var line_text: String = line["text"]
		var line_len: int = line_text.length()
		var line_start: int = line_offset
		var line_end: int = line_offset + line_len
		# `\n` between lines contributes 1 to the flat space.
		if line_end >= lo and line_start <= hi:
			# Selection overlaps this line.
			var s_local: int = max(0, lo - line_start)
			var e_local: int = min(line_len, hi - line_start)
			# Selection past line_end (continues onto next line) →
			# extend rect to line right edge so the highlight reads as
			# unbroken across the wrap, like CodeEdit / TextBlock.
			var continues_past: bool = hi > line_end
			var x0: float = inner_left + _x_at_col(line, s_local)
			var x1: float
			if continues_past:
				x1 = inner_left + line["width"]
			else:
				x1 = inner_left + _x_at_col(line, e_local)
			var y: float = inner_top + float(i) * _line_height
			# Empty selected line: synthesise a small rect so the user
			# can tell the empty line is part of the selection.
			if x1 <= x0 + 0.5:
				x1 = x0 + max(8.0, float(_resolve_font_size()) * 0.5)
			draw_rect(
				Rect2(Vector2(x0, y), Vector2(x1 - x0, _line_height)),
				_selection_color,
				true,
			)
		line_offset = line_end + 1  # +1 for the joining '\n' in flat space


# Translate a column position within a line into the cumulative pixel x
# from the line's start. Walks tokens until the column lands inside one,
# then asks that token's TextLine for the per-character caret x.
func _x_at_col(line: Dictionary, col: int) -> float:
	if col <= 0:
		return 0.0
	var x: float = 0.0
	for tok_v in line["tokens"]:
		var tok: Dictionary = tok_v
		var s: int = tok["start"]
		var e: int = tok["end"]
		if col >= e:
			x += float(tok["width"])
			continue
		# col falls inside this token.
		var local_col: int = col - s
		if local_col <= 0:
			return x
		# Use TextServer caret API to locate the exact pixel x of the
		# caret BEFORE `local_col`. Same machinery TextBlock uses for
		# its selection rect end-x calc.
		var tl: TextLine = tok["line"]
		var ts := TextServerManager.get_primary_interface()
		if ts == null:
			return x + float(tok["width"]) * float(local_col) / max(1.0, float(e - s))
		var rid: RID = tl.get_rid()
		var info: Dictionary = ts.shaped_text_get_carets(rid, local_col)
		if not info.is_empty():
			var rect_v = info.get("leading_rect", null)
			if rect_v is Rect2:
				return x + (rect_v as Rect2).position.x
		# Fallback: glyph iterate.
		var glyphs: Array = ts.shaped_text_get_glyphs(rid)
		var gx: float = 0.0
		for g_v in glyphs:
			var g: Dictionary = g_v
			var g_start: int = int(g.get("start", 0))
			if g_start >= local_col:
				return x + gx
			gx += float(g.get("advance", 0.0))
		return x + gx
	return x


# ---------------------------------------------------------------------------
# Hit testing
# ---------------------------------------------------------------------------


# Convert a local mouse position into a flat char index into `_code`.
# Always returns a valid index in [0, _code.length()] — clamps when the
# point is outside the content area.
func _hit_test_flat(local_pos: Vector2) -> int:
	if _lines.is_empty():
		return 0
	var inner_left: float = CODE_PAD_X - _scroll_x
	var inner_top: float = CODE_PAD_Y
	var inner_x: float = local_pos.x - inner_left
	var inner_y: float = local_pos.y - inner_top
	var line_idx: int = int(floor(inner_y / max(1.0, _line_height)))
	line_idx = clamp(line_idx, 0, _lines.size() - 1)
	var line: Dictionary = _lines[line_idx]
	var col: int = _col_at_x(line, inner_x)
	# Compute flat offset for line start (sum of prior line lengths + (idx) newlines).
	var flat: int = 0
	for i in range(line_idx):
		flat += int((_lines[i] as Dictionary)["text"].length()) + 1
	return flat + col


# Translate a pixel x within the line into a column index. Walks tokens
# accumulating widths; once x lands inside a token, asks TextServer to
# resolve the column.
func _col_at_x(line: Dictionary, x: float) -> int:
	if x <= 0.0:
		return 0
	var x_cursor: float = 0.0
	var col_cursor: int = 0
	for tok_v in line["tokens"]:
		var tok: Dictionary = tok_v
		var w: float = float(tok["width"])
		var s: int = tok["start"]
		var e: int = tok["end"]
		if x <= x_cursor + w:
			# Hit inside this token.
			var tl: TextLine = tok["line"]
			var ts := TextServerManager.get_primary_interface()
			if ts == null:
				return s
			var rid: RID = tl.get_rid()
			var local_x: float = x - x_cursor
			var col_in_tok: int = ts.shaped_text_hit_test_position(rid, local_x)
			return clamp(s + col_in_tok, s, e)
		x_cursor += w
		col_cursor = e
	return col_cursor


# ---------------------------------------------------------------------------
# Selection — local + manager protocol
# ---------------------------------------------------------------------------


func has_selection() -> bool:
	if _sel_anchor < 0 or _sel_focus < 0:
		return false
	return _sel_anchor != _sel_focus


func clear_selection() -> void:
	if _sel_anchor == -1 and _sel_focus == -1:
		return
	_sel_anchor = -1
	_sel_focus = -1
	_selecting = false
	set_process(false)
	set_process_input(false)
	queue_redraw()
	emit_signal("selection_changed")


func clear_selection_silent() -> void:
	if _sel_anchor == -1 and _sel_focus == -1:
		return
	_sel_anchor = -1
	_sel_focus = -1
	_selecting = false
	queue_redraw()


func get_selected_text() -> String:
	if not has_selection():
		return ""
	var lo: int = min(_sel_anchor, _sel_focus)
	var hi: int = max(_sel_anchor, _sel_focus)
	lo = clamp(lo, 0, _code.length())
	hi = clamp(hi, 0, _code.length())
	if hi <= lo:
		return ""
	return _code.substr(lo, hi - lo)


func get_text() -> String:
	return _code


# ---------------------------------------------------------------------------
# Manager protocol setters
# ---------------------------------------------------------------------------


func register_selection_manager(manager: Object) -> void:
	_selection_manager = manager


func select_range(a: int, b: int) -> void:
	var n: int = _code.length()
	_sel_anchor = clampi(a, 0, n)
	_sel_focus = clampi(b, 0, n)
	queue_redraw()


func select_from_char(start_char: int) -> void:
	_sel_anchor = clampi(start_char, 0, _code.length())
	_sel_focus = _code.length()
	queue_redraw()


func select_to_char(end_char: int) -> void:
	_sel_anchor = 0
	_sel_focus = clampi(end_char, 0, _code.length())
	queue_redraw()


func select_all() -> void:
	_sel_anchor = 0
	_sel_focus = _code.length()
	queue_redraw()


func get_selection_anchor() -> int:
	return _sel_anchor


func get_selection_caret() -> int:
	return _sel_focus


func hit_test_char(local_pos: Vector2) -> int:
	return _hit_test_flat(local_pos)


# ---------------------------------------------------------------------------
# Word / line select
# ---------------------------------------------------------------------------


func _select_word_at(flat_idx: int) -> void:
	if _code.is_empty():
		return
	var n: int = _code.length()
	var s: int = clamp(flat_idx, 0, n)
	var e: int = s
	while s > 0 and _is_word_char(_code.unicode_at(s - 1)):
		s -= 1
	while e < n and _is_word_char(_code.unicode_at(e)):
		e += 1
	if s == e:
		return
	_sel_anchor = s
	_sel_focus = e


# Triple-click: select the line that contains `flat_idx`.
func _select_line_at(flat_idx: int) -> void:
	if _code.is_empty():
		return
	var n: int = _code.length()
	var s: int = clamp(flat_idx, 0, n)
	var e: int = s
	while s > 0 and _code.unicode_at(s - 1) != 0x0a:
		s -= 1
	while e < n and _code.unicode_at(e) != 0x0a:
		e += 1
	_sel_anchor = s
	_sel_focus = e


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
	var pos: int = _hit_test_flat(local)
	if pos != _sel_focus:
		_sel_focus = pos
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
	# Wheel handling: shift+wheel = horizontal scroll within block.
	# Plain wheel = forward to ancestor ScrollContainer (transcript).
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if mb.shift_pressed and _has_horizontal_overflow():
					if mb.pressed:
						var delta: float = _WHEEL_STEP_PX
						if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
							delta = -delta
						_scroll_x += delta
						_clamp_scroll()
						accept_event()
						queue_redraw()
					return
				_forward_wheel_to_scroll(mb)
				return
			MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT:
				if _has_horizontal_overflow():
					if mb.pressed:
						var hdelta: float = _WHEEL_STEP_PX
						if mb.button_index == MOUSE_BUTTON_WHEEL_LEFT:
							hdelta = -hdelta
						_scroll_x += hdelta
						_clamp_scroll()
						accept_event()
						queue_redraw()
					return
				_forward_wheel_to_scroll(mb)
				return

		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			accept_event()
			emit_signal("right_clicked", mb.position)
			return

		if mb.button_index == MOUSE_BUTTON_LEFT:
			# Top-right copy button. Press-only — releases on the icon
			# are no-ops. Sends the entire `_code` to the system
			# clipboard (no formatting / colours), matching what the
			# right-click "Copy This Agent Response" action does
			# entry-wide.
			if _copy_hit_rect().has_point(mb.position):
				accept_event()
				if mb.pressed:
					DisplayServer.clipboard_set(_code)
					_copy_feedback_active = true
					queue_redraw()
					var tree := get_tree()
					if tree != null:
						tree.create_timer(COPY_FEEDBACK_SECONDS).timeout.connect(
							_clear_copy_feedback
						)
				return
			# Thumb hit-test: clicks on the bottom scrollbar drag the
			# thumb instead of starting selection.
			if _has_horizontal_overflow() and _hit_in_scrollbar(mb.position):
				accept_event()
				if mb.pressed:
					_hscroll_dragging = true
					_hscroll_drag_offset_x = mb.position.x - _scrollbar_thumb_x()
					queue_redraw()
				else:
					_hscroll_dragging = false
					queue_redraw()
				return
			accept_event()
			if mb.pressed:
				var pos: int = _hit_test_flat(mb.position)
				var now: float = Time.get_ticks_msec() / 1000.0
				var within: bool = (
					_last_click_time_sec >= 0.0
					and now - _last_click_time_sec <= _MULTI_CLICK_WINDOW_SEC
					and mb.position.distance_to(_last_click_pos) <= _MULTI_CLICK_TOLERANCE_PX
				)
				_click_run = _click_run + 1 if within else 1
				if _click_run > 3:
					_click_run = 1
				_last_click_time_sec = now
				_last_click_pos = mb.position

				var has_manager: bool = (
					_selection_manager != null and is_instance_valid(_selection_manager)
				)

				if mb.shift_pressed and _sel_anchor >= 0:
					_sel_focus = pos
					_selecting = true
					_begin_drag_tracking()
					queue_redraw()
					emit_signal("selection_changed")
					return

				match _click_run:
					2:
						_select_word_at(pos)
						_selecting = false
					3:
						_select_line_at(pos)
						_selecting = false
					_:
						_sel_anchor = pos
						_sel_focus = pos
						if has_manager:
							_selecting = false
						else:
							_selecting = true
							_begin_drag_tracking()
				queue_redraw()
				emit_signal("selection_changed")
				emit_signal("selection_drag_started", pos)
			else:
				_end_drag()
			return

	if event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		if _hscroll_dragging:
			_drive_thumb_drag(mm.position.x)
			accept_event()
			queue_redraw()


func _hit_in_scrollbar(pos: Vector2) -> bool:
	var bar_y: float = size.y - HSCROLL_BAR_HEIGHT - HSCROLL_BAR_INSET
	return (
		pos.y >= bar_y - 2.0
		and pos.y <= bar_y + HSCROLL_BAR_HEIGHT + 2.0
		and pos.x >= CODE_PAD_X
		and pos.x <= size.x - CODE_PAD_X
	)


func _scrollbar_thumb_x() -> float:
	var viewport_w: float = max(0.0, size.x - CODE_PAD_X * 2.0)
	if viewport_w <= 0.0 or _content_width <= viewport_w:
		return CODE_PAD_X
	var ratio: float = viewport_w / _content_width
	var thumb_w: float = max(20.0, viewport_w * ratio)
	var max_scroll: float = _content_width - viewport_w
	var t: float = (_scroll_x / max_scroll) if max_scroll > 0.0 else 0.0
	return CODE_PAD_X + (viewport_w - thumb_w) * t


func _drive_thumb_drag(mouse_x: float) -> void:
	var viewport_w: float = max(0.0, size.x - CODE_PAD_X * 2.0)
	if viewport_w <= 0.0 or _content_width <= viewport_w:
		return
	var ratio: float = viewport_w / _content_width
	var thumb_w: float = max(20.0, viewport_w * ratio)
	var max_scroll: float = _content_width - viewport_w
	var thumb_x: float = clamp(
		mouse_x - _hscroll_drag_offset_x,
		CODE_PAD_X,
		CODE_PAD_X + viewport_w - thumb_w,
	)
	var t: float = (thumb_x - CODE_PAD_X) / max(1.0, viewport_w - thumb_w)
	_scroll_x = t * max_scroll


func _has_horizontal_overflow() -> bool:
	if _content_width <= 0.0 or size.x <= 0.0:
		return false
	return _content_width > (size.x - CODE_PAD_X * 2.0) + 0.5


func _clamp_scroll() -> void:
	var viewport_w: float = max(0.0, size.x - CODE_PAD_X * 2.0)
	var max_scroll: float = max(0.0, _content_width - viewport_w)
	_scroll_x = clamp(_scroll_x, 0.0, max_scroll)


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



