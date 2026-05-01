@tool
class_name GodetteTokenFlameWidget
extends Control

# Compact "tokens consumed since install" badge sitting next to the
# add-thread (`+`) button in the dock header. Balatro-style stacked
# layout: the abbreviated token count (26.7K / 1.2M / …) reads in the
# foreground, with a stepped flame shader burning UP from behind /
# beneath the text. The flame extends above the text's top edge so it
# licks into the dock-header gap, matching Balatro's "card on fire"
# look where flame escapes the card boundary.
#
# Lifecycle (driven by dock):
#   - dock instantiates one widget when state is bound
#   - widget subscribes to `state.total_tokens_changed` and refreshes
#   - dock toggles the widget's visibility based on the
#     `godette/ui/show_token_flame` ProjectSetting

const SHADER_PATH := "res://addons/godette_agent/shaders/token_flame.gdshader"
# Balatro-style pixel font (Daniel Linssen's m6x11plus). Loaded only if
# the user has dropped the .ttf into fonts/ — otherwise we fall back
# to the editor's theme default.
const FONT_PATH := "res://addons/godette_agent/fonts/m6x11plus.ttf"
const DigitOverlayScript = preload("res://addons/godette_agent/token_flame_digit_overlay.gd")

# ProjectSettings key prefix. Each tunable below has a matching key
# under this namespace; the settings dialog reads/writes them and the
# widget loads them in `_load_settings`.
const SETTING_PREFIX := "godette/token_flame/"

# Defaults — used when ProjectSettings doesn't have the key yet, AND
# when the user hits "Reset to defaults" in the settings dialog.
# Single theme colour: drives both the card body and the flame. The
# shader derives the flame's hot tips by lightening this colour toward
# a warm white, so they always harmonise.
const DEFAULT_COLOR := Color(0.90, 0.32, 0.30, 1.0)
const DEFAULT_PADDING_X := 0
const DEFAULT_PADDING_Y := 4
const DEFAULT_FLAME_OVERFLOW_TOP := 60
const DEFAULT_CORNER_RADIUS := 8
const DEFAULT_OUTLINE_SIZE := 8
const DEFAULT_FONT_SIZE := 32  # 0 → editor's default font size; 32 ≈ Balatro chip number
# Flame animation speed as a percentage of the shader's base TIME rate.
# 100 = 1×, 50 = half-speed (lazy embers), 200 = double-speed (frantic).
# Stored as int (slider-friendly), divided by 100 before going to the
# shader's `flame_speed` float uniform.
const DEFAULT_FLAME_SPEED := 100
# Master flame switch. When false, the entire flame TextureRect is
# hidden and the widget shows only the body card + digits — useful
# for users who find the animation distracting or want to save GPU on
# low-end machines.
const DEFAULT_FLAME_ENABLED := true


# Live values — populated from ProjectSettings on _ready, mutated via
# the setter methods below (live-updated by the settings dialog).
var color: Color = DEFAULT_COLOR
var padding_x: int = DEFAULT_PADDING_X
var padding_y: int = DEFAULT_PADDING_Y
var flame_overflow_top: int = DEFAULT_FLAME_OVERFLOW_TOP
var corner_radius: int = DEFAULT_CORNER_RADIUS
var outline_size: int = DEFAULT_OUTLINE_SIZE
var font_size: int = DEFAULT_FONT_SIZE
var flame_speed: int = DEFAULT_FLAME_SPEED
var flame_enabled: bool = DEFAULT_FLAME_ENABLED


# Emitted when the user clicks the widget. Dock listens and pops the
# settings dialog so the widget itself stays unaware of the dialog
# class (low coupling).
signal settings_requested


var _state = null  # GodetteState (typed weakly to avoid class_name-load order pain)
var _body_panel: Panel  # solid coloured "card body"
var _body_style: StyleBoxFlat
var _flame_rect: TextureRect
# Custom-drawn digit overlay (Balatro-style manual glyph placement).
# Replaces the previous HBoxContainer + per-letter Label approach,
# which had to fight Label.size including outline padding. The overlay
# draws each glyph via Font.draw_string with explicit per-letter
# transforms — matches Balatro's `engine/text.lua` rendering exactly.
var _digit_overlay: GodetteTokenFlameDigitOverlay
var _shader_material: ShaderMaterial

