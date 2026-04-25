@tool
class_name GodetteMarkdownRender
extends RefCounted
#
# Event-walk renderer for Godette's markdown blocks.
#
# Input:
#   events   Array[Dictionary]   — the flat event stream produced by
#                                  GodetteMarkdown.parse()
#   ctx      Dictionary          — colours, fonts, and a few tunables
#                                  the caller resolves from the editor
#                                  theme (see "ctx keys" below)
#
# Output: a VBoxContainer of block widgets ready to drop into the feed.
#
# The renderer is stateless — every call produces a fresh Control tree —
# and intentionally Node-free (it's RefCounted) so unit tests and headless
# callers don't need a live Node to invoke it. Fonts / colours / font
# scaling live in ctx because reading them wants access to the editor
# theme, which is a Node concern and belongs in agent_dock.
#
# ---------------------------------------------------------------------------
# ctx keys (required)
# ---------------------------------------------------------------------------
#   fg                Color  — body text
#   selection_color   Color  — drag-select highlight
#   font_bold         Font
#   font_italic       Font
#   font_bold_italic  Font
#   font_mono         Font
#   font_mono_bold    Font
#   code_bg           Color  — inline code chip background
#   code_block_bg     Color  — fenced code block panel background
#   rule_color        Color  — horizontal rule + table borders
#   blockquote_bar    Color  — blockquote left accent
#   link_bg           Color  — link chip background
#   base_font_size    int    — used for heading derivation + list-marker
#                               column width (scaled by LIST_MARKER_EMS)
#   line_spacing      float  — passed through to every TextBlock
#
# ctx keys (filled in by the renderer — do NOT pre-populate):
#   selection_manager GodetteMarkdownSelection
#     created and attached as a child of the root VBox. Every text-
#     carrying block registers with it so cross-block drag selection
#     stitches the message into one coordinated highlight.

const TextBlockScript = preload("res://addons/godette_agent/text_block.gd")
const SelectionScript = preload("res://addons/godette_agent/markdown_selection_manager.gd")
const ListBlockScript = preload("res://addons/godette_agent/list_block.gd")

# Heading sizes are deltas added to the caller's base_font_size, mirroring
# the proportions browsers use (h1 ~1.6x, h2 ~1.4x, down to h6 = body).
#
# Vertical paddings follow Zed's markdown: no top margin (blocks already
# get PARAGRAPH_GAP above from the parent VBox's separation), uniform
# mb_2 = 8px below. Previous asymmetric values (10/8/6/4/4/4 top, 4/4/3/
# 2/2/2 bottom) made headings feel cramped against the next paragraph.
const HEADING_SIZE_DELTA := [10, 6, 3, 1, 0, 0]
const HEADING_TOP_PAD := [0, 0, 0, 0, 0, 0]
const HEADING_BOTTOM_PAD := [8, 8, 8, 8, 8, 8]
# Inter-block gap (VBoxContainer.separation on the root). Zed uses mb_2
# = 8px between successive paragraphs / blocks. We used 4 for a while
# and the feed read as cramped, especially on replies with many short
# list items next to a paragraph.
const PARAGRAPH_GAP := 8
const CODE_PAD_X := 10
const CODE_PAD_Y := 8
# Zed's `pl_2p5` on the whole list = 10px of left inset per item.
const LIST_INDENT := 10
const LIST_MARKER_GAP := 12
# Marker column width in ems (scaled at render time). Constant across
# list items so bullets (`•`) and ordered markers (`1.`, `10.`) all line
# up — body text starts at the same x regardless of marker width.
const LIST_MARKER_EMS := 1.6
# Blockquote: 4px accent bar + 12px gap = 16px total inset, matching
# Zed's `border_l_4 pl_4`.
const BLOCKQUOTE_BAR_WIDTH := 4
const BLOCKQUOTE_BAR_GAP := 12
const RULE_HEIGHT := 1
const RULE_VERTICAL_PAD := 8


