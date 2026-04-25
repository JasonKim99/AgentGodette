@tool
class_name GodetteMarkdownToBBCode
extends RefCounted
#
# Phase 1 of the flat-draw refactor (see design/flat_draw.md).
#
# Translates the GodetteMarkdown.parse() event stream into a flat list of
# segments suitable for a renderer that emits ONE RichTextLabel per
# continuous text run, plus dedicated Controls for content BBCode genuinely
# can't carry (code blocks, horizontal rules).
#
# This module does NOT touch the existing GodetteMarkdownRender path. It's
# a pure transformation layer that the new flat renderer will consume in
# Phase 2; until then it can be exercised independently for unit-style
# verification without affecting any rendered transcript.
#
# ---------------------------------------------------------------------------
# Output schema
# ---------------------------------------------------------------------------
# Each call returns an Array of Dictionary segments. Three types are
# produced:
#
#   {"type": "bbcode",     "text": String}
#       BBCode-encoded text run. Adjacent bbcode segments are coalesced
#       into one entry before return so the renderer doesn't have to.
#
#   {"type": "code_block", "language": String, "code": String}
#       A fenced code block. The flat renderer breaks the active RTL,
#       emits a CodeBlockCard with these fields, then starts a fresh RTL
#       for whatever follows. `code` is RAW (no BBCode escapes), since
#       the card renders it as monospace text, not as BBCode.
#
#   {"type": "rule"}
#       Horizontal rule. Same break-and-restart-RTL pattern; the flat
#       renderer emits a 1px ColorRect, identical to the current
#       GodetteMarkdownRender output.
#
# Lists, tables, blockquotes, headings, inline emphasis, links and
# inline code stay inside `bbcode` segments — RichTextLabel has native
# BBCode tags for all of them ([ul] / [ol] / [table] / [cell] / [indent]
# / [b] / [i] / [s] / [code] / [bgcolor] / [color] / [url] / [font_size]).
#
# ---------------------------------------------------------------------------
# ctx
# ---------------------------------------------------------------------------
# Optional context dict mirroring the renderer's. When fields are absent
# we fall back to sensible defaults so the translator can run in headless
# tests without a live editor theme. Used fields:
#   - base_font_size: int   — heading derivation (default 14)
#   - code_bg:        Color — inline code chip background (default grey)
#   - link_bg:        Color — link chip background (default subtle blue)
#   - blockquote_bar: Color — blockquote prefix glyph color (default fg)

# Heading sizes mirror GodetteMarkdownRender.HEADING_SIZE_DELTA so the
# flat renderer produces visually-identical headings to the current path.
const HEADING_SIZE_DELTA: Array = [10, 6, 3, 1, 0, 0]

# Default colors for headless / partial-ctx callers.
const _DEFAULT_BASE_FONT_SIZE: int = 14
const _DEFAULT_CODE_BG: Color = Color(1, 1, 1, 0.08)
const _DEFAULT_LINK_BG: Color = Color(0.55, 0.78, 1.0, 0.18)
const _DEFAULT_BLOCKQUOTE_BAR: Color = Color(0.55, 0.78, 1.0, 1.0)