# Pulse animation parameters (Balatro DynaText:pulse port). Stored as
# ints for the slider helper; converted to float at evaluation time.
#   bounce_peak_scale: peak per-letter scale at the wave's crest (% of
#       baseline; 250 = 2.5×).
#   bounce_duration_ms: total time for the triangle wave to traverse
#       the entire string and decay.
#   bounce_rotation_deg: max degrees the outermost letter can tilt at
#       the wave's crest. Inner letters tilt proportionally less, sign
#       based on side of centre — same fan-out logic as Balatro.
const DEFAULT_BOUNCE_PEAK_SCALE := 250
const DEFAULT_BOUNCE_DURATION_MS := 320
const DEFAULT_BOUNCE_ROTATION_DEG := 10
var bounce_peak_scale: int = DEFAULT_BOUNCE_PEAK_SCALE
var bounce_duration_ms: int = DEFAULT_BOUNCE_DURATION_MS
var bounce_rotation_deg: int = DEFAULT_BOUNCE_ROTATION_DEG

# Quiver: continuous per-letter rotation jitter (Balatro DynaText:set_quiver).
# Sum of 4 sinusoids with per-letter phase offsets — looks pseudorandom
# but is deterministic and smooth. Always running while > 0; gives the
# digits an "alive" feel even when no pulse is in flight. 0 = off; ~30
# is subtle; 70+ starts looking restless.
const DEFAULT_QUIVER_AMOUNT := 0
var quiver_amount: int = DEFAULT_QUIVER_AMOUNT

# Pulse internal: letters of "wave width" — how many letters are
# scaling at any one moment as the triangle wave passes through. 2.5
# is Balatro's hardcoded default.
const PULSE_WIDTH := 2.5

# `_last_total = -1` so the very first refresh (state-binding /
# disk-restore) sets the baseline without firing a pulse — we only
# want to celebrate ACTUAL token consumption, not the loaded-from-disk
# number reappearing on editor start.
var _last_total: int = -1

# Smooth count-up animation: when a new authoritative total arrives we
# don't snap the displayed digits to it — instead we lerp the
# displayed value toward the target over a short window, firing a
# throttled pulse periodically and a final pulse on arrival. If a
# fresh target arrives mid-animation we just retarget; the lerp
# naturally continues toward the new endpoint without restarting.
# This mirrors the "slot-machine spinning to a number" feel CLIs use,
# even though our token telemetry is sparse (a few usage_update
# events per turn rather than per-token streaming).
var _displayed_total: float = 0.0
var _target_total: int = 0
# Throttle for pulses fired BY the count-up animation. The animation
# drives both the number ramp and the pulse cadence — each pulse
# coincides with the number ticking up, giving the "slot machine
# clicking through values" feel. pulse_throttle_ms controls how often
# a new pulse is fired during the ramp (overlay's queue=1 makes them
# strictly sequential, no overlap).
var _last_anim_pulse_ms: int = 0
# Linear count-up animation. Each new target retarget recomputes a
# tokens/sec rate that would close the gap in count_up_duration_ms.
# Tick-based: number advances by step + pulse fires every
# pulse_throttle_ms. If turn ends before count-up finishes, we
# snap-to-target and fire one last pulse (no exponential drag).
const DEFAULT_COUNT_UP_DURATION_MS := 15000
const DEFAULT_PULSE_THROTTLE_MS := 250
var count_up_duration_ms: int = DEFAULT_COUNT_UP_DURATION_MS
var pulse_throttle_ms: int = DEFAULT_PULSE_THROTTLE_MS
var _linear_rate: float = 0.0  # tokens/second for the current linear leg

# Pulse animation state. _pulse_start_time < 0 means no pulse in
# flight; otherwise it's the seconds-since-engine-start at which the
# current wave was triggered. Quiver runs continuously when its
# amount > 0 and is gated only by the parameter, no separate state.
var _pulse_start_time: float = -1.0

# Set by `_load_int` / `_load_color` when a previously-unregistered
# ProjectSettings key was just registered with its default value.
# `_load_settings` flushes ProjectSettings.save() once at the end if
# this is true so the new key actually lands in project.godot rather
# than being re-registered on every editor reload.
var _settings_dirty: bool = false


