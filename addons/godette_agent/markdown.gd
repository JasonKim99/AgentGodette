@tool
class_name GodetteMarkdown
extends RefCounted
#
# Event-stream markdown parser for the agent feed. Produces a flat Array of
# event Dictionaries that the renderer walks sequentially, maintaining its
# own container + text-target stack. Modeled after pulldown-cmark's
# Start/End/Text event model (see vendor/zed/crates/markdown/src/parser.rs).
#
# Why event stream instead of a block tree:
# - Nesting (table → row → cell → inline styles) falls out naturally from
#   start/end pairs; a tree would need recursive walks on both sides.
# - The renderer stays ~80 lines: one match statement over event types,
#   plus one push/pop on a container stack. Adding new block constructs
#   later (task lists, footnotes, etc.) is a parser-only change.
# - Flat arrays are the easiest GDScript representation to inspect + test.
#
# Subset supported (CommonMark + GFM subset, deliberately NOT the full
# CommonMark spec — we render agent chat output, not HN comments):
#   Block: ATX headings (# .. ######), fenced code blocks (``` or ~~~ with
#     optional info string), unordered (- * +) and ordered (1. 1)) lists,
#     blockquotes (> ), horizontal rules (--- *** ___), GFM pipe tables,
#     paragraphs.
#   Inline: **bold**, *italic*, _italic_, ***bold italic***, `code`,
#     [text](url), soft breaks, hard breaks (trailing two spaces).
#
# Out of scope (degrades to plain text or an approximation):
#   Setext headings, nested lists (flattened to depth 0), emphasis nesting
#   beyond ***…***, autolinks, HTML blocks, reference-style links,
#   footnotes, task lists, strikethrough. Anything the parser can't
#   recognise becomes a text event with style "plain" so the user always
#   sees their content — never a parser error.
#
# ---------------------------------------------------------------------------
# Event shape
# ---------------------------------------------------------------------------
#
# Every event is a Dictionary with `type` set to one of the string tags
# below. Metadata fields are per-type.
#
#   {type: "start", tag: "paragraph"}
#   {type: "start", tag: "heading",    level: 1..6}
#   {type: "start", tag: "blockquote"}
#   {type: "start", tag: "code_block", language: String}
#   {type: "start", tag: "list",       ordered: bool}
#   {type: "start", tag: "list_item"}
#   {type: "start", tag: "table",      alignments: Array[String]}
#       alignments entries: "left" | "center" | "right" | "none"
#   {type: "start", tag: "table_row",  is_header: bool}
#   {type: "start", tag: "table_cell"}
#
#   {type: "end",   tag: "…"}              matching start
#
#   {type: "text",  text: String, style: String}
#       style ∈ {"plain", "bold", "italic", "bold_italic", "code", "link"}
#       when style == "link", also has `href: String`
#
#   {type: "rule"}        horizontal rule (self-contained, no start/end pair)
#   {type: "hard_break"}  explicit line break inside a paragraph
#   {type: "soft_break"}  newline in source that doesn't end the block —
#                         renderer decides whether to keep it or merge
#                         (we collapse to a space for English-flavoured
#                         prose; CJK consumers should write single-line)


const _LIST_MARKERS_UL := ["- ", "* ", "+ "]


# Public entry. Returns Array[Dictionary]; never returns null or raises.
static func parse(source: String) -> Array:
	var events: Array = []
	if source.is_empty():
		return events
	var lines: PackedStringArray = source.split("\n", true)
	var i: int = 0
	while i < lines.size():
		i = _parse_block(lines, i, events)
	return events


# ---------------------------------------------------------------------------
# Block dispatch
# ---------------------------------------------------------------------------


