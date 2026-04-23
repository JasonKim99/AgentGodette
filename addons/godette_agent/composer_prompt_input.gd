@tool
class_name GodetteComposerPromptInput
extends TextEdit
#
# Chip-aware TextEdit. Attachments appear INLINE with text like in Zed: each
# chip occupies a run of characters that the caret treats as a single glyph,
# backspace/delete eats the whole run, arrows skip over its interior, and
# typing inside it falls out of the padding onto the right edge.
#
# Representation
# --------------
# A chip is encoded in the text buffer as:
#
#     <ANCHOR_CP><PAD_CHAR>*pad_count
#
# ANCHOR_CP is a unique codepoint drawn from the private-use range
# [U+E000, U+E7FF]. Each chip gets its own codepoint — that's the chip's
# identity in the buffer, so cut+paste doesn't require a sidecar mapping.
# PAD_CHAR is U+00A0 (non-breaking space); NBSP keeps the run from wrapping
# apart, and user keystrokes essentially never produce NBSPs by accident so
# we can treat the padding block as ours.
#
# The overlay (see composer_chip_overlay.gd) paints the chip panel on top of
# the anchor+padding run so the reserved width is filled with the chip's
# icon + label. Pad count is computed from the actual chip pixel width and
# the font's NBSP advance so the overlay exactly covers the run.
#
# Reconciliation
# --------------
# Text is the source of truth for chip PRESENCE and ORDER; the chip metadata
# dictionary is the source of truth for DISPLAY. On every text_changed we:
#   1. Scan anchors in text order.
#   2. Any anchor without metadata is an orphan (stale paste from elsewhere)
#      — strip it from the text.
#   3. Any metadata codepoint no longer in text means the user deleted the
#      chip — drop the metadata and emit chips_changed.
#   4. Re-canonicalize padding (force exactly pad_count NBSPs after each
#      anchor) so selections that clipped padding can't leave the run
#      visually truncated.
#
# All internal mutations set `_mutating_internally = true` so the reconcile
# pass doesn't mis-read our own writes.

signal image_pasted(image: Image)
signal submit_requested
# Fires when the set or order of chips in the text buffer changes (user
# delete, paste, canonicalize). Carries the ordered list of chip keys so
# the dock can reorder its session attachments to match.
signal chips_changed(ordered_keys: Array)

# Names avoid ANCHOR_BASE / ANCHOR_END because the `ANCHOR_*` namespace is
# already occupied by Control's anchor-preset constants that TextEdit
# inherits — GDScript rejects member shadows even when the constants are
# unrelated in intent.
const CHIP_ANCHOR_MIN := 0xE000
const CHIP_ANCHOR_MAX := 0xE7FF
const PAD_CHAR := 0x00A0  # non-breaking space — keeps the run together at wrap
# Zero-width non-joiner prefix in front of the PUA anchor. Without this,
# HarfBuzz clusters the PUA codepoint with the preceding character as a
# single shaping run and drops the preceding glyph during layout — typing
# "123" and inserting a chip made the '3' vanish because the shaper
# merged "3" and the anchor into one cluster rendered at the anchor's
# position. ZWNJ is zero-width (no visual cost) and tells the shaper to
# treat the PUA char as its own cluster.
const SHAPING_BREAK := 0x200C

# Visual geometry of a chip panel. Overlay draws to these dimensions and we
# use the same numbers here to pick a pad count that reserves the right
# width in the text buffer.
const CHIP_ICON_SIZE := 16
const CHIP_ICON_GAP := 4
const CHIP_PAD_LEFT := 8
const CHIP_PAD_RIGHT := 8
const CHIP_MAX_LABEL_WIDTH := 180.0

# Each entry:
#   { key: String, kind: String, label: String, tooltip: String,
#     icon: Texture2D, pad_count: int, width_px: float }
var _chip_by_codepoint: Dictionary = {}
var _key_to_codepoint: Dictionary = {}
var _next_anchor_offset := 0

# Reconcile re-entrancy guard: internal mutations fire text_changed, and
# the reconcile handler mutates text again. Without this flag the handler
# would run on its own writes and possibly loop.
var _mutating_internally := false
# caret_changed fires while we snap the caret out of a run; re-entering
# the snap handler would livelock.
var _snapping_caret := false


func _ready() -> void:
	text_changed.connect(_on_text_changed_reconcile)
	caret_changed.connect(_on_caret_changed_snap)


