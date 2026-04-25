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
# Per-entry measurement state, mirrors Zed's `ItemState::Unrendered` /
# `Rendered` distinction (vendor/zed/crates/gpui/src/elements/list.rs):
# 0 = unmeasured (height in `_heights[i]` is the estimate placeholder),
# 1 = measured (height is the entry's real `get_combined_minimum_size().y`
# at our current width). `_heights[i]` is always a real number — the old
# `-1` sentinel encoded both state and value in one slot, which made every
# read site duplicate the fallback-to-estimate logic. Splitting the two
# means callers can read `_heights[i]` directly without thinking.
var _measured: PackedByteArray = PackedByteArray()
var _controls: Dictionary = {}  # entry_index -> Control
var _ordered_y: PackedFloat32Array = PackedFloat32Array()  # cumulative, size = entries + 1
var _ordered_y_dirty: bool = true
# True once `_warm_up_measure_all()` has populated `_measured` for every
# entry in the current snapshot. Goes false on any snapshot/append/update.
# Equivalent to "all items are in the Rendered state" in Zed's list.rs.
# Currently informational — read sites still tolerate unmeasured rows via
# the estimate — but lets future code gate operations on warm-up
# completion (e.g. "do not auto-scroll to a fractional anchor until heights
# settle").
var _warmed_up: bool = false
var _warm_up_pending: bool = false

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
	_measured.resize(_entries.size())
	for i in range(_entries.size()):
		_heights[i] = _estimated_row_height
		_measured[i] = 0
	_warmed_up = _entries.is_empty()
	_ordered_y_dirty = true
	_update_virtual_height()
	# Warm-up: measure every entry's real height before anything paints,
	# so virtual_height is correct from frame 1 instead of growing toward
	# truth as rows scroll into view. Mirrors Zed's `layout_all_items()`
	# warm-up pass (vendor/zed/crates/gpui/src/elements/list.rs:340-387).
	# Deferred so the layout cascade can settle our own width first —
	# warm-up at width=0 produces garbage measurements.
	_schedule_warm_up()
	_schedule_materialize()


func clear_entries() -> void:
	_destroy_all_controls()
	_entries.clear()
	_heights.resize(0)
	_measured.resize(0)
	_ordered_y.resize(0)
	_ordered_y_dirty = false
	_warmed_up = true
	_update_virtual_height()


func append_entry(entry: Dictionary) -> void:
	# Hot path during session/load replay: O(1) per append. We add the
	# entry's estimated height to the running virtual height and defer the
	# cumulative_y rebuild until the next flush. Without this, a 500-entry
	# burst would re-sum every height on every append (O(n²)) and freeze
	# the main thread.
	_entries.append(entry)
	_heights.append(_estimated_row_height)
	_measured.append(0)
	_warmed_up = false
	_ordered_y_dirty = true
	_virtual_height += _estimated_row_height
	_mark_virtual_height_dirty()
	# Single-entry warm-up: append happens hot during session/load replay
	# (one per ACP session_update). Letting these accumulate as Unmeasured
	# means virtual_height stays at N×estimate until each row scrolls
	# into view, which is exactly the bug the warm-up exists to prevent.
	_schedule_warm_up()
	_schedule_materialize()


func update_entry(entry_index: int, entry: Dictionary) -> void:
	if entry_index < 0 or entry_index >= _entries.size():
		return
	_entries[entry_index] = entry
	var was: float = _heights[entry_index]
	_heights[entry_index] = _estimated_row_height
	_measured[entry_index] = 0
	_warmed_up = false
	var existing: Variant = _controls.get(entry_index, null)
	if existing != null and is_instance_valid(existing) and existing is Control:
		_free_control(entry_index)
	_ordered_y_dirty = true
	# Adjust virtual height incrementally: was using prev height,
	# now using estimate until remeasure.
	_virtual_height += (_estimated_row_height - was)
	_mark_virtual_height_dirty()
	_schedule_warm_up()
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
			# Width may have become known while we were hidden; retrigger
			# warm-up in case the snapshot landed before the dock tab
			# was activated.
			if not _warmed_up:
				_schedule_warm_up()
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
		# Width changed → wrap-derived heights for offscreen entries are
		# now wrong. Mark them all unmeasured and retrigger warm-up so the
		# scrollbar range stays accurate without waiting for each entry
		# to scroll into view. Materialized entries are remeasured
		# immediately via _remeasure_visible (their controls already exist;
		# building a duplicate in warm-up would be wasted work).
		for i in range(_entries.size()):
			if _controls.has(i):
				continue
			_measured[i] = 0
		_warmed_up = false
		_remeasure_visible()
		_schedule_warm_up()
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
	if not _warmed_up:
		_schedule_warm_up()
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