func _init() -> void:
	# STOP rather than IGNORE so the widget catches mouse clicks (used
	# to open the settings dialog). Children that shouldn't intercept
	# (Label / TextureRect / Panel) set IGNORE individually.
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Don't clip the oversized flame TextureRect's overflow. Default for
	# Control in Godot 4 is already false, but make it explicit so
	# theme overrides / future parents can't accidentally crop the flame.
	clip_contents = false


func _ready() -> void:
	_load_settings()
	_build()
	_apply_settings_to_visuals()


# Read every parameter from ProjectSettings, falling back to the
# `DEFAULT_*` constants when a key is absent. Registers default values
# on first read so the keys appear in Project Settings even before the
# user opens the in-dock settings dialog.
func _load_settings() -> void:
	color = _load_color("color", DEFAULT_COLOR)
	padding_x = _load_int("padding_x", DEFAULT_PADDING_X)
	padding_y = _load_int("padding_y", DEFAULT_PADDING_Y)
	flame_overflow_top = _load_int("flame_overflow_top", DEFAULT_FLAME_OVERFLOW_TOP)
	corner_radius = _load_int("corner_radius", DEFAULT_CORNER_RADIUS)
	outline_size = _load_int("outline_size", DEFAULT_OUTLINE_SIZE)
	font_size = _load_int("font_size", DEFAULT_FONT_SIZE)
	flame_speed = _load_int("flame_speed", DEFAULT_FLAME_SPEED)
	flame_enabled = _load_bool("flame_enabled", DEFAULT_FLAME_ENABLED)
	count_up_duration_ms = _load_int("count_up_duration_ms", DEFAULT_COUNT_UP_DURATION_MS)
	pulse_throttle_ms = _load_int("pulse_throttle_ms", DEFAULT_PULSE_THROTTLE_MS)
	bounce_peak_scale = _load_int("bounce_peak_scale", DEFAULT_BOUNCE_PEAK_SCALE)
	bounce_duration_ms = _load_int("bounce_duration_ms", DEFAULT_BOUNCE_DURATION_MS)
	bounce_rotation_deg = _load_int("bounce_rotation_deg", DEFAULT_BOUNCE_ROTATION_DEG)
	quiver_amount = _load_int("quiver_amount", DEFAULT_QUIVER_AMOUNT)
	# Persist any newly-registered defaults so they survive editor
	# reload. Skipped when nothing was registered (steady state) to
	# avoid an unnecessary project.godot rewrite each dock build.
	if _settings_dirty:
		_settings_dirty = false
		ProjectSettings.save()


func _load_color(key: String, default_value: Color) -> Color:
	var full_key: String = SETTING_PREFIX + key
	if not ProjectSettings.has_setting(full_key):
		ProjectSettings.set_setting(full_key, default_value)
		ProjectSettings.set_initial_value(full_key, default_value)
		_settings_dirty = true
		return default_value
	var v = ProjectSettings.get_setting(full_key, default_value)
	return v if v is Color else default_value


func _load_int(key: String, default_value: int) -> int:
	var full_key: String = SETTING_PREFIX + key
	if not ProjectSettings.has_setting(full_key):
		ProjectSettings.set_setting(full_key, default_value)
		ProjectSettings.set_initial_value(full_key, default_value)
		_settings_dirty = true
		return default_value
	return int(ProjectSettings.get_setting(full_key, default_value))


func _load_bool(key: String, default_value: bool) -> bool:
	var full_key: String = SETTING_PREFIX + key
	if not ProjectSettings.has_setting(full_key):
		ProjectSettings.set_setting(full_key, default_value)
		ProjectSettings.set_initial_value(full_key, default_value)
		_settings_dirty = true
		return default_value
	return bool(ProjectSettings.get_setting(full_key, default_value))