# --- Public: chip lifecycle ------------------------------------------------
#
# The dock owns attachment metadata (`sessions[i].attachments`) and drives
# lifecycle from there. These methods are the hooks it uses to mirror that
# state into the text buffer.

# Inserts a chip at the current caret position and returns its codepoint
# (or -1 if allocation failed). `key` must be unique; inserting a chip with
# a key already present is a no-op. `payload` carries the raw attachment
# fields (path, scene_path, relative_node_path, summary, …) so hover
# tooltips can render previews without the overlay having to reach back
# into the session.
func insert_chip(key: String, kind: String, label: String, icon: Texture2D, tooltip: String, payload: Dictionary = {}) -> int:
	if key.is_empty():
		return -1
	if _key_to_codepoint.has(key):
		return _key_to_codepoint[key]

	var codepoint := _allocate_codepoint()
	if codepoint < 0:
		push_warning("GodetteComposerPromptInput: chip codepoint space exhausted")
		return -1

	var display_label := _clip_label(label)
	var width_px := _chip_display_width(display_label, icon)
	var pad_count := _compute_pad_count(width_px)

	var chip := {
		"key": key,
		"kind": kind,
		"label": display_label,
		"tooltip": tooltip,
		"icon": icon,
		"pad_count": pad_count,
		"width_px": width_px,
		"payload": payload.duplicate(),
	}
	_chip_by_codepoint[codepoint] = chip
	_key_to_codepoint[key] = codepoint

	# ZWNJ + anchor + padding. The ZWNJ prefix is the fix for a shaping
	# bug: HarfBuzz clusters the PUA anchor with the preceding character
	# and renders the cluster at the anchor's position, which makes the
	# preceding character vanish visually. ZWNJ tells the shaper to treat
	# the anchor as its own cluster so the preceding glyph stays put.
	var run_text := String.chr(SHAPING_BREAK) + String.chr(codepoint) + String.chr(PAD_CHAR).repeat(pad_count)
	var insert_line := get_caret_line()
	var insert_col := get_caret_column()
	_mutating_internally = true
	if has_selection():
		deselect()
	insert_text(run_text, insert_line, insert_col)
	set_caret_line(insert_line)
	set_caret_column(insert_col + run_text.length())
	_mutating_internally = false
	_notify_chips_changed()
	queue_redraw()
	return codepoint


# Removes the chip identified by `key` from both the text buffer and the
# metadata. Silently no-ops if no such chip exists (defensive — the overlay
# can double-fire remove if the user clicks fast).
func remove_chip_by_key(key: String) -> void:
	if not _key_to_codepoint.has(key):
		return
	var cp: int = _key_to_codepoint[key]
	var loc := _find_run(cp)
	_mutating_internally = true
	if not loc.is_empty():
		select(loc.line, loc.start, loc.line, loc.end)
		delete_selection()
	_chip_by_codepoint.erase(cp)
	_key_to_codepoint.erase(key)
	_mutating_internally = false
	_notify_chips_changed()
	queue_redraw()


# Wipe everything: used on session switch so the fresh session starts with
# an empty composer regardless of what the outgoing session left behind.
func clear_all() -> void:
	_mutating_internally = true
	text = ""
	_chip_by_codepoint.clear()
	_key_to_codepoint.clear()
	_mutating_internally = false
	_notify_chips_changed()
	queue_redraw()


# Strip every chip run but leave the user's typed text in place. Invoked by
# the dock's clear-context action so the user's draft sentence survives
# even when every attachment is being detached at once.
func remove_all_chips() -> void:
	if _chip_by_codepoint.is_empty():
		return
	_mutating_internally = true
	text = _strip_chip_runs(text)
	_chip_by_codepoint.clear()
	_key_to_codepoint.clear()
	_mutating_internally = false
	_notify_chips_changed()
	queue_redraw()


# Inverse of `remove_all_chips`: wipe everything that ISN'T a chip run,
# keeping chips in their current order at the top of the buffer. This is
# what `_send_prompt` calls after handing the text to the adapter, so the
# attachment context pins for the next turn without forcing the user to
# re-pick them.
func clear_text_keep_chips() -> void:
	var keys := get_chip_keys_in_order()
	_mutating_internally = true
	var rebuilt := ""
	for key in keys:
		if not _key_to_codepoint.has(key):
			continue
		var cp: int = _key_to_codepoint[key]
		var chip: Dictionary = _chip_by_codepoint[cp]
		rebuilt += String.chr(SHAPING_BREAK) + String.chr(cp) + String.chr(PAD_CHAR).repeat(int(chip.get("pad_count", 0)))
	text = rebuilt
	_mutating_internally = false
	var last_line := max(0, get_line_count() - 1)
	set_caret_line(last_line)
	set_caret_column(get_line(last_line).length())
	_notify_chips_changed()
	queue_redraw()


