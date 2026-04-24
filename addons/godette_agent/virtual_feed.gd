@tool
class_name GodetteVirtualFeed
extends Control
#
# Virtualized feed container. Replaces VBoxContainer for the transcript feed so
# only entries intersecting the scroll viewport are materialized as Controls.
# Everything else lives as metadata (transcript dict + cached height) and is
# rebuilt via the builder callback when scrolled into view.
#
# Mirrors the spirit of Zed's GPUI List element
# (vendor/zed/crates/gpui/src/elements/list.rs:682-692) without the SumTree —
# for our typical thread sizes a flat cumulative-y array keeps the math simple
# and the constants small. Binary search gives O(log n) visibility queries,
# which is enough.
#
# Contract:
# - The host calls `configure(builder, scroll_container)` once.
# - `set_entries_snapshot(entries)` replaces the data set (e.g. on session
#   switch) and rebuilds visible rows.
# - `append_entry(entry)` and `update_entry(index, entry)` do incremental
#   mutations in O(visible) time.
# - `get_entry_control(index)` returns the Control if it's currently
#   materialized, else null. Callers that want to touch the live Control (e.g.
#   streaming fast-path) should tolerate null.

signal entry_created(entry_index: int, control: Control)
signal entry_freed(entry_index: int, control: Control)

const DEFAULT_ESTIMATED_ROW_HEIGHT := 60.0
const DEFAULT_OVERSCAN_ROWS := 3

var _entries: Array = []
var _heights: PackedFloat32Array = PackedFloat32Array()
var _controls: Dictionary = {}  # entry_index -> Control
var _ordered_y: PackedFloat32Array = PackedFloat32Array()  # cumulative, size = entries + 1
var _ordered_y_dirty: bool = true

var _builder: Callable
var _scroll: ScrollContainer = null
var _scroll_signals_connected: bool = false

var _estimated_row_height: float = DEFAULT_ESTIMATED_ROW_HEIGHT
var _overscan_rows: int = DEFAULT_OVERSCAN_ROWS

var _virtual_height: float = 0.0
var _materialize_pending: bool = false
# Debounce heavy work so a burst of session/update events doesn't do O(n²)
# layout work. All mutations mark the relevant flag; the deferred flush runs
# once per frame.
var _cumulative_y_recompute_pending: bool = false
var _follow_tail_pending: bool = false
# `entry_index -> true` set of rows already queued for `_measure_entry` this
# frame. Without this dedup, a row's `minimum_size_changed` can fire many
# times while wrapping settles (TextBlock reshape, Container resort,
# reposition...), each one re-queueing `_measure_entry`. Measuring the
# same row 5-10× per frame was a real hot spot during long replay bursts.
var _pending_measure: Dictionary = {}
# Track the last width we acted on. NOTIFICATION_RESIZED fires for any
# size change (including pure y changes from children's min_size
# propagating), but only width changes actually require invalidating
# wrap-derived heights. Guarding on width prevents the ScrollContainer
# scrollbar visibility flipping back and forth from sending us into an
# infinite re-measure loop.
var _last_known_width: float = 0.0

# Chat-UI "follow tail" behavior. When true, any change that grows the
# virtual height auto-scrolls the viewport to the bottom. User scrolling up
# turns this off; scrolling back to bottom re-arms it. This is how Zed /
# Messenger-style apps avoid "reading history from top" when opening a long
# session — new entries arriving during session/load replay slide in at the
# bottom and the user always sees the latest state.
var _follow_tail: bool = true
# Last observed scroll position. Used to distinguish "user actively scrolled
# down to the bottom" (value increased to max) from "virtual_height shrunk
# and clamped scroll_vertical to the new max" (value decreased to max).
# The first should re-arm follow_tail; the second should not.
var _last_scroll_value: float = 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	clip_contents = false


func configure(builder: Callable, scroll_container: ScrollContainer) -> void:
	_builder = builder
	if _scroll == scroll_container:
		return
	_disconnect_scroll_signals()
	_scroll = scroll_container
	_connect_scroll_signals()


func set_estimated_row_height(value: float) -> void:
	_estimated_row_height = max(16.0, value)
	_ordered_y_dirty = true
	_schedule_materialize()