static func _parse_block(lines: PackedStringArray, i: int, events: Array) -> int:
	# Each branch consumes some number of lines, emits events, returns the
	# new cursor. Ordered by priority: fenced code first (greedy), then the
	# exclusive line-based constructs, then paragraph as fallback.
	var line: String = lines[i]

	if _is_blank(line):
		return i + 1

	var fence: Dictionary = _try_match_fence(line)
	if not fence.is_empty():
		return _emit_code_block(lines, i, events, fence)

	if _is_horizontal_rule(line):
		events.append({"type": "rule"})
		return i + 1

	var heading: Dictionary = _try_match_heading(line)
	if not heading.is_empty():
		events.append({"type": "start", "tag": "heading", "level": heading["level"]})
		_parse_inline(heading["text"], events)
		events.append({"type": "end", "tag": "heading"})
		return i + 1

	if _is_blockquote(line):
		return _emit_blockquote(lines, i, events)

	var list_hit: Dictionary = _try_match_list_item(line)
	if not list_hit.is_empty():
		return _emit_list(lines, i, events, bool(list_hit["ordered"]))

	# GFM table: header row followed by delimiter row (`| --- | --- |`).
	# We only recognise it when BOTH lines look table-ish, otherwise fall
	# through to paragraph so a stray pipe in prose doesn't trigger a
	# half-table render.
	if i + 1 < lines.size() and _looks_like_table_delimiter(lines[i + 1]):
		var table_hit: Dictionary = _try_match_table(lines, i)
		if not table_hit.is_empty():
			return _emit_table(events, table_hit)

	return _emit_paragraph(lines, i, events)


# ---------------------------------------------------------------------------
# Block emitters
# ---------------------------------------------------------------------------


static func _emit_code_block(lines: PackedStringArray, i: int, events: Array, fence: Dictionary) -> int:
	var marker: String = fence["marker"]
	var min_len: int = fence["min_len"]
	var lang: String = fence["lang"]
	events.append({"type": "start", "tag": "code_block", "language": lang})
	var code_lines: PackedStringArray = PackedStringArray()
	var j: int = i + 1
	while j < lines.size():
		if _is_closing_fence(lines[j], marker, min_len):
			j += 1
			break
		code_lines.append(lines[j])
		j += 1
	# Code block content is emitted as a single "plain" text event. The
	# renderer is expected to preserve whitespace verbatim when the current
	# block is a code_block — the `plain` style is correct, the special
	# handling lives on the render side, not in the event stream.
	events.append({"type": "text", "text": "\n".join(code_lines), "style": "plain"})
	events.append({"type": "end", "tag": "code_block"})
	return j


static func _emit_blockquote(lines: PackedStringArray, i: int, events: Array) -> int:
	events.append({"type": "start", "tag": "blockquote"})
	var quote_text: String = _strip_quote_marker(lines[i])
	var j: int = i + 1
	while j < lines.size() and _is_blockquote(lines[j]):
		quote_text += " " + _strip_quote_marker(lines[j])
		j += 1
	_parse_inline(quote_text.strip_edges(), events)
	events.append({"type": "end", "tag": "blockquote"})
	return j


static func _emit_list(lines: PackedStringArray, i: int, events: Array, ordered: bool) -> int:
	# Wrap consecutive items of matching kind in one `list` block so the
	# renderer can draw uniform bullet/numeric margins without guessing at
	# boundaries. A blank line OR a marker of the other kind closes the list.
	events.append({"type": "start", "tag": "list", "ordered": ordered})
	var j: int = i
	while j < lines.size():
		if _is_blank(lines[j]):
			break
		var hit: Dictionary = _try_match_list_item(lines[j])
		if hit.is_empty() or bool(hit["ordered"]) != ordered:
			break
		events.append({"type": "start", "tag": "list_item"})
		# Item text may continue on indented lines (≥2 spaces). Fold them in
		# so the renderer sees one logical paragraph per item.
		var item_text: String = hit["text"]
		j += 1
		while j < lines.size():
			var cont: String = lines[j]
			if _is_blank(cont):
				break
			if cont.begins_with("  ") and _try_match_list_item(cont.lstrip(" \t")).is_empty():
				item_text += " " + cont.strip_edges()
				j += 1
				continue
			break
		_parse_inline(item_text, events)
		events.append({"type": "end", "tag": "list_item"})
	events.append({"type": "end", "tag": "list"})
	return j