# Ordered list of chip keys as they currently appear in the text.
func get_chip_keys_in_order() -> Array:
	var keys: Array = []
	var s := text
	var i := 0
	while i < s.length():
		var c := s.unicode_at(i)
		if c >= CHIP_ANCHOR_MIN and c <= CHIP_ANCHOR_MAX and _chip_by_codepoint.has(c):
			keys.append(str(_chip_by_codepoint[c]["key"]))
		i += 1
	return keys


# Text with all chip runs stripped. This is what gets sent as the prompt
# body — the attachments flow through as structured blocks built by the
# dock from its session.attachments array.
func get_plain_text() -> String:
	return _strip_chip_runs(text)


# Ordered list of serializable segments matching Zed's segmented user-
# message model: text runs and chip references interleaved in the exact
# visual order they appear in the composer. The dock stores this on the
# user transcript entry so the sent-message bubble can reproduce the
# inline chip layout from the composer.
#
# Output entries:
#   {"type": "text", "text": String}
#   {"type": "chip", "key": String, "kind": String, "label": String,
#    "tooltip": String, "payload": Dictionary}
#
# Texture2D icon is not included — it's re-resolved at render time from
# (kind, path) via the dock's _attachment_icon, so transcripts round-
# trip through session_store as pure JSON.
func get_segments() -> Array:
	var segments: Array = []
	var text_buf := ""
	var s := text
	var i := 0
	var length := s.length()
	while i < length:
		var c := s.unicode_at(i)
		if c >= CHIP_ANCHOR_MIN and c <= CHIP_ANCHOR_MAX and _chip_by_codepoint.has(c):
			# The ZWNJ prefix that sits just before the anchor belongs to
			# the chip run, not the preceding text. Peel it back off the
			# text buffer before we flush so typed text doesn't drag a
			# stray zero-width char with it.
			if not text_buf.is_empty() and text_buf.unicode_at(text_buf.length() - 1) == SHAPING_BREAK:
				text_buf = text_buf.substr(0, text_buf.length() - 1)
			if not text_buf.is_empty():
				segments.append({"type": "text", "text": text_buf})
				text_buf = ""
			var chip: Dictionary = _chip_by_codepoint[c]
			var payload_variant = chip.get("payload", {})
			var payload: Dictionary = payload_variant if typeof(payload_variant) == TYPE_DICTIONARY else {}
			segments.append({
				"type": "chip",
				"key": str(chip.get("key", "")),
				"kind": str(chip.get("kind", "")),
				"label": str(chip.get("label", "")),
				"tooltip": str(chip.get("tooltip", "")),
				"payload": payload.duplicate(),
			})
			i += 1
			var pad_count := int(chip.get("pad_count", 0))
			var consumed := 0
			while i < length and consumed < pad_count and s.unicode_at(i) == PAD_CHAR:
				i += 1
				consumed += 1
			continue
		text_buf += s.substr(i, 1)
		i += 1
	if not text_buf.is_empty():
		segments.append({"type": "text", "text": text_buf})
	return segments


# Metadata snapshot for a chip, used by the overlay when it repaints. Empty
# dict if the codepoint is unknown.
func get_chip_meta(codepoint: int) -> Dictionary:
	return _chip_by_codepoint.get(codepoint, {})


# Iterator-style access so the overlay doesn't poke our private dict.
func get_chip_codepoints() -> Array:
	return _chip_by_codepoint.keys()


# Ordered list of chip run infos for the overlay to paint and hit-test
# against. Each entry carries enough to build the run's screen rect:
#
#     { line: int, start: int, end: int, codepoint: int, meta: Dictionary }
#
# `meta` is the same dictionary stored internally — overlay must treat it
# as read-only. Order matches visual order in the text buffer.
func get_chip_runs() -> Array:
	var out: Array = []
	var lines_count := get_line_count()
	for line in range(lines_count):
		for run in _runs_on_line(line):
			var meta: Dictionary = _chip_by_codepoint.get(run.codepoint, {})
			if meta.is_empty():
				continue
			out.append({
				"line": line,
				"start": run.start,
				"anchor": run.anchor,
				"end": run.end,
				"codepoint": run.codepoint,
				"meta": meta,
			})
	return out