# Push the live values onto the visual nodes. Called after _build, and
# again whenever the settings dialog changes one of the parameters.
func _apply_settings_to_visuals() -> void:
	if _flame_rect != null:
		_flame_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_flame_rect.offset_left = 0
		_flame_rect.offset_right = 0
		_flame_rect.offset_top = -flame_overflow_top
		_flame_rect.offset_bottom = 0
		# Master switch — hide the whole flame layer when disabled. The
		# digits + body still render normally; just no shader pass.
		_flame_rect.visible = flame_enabled
	if _body_style != null:
		_body_style.corner_radius_top_left = corner_radius
		_body_style.corner_radius_top_right = corner_radius
		_body_style.corner_radius_bottom_left = corner_radius
		_body_style.corner_radius_bottom_right = corner_radius
		if _body_panel != null:
			_body_panel.add_theme_stylebox_override("panel", _body_style)
	# Push current visual + animation params onto the digit overlay.
	# Overlay reads them on every _draw, so a settings change is
	# reflected on the next frame without explicit invalidation.
	if _digit_overlay != null:
		_digit_overlay.pixel_font = _resolve_digit_font()
		_digit_overlay.glyph_size = font_size if font_size > 0 else 16
		_digit_overlay.outline_size_px = outline_size
		_digit_overlay.fill_color = Color(1.0, 1.0, 1.0, 1.0)
		_digit_overlay.outline_color = Color(0.0, 0.0, 0.0, 0.95)
		_digit_overlay.pulse_peak_scale_pct = bounce_peak_scale
		_digit_overlay.pulse_duration_ms = bounce_duration_ms
		_digit_overlay.pulse_rotation_deg = bounce_rotation_deg
		_digit_overlay.quiver_amount_pct = quiver_amount
		_digit_overlay.queue_redraw()
		_digit_overlay.update_minimum_size()
	# Single-colour theme: body and flame both fed `color`. The shader
	# derives flame highlights internally by lightening this colour
	# toward a warm-white target, so they harmonise without needing a
	# separate flame-colour uniform.
	if _body_style != null:
		_body_style.bg_color = color
		if _body_panel != null:
			_body_panel.add_theme_stylebox_override("panel", _body_style)
	if _shader_material != null:
		_shader_material.set_shader_parameter("ColorParameter", color)
		# `flame_speed` is stored as percent for slider friendliness;
		# the shader expects a float multiplier on TIME (1.0 = base).
		_shader_material.set_shader_parameter("flame_speed", float(flame_speed) / 100.0)
		# `flame_intensity` is now token-driven (see `_compute_flame_intensity`).
		# Seed from the last known total so a settings tweak doesn't
		# briefly drop the flame back to the shader's uniform default
		# while waiting for the next state-driven refresh.
		_shader_material.set_shader_parameter(
			"flame_intensity",
			_compute_flame_intensity(max(_last_total, 0))
		)
	update_minimum_size()
	_push_geometry_uniforms()


# Tell the shader where the body's top edge sits in the flame rect's
# UV.y, so flame_top_edge can scale with the user's overflow_top
# setting (otherwise small overflow_top values push the wavy flame top
# behind the body and leave nothing visible). Pushed whenever settings
# change AND whenever the rect actually resizes.
func _push_geometry_uniforms() -> void:
	if _shader_material == null or _flame_rect == null:
		return
	var rect_size: Vector2 = _flame_rect.size
	if rect_size.x <= 0.0 or rect_size.y <= 0.0:
		# Layout hasn't run yet — values would be infinite. The
		# `resized` signal will call this again with real size.
		return
	# Body covers UV.y in [body_top_uvy, 1.0]. body's top in flame-rect
	# pixel coords is at flame_overflow_top (since the rect extends
	# overflow_top pixels above the widget; body starts at the widget's
	# top, which is at rect-pixel-y = overflow_top). The shader uses
	# this to scale the wavy flame top into the overflow region so it
	# stays visible regardless of the user's overflow_top setting.
	var body_top_uvy: float = float(flame_overflow_top) / rect_size.y
	# corner_radius is in PIXELS (StyleBoxFlat). Normalise to UV space
	# separately on each axis so the shader's corner-fill stage matches
	# the body's CIRCULAR pixel-space corner regardless of rect aspect.
	var corner_radius_uv: Vector2 = Vector2(
		float(corner_radius) / rect_size.x,
		float(corner_radius) / rect_size.y,
	)
	_shader_material.set_shader_parameter("body_top_uvy", body_top_uvy)
	_shader_material.set_shader_parameter("corner_radius_uv", corner_radius_uv)


# Click → emit `settings_requested`. Dock catches and pops the dialog.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			settings_requested.emit()
			accept_event()