static func _emit_table(events: Array, table: Dictionary) -> int:
	var header: Array = table["header"]
	var alignments: Array = table["alignments"]
	var rows: Array = table["rows"]
	var consumed: int = int(table["consumed"])

	events.append({"type": "start", "tag": "table", "alignments": alignments})
	events.append({"type": "start", "tag": "table_row", "is_header": true})
	for cell_text in header:
		events.append({"type": "start", "tag": "table_cell"})
		_parse_inline(str(cell_text), events)
		events.append({"type": "end", "tag": "table_cell"})
	events.append({"type": "end", "tag": "table_row"})

	for row_variant in rows:
		var row: Array = row_variant
		events.append({"type": "start", "tag": "table_row", "is_header": false})
		for cell_text in row:
			events.append({"type": "start", "tag": "table_cell"})
			_parse_inline(str(cell_text), events)
			events.append({"type": "end", "tag": "table_cell"})
		events.append({"type": "end", "tag": "table_row"})

	events.append({"type": "end", "tag": "table"})
	return consumed


static func _emit_paragraph(lines: PackedStringArray, i: int, events: Array) -> int:
	# Paragraphs absorb consecutive non-blank lines up to the next block
	# construct. Line joins emit a soft_break event so the renderer can
	# decide how to handle them (usually a space; CJK callers may want
	# nothing). Hard breaks — two trailing spaces or a trailing backslash —
	# emit `hard_break` instead, producing a newline inside the paragraph.
	events.append({"type": "start", "tag": "paragraph"})
	var j: int = i
	var first: bool = true
	while j < lines.size():
		var line: String = lines[j]
		if _is_blank(line):
			break
		# Peek for block starts that interrupt the paragraph. Must include
		# the same constructs _parse_block recognises so a block marker
		# after a paragraph line closes it cleanly.
		if not first:
			if not _try_match_fence(line).is_empty():
				break
			if _is_horizontal_rule(line):
				break
			if not _try_match_heading(line).is_empty():
				break
			if _is_blockquote(line):
				break
			if not _try_match_list_item(line).is_empty():
				break
			if j + 1 < lines.size() and _looks_like_table_delimiter(lines[j + 1]):
				if not _try_match_table(lines, j).is_empty():
					break
		var hard_break: bool = _has_hard_break_suffix(line)
		var content: String = line
		if hard_break:
			# Strip the trailing spaces / backslash so the inline parser
			# doesn't render them literally.
			content = content.rstrip(" ")
			if content.ends_with("\\"):
				content = content.substr(0, content.length() - 1)
		if not first:
			events.append({"type": "soft_break"})
		_parse_inline(content.strip_edges(), events)
		if hard_break:
			events.append({"type": "hard_break"})
		first = false
		j += 1
	events.append({"type": "end", "tag": "paragraph"})
	return j


# ---------------------------------------------------------------------------
# Block matchers
# ---------------------------------------------------------------------------


static func _is_blank(line: String) -> bool:
	return line.strip_edges().is_empty()


static func _try_match_fence(line: String) -> Dictionary:
	var stripped: String = line.lstrip(" ")
	if line.length() - stripped.length() > 3:
		return {}
	if stripped.is_empty():
		return {}
	var ch: String = stripped.substr(0, 1)
	if ch != "`" and ch != "~":
		return {}
	var run: int = 0
	while run < stripped.length() and stripped.substr(run, 1) == ch:
		run += 1
	if run < 3:
		return {}
	var lang: String = stripped.substr(run).strip_edges()
	# Backtick fences forbid backticks in the info string (avoids ambiguity
	# with inline code on the same line). Tilde fences allow anything.
	if ch == "`" and lang.find("`") >= 0:
		return {}
	return {"marker": ch, "min_len": run, "lang": lang}


static func _is_closing_fence(line: String, marker: String, min_len: int) -> bool:
	var stripped: String = line.lstrip(" ")
	if line.length() - stripped.length() > 3:
		return false
	if stripped.length() < min_len:
		return false
	var run: int = 0
	while run < stripped.length() and stripped.substr(run, 1) == marker:
		run += 1
	if run < min_len:
		return false
	return stripped.substr(run).strip_edges().is_empty()


static func _is_horizontal_rule(line: String) -> bool:
	var s: String = line.strip_edges()
	if s.length() < 3:
		return false
	var ch: String = s.substr(0, 1)
	if ch != "-" and ch != "*" and ch != "_":
		return false
	for k in range(s.length()):
		var c: String = s.substr(k, 1)
		if c != ch and c != " ":
			return false
	var marker_count: int = 0
	for k in range(s.length()):
		if s.substr(k, 1) == ch:
			marker_count += 1
	return marker_count >= 3