# Public entry. Returns Array[Dictionary] of segments.
static func translate(events: Array, ctx: Dictionary = {}) -> Array:
	var segments: Array = []
	# Buffer for the BBCode run currently being assembled. Flushed into
	# `segments` whenever a non-bbcode segment (code_block, rule) needs
	# to break the run, and at the end of the event stream.
	var buf: String = ""

	# Block-state tracking. Lists need state to know which closing tag
	# to emit ([/ul] vs [/ol]); table cells need to know their parent
	# row's header flag; code blocks need to buffer raw text without
	# BBCode escaping.
	#
	# Frame: Dictionary with at least a "tag" key. Specific frames may
	# add: "ordered" (bool, list), "is_header" (bool, table_row),
	# "alignments" (Array, table), "code_lang" + "code_buffer"
	# (code_block).
	var stack: Array = []

	# Resolved theme bits with defaults backfilled.
	var base_font_size: int = int(ctx.get("base_font_size", _DEFAULT_BASE_FONT_SIZE))
	var code_bg_hex: String = _color_to_hex(ctx.get("code_bg", _DEFAULT_CODE_BG))
	var link_bg_hex: String = _color_to_hex(ctx.get("link_bg", _DEFAULT_LINK_BG))
	var bq_bar_hex: String = _color_to_hex(ctx.get("blockquote_bar", _DEFAULT_BLOCKQUOTE_BAR))

	for ev_variant in events:
		if typeof(ev_variant) != TYPE_DICTIONARY:
			continue
		var ev: Dictionary = ev_variant
		var ev_type: String = str(ev.get("type", ""))

		# Code block content path: ALL events while inside a code_block
		# frame buffer their text raw. The matching `end code_block`
		# event flushes the current bbcode run, then emits the segment.
		if not stack.is_empty() and str(stack[-1].get("tag", "")) == "code_block":
			if ev_type == "text":
				stack[-1]["code_buffer"].append(str(ev.get("text", "")))
				continue
			if ev_type == "end" and str(ev.get("tag", "")) == "code_block":
				if not buf.is_empty():
					segments.append({"type": "bbcode", "text": buf})
					buf = ""
				var code_text: String = "\n".join(stack[-1]["code_buffer"])
				segments.append({
					"type": "code_block",
					"language": str(stack[-1].get("code_lang", "")),
					"code": code_text,
				})
				stack.pop_back()
				continue
			# Anything else inside a code_block (shouldn't happen with
			# well-formed events) — ignore to stay robust.
			continue

		match ev_type:
			"start":
				buf = _handle_start(ev, stack, buf, base_font_size, bq_bar_hex)
			"end":
				buf = _handle_end(ev, stack, buf)
			"text":
				buf += _encode_text_event(ev, code_bg_hex, link_bg_hex)
			"rule":
				if not buf.is_empty():
					segments.append({"type": "bbcode", "text": buf})
					buf = ""
				segments.append({"type": "rule"})
			"soft_break":
				buf += " "
			"hard_break":
				buf += "\n"
			_:
				pass

	# Final flush.
	if not buf.is_empty():
		segments.append({"type": "bbcode", "text": buf})

	return _coalesce(segments)


# ---------------------------------------------------------------------------
# Block start / end handlers
# ---------------------------------------------------------------------------


# Emits opening BBCode for a `start` event and pushes a frame onto the
# stack. Returns the updated buffer; stack mutation happens in-place.
static func _handle_start(ev: Dictionary, stack: Array, buf: String, base_font_size: int, bq_bar_hex: String) -> String:
	var tag: String = str(ev.get("tag", ""))
	match tag:
		"paragraph":
			# Pure state — no BBCode emit until inline text arrives.
			stack.append({"tag": "paragraph"})
		"heading":
			var level: int = clamp(int(ev.get("level", 1)), 1, 6)
			var size: int = base_font_size + int(HEADING_SIZE_DELTA[level - 1])
			stack.append({"tag": "heading", "level": level})
			buf += "[font_size=%d][b]" % size
		"blockquote":
			# Approximate Zed's left accent bar with a coloured ▎ glyph
			# at the start of an [indent] block. The bar is one glyph
			# tall; multi-line quotes won't have a continuous bar — a
			# known §4.1 tradeoff in design/flat_draw.md.
			stack.append({"tag": "blockquote"})
			buf += "[indent][color=%s]▎[/color] " % bq_bar_hex
		"code_block":
			# Switch into raw-buffering mode. The early-return path
			# above accumulates text events into code_buffer and emits
			# the code_block segment on `end code_block`.
			stack.append({
				"tag": "code_block",
				"code_lang": str(ev.get("language", "")),
				"code_buffer": [],
			})
		"list":
			var ordered: bool = bool(ev.get("ordered", false))
			stack.append({"tag": "list", "ordered": ordered})
			buf += "[ol]" if ordered else "[ul]"
		"list_item":
			# RTL fills bullets / numbers from the surrounding [ul] /
			# [ol] tag. Pure state-only frame on our side.
			stack.append({"tag": "list_item"})
		"table":
			var alignments: Array = ev.get("alignments", [])
			var cols: int = max(1, alignments.size())
			stack.append({"tag": "table", "alignments": alignments})
			buf += "[table=%d]" % cols
		"table_row":
			# State-only — RTL `[table]` advances rows automatically
			# every `cols` cells.
			stack.append({
				"tag": "table_row",
				"is_header": bool(ev.get("is_header", false)),
			})
		"table_cell":
			# Header cells get bold text. Find the enclosing row to
			# decide.
			var is_header: bool = false
			for i in range(stack.size() - 1, -1, -1):
				if str(stack[i].get("tag", "")) == "table_row":
					is_header = bool(stack[i].get("is_header", false))
					break
			stack.append({"tag": "table_cell", "is_header": is_header})
			buf += "[cell][b]" if is_header else "[cell]"
		_:
			# Unknown tag — push a stub so the matching `end` still
			# pops cleanly. Future parser additions degrade to no-op
			# instead of breaking the stack.
			stack.append({"tag": tag})
	return buf