func _build() -> void:
	# Layer order matters (Balatro look): flame TextureRect (back) →
	# Panel (mid, covers the flame's base) → Label (front). Only the
	# flame's UPPER tips that overflow past the widget's top edge end up
	# visible — the rest is hidden behind the solid Panel, matching
	# Balatro's "card on fire from below" aesthetic.
	# HBoxContainer parent measures `self`'s minimum_size, which our
	# `_get_minimum_size` overrides to track the Label + padding.
	_flame_rect = TextureRect.new()
	_flame_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# `STRETCH_SCALE` makes the 1x1 placeholder texture stretch over
	# the entire rect — without it the shader would only run on a
	# single pixel quad in the rect centre. UVs span 0..1 across the
	# rect regardless of underlying texture size.
	_flame_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_flame_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Anchor: full rect, with negative top offset so the flame visibly
	# licks ABOVE the widget's nominal top edge. Sides overflow a bit
	# too so the flame's base widens past the text without looking
	# clipped at the corners. The flame rect EXTENDS BEHIND the body
	# panel — the body covers its lower half visually, but the body's
	# rounded top corners are transparent cutouts that would show the
	# flame through them. The shader masks those corner cutouts so the
	# silhouette stays clean (see `body_top_uvy` / `corner_radius_uv`
	# uniforms below + the corner_mask in token_flame.gdshader).
	_flame_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flame_rect.offset_left = 0
	_flame_rect.offset_right = 0
	_flame_rect.offset_top = -flame_overflow_top
	_flame_rect.offset_bottom = 0
	# Shader needs SOMETHING to sample for UV — a 1x1 white image is
	# enough; the flame appearance comes from the bound noise uniform.
	var blank := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	blank.fill(Color.WHITE)
	_flame_rect.texture = ImageTexture.create_from_image(blank)
	_shader_material = ShaderMaterial.new()
	_shader_material.shader = load(SHADER_PATH)
	# No noise-texture binding: the Balatro-port shader generates its
	# own pseudonoise procedurally via 5-iteration domain warp.
	_shader_material.set_shader_parameter("ColorParameter", color)
	_flame_rect.material = _shader_material
	# Re-push body_top_uvy whenever the rect actually resizes — the
	# UV-normalised body position depends on the live pixel size.
	_flame_rect.resized.connect(_push_geometry_uniforms)
	add_child(_flame_rect)

	_body_panel = Panel.new()
	_body_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_body_style = StyleBoxFlat.new()
	_body_style.bg_color = color
	_body_style.corner_radius_top_left = corner_radius
	_body_style.corner_radius_top_right = corner_radius
	_body_style.corner_radius_bottom_left = corner_radius
	_body_style.corner_radius_bottom_right = corner_radius
	_body_panel.add_theme_stylebox_override("panel", _body_style)
	add_child(_body_panel)

	# Custom-draw digit overlay — Balatro-style manual glyph placement.
	# Anchored to widget's full rect; renders each character via
	# Font.draw_string with its own per-letter transform. Added LAST so
	# it draws on top of body_panel + flame_rect (Godot draws siblings
	# in child order, last child = topmost).
	_digit_overlay = DigitOverlayScript.new()
	_digit_overlay.tooltip_text = "Total tokens consumed by Godette in this project"
	_digit_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_digit_overlay)
	# Seed with "0" so min_size resolves before bind_state runs.
	_digit_overlay.set_text("0")


# Plug the dock's shared GodetteState. Widget reads cumulative counters
# off `_state.total_*_tokens` and listens to `total_tokens_changed`.
func bind_state(p_state) -> void:
	if _state == p_state:
		return
	# Disconnect previous bindings first so we don't double-fire if
	# bind_state is ever called twice.
	if _state != null:
		if _state.has_signal("total_tokens_changed") \
		and _state.total_tokens_changed.is_connected(_on_total_tokens_changed):
			_state.total_tokens_changed.disconnect(_on_total_tokens_changed)
		if _state.has_signal("session_busy_changed") \
		and _state.session_busy_changed.is_connected(_on_session_busy_changed):
			_state.session_busy_changed.disconnect(_on_session_busy_changed)
	_state = p_state
	if _state != null:
		if _state.has_signal("total_tokens_changed"):
			_state.total_tokens_changed.connect(_on_total_tokens_changed)
		if _state.has_signal("session_busy_changed"):
			_state.session_busy_changed.connect(_on_session_busy_changed)
	# `token_pulse_requested` from the dock is intentionally NOT bound
	# here. Pulses are driven entirely by the count-up animation in
	# `_process` — number ramp ticks and pulses fire together at
	# pulse_throttle_ms intervals. Letting token events directly
	# trigger pulses would queue extras out-of-sync with the ramp.
	_refresh()


