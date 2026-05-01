@tool
class_name GodetteTokenFlameSettingsDialog
extends AcceptDialog

# Settings popup for the token flame widget. Click the widget in the
# dock header → dock pops one of these → user tweaks colours / padding
# / overflow sliders and sees the widget update live. Changes write
# straight to ProjectSettings (under `godette/token_flame/...`) so they
# persist across editor sessions.
#
# Lifecycle:
#   - Dock instantiates per click, calls `bind(widget)`, popups via
#     `popup_centered`. Dialog frees itself when closed (`hide` →
#     `queue_free`) so we don't leak hidden Windows on repeated opens.
#   - All edits are live-applied to the widget AND written to
#     ProjectSettings on change. There's no "Cancel and revert" — a
#     "Reset to defaults" button covers undo. Fits the "tweak until
#     happy" UX better than confirm/cancel.

const TokenFlameWidgetScript = preload("res://addons/godette_agent/token_flame_widget.gd")

# Settings whose effect is only visible during a pulse animation —
# changing them does nothing to the static widget unless we replay
# a pulse. Trigger one preview-pulse on each slider change so the
# user can see the new value's impact immediately.
const PULSE_PREVIEW_KEYS := [
	"bounce_peak_scale",
	"bounce_duration_ms",
	"bounce_rotation_deg",
]


var _widget: GodetteTokenFlameWidget


func _init() -> void:
	title = "Token Flame Settings"
	min_size = Vector2(420, 0)
	# AcceptDialog's "OK" button just dismisses; live changes are
	# already saved.
	get_ok_button().text = "Close"
	# Reset button gets added ONCE here. `_build()` only manages the
	# grid of color pickers / sliders, so rebuilding (after Reset)
	# doesn't duplicate this button.
	add_button("Reset to defaults", false, "reset")
	custom_action.connect(_on_custom_action)


func bind(p_widget: GodetteTokenFlameWidget) -> void:
	_widget = p_widget
	_build()


func _build() -> void:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 8)
	add_child(grid)

	# --- Master switch ------------------------------------------------------
	_add_bool_row(grid, "Show Flame", "flame_enabled", _widget.flame_enabled)

	# --- Colour picker ------------------------------------------------------
	# Single theme colour. Drives the card body directly; the shader
	# derives flame highlights from the same value internally.
	_add_color_row(grid, "Color", "color", _widget.color)

	# Visual separator between colours and dimensions.
	var sep1 := HSeparator.new()
	grid.add_child(sep1)
	var sep2 := HSeparator.new()
	grid.add_child(sep2)

	# --- Sliders ------------------------------------------------------------
	_add_int_row(grid, "Padding X", "padding_x", _widget.padding_x, 0, 30)
	_add_int_row(grid, "Padding Y", "padding_y", _widget.padding_y, 0, 30)
	# Flame Overflow · Top intentionally not exposed — locked to
	# DEFAULT_FLAME_OVERFLOW_TOP (= 60, the slider's previous max). The
	# Balatro-port shader looks best with maximum vertical room; finer
	# control via ProjectSettings → godette/token_flame/flame_overflow_top.
	_add_int_row(grid, "Corner Radius", "corner_radius", _widget.corner_radius, 0, 16)
	# Outline Size intentionally not exposed — locked to DEFAULT_OUTLINE_SIZE
	# (= 8). Tuned alongside DEFAULT_DIGIT_SPACING_OFFSET for the
	# Balatro-tight character spacing. Override via ProjectSettings →
	# godette/token_flame/outline_size.
	# Font Size intentionally not exposed — locked to DEFAULT_FONT_SIZE
	# (= 32, tuned for the m6x11plus pixel font + corner radius combo).
	# Override via ProjectSettings → godette/token_flame/font_size.
	_add_int_row(grid, "Flame Speed (%)", "flame_speed", _widget.flame_speed, 10, 300)
	# Flame Intensity is now token-driven (log_5 mapping in widget) — no
	# manual slider. See `_compute_flame_intensity`.
	_add_int_row(grid, "Bounce Peak (%)", "bounce_peak_scale", _widget.bounce_peak_scale, 150, 300)
	_add_int_row(grid, "Bounce Duration (ms)", "bounce_duration_ms", _widget.bounce_duration_ms, 100, 1000)
	_add_int_row(grid, "Count-up Duration (ms)", "count_up_duration_ms", _widget.count_up_duration_ms, 10000, 30000)
	_add_int_row(grid, "Pulse Throttle (ms)", "pulse_throttle_ms", _widget.pulse_throttle_ms, 50, 800)
	_add_int_row(grid, "Bounce Rotation (°)", "bounce_rotation_deg", _widget.bounce_rotation_deg, 0, 30)
	# Quiver Amount intentionally not exposed — locked to
	# DEFAULT_QUIVER_AMOUNT (= 0, off). The Balatro-style continuous
	# jitter clashes with the discrete pulse-on-update we use here;
	# advanced users can still flip it on via ProjectSettings →
	# godette/token_flame/quiver_amount.



