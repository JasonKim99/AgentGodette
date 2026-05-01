@tool
class_name GodetteTokenFlameDigitOverlay
extends Control

# Custom-drawn digit text for the token flame widget. This is the
# Godot-side equivalent of Balatro's `DynaText:draw` (engine/text.lua):
# we manually compute each glyph's advance width from the font, place
# letters by accumulating those widths (no Container layout), and apply
# per-letter pulse + quiver transforms in `_draw()` rather than via
# Tween-on-Label.
#
# Two reasons for the custom-draw approach over HBoxContainer + Labels:
#   1. Label.size includes outline padding — adjacent Labels with
#      separation=0 still show 2*outline_size of empty pixels between
#      glyphs. Negative separation only papers over this; per-glyph
#      manual placement removes the dependency entirely.
#   2. Outline can be drawn as a separate `draw_string_outline` pass
#      (matching Balatro's "shadow" pass) so the outline doesn't
#      affect glyph spacing.
#
# Owner widget pushes properties via direct field assignment + calls
# `set_text(...)` / `trigger_pulse()` — overlay maintains animation
# state internally and re-queues redraws while a pulse or quiver is
# in flight.

const PULSE_WIDTH := 2.5  # letters; matches Balatro's hardcoded value

# --- Visual config (pushed by owner widget) -----------------------------
var pixel_font: Font = null
var glyph_size: int = 32
var outline_size_px: int = 8
var fill_color: Color = Color(1.0, 1.0, 1.0, 1.0)
var outline_color: Color = Color(0.0, 0.0, 0.0, 0.95)

# --- Pulse + quiver tunables --------------------------------------------
var pulse_peak_scale_pct: int = 250
var pulse_duration_ms: int = 320
var pulse_rotation_deg: int = 10
var quiver_amount_pct: int = 0

# --- Animation state (internal) -----------------------------------------
var _text: String = "0"
# Single in-flight pulse wave — strict "one wave at a time" model.
# Triggers arriving while a wave is still propagating set the queue
# flag (single slot, coalesces bursts) and the queued wave starts the
# moment the current one ends. This gives the "wave after wave, no
# overlap" cadence that pairs with the count-up animation in the
# parent widget — number ticks + pulses fire at the same throttle.
var _pulse_start_time: float = -1.0
var _pulse_queued: bool = false


func _init() -> void:
	# Visual-only — tooltip / clicks belong on the parent widget.
	mouse_filter = Control.MOUSE_FILTER_IGNORE


# Set the digit string. Triggers a redraw; min_size update lets the
# parent widget resize itself around the new glyph metrics.
func set_text(new_text: String) -> void:
	if new_text == _text:
		return
	_text = new_text
	queue_redraw()
	update_minimum_size()


# Request a pulse. If no wave is in flight, start one immediately.
# Otherwise just set the queue flag — the in-flight wave plays through
# to completion and the queued slot's wave starts the moment it ends.
# Subsequent triggers during the same in-flight wave coalesce into the
# single queue slot (no unbounded backlog).
func trigger_pulse() -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	if _pulse_start_time < 0.0:
		_pulse_start_time = now
	else:
		_pulse_queued = true
	queue_redraw()


# Re-queue the redraw while any pulse / quiver has visible effect, so
# the letters animate frame-by-frame without us having to tween
# anything. Static text (no in-flight pulses, no quiver) costs zero
# CPU here.
func _process(_delta: float) -> void:
	if _pulse_start_time >= 0.0 or quiver_amount_pct > 0:
		queue_redraw()


# Min-size = total glyph advance + the Balatro-style outline shadow's
# x parallax (negligible, but include the outline_size on each side
# defensively so nothing gets clipped at the edges).
func _get_minimum_size() -> Vector2:
	if pixel_font == null or _text.is_empty():
		return Vector2.ZERO
	var s: Vector2 = pixel_font.get_string_size(
		_text, HORIZONTAL_ALIGNMENT_LEFT, -1, glyph_size
	)
	# Outline doesn't add to advance width, but visually extends past
	# the glyph by `outline_size_px` on each side. Pad min-size so the
	# parent's body panel ends up sized to fit outline-included visual.
	return s + Vector2(float(outline_size_px) * 2.0, 0.0)