func set_entries_snapshot(entries: Array) -> void:
	# Pure data sync: replaces the entry set and resets caches. Scroll
	# position + follow_tail are NOT touched here — they reflect user
	# intent, and `_refresh_chat_log()` gets called in lots of non-switch
	# situations (tool-call disclosure fallback, plan expand fallback,
	# session/load replay completion, etc). Yanking the viewport to the
	# bottom on every such rebuild was the reason mid-scroll users kept
	# getting snapped to the latest message for no apparent reason.
	# Callers that truly want "jump to bottom" (session switch) should
	# follow this with `scroll_to_bottom()` explicitly.
	_destroy_all_controls()
	_entries = entries.duplicate()
	_heights.resize(_entries.size())
	for i in range(_entries.size()):
		_heights[i] = -1.0
	_ordered_y_dirty = true
	_update_virtual_height()
	_schedule_materialize()


func clear_entries() -> void:
	_destroy_all_controls()
	_entries.clear()
	_heights.resize(0)
	_ordered_y.resize(0)
	_ordered_y_dirty = false
	_update_virtual_height()


func append_entry(entry: Dictionary) -> void:
	# Hot path during session/load replay: O(1) per append. We add the
	# entry's estimated height to the running virtual height and defer the
	# cumulative_y rebuild until the next flush. Without this, a 500-entry
	# burst would re-sum every height on every append (O(n²)) and freeze
	# the main thread.
	_entries.append(entry)
	_heights.append(-1.0)
	_ordered_y_dirty = true
	_virtual_height += _estimated_row_height
	_mark_virtual_height_dirty()
	_schedule_materialize()


func update_entry(entry_index: int, entry: Dictionary) -> void:
	if entry_index < 0 or entry_index >= _entries.size():
		return
	_entries[entry_index] = entry
	var prev_height: float = _heights[entry_index]
	_heights[entry_index] = -1.0
	var existing: Variant = _controls.get(entry_index, null)
	if existing != null and is_instance_valid(existing) and existing is Control:
		_free_control(entry_index)
	_ordered_y_dirty = true
	# Adjust virtual height incrementally: was using prev height (or estimate
	# if unmeasured), now using estimate until remeasure.
	var was: float = prev_height if prev_height > 0.0 else _estimated_row_height
	_virtual_height += (_estimated_row_height - was)
	_mark_virtual_height_dirty()
	_schedule_materialize()


func get_entry_count() -> int:
	return _entries.size()


func get_entry_control(entry_index: int) -> Control:
	var value: Variant = _controls.get(entry_index, null)
	if value == null or not is_instance_valid(value):
		return null
	if value is Control:
		return value
	return null


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		# Dock plugins' child controls are wrapped in the editor's tab
		# widget — on first activation the scroll container's size is
		# still 0 when `set_entries_snapshot` runs, so the initial
		# `_schedule_materialize` picks an empty visible range and the
		# feed renders blank until the user scrolls / switches session.
		# Retrigger materialize whenever visibility flips on, catching
		# the "tab was hidden, now shown" case.
		if is_visible_in_tree() and not _entries.is_empty():
			_schedule_materialize()
		return
	if what == NOTIFICATION_RESIZED:
		# Only width changes invalidate wrap-derived heights. Height-only
		# resize notifications arrive constantly as our own virtual_height
		# updates ripple through the parent layout; reacting to those would
		# loop forever (heights → virtual_height → scroll bar visibility
		# → viewport width → heights → ...).
		if is_equal_approx(size.x, _last_known_width):
			return
		_last_known_width = size.x
		if _entries.is_empty():
			return
		# Do NOT bulk-invalidate every height to -1 here. Doing that makes
		# `_update_virtual_height()` rebuild the cumulative sum from the
		# estimated-row-height fallback for every row (~60 px), which on a
		# long thread collapses virtual_height by 5-10×, yanks the
		# scrollbar range, and clamps `scroll_vertical` — the viewport
		# ends up pointing at empty content while the user is still
		# dragging. Offscreen rows keep their last measured height (a
		# slight approximation for the new width, but one that self-
		# corrects the next time they enter view). Only visible rows need
		# to re-measure immediately.
		_ordered_y_dirty = true
		_remeasure_visible()
		_schedule_materialize()