# Per-session draft persistence. `serialize_draft` captures just enough to
# round-trip the composer state (text buffer + codepoint→key mapping); the
# attachment metadata itself comes from session.attachments on restore.
func serialize_draft() -> Dictionary:
	var bindings: Array = []
	for cp in _chip_by_codepoint.keys():
		var chip: Dictionary = _chip_by_codepoint[cp]
		bindings.append({
			"codepoint": int(cp),
			"key": str(chip.get("key", "")),
			"pad_count": int(chip.get("pad_count", 0)),
		})
	return {"text": text, "bindings": bindings}


# Restore a previously serialized draft. `metadata_lookup` maps chip key →
# {kind, label, tooltip, icon} so the dock can source the display bits
# from its session.attachments without this module storing them.
func restore_draft(draft: Dictionary, metadata_lookup: Dictionary) -> void:
	_mutating_internally = true
	_chip_by_codepoint.clear()
	_key_to_codepoint.clear()

	var bindings_variant = draft.get("bindings", [])
	if bindings_variant is Array:
		for binding_variant in bindings_variant:
			if typeof(binding_variant) != TYPE_DICTIONARY:
				continue
			var binding: Dictionary = binding_variant
			var cp := int(binding.get("codepoint", -1))
			var key := str(binding.get("key", ""))
			if cp < CHIP_ANCHOR_MIN or cp > CHIP_ANCHOR_MAX or key.is_empty():
				continue
			var meta_variant = metadata_lookup.get(key, {})
			if typeof(meta_variant) != TYPE_DICTIONARY:
				continue
			var meta: Dictionary = meta_variant
			var display_label := _clip_label(str(meta.get("label", "")))
			var icon: Texture2D = meta.get("icon", null)
			var width_px := _chip_display_width(display_label, icon)
			var payload_variant = meta.get("payload", {})
			var payload: Dictionary = payload_variant if typeof(payload_variant) == TYPE_DICTIONARY else {}
			_chip_by_codepoint[cp] = {
				"key": key,
				"kind": str(meta.get("kind", "")),
				"label": display_label,
				"tooltip": str(meta.get("tooltip", "")),
				"icon": icon,
				"pad_count": int(binding.get("pad_count", _compute_pad_count(width_px))),
				"width_px": width_px,
				"payload": payload.duplicate(),
			}
			_key_to_codepoint[key] = cp

	text = str(draft.get("text", ""))
	_mutating_internally = false
	# Strip anchors without metadata, fix padding that drifted vs stored
	# pad_count (font may have changed). Reconcile handles both.
	_reconcile_now()
	_notify_chips_changed()
	queue_redraw()


# --- Input interception ----------------------------------------------------

# `_input` fires before the control's own `_gui_input`. We use it for the
# two global precedence cases (image paste, Enter submit) matching the old
# behaviour, plus the chip-atomic key intercepts.
func _input(event: InputEvent) -> void:
	if not has_focus():
		return
	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event
	if not key_event.pressed or key_event.echo:
		return

	# Enter → submit unless modified. Shift/Alt+Enter still newline-through
	# to TextEdit for multi-line prompts. Ctrl+Enter also submits (common
	# alternate binding elsewhere).
	if key_event.keycode == KEY_ENTER or key_event.keycode == KEY_KP_ENTER:
		if key_event.shift_pressed or key_event.alt_pressed:
			return
		emit_signal("submit_requested")
		get_viewport().set_input_as_handled()
		return

	# Image paste: when the clipboard holds an image (screenshots, copied
	# rasters), intercept Ctrl+V before TextEdit's native paste runs so the
	# image doesn't stringify into the buffer.
	if (key_event.ctrl_pressed or key_event.meta_pressed) and key_event.keycode == KEY_V:
		if DisplayServer.clipboard_has_image():
			var image: Image = DisplayServer.clipboard_get_image()
			if image != null and not image.is_empty():
				emit_signal("image_pasted", image)
				get_viewport().set_input_as_handled()
				return

	# Chip-atomic keys: backspace / delete over run edges, arrows skipping
	# run interiors, typing that would land inside padding.
	if _handle_chip_aware_key(key_event):
		get_viewport().set_input_as_handled()