# Emits closing BBCode for an `end` event and pops the matching frame.
# We capture the popped frame BEFORE popping so list / table_cell
# closes can read state (ordered / is_header) that was set on open.
static func _handle_end(ev: Dictionary, stack: Array, buf: String) -> String:
	var tag: String = str(ev.get("tag", ""))
	var popped: Dictionary = {}
	if not stack.is_empty() and str(stack[-1].get("tag", "")) == tag:
		popped = stack[-1]
		stack.pop_back()
	match tag:
		"paragraph":
			buf += "\n\n"
		"heading":
			buf += "[/b][/font_size]\n\n"
		"blockquote":
			buf += "[/indent]\n\n"
		"code_block":
			# Should have been intercepted by the outer loop's
			# code-block early-return. Defensive no-op for malformed
			# event streams.
			pass
		"list":
			var ordered: bool = bool(popped.get("ordered", false))
			buf += "[/ol]\n\n" if ordered else "[/ul]\n\n"
		"list_item":
			buf += "\n"
		"table":
			buf += "[/table]\n\n"
		"table_row":
			pass
		"table_cell":
			var is_header: bool = bool(popped.get("is_header", false))
			buf += "[/b][/cell]" if is_header else "[/cell]"
		_:
			pass
	return buf


# ---------------------------------------------------------------------------
# Inline text encoding
# ---------------------------------------------------------------------------


static func _encode_text_event(ev: Dictionary, code_bg_hex: String, link_bg_hex: String) -> String:
	var text: String = str(ev.get("text", ""))
	if text.is_empty():
		return ""
	var style: String = str(ev.get("style", "plain"))
	var escaped: String = _bbcode_escape(text)
	match style:
		"bold":
			return "[b]%s[/b]" % escaped
		"italic":
			return "[i]%s[/i]" % escaped
		"bold_italic":
			return "[b][i]%s[/i][/b]" % escaped
		"code":
			# Inline code: chip-style bgcolor + monospace via [code].
			# RTL's `[code]` switches to the mono font; the bgcolor
			# wrap gives the chip background, matching the current
			# renderer's inline code span.
			return "[bgcolor=%s][code]%s[/code][/bgcolor]" % [code_bg_hex, escaped]
		"link":
			# `[url=meta]` carries the href in the meta field; the
			# flat renderer wires `meta_clicked` on the RTL to
			# `OS.shell_open` (or whichever handler agent_dock
			# already uses for links). bgcolor mimics the chip the
			# current path paints behind link spans.
			var href: String = str(ev.get("href", ""))
			var href_escaped: String = _bbcode_escape(href)
			return "[url=%s][bgcolor=%s]%s[/bgcolor][/url]" % [href_escaped, link_bg_hex, escaped]
		_:
			# plain
			return escaped


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


# Escape BBCode metacharacters in user text. RichTextLabel parses `[`
# as a tag opener; `[lb]` is the documented escape that produces a
# literal `[` in the rendered output. `]` outside a tag context is
# already treated as literal so we don't escape it.
static func _bbcode_escape(text: String) -> String:
	return text.replace("[", "[lb]")


# Convert a Color to the `#rrggbb` form BBCode expects in
# `[color=...]` and `[bgcolor=...]`. Drops alpha — translucency on
# inline chips comes from the renderer's underlying StyleBox; alpha-
# suffixed hex would double-apply.
static func _color_to_hex(color_variant) -> String:
	if color_variant is Color:
		return "#" + (color_variant as Color).to_html(false)
	if typeof(color_variant) == TYPE_STRING:
		var s: String = color_variant
		return s if s.begins_with("#") else "#" + s
	return "#ffffff"


# Coalesce adjacent bbcode segments. The translator emits one bbcode
# segment per event for clarity, but the flat renderer wants one per
# RTL run — anything not broken by code_block / rule should be a
# single string.
static func _coalesce(segments: Array) -> Array:
	var result: Array = []
	for seg_variant in segments:
		var seg: Dictionary = seg_variant
		if str(seg.get("type", "")) == "bbcode" and not result.is_empty() and str(result[-1].get("type", "")) == "bbcode":
			result[-1]["text"] = str(result[-1]["text"]) + str(seg["text"])
		else:
			result.append(seg)
	return result