func _connect_scroll_signals() -> void:
	if _scroll == null:
		return
	# Resized fires on ScrollContainer itself from day one; connect it
	# unconditionally so we can react to dock resize even before the
	# scrollbar is available.
	if not _scroll.resized.is_connected(_on_scroll_resized):
		_scroll.resized.connect(_on_scroll_resized)
	var bar := _scroll.get_v_scroll_bar()
	if bar == null:
		# ScrollContainer creates its scrollbars during its own _ready, which
		# can run AFTER our configure() was called (we're instantiated inside
		# the parent dock's _build_ui, before children's _ready fires). Retry
		# on the next idle tick until the scrollbar exists — without this,
		# value_changed / changed never get wired up and follow-tail never
		# triggers after initial layout.
		call_deferred("_connect_scroll_signals")
		return
	if not bar.value_changed.is_connected(_on_scroll_value_changed):
		bar.value_changed.connect(_on_scroll_value_changed)
	if not bar.changed.is_connected(_on_scroll_range_changed):
		bar.changed.connect(_on_scroll_range_changed)
	_scroll_signals_connected = true
	# Prime follow-tail + materialize once signals land; bar.max may have
	# grown during the frames we waited and we missed those `changed` events.
	if _follow_tail and not _follow_tail_pending:
		_follow_tail_pending = true
		call_deferred("_flush_follow_tail")
	if not _materialize_pending:
		_materialize_pending = true
		call_deferred("_flush_materialize")


func _disconnect_scroll_signals() -> void:
	if _scroll == null or not _scroll_signals_connected:
		return
	var bar := _scroll.get_v_scroll_bar()
	if bar != null:
		if bar.value_changed.is_connected(_on_scroll_value_changed):
			bar.value_changed.disconnect(_on_scroll_value_changed)
		if bar.changed.is_connected(_on_scroll_range_changed):
			bar.changed.disconnect(_on_scroll_range_changed)
	if _scroll.resized.is_connected(_on_scroll_resized):
		_scroll.resized.disconnect(_on_scroll_resized)
	_scroll_signals_connected = false


func _on_scroll_value_changed(value: float) -> void:
	# Disarm follow-tail when user pulls the scroll away from the bottom;
	# re-arm only when they actively scroll *down into* the bottom. We have
	# to distinguish two flavors of "value == max":
	#   a) user scrolled down (value increased) until it hit the bottom —
	#      genuine intent, re-arm follow_tail.
	#   b) virtual_height shrank (e.g., freshly measured rows came back
	#      smaller than our 60 px estimate), so ScrollContainer clamped
	#      scroll_vertical down to the new max — value *decreased* to end
	#      up at max. No user intent; follow_tail must not re-arm, or the
	#      next grow-measure will pin the viewport to the bottom and yank
	#      the user out of whatever row they were reading.
	# `_apply_follow_tail`'s own programmatic writes flow through here too,
	# but only when follow_tail is already true, so the rule stays safe:
	# going from old_max to new_max is a strict increase, still re-arms.
	var previous_value := _last_scroll_value
	_last_scroll_value = value
	if _scroll != null:
		var bar := _scroll.get_v_scroll_bar()
		if bar != null:
			var max_value: float = bar.max_value - bar.page
			var at_bottom: bool = value >= max_value - 1.0
			if not at_bottom:
				_follow_tail = false
			elif value > previous_value + 0.5:
				_follow_tail = true
			# at_bottom but value didn't increase → this is a clamp, leave
			# _follow_tail alone.
	_schedule_materialize()


func _on_scroll_range_changed() -> void:
	# Scrollbar range can change many times in a single frame during a
	# session/load burst (one per append). Coalesce the follow-tail write
	# to one per frame; a direct scroll_vertical write per event would
	# force a ScrollContainer layout pass every time.
	if _follow_tail_pending:
		return
	_follow_tail_pending = true
	call_deferred("_flush_follow_tail")


func _flush_follow_tail() -> void:
	_follow_tail_pending = false
	_apply_follow_tail()