func _handle_chip_aware_key(key_event: InputEventKey) -> bool:
	# Only intercept keys that need chip-atomic semantics. Typed characters
	# flow straight through to TextEdit — `_snap_caret_out_of_run` guarantees
	# the caret never sits inside a run interior, so typing always lands at
	# a safe column without pre-intervention.
	match key_event.keycode:
		KEY_BACKSPACE:
			return _try_delete_run_before_caret()
		KEY_DELETE:
			return _try_delete_run_after_caret()
		KEY_LEFT:
			if key_event.shift_pressed:
				return false  # let TextEdit extend selection; reconcile fixes state
			return _try_skip_run_left()
		KEY_RIGHT:
			if key_event.shift_pressed:
				return false
			return _try_skip_run_right()
	return false


func _try_delete_run_before_caret() -> bool:
	if has_selection():
		return false  # TextEdit will delete the selection; reconcile picks it up
	var line := get_caret_line()
	var col := get_caret_column()
	for run in _runs_on_line(line):
		var run_start: int = int(run.start)
		var run_end: int = int(run.end)
		var run_cp: int = int(run.codepoint)
		if col == run_end:
			_delete_run_at(line, run_start, run_end, run_cp)
			return true
	return false


func _try_delete_run_after_caret() -> bool:
	if has_selection():
		return false
	var line := get_caret_line()
	var col := get_caret_column()
	for run in _runs_on_line(line):
		var run_start: int = int(run.start)
		var run_end: int = int(run.end)
		var run_cp: int = int(run.codepoint)
		if col == run_start:
			_delete_run_at(line, run_start, run_end, run_cp)
			return true
	return false


func _try_skip_run_left() -> bool:
	var line := get_caret_line()
	var col := get_caret_column()
	for run in _runs_on_line(line):
		var run_start: int = int(run.start)
		var run_end: int = int(run.end)
		# Caret sitting just past the right edge of a run: a single left
		# arrow would drop it into the padding interior; jump to the
		# pre-run position instead so the chip feels like one glyph.
		if col == run_end:
			set_caret_column(run_start)
			return true
		# Safety for any caret that's already in the interior (shouldn't
		# happen after snap, but be defensive).
		if col > run_start and col < run_end:
			set_caret_column(run_start)
			return true
	return false


func _try_skip_run_right() -> bool:
	var line := get_caret_line()
	var col := get_caret_column()
	for run in _runs_on_line(line):
		var run_start: int = int(run.start)
		var run_end: int = int(run.end)
		if col == run_start:
			set_caret_column(run_end)
			return true
		if col > run_start and col < run_end:
			set_caret_column(run_end)
			return true
	return false


func _delete_run_at(line: int, start: int, run_end: int, cp: int) -> void:
	_mutating_internally = true
	select(line, start, line, run_end)
	delete_selection()
	_mutating_internally = false
	var removed_key := str(_chip_by_codepoint.get(cp, {}).get("key", ""))
	_chip_by_codepoint.erase(cp)
	if not removed_key.is_empty():
		_key_to_codepoint.erase(removed_key)
	_notify_chips_changed()
	queue_redraw()


# --- Reconcile -------------------------------------------------------------

func _on_text_changed_reconcile() -> void:
	if _mutating_internally:
		return
	_reconcile_now()