static func _try_match_heading(line: String) -> Dictionary:
	var s: String = line.lstrip(" ")
	if line.length() - s.length() > 3:
		return {}
	var level: int = 0
	while level < s.length() and level < 6 and s.substr(level, 1) == "#":
		level += 1
	if level == 0:
		return {}
	if level >= s.length():
		return {"level": level, "text": ""}
	if s.substr(level, 1) != " ":
		return {}
	var text: String = s.substr(level + 1).strip_edges()
	while text.ends_with("#"):
		text = text.substr(0, text.length() - 1)
	return {"level": level, "text": text.strip_edges()}


static func _is_blockquote(line: String) -> bool:
	var s: String = line.lstrip(" ")
	if line.length() - s.length() > 3:
		return false
	return s.begins_with(">")


static func _strip_quote_marker(line: String) -> String:
	var s: String = line.lstrip(" ")
	if not s.begins_with(">"):
		return line
	s = s.substr(1)
	if s.begins_with(" "):
		s = s.substr(1)
	return s


static func _try_match_list_item(line: String) -> Dictionary:
	var s: String = line.lstrip(" ")
	if line.length() - s.length() > 3:
		return {}
	for marker in _LIST_MARKERS_UL:
		if s.begins_with(marker):
			return {
				"ordered": false,
				"marker": marker.substr(0, 1),
				"text": s.substr(marker.length()),
			}
	var k: int = 0
	while k < s.length() and s.substr(k, 1) >= "0" and s.substr(k, 1) <= "9":
		k += 1
	if k == 0 or k > 9:
		return {}
	if k >= s.length():
		return {}
	var sep: String = s.substr(k, 1)
	if sep != "." and sep != ")":
		return {}
	if k + 1 >= s.length() or s.substr(k + 1, 1) != " ":
		return {}
	return {
		"ordered": true,
		"marker": s.substr(0, k) + sep,
		"text": s.substr(k + 2),
	}


static func _has_hard_break_suffix(line: String) -> bool:
	# CommonMark hard breaks: two or more trailing spaces OR a trailing `\`.
	if line.ends_with("\\"):
		return true
	if line.length() >= 2 and line.substr(line.length() - 2, 2) == "  ":
		return true
	return false


# ---------------------------------------------------------------------------
# Tables (GFM pipe syntax)
# ---------------------------------------------------------------------------


static func _looks_like_table_delimiter(line: String) -> bool:
	# A delimiter row matches /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/
	# — any sequence of `:?---:?` cells separated by pipes. Cheap prefilter
	# used to avoid running _try_match_table on every paragraph line.
	var s: String = line.strip_edges()
	if s.is_empty():
		return false
	# Drop optional leading/trailing pipes.
	if s.begins_with("|"):
		s = s.substr(1)
	if s.ends_with("|"):
		s = s.substr(0, s.length() - 1)
	if s.strip_edges().is_empty():
		return false
	var parts: PackedStringArray = s.split("|", false)
	for part_variant in parts:
		var part: String = (part_variant as String).strip_edges()
		if part.is_empty():
			return false
		# Allow leading `:` and trailing `:` for alignment flags.
		if part.begins_with(":"):
			part = part.substr(1)
		if part.ends_with(":"):
			part = part.substr(0, part.length() - 1)
		if part.is_empty():
			return false
		for k in range(part.length()):
			if part.substr(k, 1) != "-":
				return false
	return true