func _on_scroll_resized() -> void:
	if not _follow_tail_pending:
		_follow_tail_pending = true
		call_deferred("_flush_follow_tail")
	_schedule_materialize()


func _apply_follow_tail() -> void:
	if not _follow_tail or _scroll == null:
		return
	var bar := _scroll.get_v_scroll_bar()
	if bar == null:
		return
	var target: float = max(0.0, bar.max_value - bar.page)
	# Prime _last_scroll_value so the ensuing value_changed callback does
	# not misread our own programmatic jump as a scroll delta. Without
	# this, going from "not yet following tail" (previous_value = 0) to
	# tail via a single write would show up as value >> previous and
	# re-arm follow_tail unnecessarily — benign, but we want user input
	# to be the *only* thing that flips that flag.
	_last_scroll_value = target
	_scroll.scroll_vertical = int(target)


func scroll_to_bottom() -> void:
	_follow_tail = true
	_apply_follow_tail()


func scroll_to_top() -> void:
	_follow_tail = false
	if _scroll != null:
		_last_scroll_value = 0.0
		_scroll.scroll_vertical = 0


func _schedule_materialize() -> void:
	if _materialize_pending:
		return
	_materialize_pending = true
	call_deferred("_flush_materialize")


func _flush_materialize() -> void:
	_materialize_pending = false
	_ensure_cumulative_y()
	_materialize_visible_range()
	_reposition_visible_controls()
	# Re-pin to the bottom if follow_tail is still armed. This is safe to
	# call even when _flush_materialize was triggered by the user's own
	# scroll event: _on_scroll_value_changed disarms _follow_tail the
	# moment the user scrolls off bottom, and _apply_follow_tail early-
	# returns while _follow_tail is false.
	if _follow_tail and not _follow_tail_pending:
		_follow_tail_pending = true
		call_deferred("_flush_follow_tail")


func _ensure_cumulative_y() -> void:
	if not _ordered_y_dirty and _ordered_y.size() == _entries.size() + 1:
		return
	_ordered_y.resize(_entries.size() + 1)
	var running: float = 0.0
	for i in range(_entries.size()):
		_ordered_y[i] = running
		var h: float = _heights[i]
		if h < 0.0:
			h = _estimated_row_height
		running += h
	_ordered_y[_entries.size()] = running
	_ordered_y_dirty = false


func _mark_virtual_height_dirty() -> void:
	if _cumulative_y_recompute_pending:
		return
	_cumulative_y_recompute_pending = true
	call_deferred("_flush_virtual_height")


func _flush_virtual_height() -> void:
	_cumulative_y_recompute_pending = false
	_ensure_cumulative_y()
	var total: float = _ordered_y[_entries.size()] if not _ordered_y.is_empty() else 0.0
	_virtual_height = total
	if not is_equal_approx(custom_minimum_size.y, total):
		custom_minimum_size.y = total
		update_minimum_size()
	# Same reasoning as _flush_materialize: the scroll bar's max updates one
	# layout cycle after our min_size change, so a deferred retry after that
	# cycle catches the final range.
	if _follow_tail and not _follow_tail_pending:
		_follow_tail_pending = true
		call_deferred("_flush_follow_tail")


func _update_virtual_height() -> void:
	# Synchronous path for call sites that need min_size updated now (e.g.
	# set_entries_snapshot, clear_entries). Most mutation paths go through
	# _mark_virtual_height_dirty to coalesce bursts.
	_cumulative_y_recompute_pending = false
	_ensure_cumulative_y()
	var total: float = _ordered_y[_entries.size()] if not _ordered_y.is_empty() else 0.0
	_virtual_height = total
	if not is_equal_approx(custom_minimum_size.y, total):
		custom_minimum_size.y = total
		update_minimum_size()


func _compute_visible_range() -> Vector2i:
	if _entries.is_empty():
		return Vector2i(0, 0)
	if _scroll == null:
		return Vector2i(0, _entries.size())
	var scroll_top: float = float(_scroll.scroll_vertical)
	var viewport_h: float = max(0.0, _scroll.size.y)
	var scroll_bottom: float = scroll_top + viewport_h

	var start: int = _search_first_bottom_after(scroll_top)
	var end: int = _search_first_top_after(scroll_bottom)

	start = max(0, start - _overscan_rows)
	end = min(_entries.size(), end + _overscan_rows)
	if end < start:
		end = start
	return Vector2i(start, end)