# Entry point. Returns the root VBoxContainer. Mutates `ctx` by storing
# the selection manager under `"selection_manager"` — callers can read
# that if they need to coordinate with the manager later, but the
# common case is "render and forget".
static func render_events(events: Array, ctx: Dictionary) -> Control:
	# Root container. All top-level blocks attach here; nested blocks
	# attach to whatever is at the top of the stack at Start time.
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", PARAGRAPH_GAP)

	# One selection manager per message. Attached as a child of the root
	# VBox so its lifetime tracks the message — when the feed swaps this
	# entry (e.g. after streaming finishes or a message is updated), the
	# manager is freed with the tree and its dangling references with
	# it. Stored on ctx so every text-block-creating branch below can
	# register without having to thread the manager through call sites.
	var selection_manager: GodetteMarkdownSelection = SelectionScript.new()
	selection_manager.name = "MarkdownSelectionManager"
	root.add_child(selection_manager)
	ctx["selection_manager"] = selection_manager

	# Stack of frames, each describing one open block. Fields:
	#   tag          — matches the parser tag (paragraph, table, …)
	#   container    — where child blocks attach (may be null for state-only
	#                  frames like table_row that don't own a Control)
	#   text_target  — GodetteTextBlock for inline text to flow into, or null
	#   Tag-specific extras: ordered, list_counter, alignments, is_header,
	#   col_index — stored inline to avoid a second nested Dictionary.
	var stack: Array = [{"tag": "root", "container": root, "text_target": null}]

	for ev_variant in events:
		var ev: Dictionary = ev_variant
		match str(ev.get("type", "")):
			"start":
				_handle_start(ev, stack, ctx)
			"end":
				_handle_end(ev, stack)
			"text":
				_handle_text(ev, stack, ctx)
			"rule":
				_emit_rule(stack, ctx)
			"soft_break":
				_emit_break(stack, " ")
			"hard_break":
				_emit_break(stack, "\n")

	return root


# ---------------------------------------------------------------------------
# Stack accessors
# ---------------------------------------------------------------------------


# Walk the stack from top to find the innermost text target. Returns null
# when no open block accepts text. Returns Object (not strict TextBlock)
# so ListBlock — which exposes the same `append_span` / `append_text`
# surface but isn't a TextBlock subclass — can also be a target.
static func _current_text_target(stack: Array) -> Object:
	for i in range(stack.size() - 1, -1, -1):
		var tt = (stack[i] as Dictionary).get("text_target", null)
		if tt is Object and is_instance_valid(tt) and tt.has_method("append_span"):
			return tt
	return null


# Walk the stack from top to find the nearest container that can accept a
# new child Control. State-only frames (table_row) carry container=null
# and are skipped.
static func _current_container(stack: Array) -> Control:
	for i in range(stack.size() - 1, -1, -1):
		var c = (stack[i] as Dictionary).get("container", null)
		if c is Control:
			return c
	return null


# ---------------------------------------------------------------------------
# Event handlers
# ---------------------------------------------------------------------------