static func _try_match_table(lines: PackedStringArray, i: int) -> Dictionary:
	# Expects lines[i] to be the header row and lines[i+1] to be the
	# delimiter row (prechecked via _looks_like_table_delimiter). Returns
	# {header, alignments, rows, consumed} or {} on malformed input.
	if i + 1 >= lines.size():
		return {}
	var header_cells: Array = _split_table_cells(lines[i])
	var delim_cells: Array = _split_table_cells(lines[i + 1])
	if header_cells.is_empty() or delim_cells.is_empty():
		return {}
	if header_cells.size() != delim_cells.size():
		return {}
	var alignments: Array = []
	for cell_variant in delim_cells:
		var cell: String = (cell_variant as String).strip_edges()
		var left: bool = cell.begins_with(":")
		var right: bool = cell.ends_with(":")
		if left and right:
			alignments.append("center")
		elif right:
			alignments.append("right")
		elif left:
			alignments.append("left")
		else:
			alignments.append("none")

	var rows: Array = []
	var j: int = i + 2
	while j < lines.size():
		if _is_blank(lines[j]):
			break
		# Require a pipe to continue the table — otherwise a non-table line
		# following the delimiter closes it.
		if lines[j].find("|") < 0:
			break
		var cells: Array = _split_table_cells(lines[j])
		# Pad or truncate to header width so the renderer gets uniform rows.
		while cells.size() < header_cells.size():
			cells.append("")
		if cells.size() > header_cells.size():
			cells.resize(header_cells.size())
		rows.append(cells)
		j += 1
	return {
		"header": header_cells,
		"alignments": alignments,
		"rows": rows,
		"consumed": j,
	}


static func _split_table_cells(line: String) -> Array:
	# GFM pipe table cell splitter. Drops optional leading/trailing pipe,
	# splits on the remaining unescaped pipes, trims whitespace around each
	# cell. Does NOT handle backslash-escaped pipes inside cells (out of
	# scope for v1 — the agent's tables don't need it).
	var s: String = line.strip_edges()
	if s.begins_with("|"):
		s = s.substr(1)
	if s.ends_with("|"):
		s = s.substr(0, s.length() - 1)
	if s.is_empty():
		return []
	var parts: PackedStringArray = s.split("|", true)
	var cells: Array = []
	for part in parts:
		cells.append((part as String).strip_edges())
	return cells


# ---------------------------------------------------------------------------
# Inline parser
# ---------------------------------------------------------------------------
#
# Emits `text` events (with a single `style` string) directly into the
# supplied `events` Array. Ambiguous input degrades to plain text rather
# than guessing — missing close delimiter ⇒ treat the opener as literal.
#
# Priority at each position:
#   1. Inline code  — backtick-delimited, literal content, no nesting
#   2. Link         — [label](url)
#   3. Bold+italic  — ***text***
#   4. Bold         — **text**
#   5. Italic       — *text* or _text_
#   6. Plain char


static func _parse_inline(text: String, events: Array) -> void:
	if text.is_empty():
		return
	var buf: String = ""
	var i: int = 0
	var n: int = text.length()
	while i < n:
		var ch: String = text.substr(i, 1)

		# Inline code — terminated by the same number of backticks. We
		# match CommonMark's "double backticks let you embed a single
		# backtick" behaviour.
		if ch == "`":
			var run_len: int = 1
			while i + run_len < n and text.substr(i + run_len, 1) == "`":
				run_len += 1
			var close_at: int = _find_backtick_close(text, i + run_len, run_len)
			if close_at >= 0:
				_flush_plain(events, buf)
				buf = ""
				var inner: String = text.substr(i + run_len, close_at - (i + run_len))
				# Trim exactly one leading + trailing space when both are
				# present (CommonMark rule — lets you write `` ` `` to get
				# a literal backtick).
				if inner.length() >= 2 and inner.begins_with(" ") and inner.ends_with(" ") and inner.strip_edges() != "":
					inner = inner.substr(1, inner.length() - 2)
				events.append({"type": "text", "text": inner, "style": "code"})
				i = close_at + run_len
				continue
			buf += text.substr(i, run_len)
			i += run_len
			continue

		# Link: [text](url) on a single line.
		if ch == "[":
			var link_match: Dictionary = _try_match_link(text, i)
			if not link_match.is_empty():
				_flush_plain(events, buf)
				buf = ""
				events.append({
					"type": "text",
					"text": str(link_match["text"]),
					"style": "link",
					"href": str(link_match["href"]),
				})
				i = int(link_match["end"])
				continue

		# Bold + italic: ***text***
		if ch == "*" and i + 2 < n and text.substr(i + 1, 1) == "*" and text.substr(i + 2, 1) == "*":
			var close_bi: int = _find_exact_delim_close(text, i + 3, "***")
			if close_bi > i + 3:
				_flush_plain(events, buf)
				buf = ""
				events.append({
					"type": "text",
					"text": text.substr(i + 3, close_bi - (i + 3)),
					"style": "bold_italic",
				})
				i = close_bi + 3
				continue

		# Bold: **text**
		if ch == "*" and i + 1 < n and text.substr(i + 1, 1) == "*":
			var close_b: int = _find_exact_delim_close(text, i + 2, "**")
			if close_b > i + 2:
				_flush_plain(events, buf)
				buf = ""
				events.append({
					"type": "text",
					"text": text.substr(i + 2, close_b - (i + 2)),
					"style": "bold",
				})
				i = close_b + 2
				continue

		# Italic: *text* or _text_
		if ch == "*" or ch == "_":
			var close_i: int = _find_single_delim_close(text, i + 1, ch)
			if close_i > i + 1:
				_flush_plain(events, buf)
				buf = ""
				events.append({
					"type": "text",
					"text": text.substr(i + 1, close_i - (i + 1)),
					"style": "italic",
				})
				i = close_i + 1
				continue

		buf += ch
		i += 1

	_flush_plain(events, buf)