# Rebuilds the text buffer into canonical form: orphan anchors stripped,
# duplicate anchors de-duped, padding count brought back to metadata's
# pad_count. Also prunes metadata for chips the user deleted.
func _reconcile_now() -> void:
	var s := text
	var codepoints_in_text: Dictionary = {}
	var rewrote := false
	var out := ""
	var i := 0
	var length := s.length()

	while i < length:
		var c := s.unicode_at(i)
		if c >= CHIP_ANCHOR_MIN and c <= CHIP_ANCHOR_MAX:
			# Skip any anchor we can't bind (orphan / duplicate from paste).
			if not _chip_by_codepoint.has(c) or codepoints_in_text.has(c):
				rewrote = true
				# Back out a ZWNJ prefix we may have already copied — it
				# belonged to this now-stripped orphan run.
				if not out.is_empty() and out.unicode_at(out.length() - 1) == SHAPING_BREAK:
					out = out.substr(0, out.length() - 1)
				i += 1
				# Also eat any NBSPs that were tagging along with the
				# orphan so the user doesn't see ghost whitespace.
				while i < length and s.unicode_at(i) == PAD_CHAR:
					i += 1
				continue
			codepoints_in_text[c] = true
			var pad_count := int(_chip_by_codepoint[c]["pad_count"])
			# Ensure the ZWNJ prefix is present in the canonical form.
			# If the source didn't have it (shouldn't normally happen, but
			# defensive against pastes from elsewhere), add it here and
			# flag rewrote so the buffer is fixed up.
			if out.is_empty() or out.unicode_at(out.length() - 1) != SHAPING_BREAK:
				out += String.chr(SHAPING_BREAK)
				rewrote = true
			out += String.chr(c)
			out += String.chr(PAD_CHAR).repeat(pad_count)
			# Walk past the current run's NBSPs in source, regardless of
			# their count — we just replaced with exactly pad_count NBSPs.
			var j := i + 1
			var consumed := 0
			while j < length and consumed < pad_count and s.unicode_at(j) == PAD_CHAR:
				j += 1
				consumed += 1
			if consumed != pad_count:
				rewrote = true
			# If the source had MORE NBSPs than pad_count, leave the excess
			# — they're user-typed whitespace at the seam and shouldn't
			# evaporate. The fact that NBSPs are essentially untypable by
			# hand means this branch is almost always a no-op in practice.
			i = j
			continue
		out += s.substr(i, 1)
		i += 1

	# Prune metadata the user deleted (anchor no longer in text).
	var removed_keys: Array = []
	for cp_variant in _chip_by_codepoint.keys():
		var cp := int(cp_variant)
		if not codepoints_in_text.has(cp):
			removed_keys.append(str(_chip_by_codepoint[cp].get("key", "")))
			_chip_by_codepoint.erase(cp)
	for removed_key in removed_keys:
		if not removed_key.is_empty():
			_key_to_codepoint.erase(removed_key)

	if rewrote:
		# Preserve caret by clamping to post-rewrite buffer; simpler than
		# remapping through the edit. Users who hit this branch are
		# typically recovering from a selection-delete where caret
		# placement is already "wherever it landed", not a precise spot.
		var prior_line := get_caret_line()
		var prior_col := get_caret_column()
		_mutating_internally = true
		text = out
		_mutating_internally = false
		_clamp_caret(prior_line, prior_col)

	if not removed_keys.is_empty() or rewrote:
		_notify_chips_changed()
		queue_redraw()


func _clamp_caret(line: int, column: int) -> void:
	var target_line := clamp(line, 0, max(0, get_line_count() - 1))
	var line_len := get_line(target_line).length()
	var target_col := clamp(column, 0, line_len)
	set_caret_line(target_line)
	set_caret_column(target_col)
	_snap_caret_out_of_run()


# --- Caret snap ------------------------------------------------------------

func _on_caret_changed_snap() -> void:
	if _mutating_internally or _snapping_caret:
		return
	_snap_caret_out_of_run()


func _snap_caret_out_of_run() -> void:
	var line := get_caret_line()
	var col := get_caret_column()
	for run in _runs_on_line(line):
		var run_start: int = int(run.start)
		var run_end: int = int(run.end)
		if col > run_start and col < run_end:
			# Snap to whichever edge is closer so click-in-the-middle
			# feels more like click-on-the-chip than arbitrary repel.
			var mid: int = (run_start + run_end) / 2
			var target_col: int = run_start if col <= mid else run_end
			_snapping_caret = true
			set_caret_column(target_col)
			_snapping_caret = false
			return


# --- Scan helpers ----------------------------------------------------------

func _runs_on_line(line: int) -> Array:
	var runs: Array = []
	if line < 0 or line >= get_line_count():
		return runs
	var line_text := get_line(line)
	var col := 0
	var length := line_text.length()
	while col < length:
		var c := line_text.unicode_at(col)
		if c >= CHIP_ANCHOR_MIN and c <= CHIP_ANCHOR_MAX and _chip_by_codepoint.has(c):
			var pad_count := int(_chip_by_codepoint[c]["pad_count"])
			# Extend run backwards to swallow the ZWNJ prefix (if present)
			# so backspace / delete / arrow-skip treat ZWNJ+anchor+padding
			# as one atomic glyph.
			var text_start := col
			if col > 0 and line_text.unicode_at(col - 1) == SHAPING_BREAK:
				text_start = col - 1
			var run_end := col + 1 + pad_count
			if run_end > length:
				run_end = length
			runs.append({
				"start": text_start,
				"anchor": col,
				"end": run_end,
				"codepoint": c,
			})
			col = run_end
		else:
			col += 1
	return runs


