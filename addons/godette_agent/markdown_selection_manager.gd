@tool
class_name GodetteMarkdownSelection
extends Node
#
# Cross-block selection coordinator for a single markdown-rendered
# assistant message. Zed / VSCode get this for free because their
# markdown lives in one text buffer underneath; we render each block as
# its own TextBlock, so selection across them has to be stitched by a
# manager that owns the global state and fans partial selections back
# into each block.
#
# Scope deliberately capped:
# - Selection is constrained to one `root` VBoxContainer. Cross-message
#   selection is out (see roadmap).
# - Virtualisation doesn't bite here because the whole root is a single
#   entry control — when the entry scrolls off and the control is freed,
#   the manager goes with it and its selection state with it. That's
#   acceptable: the alternative (persisting selection across
#   materialisations) would require an entry-index + block-path model
#   we don't have yet.
# - Single-selection only. No multi-cursor.
# - Shift-click / double-click / triple-click still stay inside the
#   originating block and don't participate in multi-block selection
#   (they come in as a `selection_drag_started` anyway, so the manager
#   resets its anchor to match and any later drag extends normally).
#
# Lifecycle:
#   agent_dock's markdown renderer instantiates one manager per message,
#   adds it as a hidden child of the root VBox, then calls
#   `register_block(tb)` on every TextBlock it creates in that tree.
#   The manager subscribes to each block's `selection_drag_started` and
#   watches `_input` for motion + button-release + keyboard during an
#   active drag. When the root VBox is freed, the manager goes with it.


const _SCROLL_AUTOSTEP_PX := 14.0


var _blocks: Array = []  # Array[GodetteTextBlock] in document order.
# Parallel array, same length as _blocks. Each entry is either null (use
# the TextBlock itself as the hit area) or a Control somewhere in its
# ancestor chain that represents the full clickable area for the drag
# search. Table cells need this: the TextBlock inside a cell uses
# SIZE_SHRINK_CENTER so short cells stay centred, which leaves
# whitespace padding above / below the TextBlock that visually belongs
# to the cell but isn't inside the TextBlock's own rect. Without a
# hit_area override, a drag passing through that padding would skip
# the cell entirely.
var _hit_areas: Array = []
var _anchor_block = null  # weakly-typed: GodetteTextBlock | null
var _anchor_char: int = -1
var _focus_block = null
var _focus_char: int = -1
var _dragging: bool = false


func register_block(block: Node, hit_area: Node = null) -> void:
	# Called once per block the markdown renderer emits. Order of
	# registration is the document order — that's the order the renderer
	# walks events in, so `_blocks.find(block)` ordering is valid for
	# "is A above or below B" comparisons without a second sort.
	#
	# `hit_area` is optional and overrides the rect used during drag hit
	# testing. Pass the containing cell/row Control when the TextBlock's
	# own rect doesn't cover everything the user perceives as "this
	# block" (notably: SHRINK_CENTER cells inside table grids).
	if block == null or not is_instance_valid(block):
		return
	if _blocks.has(block):
		return
	_blocks.append(block)
	_hit_areas.append(hit_area)
	block.register_selection_manager(self)
	if not block.selection_drag_started.is_connected(_on_block_drag_started):
		block.selection_drag_started.connect(_on_block_drag_started.bind(block))
	if not block.tree_exiting.is_connected(_on_block_tree_exiting):
		block.tree_exiting.connect(_on_block_tree_exiting.bind(block))


func _on_block_tree_exiting(block: Node) -> void:
	# Block is being freed (e.g. the root was swapped by _update_entry_in_feed).
	# Drop it so we don't hold a dangling reference the next time
	# _apply_selection iterates.
	var idx: int = _blocks.find(block)
	if idx >= 0:
		_blocks.remove_at(idx)
		_hit_areas.remove_at(idx)
	if _anchor_block == block:
		_anchor_block = null
	if _focus_block == block:
		_focus_block = null


func _hit_rect_for_index(idx: int) -> Rect2:
	# Returns the rect used for mouse hit-testing the block at `idx`.
	# Defaults to the block's own rect; overridden by a hit_area control
	# when the block's visual "clickable area" is larger than its
	# TextBlock rect (table cells with SHRINK_CENTER centering).
	var block = _blocks[idx]
	var hit_area = _hit_areas[idx]
	var target: Node = hit_area if hit_area != null and is_instance_valid(hit_area) else block
	if target == null or not is_instance_valid(target):
		return Rect2()
	return Rect2(target.global_position, target.size)