static func _flush_plain(events: Array, buf: String) -> void:
	if buf.is_empty():
		return
	events.append({"type": "text", "text": buf, "style": "plain"})


static func _find_backtick_close(text: String, from: int, run_len: int) -> int:
	var i: int = from
	var n: int = text.length()
	while i < n:
		if text.substr(i, 1) != "`":
			i += 1
			continue
		var len: int = 0
		while i + len < n and text.substr(i + len, 1) == "`":
			len += 1
		if len == run_len:
			return i
		i += len
	return -1


static func _find_exact_delim_close(text: String, from: int, delim: String) -> int:
	# Locate an exact `delim` run of matching length. Used for ** and ***
	# so that `***foo**` isn't parsed as italic inside bold.
	if from >= text.length():
		return -1
	if text.substr(from, 1) == " ":
		return -1
	var dlen: int = delim.length()
	var i: int = from
	var n: int = text.length()
	while i < n:
		if text.substr(i, dlen) == delim:
			# Make sure the run is EXACTLY dlen (not longer). Longer runs
			# belong to a different emphasis level.
			var run_end: int = i
			while run_end < n and text.substr(run_end, 1) == "*":
				run_end += 1
			if run_end - i == dlen and i > from and text.substr(i - 1, 1) != " ":
				return i
			i = run_end
			continue
		i += 1
	return -1


static func _find_single_delim_close(text: String, from: int, delim: String) -> int:
	# Single-character delimiter (italic). Must not be preceded by whitespace
	# and must not be part of a `**` run (which bold already handled).
	if from >= text.length():
		return -1
	if text.substr(from, 1) == " ":
		return -1
	var i: int = from
	var n: int = text.length()
	while i < n:
		if text.substr(i, 1) == delim:
			if i > from and text.substr(i - 1, 1) != " ":
				if delim == "*" and i + 1 < n and text.substr(i + 1, 1) == "*":
					i += 2
					continue
				return i
		i += 1
	return -1


static func _try_match_link(text: String, from: int) -> Dictionary:
	var n: int = text.length()
	if from >= n or text.substr(from, 1) != "[":
		return {}
	var bracket_end: int = -1
	var k: int = from + 1
	while k < n:
		var c: String = text.substr(k, 1)
		if c == "]":
			bracket_end = k
			break
		if c == "[":
			return {}
		k += 1
	if bracket_end < 0 or bracket_end + 1 >= n:
		return {}
	if text.substr(bracket_end + 1, 1) != "(":
		return {}
	var paren_end: int = -1
	k = bracket_end + 2
	while k < n:
		var c2: String = text.substr(k, 1)
		if c2 == ")":
			paren_end = k
			break
		if c2 == "(":
			return {}
		k += 1
	if paren_end < 0:
		return {}
	var label: String = text.substr(from + 1, bracket_end - (from + 1))
	var href: String = text.substr(bracket_end + 2, paren_end - (bracket_end + 2)).strip_edges()
	if label.is_empty() or href.is_empty():
		return {}
	return {"text": label, "href": href, "end": paren_end + 1}