static func _handle_start(ev: Dictionary, stack: Array, ctx: Dictionary) -> void:
	var tag: String = str(ev.get("tag", ""))
	match tag:
		"paragraph":
			var tb := _make_textblock(ctx)
			_current_container(stack).add_child(tb)
			stack.append({"tag": tag, "container": tb, "text_target": tb})

		"heading":
			var level: int = clamp(int(ev.get("level", 1)), 1, 6)
			var wrapper := MarginContainer.new()
			wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			wrapper.add_theme_constant_override("margin_top", HEADING_TOP_PAD[level - 1])
			wrapper.add_theme_constant_override("margin_bottom", HEADING_BOTTOM_PAD[level - 1])
			var tb := _make_textblock(ctx)
			tb.set_font(ctx["font_bold"])
			tb.set_font_size(int(ctx["base_font_size"]) + HEADING_SIZE_DELTA[level - 1])
			wrapper.add_child(tb)
			_current_container(stack).add_child(wrapper)
			stack.append({"tag": tag, "container": wrapper, "text_target": tb})

		"blockquote":
			var row := HBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_theme_constant_override("separation", BLOCKQUOTE_BAR_GAP)
			var bar := ColorRect.new()
			bar.color = ctx["blockquote_bar"]
			bar.custom_minimum_size = Vector2(BLOCKQUOTE_BAR_WIDTH, 0)
			bar.size_flags_vertical = Control.SIZE_EXPAND_FILL
			bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(bar)
			# Manual register with `row` as hit area so a drag passing
			# through the left accent bar still treats this whole row as
			# "in this block".
			var tb := _make_textblock(ctx, false)
			tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var muted: Color = ctx["fg"]
			muted.a = max(0.7, muted.a * 0.85)
			tb.set_color(muted)
			row.add_child(tb)
			_register_with_hit_area(tb, row, ctx)
			_current_container(stack).add_child(row)
			stack.append({"tag": tag, "container": row, "text_target": tb})

		"code_block":
			var panel := PanelContainer.new()
			panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var style := StyleBoxFlat.new()
			style.bg_color = ctx["code_block_bg"]
			style.set_corner_radius_all(4)
			panel.add_theme_stylebox_override("panel", style)
			var pad := MarginContainer.new()
			pad.add_theme_constant_override("margin_left", CODE_PAD_X)
			pad.add_theme_constant_override("margin_right", CODE_PAD_X)
			pad.add_theme_constant_override("margin_top", CODE_PAD_Y)
			pad.add_theme_constant_override("margin_bottom", CODE_PAD_Y)
			panel.add_child(pad)
			var tb := _make_textblock(ctx)
			tb.set_font(ctx["font_mono"])
			pad.add_child(tb)
			_current_container(stack).add_child(panel)
			stack.append({"tag": tag, "container": panel, "text_target": tb})

		"list":
			# Route 3 PoC re-enabled for swap-bug diagnostic.
			var list_block: GodetteListBlock = ListBlockScript.new()
			list_block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			list_block.set_color(ctx["fg"])
			list_block.set_fonts(
				null,
				ctx["font_bold"],
				ctx["font_italic"],
				ctx["font_bold_italic"],
				ctx["font_mono"]
			)
			list_block.set_font_size(int(ctx["base_font_size"]))
			list_block.set_line_spacing(float(ctx["line_spacing"]))
			list_block.set_ordered(bool(ev.get("ordered", false)))

			var indent := MarginContainer.new()
			indent.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			indent.add_theme_constant_override("margin_left", LIST_INDENT)
			indent.add_child(list_block)
			_current_container(stack).add_child(indent)

			stack.append({
				"tag": tag,
				"container": indent,
				"text_target": list_block,
				"list_block": list_block,
				"ordered": bool(ev.get("ordered", false)),
			})

		"list_item":
			var list_frame: Dictionary = stack[stack.size() - 1]
			var lb_v = list_frame.get("list_block", null)
			if lb_v != null and lb_v.has_method("begin_item"):
				lb_v.begin_item()
			stack.append({"tag": tag, "container": null, "text_target": null})

		"table":
			# Outer PanelContainer gives the grid its visible border; the
			# inner GridContainer lays out cells row-major. h/v separation
			# is zero so adjacent cells share their borders (painted on
			# each cell's right+bottom edges in the table_cell branch).
			var alignments: Array = ev.get("alignments", [])
			var grid_wrap := PanelContainer.new()
			grid_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var tbl_style := StyleBoxFlat.new()
			tbl_style.bg_color = Color(0, 0, 0, 0)
			tbl_style.border_color = ctx["rule_color"]
			tbl_style.set_border_width_all(1)
			tbl_style.set_corner_radius_all(3)
			grid_wrap.add_theme_stylebox_override("panel", tbl_style)
			var grid := GridContainer.new()
			grid.columns = max(1, alignments.size())
			grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			grid.add_theme_constant_override("h_separation", 0)
			grid.add_theme_constant_override("v_separation", 0)
			grid_wrap.add_child(grid)
			_current_container(stack).add_child(grid_wrap)
			stack.append({
				"tag": tag,
				"container": grid,
				"text_target": null,
				"alignments": alignments,
			})

		"table_row":
			# State-only frame. No Control of its own; the grid lays cells
			# out row-major and column boundaries fall out of
			# grid.columns * n_cells. col_index resets to 0 per row so
			# table_cell can pick the right alignment from `alignments`.
			stack.append({
				"tag": tag,
				"container": null,
				"text_target": null,
				"is_header": bool(ev.get("is_header", false)),
				"col_index": 0,
			})

		"table_cell":
			var table_frame: Dictionary = {}
			var row_frame: Dictionary = {}
			for i in range(stack.size() - 1, -1, -1):
				var f: Dictionary = stack[i]
				if f.get("tag", "") == "table_row" and row_frame.is_empty():
					row_frame = f
				elif f.get("tag", "") == "table":
					table_frame = f
					break
			if table_frame.is_empty() or row_frame.is_empty():
				# Orphan cell — emit a tombstone so the stack depth stays
				# balanced with the matching `end` event. Anything appended
				# inside won't render because text_target is null.
				stack.append({"tag": "table_cell", "container": null, "text_target": null})
				return
			var is_header: bool = bool(row_frame.get("is_header", false))
			var cell_bg := PanelContainer.new()
			cell_bg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var cell_style := StyleBoxFlat.new()
			cell_style.bg_color = Color(0, 0, 0, 0)
			if is_header:
				# Header row gets a subtle bg tint; reuses the inline-code
				# chip colour since both express "this content is
				# structural, not a sentence."
				cell_style.bg_color = ctx["code_bg"]
			cell_style.border_color = ctx["rule_color"]
			# Right + bottom borders only — adjacent cells share edges so
			# doubling would make every internal grid line 2 px wide.
			cell_style.border_width_right = 1
			cell_style.border_width_bottom = 1
			cell_bg.add_theme_stylebox_override("panel", cell_style)
			var cell_pad := MarginContainer.new()
			cell_pad.add_theme_constant_override("margin_left", 8)
			cell_pad.add_theme_constant_override("margin_right", 8)
			cell_pad.add_theme_constant_override("margin_top", 4)
			cell_pad.add_theme_constant_override("margin_bottom", 4)
			cell_bg.add_child(cell_pad)
			# We register this TextBlock with the selection manager manually
			# (selectable=false to skip the default auto-register) so we can
			# pass `cell_bg` as the hit area. The cell's SHRINK_CENTER on the
			# TextBlock leaves whitespace above/below inside the grid cell;
			# without the larger hit_area the drag search can't find this
			# cell when the cursor is over that padding.
			var tb := _make_textblock(ctx, false)
			tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			# SHRINK_CENTER vertically so a short cell dropped into a tall row
			# (the Grid forces every cell in a row to the tallest cell's
			# height) ends up with its text centred rather than anchored to
			# the top, leaving an awkward block of whitespace below. Tall
			# cells still fill their own row height because the text itself
			# provides the min_y.
			tb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			if is_header:
				tb.set_font(ctx["font_bold"])
			cell_pad.add_child(tb)
			_register_with_hit_area(tb, cell_bg, ctx)
			var grid: Control = table_frame.get("container")
			if grid != null:
				grid.add_child(cell_bg)
			# Advance the row's column pointer so subsequent cells see the
			# next column index.
			row_frame["col_index"] = int(row_frame.get("col_index", 0)) + 1
			stack.append({"tag": tag, "container": cell_pad, "text_target": tb})

		_:
			# Unknown tag — push a stub frame so the matching `end` still
			# pops cleanly. Keeps the stack depth invariant regardless of
			# parser additions we haven't wired into the renderer yet.
			stack.append({"tag": tag, "container": null, "text_target": null})


