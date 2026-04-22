@tool
class_name GodetteLoadingScanner
extends Control
#
# Knight Rider-style indeterminate progress strip. A bright cursor sweeps
# horizontally with sinusoidal easing; a short trail of dimmer afterimages
# follows behind, and a faint track runs along the full width so the control
# reads as active even when the cursor is near an edge.
#
# Used while a session is being loaded or a remote session is being created —
# the ACP call is in-flight and we have no determinate progress to show.
# Hidden when idle (controls its own _process via NOTIFICATION_VISIBILITY).

@export var color: Color = Color(0.55, 0.78, 1.0, 1.0)
@export var track_color: Color = Color(1.0, 1.0, 1.0, 0.05)
@export var light_width: float = 48.0
@export var cycle_seconds: float = 1.6
@export var trail_samples: int = 5
# Time gap between trail afterimages, expressed as a fraction of one cycle.
@export var trail_step_fraction: float = 0.02

var _phase: float = 0.0
var _elapsed: float = 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(0, 3)


func set_accent(accent_color: Color) -> void:
	color = accent_color
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		if is_visible_in_tree():
			_elapsed = 0.0
			set_process(true)
		else:
			set_process(false)


func _process(delta: float) -> void:
	_elapsed += delta
	if cycle_seconds > 0.0:
		while _elapsed >= cycle_seconds:
			_elapsed -= cycle_seconds
		_phase = _elapsed / cycle_seconds
	queue_redraw()


func _draw() -> void:
	var total_width: float = size.x
	var total_height: float = size.y
	if total_width <= 0.0 or total_height <= 0.0:
		return

	# Faint constant track so the widget remains perceptible near extremes.
	draw_rect(Rect2(Vector2.ZERO, size), track_color)

	var sweep_range: float = max(total_width - light_width, 0.0)

	# Draw trail first, head last, so the head always reads cleanly.
	for i in range(trail_samples, -1, -1):
		var sample_phase: float = _phase - float(i) * trail_step_fraction
		while sample_phase < 0.0:
			sample_phase += 1.0
		# Sinusoidal ease — classic Knight Rider sweep feel. Maps phase
		# 0..1 → position 0→1→0 with slow ends and fast middle.
		var t: float = 0.5 - 0.5 * cos(sample_phase * TAU)
		var x: float = t * sweep_range
		var falloff: float = 1.0 - float(i) / float(trail_samples + 1)
		var sample_color: Color = color
		sample_color.a = color.a * falloff * falloff
		draw_rect(Rect2(Vector2(x, 0.0), Vector2(light_width, total_height)), sample_color)