func _find_run(cp: int) -> Dictionary:
	var lines_count := get_line_count()
	for line in range(lines_count):
		var line_text := get_line(line)
		var col := 0
		var length := line_text.length()
		while col < length:
			if line_text.unicode_at(col) == cp:
				var pad_count := int(_chip_by_codepoint.get(cp, {}).get("pad_count", 0))
				var text_start := col
				if col > 0 and line_text.unicode_at(col - 1) == SHAPING_BREAK:
					text_start = col - 1
				var run_end := col + 1 + pad_count
				if run_end > length:
					run_end = length
				return {"line": line, "start": text_start, "anchor": col, "end": run_end}
			col += 1
	return {}


func _strip_chip_runs(s: String) -> String:
	if s.is_empty():
		return s
	var out := ""
	var i := 0
	var length := s.length()
	while i < length:
		var c := s.unicode_at(i)
		if c >= CHIP_ANCHOR_MIN and c <= CHIP_ANCHOR_MAX and _chip_by_codepoint.has(c):
			var pad_count := int(_chip_by_codepoint[c]["pad_count"])
			# Back out the ZWNJ prefix from `out` if we already copied it
			# in a previous iteration — it's part of the chip run, not
			# user text.
			if not out.is_empty() and out.unicode_at(out.length() - 1) == SHAPING_BREAK:
				out = out.substr(0, out.length() - 1)
			i += 1
			var consumed := 0
			while i < length and consumed < pad_count and s.unicode_at(i) == PAD_CHAR:
				i += 1
				consumed += 1
			continue
		out += s.substr(i, 1)
		i += 1
	return out


# --- Font / width measurement ----------------------------------------------

func _font() -> Font:
	var font := get_theme_font("font")
	if font == null:
		# TextEdit sometimes reports null when queried before being added to
		# the tree; default theme fallback keeps measurement sensible.
		font = ThemeDB.fallback_font
	return font


func _font_size() -> int:
	var size := get_theme_font_size("font_size")
	if size <= 0:
		size = ThemeDB.fallback_font_size
	return size


func _measure_text_width(s: String) -> float:
	if s.is_empty():
		return 0.0
	var font := _font()
	if font == null:
		return 0.0
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size()).x


func _chip_display_width(label: String, icon: Texture2D) -> float:
	var label_width := _measure_text_width(label)
	var icon_width := 0.0
	if icon != null:
		icon_width = float(CHIP_ICON_SIZE) + float(CHIP_ICON_GAP)
	return float(CHIP_PAD_LEFT) + icon_width + label_width + float(CHIP_PAD_RIGHT)


func _compute_pad_count(chip_width_px: float) -> int:
	var anchor_advance := _measure_text_width(String.chr(CHIP_ANCHOR_MIN))
	var pad_advance := _measure_text_width(String.chr(PAD_CHAR))
	if pad_advance <= 0.0:
		pad_advance = _measure_text_width(" ")
	if pad_advance <= 0.0:
		return 0
	var remaining := chip_width_px - anchor_advance
	if remaining <= 0.0:
		return 0
	return int(ceil(remaining / pad_advance))


func _clip_label(label: String) -> String:
	# Keep the chip from ballooning when someone attaches a long absolute
	# path. Width-based clip matches what the overlay draws, with a … tail
	# when we had to trim.
	if label.is_empty():
		return label
	if _measure_text_width(label) <= CHIP_MAX_LABEL_WIDTH:
		return label
	var truncated := label
	while truncated.length() > 1 and _measure_text_width(truncated + "…") > CHIP_MAX_LABEL_WIDTH:
		truncated = truncated.substr(0, truncated.length() - 1)
	return truncated + "…"


# --- Misc helpers ----------------------------------------------------------

func _allocate_codepoint() -> int:
	var range_size := CHIP_ANCHOR_MAX - CHIP_ANCHOR_MIN + 1
	for _i in range(range_size):
		var candidate := CHIP_ANCHOR_MIN + _next_anchor_offset
		_next_anchor_offset = (_next_anchor_offset + 1) % range_size
		if not _chip_by_codepoint.has(candidate):
			return candidate
	return -1


func _notify_chips_changed() -> void:
	emit_signal("chips_changed", get_chip_keys_in_order())