# ---------------------------------------------------------------------------
# Warm-up measurement
# ---------------------------------------------------------------------------
#
# Ports Zed's `layout_all_items()` warm-up pass (vendor/zed/crates/gpui/
# src/elements/list.rs:340-387). On a fresh entry set we want every row's
# real height in the cache before the first paint — without it,
# virtual_height stays at N×estimate until rows scroll into view, the
# ScrollContainer's scrollbar range under-reports the true content
# extent, and content visually extends below the viewport with no way
# to scroll there. That was the "reload session, no scrollbar" bug.
#
# The pass is synchronous within a single deferred flush: build each
# unmeasured entry off-screen, read get_combined_minimum_size(), free.
# The cost is O(entries) builder calls per snapshot; with the typical
# transcript size (≤100 entries) the perceptible freeze is well under
# 200ms.
#
# Skipped while `size.x <= 0` — measuring at width 0 produces garbage
# wrap heights. The width-becomes-known path (NOTIFICATION_RESIZED,
# visibility flips) re-schedules warm-up so first-frame snapshots
# eventually settle.


func _schedule_warm_up() -> void:
	if _warm_up_pending:
		return
	_warm_up_pending = true
	call_deferred("_flush_warm_up")


func _flush_warm_up() -> void:
	_warm_up_pending = false
	_warm_up_measure_all()