func _search_first_bottom_after(y: float) -> int:
	# Smallest i such that _ordered_y[i+1] > y. O(log n).
	if _entries.is_empty():
		return 0
	var lo: int = 0
	var hi: int = _entries.size() - 1
	var result: int = _entries.size()
	while lo <= hi:
		var mid: int = (lo + hi) / 2
		if _ordered_y[mid + 1] > y:
			result = mid
			hi = mid - 1
		else:
			lo = mid + 1
	return result


func _search_first_top_after(y: float) -> int:
	# Smallest i such that _ordered_y[i] >= y. Returns entry count if none.
	if _entries.is_empty():
		return 0
	var lo: int = 0
	var hi: int = _entries.size() - 1
	var result: int = _entries.size()
	while lo <= hi:
		var mid: int = (lo + hi) / 2
		if _ordered_y[mid] >= y:
			result = mid
			hi = mid - 1
		else:
			lo = mid + 1
	return result


func _materialize_visible_range() -> void:
	var vis_range := _compute_visible_range()
	# Free controls outside the range.
	var to_free: Array = []
	for key in _controls.keys():
		var idx: int = int(key)
		if idx < vis_range.x or idx >= vis_range.y:
			to_free.append(idx)
	for idx in to_free:
		_free_control(int(idx))
	# Materialize missing in-range entries.
	var changed: bool = false
	for i in range(vis_range.x, vis_range.y):
		if _controls.has(i):
			continue
		_materialize(i)
		changed = true
	if changed:
		_update_virtual_height()


func _materialize(entry_index: int) -> void:
	if entry_index < 0 or entry_index >= _entries.size():
		return
	if not _builder.is_valid():
		return
	var entry_variant = _entries[entry_index]
	if typeof(entry_variant) != TYPE_DICTIONARY:
		return
	var ctrl_variant = _builder.call(entry_variant, entry_index)
	if not (ctrl_variant is Control):
		return
	var ctrl: Control = ctrl_variant
	add_child(ctrl)
	# Width is authoritative immediately so Container descendants start wrap
	# calculations with the right constraint; height seeds from the cached
	# measurement when one exists (row scrolled out and back in), falling
	# back to the estimate only for never-measured rows. Two reasons:
	#   1. Cached-height path: avoids a one-frame size flash (60 px then
	#      real height) as the user scrolls rows back into view. That
	#      flash read as a visible flicker on every wheel tick.
	#   2. We MUST NOT clobber `_heights[entry_index]` here itself — that
	#      would make cumulative_y rebuilds treat re-entering rows as
	#      unmeasured, collapse `_virtual_height`, and yank the scrollbar
	#      back (the old "scrolling does nothing" bug).
	var initial_h: float = _heights[entry_index]
	if initial_h < 0.0:
		initial_h = _estimated_row_height
	ctrl.size = Vector2(size.x, initial_h)
	ctrl.position = Vector2(0.0, _ordered_y[entry_index])
	_controls[entry_index] = ctrl
	if not ctrl.minimum_size_changed.is_connected(_on_entry_min_size_changed):
		ctrl.minimum_size_changed.connect(_on_entry_min_size_changed.bind(entry_index))
	# Defer the first measure so the Container subtree can sort/size children
	# (Container layout is queued, not immediate).
	_schedule_measure(entry_index)
	emit_signal("entry_created", entry_index, ctrl)


func _on_entry_min_size_changed(entry_index: int) -> void:
	_schedule_measure(entry_index)


func _schedule_measure(entry_index: int) -> void:
	if _pending_measure.has(entry_index):
		return
	_pending_measure[entry_index] = true
	call_deferred("_measure_entry", entry_index)