func _on_block_drag_started(char_pos: int, block: Node) -> void:
	# User mouse-down landed on this block. Reset every other block's
	# selection and plant the anchor here; motion events arrive via
	# `_input` until the button comes up.
	for b in _blocks:
		if b != block and is_instance_valid(b):
			b.clear_selection_silent()
	_anchor_block = block
	_focus_block = block
	_dragging = true
	# If the block ALREADY has a selection at this point it means the press
	# was a double/triple click — the TextBlock ran word/line select
	# locally, then emitted the signal so we'd sync our anchor. Preserve
	# that range: take its endpoints as the anchor/focus so subsequent
	# drag extends from the nearest edge of the selected word instead of
	# collapsing to the click char.
	if is_instance_valid(block) and block.has_selection():
		var sel_a: int = block.get_selection_anchor()
		var sel_c: int = block.get_selection_caret()
		_anchor_char = sel_a
		_focus_char = sel_c
	else:
		_anchor_char = char_pos
		_focus_char = char_pos
		# Paint the anchor caret immediately so a click-without-drag shows the
		# caret location rather than looking like nothing happened.
		if is_instance_valid(block):
			block.select_range(char_pos, char_pos)


func _input(event: InputEvent) -> void:
	# Ctrl+C copies the current selection regardless of drag state. Esc
	# clears. Both are handled even when we're not actively dragging —
	# the user expects the post-release selection to respond to these.
	if event is InputEventKey:
		var key_event: InputEventKey = event
		if not key_event.pressed or key_event.echo:
			return
		if key_event.keycode == KEY_ESCAPE:
			if _has_selection():
				clear_selection()
				get_viewport().set_input_as_handled()
			return
		if key_event.keycode == KEY_C and (key_event.ctrl_pressed or key_event.meta_pressed):
			var text: String = get_selected_text()
			if not text.is_empty():
				DisplayServer.clipboard_set(text)
				get_viewport().set_input_as_handled()
			return
		return

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			# A mouse-down outside every block we own releases our
			# selection. One dock can host several of these managers
			# (one per assistant message), and they don't know about
			# each other — so when the user clicks into message B,
			# message A's manager needs to notice "that wasn't on any
			# of mine" and drop its highlight. Without this check the
			# old selection stays painted until something else clears
			# it (Esc, a drag that starts on one of our own blocks).
			#
			# Skipped while we're dragging: mid-drag button events can
			# fire due to auto-repeat / device quirks, and clearing
			# the anchor mid-gesture would obviously break the drag.
			if _dragging:
				return
			if _has_selection() and not _click_hits_any_registered_block(mb.global_position):
				clear_selection()
			return
		# Release
		if _dragging:
			_dragging = false
			# Don't clear selection on release — user may want to copy.
		return

	if not _dragging:
		return

	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		_update_drag_focus(motion.global_position)
		return


func _click_hits_any_registered_block(global_pos: Vector2) -> bool:
	# Uses the same hit_area logic as drag focus (so list item / table
	# cell padding counts as "on the block"). Cheap linear scan — block
	# counts per message sit in the low dozens even for long replies.
	for i in range(_blocks.size()):
		var b = _blocks[i]
		if not is_instance_valid(b):
			continue
		var rect: Rect2 = _hit_rect_for_index(i)
		if rect.size.y <= 0:
			continue
		if rect.has_point(global_pos):
			return true
	return false