func _on_total_tokens_changed() -> void:
	_refresh()


# Turn-state change for any session. When a session flips OUT of busy
# (= `prompt_finished` arrived) AND the count-up still has remaining
# diff (couldn't finish within count_up_duration_ms): snap straight
# to the authoritative target, fire one final pulse, and stop. We
# don't drag out an exponential lerp — the user said "if the duration
# wasn't enough, just one final pulse and end".
#
# If displayed already equals target (animation finished naturally
# before turn end), do nothing.
func _on_session_busy_changed(_idx: int, busy: bool) -> void:
	if busy:
		return
	if _digit_overlay == null:
		return
	if abs(float(_target_total) - _displayed_total) < 0.5:
		return  # already at target
	_displayed_total = float(_target_total)
	_digit_overlay.set_text(_format_short(_target_total))
	update_minimum_size()
	_trigger_pulse()


func _refresh() -> void:
	if _state == null or _digit_overlay == null:
		return
	var input_tokens: int = int(_state.total_input_tokens)
	var output_tokens: int = int(_state.total_output_tokens)
	var cache_create: int = int(_state.total_cache_creation_tokens)
	# Codex bucket is undifferentiated tokens (no input/output/cache split
	# from codex-acp's wire). Summed into the displayed total so the user
	# sees one cumulative figure across all adapters.
	var codex_tokens: int = int(_state.total_codex_tokens)
	# Aider / Cline-style headline: cache_read tokens are 10%-billed by
	# Anthropic's prompt cache, so summing them in inflates the number
	# 5-10× without reflecting actual cost. They stay tracked in state,
	# they just aren't part of the displayed total.
	var total: int = input_tokens + output_tokens + cache_create + codex_tokens
	# Token-driven flame intensity — burn brighter / bigger as more
	# tokens accumulate. Auto-update each refresh so the flame grows
	# in lockstep with consumption.
	if _shader_material != null:
		_shader_material.set_shader_parameter(
			"flame_intensity", _compute_flame_intensity(total)
		)
	# First refresh after bind_state / disk-restore: snap directly to
	# the loaded total without any animation or pulse. Subsequent
	# refreshes set a new target and let `_process` lerp the displayed
	# value toward it (with periodic + final pulses).
	if _last_total < 0:
		_last_total = total
		_target_total = total
		_displayed_total = float(total)
		_digit_overlay.set_text(_format_short(total))
		update_minimum_size()
		return
	_last_total = total
	_target_total = total
	# Mid-stream telemetry → linear count-up. Recompute the per-second
	# rate so the new gap closes in count_up_duration_ms. A retarget
	# part-way through just resets this rate against the new diff —
	# the displayed value continues moving smoothly toward the latest
	# target without a visible discontinuity.
	var diff_for_rate: float = float(_target_total) - _displayed_total
	var duration_sec: float = max(float(count_up_duration_ms) / 1000.0, 0.1)
	if abs(diff_for_rate) >= 0.5:
		_linear_rate = diff_for_rate / duration_sec


# Map cumulative token consumption to Balatro's flame `amount` (0..10),
# tuned so 1B tokens hits the max. Curve:
#
#   0 tokens     → 0    (no flame on a fresh install)
#   1k tokens    → 3.3
#   10k tokens   → 4.4
#   100k tokens  → 5.6
#   1M tokens    → 6.7
#   10M tokens   → 7.8
#   100M tokens  → 8.9
#   1B+ tokens   → 10   (max, clamped — roaring inferno)
#
# Each 10× growth in tokens adds ~1.11 intensity; logarithmic was the
# only sensible choice — token totals span ~9 orders of magnitude
# across users, and a linear mapping would either leave new users
# with no flame or saturate everyone after their first turn.
func _compute_flame_intensity(total: int) -> float:
	var t: float = float(max(total, 0))
	# Scaled log_10: log_10(1e9) = 9, multiplied by 10/9 lands 1B
	# exactly on intensity 10. The +1 inside the log dodges log(0)
	# when total=0 (raw becomes exactly 0 there).
	var raw: float = (10.0 / 9.0) * log(t + 1.0) / log(10.0)
	return clampf(raw, 0.0, 10.0)


# Trigger a Balatro-style pulse on the digit overlay. The actual
# triangle-wave evaluation lives in the overlay's `_draw()` — we just
# poke its start-time stamp here.
func _trigger_pulse() -> void:
	if _digit_overlay == null:
		return
	_digit_overlay.trigger_pulse()