func _add_color_row(grid: GridContainer, label_text: String, key: String, current: Color) -> void:
	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(lbl)

	var picker := ColorPickerButton.new()
	picker.color = current
	picker.custom_minimum_size = Vector2(160, 28)
	picker.color_changed.connect(_on_color_changed.bind(key))
	grid.add_child(picker)


func _add_bool_row(grid: GridContainer, label_text: String, key: String, current: bool) -> void:
	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(lbl)

	var checkbox := CheckBox.new()
	checkbox.button_pressed = current
	checkbox.toggled.connect(_on_bool_changed.bind(key))
	grid.add_child(checkbox)


func _add_int_row(grid: GridContainer, label_text: String, key: String, current: int, min_value: int, max_value: int) -> void:
	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(lbl)

	# Row container so slider + numeric readout sit side by side.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = 1
	slider.value = current
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(140, 0)

	var readout := Label.new()
	readout.text = str(current)
	readout.custom_minimum_size = Vector2(28, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	slider.value_changed.connect(_on_int_changed.bind(key, readout))
	row.add_child(slider)
	row.add_child(readout)
	grid.add_child(row)


func _on_color_changed(value: Color, key: String) -> void:
	if _widget == null:
		return
	_widget.set(key, value)
	_widget._apply_settings_to_visuals()
	ProjectSettings.set_setting(TokenFlameWidgetScript.SETTING_PREFIX + key, value)
	# Persist to project.godot — set_setting alone only updates the
	# in-memory copy, which is lost on editor reload.
	ProjectSettings.save()


func _on_int_changed(value: float, key: String, readout: Label) -> void:
	if _widget == null:
		return
	var int_value: int = int(value)
	readout.text = str(int_value)
	_widget.set(key, int_value)
	_widget._apply_settings_to_visuals()
	ProjectSettings.set_setting(TokenFlameWidgetScript.SETTING_PREFIX + key, int_value)
	ProjectSettings.save()
	# Live preview: bounce-related sliders are invisible without a
	# pulse to demo them on, so kick one off whenever the user drags.
	# Overlay's queue=1 means rapid drag → at most one queued
	# preview pulse, so we don't backlog.
	if key in PULSE_PREVIEW_KEYS and _widget.has_method("debug_play_bounce"):
		_widget.debug_play_bounce()


func _on_bool_changed(value: bool, key: String) -> void:
	if _widget == null:
		return
	_widget.set(key, value)
	_widget._apply_settings_to_visuals()
	ProjectSettings.set_setting(TokenFlameWidgetScript.SETTING_PREFIX + key, value)
	ProjectSettings.save()


func _on_custom_action(action: StringName) -> void:
	if action == "reset":
		_on_reset_pressed()


func _on_reset_pressed() -> void:
	if _widget == null:
		return
	# Restore each tunable to its DEFAULT_*, applying live and writing
	# back to ProjectSettings. Then rebuild the dialog UI so sliders /
	# pickers reflect the reset values.
	var defaults := {
		"color": TokenFlameWidgetScript.DEFAULT_COLOR,
		"padding_x": TokenFlameWidgetScript.DEFAULT_PADDING_X,
		"padding_y": TokenFlameWidgetScript.DEFAULT_PADDING_Y,
		"flame_overflow_top": TokenFlameWidgetScript.DEFAULT_FLAME_OVERFLOW_TOP,
		"corner_radius": TokenFlameWidgetScript.DEFAULT_CORNER_RADIUS,
		"outline_size": TokenFlameWidgetScript.DEFAULT_OUTLINE_SIZE,
		"font_size": TokenFlameWidgetScript.DEFAULT_FONT_SIZE,
		"flame_speed": TokenFlameWidgetScript.DEFAULT_FLAME_SPEED,
		"flame_enabled": TokenFlameWidgetScript.DEFAULT_FLAME_ENABLED,
		"bounce_peak_scale": TokenFlameWidgetScript.DEFAULT_BOUNCE_PEAK_SCALE,
		"bounce_duration_ms": TokenFlameWidgetScript.DEFAULT_BOUNCE_DURATION_MS,
		"bounce_rotation_deg": TokenFlameWidgetScript.DEFAULT_BOUNCE_ROTATION_DEG,
		"count_up_duration_ms": TokenFlameWidgetScript.DEFAULT_COUNT_UP_DURATION_MS,
		"pulse_throttle_ms": TokenFlameWidgetScript.DEFAULT_PULSE_THROTTLE_MS,
		"quiver_amount": TokenFlameWidgetScript.DEFAULT_QUIVER_AMOUNT,
	}
	for key in defaults:
		var v = defaults[key]
		_widget.set(key, v)
		ProjectSettings.set_setting(TokenFlameWidgetScript.SETTING_PREFIX + key, v)
	# Flush to project.godot so the reset survives editor reload — without
	# this, set_setting only mutates the in-memory copy and the next
	# project load reads the old persisted values back.
	ProjectSettings.save()
	_widget._apply_settings_to_visuals()
	# Rebuild grid so the controls show the reset values.
	for child in get_children():
		if child is GridContainer:
			child.queue_free()
	# Defer because queue_free runs end-of-frame; otherwise the new
	# grid would be added alongside the about-to-be-freed one.
	call_deferred("_build")