func _draw() -> void:
	if _text.is_empty() or pixel_font == null:
		return
	var n: int = _text.length()
	if n == 0:
		return

	# ---- Glyph advance widths (Balatro's per-letter `tx`) ------------
	# Width per character is the FONT'S OWN advance for that glyph,
	# variable per-character (so "1" is narrower than "5"). This is
	# what gives Balatro its naturally tight digit layout — we don't
	# pad anything beyond what the font itself reports.
	var glyph_widths := PackedFloat32Array()
	glyph_widths.resize(n)
	var total_w: float = 0.0
	for i in n:
		var w: float = pixel_font.get_string_size(
			_text.substr(i, 1), HORIZONTAL_ALIGNMENT_LEFT, -1, glyph_size
		).x
		glyph_widths[i] = w
		total_w += w

	# ---- Vertical metrics + horizontal centring ----------------------
	var ascent: float = pixel_font.get_ascent(glyph_size)
	var descent: float = pixel_font.get_descent(glyph_size)
	var widget_size: Vector2 = size
	# Centre the run of glyphs horizontally, vertically align baseline
	# so the visual midline of the text sits at widget centre.
	var top_y: float = (widget_size.y - (ascent + descent)) * 0.5
	var baseline_y: float = top_y + ascent
	var run_x: float = (widget_size.x - total_w) * 0.5

	# ---- Pulse + quiver param resolution -----------------------------
	var t: float = Time.get_ticks_msec() / 1000.0
	var centre: float = (float(n) + 1.0) * 0.5
	var max_offset: float = max((float(n) - 1.0) / 2.0, 0.5)
	var rotation_rad: float = deg_to_rad(float(pulse_rotation_deg))

	var peak_scale: float = float(pulse_peak_scale_pct) / 100.0
	var pulse_amount: float = (peak_scale - 1.0) * PULSE_WIDTH / (PULSE_WIDTH + 1.0)
	var max_boost: float = pulse_amount * (PULSE_WIDTH + 1.0) / PULSE_WIDTH
	var duration_sec: float = max(float(pulse_duration_ms) / 1000.0, 0.05)
	var pulse_speed: float = (float(n) + PULSE_WIDTH + 2.0) / duration_sec

	# In-flight wave bookkeeping: if the current wave just finished,
	# either start the queued one immediately (no gap) or go idle.
	if _pulse_start_time >= 0.0 and t - _pulse_start_time > duration_sec + 0.1:
		if _pulse_queued:
			_pulse_queued = false
			_pulse_start_time = t
		else:
			_pulse_start_time = -1.0

	var quiver_amt: float = float(quiver_amount_pct) / 100.0
	var quiver_speed: float = 0.5

	var ci: RID = get_canvas_item()

	# ---- Per-letter draw loop ----------------------------------------
	for i in n:
		var k: int = i + 1  # 1-based to match Balatro indexing
		var ch: String = _text.substr(i, 1)
		var ch_w: float = glyph_widths[i]

		# Pulse contribution from the single in-flight wave (if any).
		var letter_scale_boost: float = 0.0
		var letter_r: float = 0.0
		if _pulse_start_time >= 0.0:
			var elapsed: float = t - _pulse_start_time
			var rising: float = -elapsed * pulse_speed + float(k) + PULSE_WIDTH
			var falling: float = elapsed * pulse_speed - float(k) + PULSE_WIDTH + 2.0
			var wave: float = max(0.0, min(rising, falling))
			if wave > 0.0:
				letter_scale_boost = (1.0 / PULSE_WIDTH) * pulse_amount * wave
				if max_boost > 0.001:
					var boost_ratio: float = letter_scale_boost / max_boost
					var pos_normalised: float = (float(k) - centre) / max_offset
					letter_r += boost_ratio * pos_normalised * rotation_rad

		var letter_scale: float = 1.0 + letter_scale_boost

		# Quiver contribution (Balatro's set_quiver sum-of-sinusoids)
		if quiver_amt > 0.001:
			letter_r += 0.3 * quiver_amt * (
				sin(41.12 * t * quiver_speed + float(k) * 1223.2) +
				cos(63.21 * t * quiver_speed + float(k) * 1112.2) * sin(36.12 * t * quiver_speed) +
				cos(95.12 * t * quiver_speed + float(k) * 1233.2) -
				sin(30.13 * t * quiver_speed + float(k) * 123.2)
			)

		# Per-letter transform: anchor at the glyph's visual centre,
		# rotate, then scale. After this the local origin sits at the
		# glyph centre, so we draw at (-ch_w/2, ascent*0.5) to put the
		# baseline directly below origin and the glyph horizontally
		# centred on origin.
		var letter_centre := Vector2(
			run_x + ch_w * 0.5,
			baseline_y - ascent * 0.5
		)
		draw_set_transform(
			letter_centre,
			letter_r,
			Vector2(letter_scale, letter_scale)
		)
		var glyph_pos := Vector2(-ch_w * 0.5, ascent * 0.5)
		# Outline first (Balatro's "shadow" pass equivalent), then
		# fill on top — matches Balatro's two-pass rendering.
		if outline_size_px > 0:
			pixel_font.draw_string_outline(
				ci, glyph_pos, ch,
				HORIZONTAL_ALIGNMENT_LEFT, -1,
				glyph_size, outline_size_px, outline_color
			)
		pixel_font.draw_string(
			ci, glyph_pos, ch,
			HORIZONTAL_ALIGNMENT_LEFT, -1,
			glyph_size, fill_color
		)

		run_x += ch_w

	# Reset transform so subsequent draws (none here, but defensively)
	# don't inherit the last letter's matrix.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