func _measure_entry(entry_index: int) -> void:
	# Mirrors Zed's list.rs:1414-1443 behavior: when an item's measured
	# height changes, preserve the user's visual position in the scrollable
	# content. Without anchoring, remeasuring entries above the viewport
	# shifts subsequent entries and visible content jitters.
	_pending_measure.erase(entry_index)
	if not _controls.has(entry_index):
		return
	var ctrl: Control = _controls[entry_index]
	if not is_instance_valid(ctrl):
		return
	var min_y: float = max(ctrl.get_combined_minimum_size().y, _estimated_row_height)
	# `_heights[i] = -1.0` is the "unmeasured" sentinel; the virtual-height
	# and cumulative-y math all treat that as _estimated_row_height, so we
	# must do the same here. Using -1 directly would compute a delta of
	# `min_y - (-1)` per first measure, over-inflating the total scroll
	# height and leaving a phantom empty gap below the last entry.
	# Remember whether this was the first real measurement (transitioning
	# from the estimate placeholder) — the anchor-preservation branch
	# below keys off it.
	var was_unmeasured: bool = _heights[entry_index] < 0.0
	var prev: float = _heights[entry_index]
	if was_unmeasured:
		prev = _estimated_row_height
	if abs(min_y - prev) < 0.5:
		# Even when the height matches, stamp the real value so the stored
		# cache no longer reads as "unmeasured" — otherwise subsequent
		# cumulative_y rebuilds still use the estimate fallback.
		_heights[entry_index] = min_y
		return

	# Snapshot the scroll anchor BEFORE mutating heights. _ordered_y is
	# guaranteed fresh here via _ensure_cumulative_y.
	_ensure_cumulative_y()
	var entry_top_before: float = _ordered_y[entry_index]
	var entry_bottom_before: float = entry_top_before + prev
	var scroll_top_before: float = 0.0
	if _scroll != null:
		scroll_top_before = float(_scroll.scroll_vertical)

	var delta: float = min_y - prev
	_heights[entry_index] = min_y
	ctrl.size.y = min_y
	_ordered_y_dirty = true
	_virtual_height += delta
	if not is_equal_approx(custom_minimum_size.y, _virtual_height):
		custom_minimum_size.y = _virtual_height
		update_minimum_size()

	# Anchor preservation: when a row whose height was already known
	# shifts, compensate scroll_vertical by the delta so the content the
	# user is looking at stays put on screen.
	#
	# Crucially, skip on the FIRST measurement (was_unmeasured). A brand
	# new row's "previous height" was the 60 px estimate placeholder —
	# never something the user actually saw. Shifting scroll_vertical by
	# that fictional delta fights against wheel input: every wheel tick
	# pulls a fresh row into overscan, which measures taller than
	# estimate, which pushes scroll back, which undoes the wheel. The
	# viewport ends up jittering in place instead of scrolling.
	# Skip follow_tail too: in that mode the `changed` signal re-pins us
	# to the new max automatically.
	if (
		not was_unmeasured
		and not _follow_tail
		and _scroll != null
		and entry_bottom_before <= scroll_top_before + 0.5
	):
		var target: float = scroll_top_before + delta
		if target < 0.0:
			target = 0.0
		_scroll.scroll_vertical = int(target)

	_reposition_visible_controls()


func _remeasure_visible() -> void:
	for key in _controls.keys():
		var idx: int = int(key)
		var ctrl: Control = _controls[idx]
		if not is_instance_valid(ctrl):
			continue
		ctrl.size.x = size.x
		_schedule_measure(idx)


func _reposition_visible_controls() -> void:
	_ensure_cumulative_y()
	for key in _controls.keys():
		var idx: int = int(key)
		var ctrl: Control = _controls[idx]
		if not is_instance_valid(ctrl):
			continue
		ctrl.position = Vector2(0.0, _ordered_y[idx])
		if not is_equal_approx(ctrl.size.x, size.x):
			ctrl.size.x = size.x


func _free_control(entry_index: int) -> void:
	var value: Variant = _controls.get(entry_index, null)
	if value != null and is_instance_valid(value) and value is Control:
		var ctrl: Control = value
		emit_signal("entry_freed", entry_index, ctrl)
		ctrl.queue_free()
	_controls.erase(entry_index)
	_pending_measure.erase(entry_index)


func _destroy_all_controls() -> void:
	for key in _controls.keys():
		var value: Variant = _controls[key]
		if value != null and is_instance_valid(value) and value is Control:
			(value as Control).queue_free()
	_controls.clear()
	_pending_measure.clear()