func _update_drag_focus(global_pos: Vector2) -> void:
	if _blocks.is_empty():
		return

	# Vertical-only matching. VBox children stack top-down; x-axis doesn't
	# determine which block owns the pointer. Using `rect.has_point` was
	# the old bug: when the cursor landed in the horizontal margin a list
	# item adds on its left (indent column) or above/below a paragraph in
	# the separation gap, NO block's rect contained the point and we
	# clamped to "last block" — which flashed the selection to the end of
	# the message every time the user dragged through a separator. Result
	# was both the flicker and the "middle blocks aren't selected" gap
	# (the clamp ran in between two real hit frames and the subsequent
	# apply cleared the blocks it had just selected).
	var target = null
	var target_char_override: int = -1
	for i in range(_blocks.size()):
		var b = _blocks[i]
		if not is_instance_valid(b):
			continue
		var rect: Rect2 = _hit_rect_for_index(i)
		if rect.size.y <= 0:
			continue
		if global_pos.y >= rect.position.y and global_pos.y < rect.position.y + rect.size.y:
			# Also require x to overlap — matters for grid layouts where
			# multiple cells occupy the same y range. Without the x
			# check, every cell at that y matches and the first-
			# registered (leftmost column) always wins, which is why the
			# drag failed to "enter" the middle / right columns of a
			# table.
			if global_pos.x >= rect.position.x and global_pos.x < rect.position.x + rect.size.x:
				target = b
				break

	if target == null:
		# Cursor between two blocks (or in a gap the hit_area doesn't
		# cover — horizontal margins, inter-paragraph separation, etc.).
		# Find the nearest valid block by vertical distance and snap to
		# its top/bottom edge depending on which side the cursor is on.
		var best_dist: float = INF
		var best_above: bool = false
		for i in range(_blocks.size()):
			var b = _blocks[i]
			if not is_instance_valid(b):
				continue
			var rect: Rect2 = _hit_rect_for_index(i)
			if rect.size.y <= 0:
				continue
			var top: float = rect.position.y
			var bottom: float = top + rect.size.y
			var dist: float
			var above: bool
			if global_pos.y < top:
				dist = top - global_pos.y
				above = true
			elif global_pos.y >= bottom:
				dist = global_pos.y - bottom
				above = false
			else:
				# Y is in range but x wasn't — treat as "in this block's
				# row", clamp char based on x side.
				dist = 0.0
				above = global_pos.x < rect.position.x
			if dist < best_dist:
				best_dist = dist
				target = b
				best_above = above
		if target == null:
			return
		if best_above:
			target_char_override = 0
		else:
			target_char_override = target.get_text().length()

	if target_char_override >= 0:
		_focus_char = target_char_override
	else:
		var local: Vector2 = global_pos - target.global_position
		_focus_char = target.hit_test_char(local)

	_focus_block = target
	_apply_selection()


func _apply_selection() -> void:
	if _anchor_block == null or _focus_block == null:
		return
	if not is_instance_valid(_anchor_block) or not is_instance_valid(_focus_block):
		return

	var anchor_idx: int = _blocks.find(_anchor_block)
	var focus_idx: int = _blocks.find(_focus_block)
	if anchor_idx < 0 or focus_idx < 0:
		return

	# Resolve the forward (top-down) edges of the selection: the direction
	# is anchor→focus by default, but if the user dragged UP the focus is
	# above the anchor and we flip.
	var forward: bool = (
		focus_idx > anchor_idx
		or (focus_idx == anchor_idx and _focus_char >= _anchor_char)
	)
	var start_block = _anchor_block if forward else _focus_block
	var start_char: int = _anchor_char if forward else _focus_char
	var end_block = _focus_block if forward else _anchor_block
	var end_char: int = _focus_char if forward else _anchor_char
	var start_idx: int = _blocks.find(start_block)
	var end_idx: int = _blocks.find(end_block)

	for i in range(_blocks.size()):
		var b = _blocks[i]
		if not is_instance_valid(b):
			continue
		if i < start_idx or i > end_idx:
			b.clear_selection_silent()
		elif i == start_idx and i == end_idx:
			b.select_range(start_char, end_char)
		elif i == start_idx:
			b.select_from_char(start_char)
		elif i == end_idx:
			b.select_to_char(end_char)
		else:
			b.select_all()


func get_selected_text() -> String:
	# Concatenate each block's selected substring top-down, joined by
	# newlines so the clipboard output reads as "paragraph 1\nparagraph 2"
	# rather than one run-on string.
	if not _has_selection():
		return ""
	var parts := PackedStringArray()
	for b in _blocks:
		if not is_instance_valid(b):
			continue
		var chunk: String = b.get_selected_text()
		if not chunk.is_empty():
			parts.append(chunk)
	return "\n".join(parts)


func clear_selection() -> void:
	for b in _blocks:
		if is_instance_valid(b):
			b.clear_selection_silent()
	_anchor_block = null
	_focus_block = null
	_anchor_char = -1
	_focus_char = -1
	_dragging = false


func _has_selection() -> bool:
	for b in _blocks:
		if is_instance_valid(b) and b.has_selection():
			return true
	return false


func _first_valid_block():
	for b in _blocks:
		if is_instance_valid(b):
			return b
	return null


func _last_valid_block():
	for i in range(_blocks.size() - 1, -1, -1):
		if is_instance_valid(_blocks[i]):
			return _blocks[i]
	return null