static func _handle_end(ev: Dictionary, stack: Array) -> void:
	if stack.size() <= 1:
		return
	var expected: String = str(ev.get("tag", ""))
	var top: Dictionary = stack[stack.size() - 1]
	if top.get("tag", "") != expected:
		push_warning("[godette/md] end '%s' but stack top is '%s'" % [expected, top.get("tag", "")])
	# Route 3: list_item end finalises the current item on the enclosing
	# ListBlock so it shapes + measures incrementally as items arrive.
	if expected == "list_item" and stack.size() >= 2:
		var enclosing: Dictionary = stack[stack.size() - 2]
		var lb_v = enclosing.get("list_block", null)
		if lb_v != null and is_instance_valid(lb_v) and lb_v.has_method("end_item"):
			lb_v.end_item()
	stack.pop_back()


static func _handle_text(ev: Dictionary, stack: Array, ctx: Dictionary) -> void:
	var target := _current_text_target(stack)
	if target == null:
		return
	var text: String = str(ev.get("text", ""))
	if text.is_empty():
		return
	var style: String = str(ev.get("style", "plain"))
	var opts: Dictionary = {}
	match style:
		"bold":
			opts["font"] = ctx["font_bold"]
		"italic":
			opts["font"] = ctx["font_italic"]
		"bold_italic":
			opts["font"] = ctx["font_bold_italic"]
		"code":
			opts["font"] = ctx["font_mono"]
			opts["bg"] = ctx["code_bg"]
		"link":
			# v1: italic glyphs + faint chip bg. Per-glyph foreground
			# colour would need a self-draw path (see TextBlock.set_color
			# note); we don't paint a separate link colour in v1.
			opts["font"] = ctx["font_italic"]
			opts["bg"] = ctx["link_bg"]
		_:
			pass
	target.append_span(text, opts)