func _warm_up_measure_all() -> void:
	if _warmed_up:
		return
	if _entries.is_empty():
		_warmed_up = true
		return
	if size.x <= 0.0 or not _builder.is_valid():
		# Bail until we have width and a builder; another retrigger will
		# come (resize / visibility / configure).
		return

	var changed: bool = false
	for i in range(_entries.size()):
		if _measured[i] == 1:
			continue
		if _controls.has(i):
			# Currently materialized — the normal _measure_entry path will
			# stamp `_measured` for it. Skip to avoid double-build.
			continue
		var entry_variant = _entries[i]
		if typeof(entry_variant) != TYPE_DICTIONARY:
			# Not buildable; treat the estimate as the final answer rather
			# than leaving it unmeasured forever.
			_measured[i] = 1
			changed = true
			continue
		var ctrl_variant = _builder.call(entry_variant, i)
		if not (ctrl_variant is Control):
			_measured[i] = 1
			changed = true
			continue
		var ctrl: Control = ctrl_variant
		add_child(ctrl)
		# Width is the only constraint that matters for wrap-derived
		# heights. Position off-screen so the temporary control doesn't
		# flash into view between add_child and queue_free (queue_free
		# defers destruction to end-of-frame, so the ctrl draws once
		# unless we hide it). `visible = false` would short-circuit some
		# Container layouts and corrupt the measurement, so we use
		# off-screen position instead.
		ctrl.size.x = size.x
		ctrl.position = Vector2(-99999.0, 0.0)
		var measured: float = max(ctrl.get_combined_minimum_size().y, _estimated_row_height)
		_heights[i] = measured
		_measured[i] = 1
		ctrl.queue_free()
		changed = true

	_warmed_up = true
	if changed:
		_ordered_y_dirty = true
		_update_virtual_height()
		_schedule_materialize()
		# follow-tail re-pins now that virtual_height reflects truth.
		if _follow_tail and not _follow_tail_pending:
			_follow_tail_pending = true
			call_deferred("_flush_follow_tail")


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
		# For materialized entries, the live control's `size.y` is the
		# authoritative source — that's literally what gets rendered. The
		# `_heights[i]` cache can drift behind reality when a Container
		# subtree re-lays-out without bubbling `minimum_size_changed` up
		# to our outer signal, causing the cumulative_y math to place the
		# next entry inside this one (the visible "overlap" symptom).
		# Reading from the control directly closes that gap and also
		# refreshes the cache so dematerialization later has the right
		# fallback value.
		if _controls.has(i):
			var ctrl_variant: Variant = _controls[i]
			if ctrl_variant is Control and is_instance_valid(ctrl_variant):
				var live_h: float = (ctrl_variant as Control).size.y
				_heights[i] = live_h
				_measured[i] = 1
		running += _heights[i]
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
	# Free controls outside the range — cheap, batch all at once.
	var to_free: Array = []
	for key in _controls.keys():
		var idx: int = int(key)
		if idx < vis_range.x or idx >= vis_range.y:
			to_free.append(idx)
	for idx in to_free:
		_free_control(int(idx))

	# Materialize at most ONE missing in-range entry per flush, then
	# schedule another flush for the rest. This serialises what was
	# previously "build every visible entry in the same frame, then
	# rely on Godot's deferred layout cascade to settle them all in
	# parallel" — the parallel cascade made historical-session reload
	# unstable: N ListBlocks all firing minimum_size_changed inside one
	# frame interleaved through a single VBox queue_sort, with each
	# ListBlock's _sync_paragraphs running while its siblings hadn't
	# yet stabilised their own widths. Symptom: heights computed at
	# the wrong width, virtual_height wrong, scroll broken.
	#
	# Serialising means each entry gets its own clean frame to:
	#   1. Build (force-resolved min via _build_chat_message_entry).
	#   2. add_child + initial size apply.
	#   3. NOTIFICATION_RESIZED at real width on the next frame.
	#   4. _measure_entry's call_deferred fires on a settled control.
	# Cost: N frames to populate N visible entries. At 60 fps a 10-row
	# session loads visually in ~167ms — noticeable but worth the
	# correctness gain. Streaming-append is unaffected (only one entry
	# is added there per turn).
	var built: bool = false
	var more_pending: bool = false
	for i in range(vis_range.x, vis_range.y):
		if _controls.has(i):
			continue
		if built:
			more_pending = true
			break
		_materialize(i)
		built = true

	if built:
		_update_virtual_height()
	if more_pending and not _materialize_pending:
		# Use the existing pending flag + deferred plumbing so a burst
		# of mid-flow scroll events doesn't queue 50 redundant flushes.
		_materialize_pending = true
		call_deferred("_flush_materialize")


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
	# measurement (the warm-up pass populates this for every entry, so
	# `_heights[i]` is always a real number — measured or estimate, but
	# never the old `-1` sentinel). Avoiding the size flash matters because
	# scrolling a row out and back in used to flicker (60 px → real height)
	# on every wheel tick.
	ctrl.size = Vector2(size.x, _heights[entry_index])
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
	# `_heights[entry_index]` is always a real number under the new
	# explicit-state regime — `_measured[entry_index]` says whether it's
	# the estimate placeholder (0) or a real measurement (1). The anchor-
	# preservation branch below keys off the transition.
	var was_unmeasured: bool = _measured[entry_index] == 0
	var prev: float = _heights[entry_index]
	if abs(min_y - prev) < 0.5:
		# Stamp measured even when the value matches the estimate, so
		# subsequent reads stop treating the entry as unmeasured.
		_heights[entry_index] = min_y
		_measured[entry_index] = 1
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
	_measured[entry_index] = 1
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
	# First normalise widths — this can itself cascade Container
	# layouts that change `size.y` of materialized controls.
	for key in _controls.keys():
		var idx: int = int(key)
		var ctrl: Control = _controls[idx]
		if not is_instance_valid(ctrl):
			continue
		if not is_equal_approx(ctrl.size.x, size.x):
			ctrl.size.x = size.x
	# Force cumulative_y to rebuild using the live `ctrl.size.y` of
	# materialized entries (see `_ensure_cumulative_y`). Without
	# `_ordered_y_dirty = true` here the rebuild is skipped when sizes
	# changed externally without going through `_measure_entry` (which
	# is the only path that normally marks the cache dirty), and stale
	# positions cause the visible "entries glued together" overlap.
	_ordered_y_dirty = true
	_ensure_cumulative_y()
	for key in _controls.keys():
		var idx: int = int(key)
		var ctrl: Control = _controls[idx]
		if not is_instance_valid(ctrl):
			continue
		ctrl.position = Vector2(0.0, _ordered_y[idx])


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