# Per-frame: lerp `_displayed_total` toward `_target_total` (set by
# `_refresh` whenever new token telemetry arrives). Drives both the
# slot-machine count-up animation and a sequence of pulses while the
# count-up is in progress — gives continuous visual activity even
# though the underlying ACP `usage_update` notifications are sparse.
func _process(_delta: float) -> void:
	if _digit_overlay == null:
		return
	var diff: float = float(_target_total) - _displayed_total
	if abs(diff) < 0.5:
		# Already at target — nothing to do.
		return

	# LINEAR count-up: tick-based. Number advances ONLY
	# at pulse-throttle boundaries, and each tick fires both a number
	# step AND a pulse — so the count-up reads as "click-clack…"
	# slot-machine progress with each click visibly synced to a pulse.
	#
	# Number of ticks per retarget ≈ count_up_duration_ms / pulse_throttle_ms.
	# Step per tick = linear_rate × throttle_seconds.
	var now: int = Time.get_ticks_msec()
	if now - _last_anim_pulse_ms < pulse_throttle_ms:
		return  # holding between ticks
	_last_anim_pulse_ms = now
	var step: float = _linear_rate * (float(pulse_throttle_ms) / 1000.0)
	# Clamp the step so we don't overshoot the target on the final tick.
	if step > 0.0 and step > diff:
		step = diff
	elif step < 0.0 and step < diff:
		step = diff
	var new_displayed: float = _displayed_total + step
	var snapped: bool = abs(float(_target_total) - new_displayed) < 0.5
	if snapped:
		new_displayed = float(_target_total)
	_displayed_total = new_displayed
	_digit_overlay.set_text(_format_short(int(round(_displayed_total))))
	update_minimum_size()
	_trigger_pulse()


# Debug-trigger the pulse without an actual token increment. Bound to
# Ctrl+` below; useful for previewing the animation while tweaking
# `bounce_peak_scale` / `bounce_duration_ms` / `bounce_rotation_deg`
# from the settings dialog.
func debug_play_bounce() -> void:
	_trigger_pulse()


# Listen for the debug shortcut while the dock is visible. Editor
# unhandled-key path so we don't fight focused inputs (composer, etc).
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event
	if not key_event.pressed or key_event.echo:
		return
	# Ctrl+` (backtick / grave accent) — KEY_QUOTELEFT in Godot 4.
	if key_event.keycode == KEY_QUOTELEFT \
	and key_event.ctrl_pressed \
	and not key_event.alt_pressed \
	and not key_event.shift_pressed:
		_trigger_pulse()
		get_viewport().set_input_as_handled()


# Abbreviated count with 2 decimals at K/M/B ranges. Two decimals
# rather than one so the digit ticks are visible during the slow
# count-up ramp — at one decimal a single step of 30-50 tokens often
# rounds to the same "100.0K" string for 5+ ticks in a row, and the
# user sees the pulses but no number motion. With two decimals every
# ~10 token change updates the display, keeping the count-up visibly
# alive throughout the animation window.
static func _format_short(n: int) -> String:
	if n < 1000:
		return str(n)
	if n < 1_000_000:
		return "%.2fK" % (float(n) / 1000.0)
	if n < 1_000_000_000:
		return "%.2fM" % (float(n) / 1_000_000.0)
	return "%.2fB" % (float(n) / 1_000_000_000.0)


# A plain Control doesn't inherit children's min_size automatically
# (only Containers do). Forward the overlay's natural glyph-run size
# plus padding so the dock-header HBox allocates room for both the
# digits and the card border.
func _get_minimum_size() -> Vector2:
	if _digit_overlay == null:
		return Vector2.ZERO
	return _digit_overlay.get_minimum_size() + Vector2(padding_x * 2, padding_y * 2)


# Resolve which font the overlay should render with. Prefer m6x11plus
# if the user has dropped the .ttf into fonts/; otherwise fall back to
# the editor theme's default font so the widget still renders text.
func _resolve_digit_font() -> Font:
	if ResourceLoader.exists(FONT_PATH):
		var pixel: Font = load(FONT_PATH)
		if pixel != null:
			return pixel
	# Theme fallback — ThemeDB exposes the global default font that
	# editor controls use when no override is specified.
	return ThemeDB.fallback_font