static func _emit_break(stack: Array, char_: String) -> void:
	var target := _current_text_target(stack)
	if target == null:
		return
	target.append_text(char_)


static func _emit_rule(stack: Array, ctx: Dictionary) -> void:
	var wrapper := MarginContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_theme_constant_override("margin_top", RULE_VERTICAL_PAD)
	wrapper.add_theme_constant_override("margin_bottom", RULE_VERTICAL_PAD)
	var rule := ColorRect.new()
	rule.color = ctx["rule_color"]
	rule.custom_minimum_size = Vector2(0, RULE_HEIGHT)
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.add_child(rule)
	_current_container(stack).add_child(wrapper)


# ---------------------------------------------------------------------------
# TextBlock + selection manager helpers
# ---------------------------------------------------------------------------


# Make a TextBlock styled from ctx. When `selectable` is true (default),
# register it with the context's selection manager using the TextBlock
# itself as the hit area. Callers that need a different hit area (e.g.
# list item body, table cell body) should pass `selectable=false` and
# then call `_register_with_hit_area` explicitly.
static func _make_textblock(ctx: Dictionary, selectable: bool = true) -> GodetteTextBlock:
	var tb: GodetteTextBlock = TextBlockScript.new()
	tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tb.set_color(ctx["fg"])
	tb.set_line_spacing(float(ctx["line_spacing"]))
	tb.set_selection_color(ctx["selection_color"])
	if selectable:
		_register_with_hit_area(tb, null, ctx)
	return tb


# Register a TextBlock with the selection manager. Passing `hit_area=null`
# uses the TextBlock's own rect for hit testing. Safe to call when no
# manager is attached (no-op).
static func _register_with_hit_area(tb: Node, hit_area: Node, ctx: Dictionary) -> void:
	if not ctx.has("selection_manager"):
		return
	var manager = ctx["selection_manager"]
	if manager == null or not is_instance_valid(manager):
		return
	manager.register_block(tb, hit_area)
