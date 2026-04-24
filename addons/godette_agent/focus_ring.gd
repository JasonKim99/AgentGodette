@tool
extends PanelContainer
class_name GodetteFocusRing

# Marching-ants animated border. When `_active` is true, draws a dashed
# stroke along the perimeter whose phase advances over time, producing a
# "rotating" effect. Used by the composer's Scene Tree focus indicator to
# signal that the currently selected node will be injected as context.

const DASH: float = 6.0
const GAP: float = 4.0
const LINE_WIDTH: float = 1.5
const SPEED_PX_PER_SEC: float = 24.0
const CORNER_RADIUS: float = 6.0
const ARC_SUBDIVS: int = 4

var _active: bool = false
var _phase: float = 0.0
var _stroke_color: Color = Color(0.45, 0.65, 1.0, 0.95)


func _ready() -> void:
	# Own stylebox is empty, but content margins keep the dashed stroke
	# from grazing the inner eye button / label glyphs.
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = 4.0
	sb.content_margin_right = 4.0
	sb.content_margin_top = 2.0
	sb.content_margin_bottom = 2.0
	add_theme_stylebox_override("panel", sb)
	# STOP (default) so clicks on the ring's empty area fire gui_input on
	# us — the whole frame is a hot zone for the eye toggle. The eye
	# Button child still consumes its own clicks because hit testing is
	# top-down.
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	set_process(false)


func set_active(active: bool) -> void:
	if _active == active:
		return
	_active = active
	set_process(active)
	if not active:
		_phase = 0.0
	queue_redraw()


func set_stroke_color(c: Color) -> void:
	if _stroke_color == c:
		return
	_stroke_color = c
	queue_redraw()


func _process(delta: float) -> void:
	_phase = fposmod(_phase + delta * SPEED_PX_PER_SEC, DASH + GAP)
	queue_redraw()


func _draw() -> void:
	if not _active:
		return
	if size.x <= 2.0 or size.y <= 2.0:
		return
	# Inset by half the stroke width so the line sits fully inside the rect.
	var inset: float = LINE_WIDTH * 0.5
	var rect := Rect2(Vector2(inset, inset), size - Vector2(inset * 2.0, inset * 2.0))
	var pts := _rounded_rect_perimeter(rect, CORNER_RADIUS, ARC_SUBDIVS)
	_draw_marching_dashes(pts, DASH, GAP, _phase)


func _rounded_rect_perimeter(rect: Rect2, radius: float, arc_subdiv: int) -> PackedVector2Array:
	# Walk the perimeter clockwise starting at the top edge just past the
	# top-left corner. Each corner becomes a quarter-arc with `arc_subdiv`
	# line segments so the marching-ants stroke bends smoothly around it.
	var r: float = min(radius, min(rect.size.x, rect.size.y) * 0.5)
	var x: float = rect.position.x
	var y: float = rect.position.y
	var w: float = rect.size.x
	var h: float = rect.size.y
	var pts := PackedVector2Array()

	# Top edge + top-right arc.
	pts.append(Vector2(x + r, y))
	pts.append(Vector2(x + w - r, y))
	_append_arc(pts, Vector2(x + w - r, y + r), r, -PI * 0.5, 0.0, arc_subdiv)

	# Right edge + bottom-right arc.
	pts.append(Vector2(x + w, y + h - r))
	_append_arc(pts, Vector2(x + w - r, y + h - r), r, 0.0, PI * 0.5, arc_subdiv)

	# Bottom edge + bottom-left arc.
	pts.append(Vector2(x + r, y + h))
	_append_arc(pts, Vector2(x + r, y + h - r), r, PI * 0.5, PI, arc_subdiv)

	# Left edge + top-left arc, closing back to the start point.
	pts.append(Vector2(x, y + r))
	_append_arc(pts, Vector2(x + r, y + r), r, PI, PI * 1.5, arc_subdiv)

	return pts


func _append_arc(pts: PackedVector2Array, center: Vector2, radius: float, start_angle: float, end_angle: float, subdiv: int) -> void:
	# Appends arc samples INCLUDING the end point but skipping the start —
	# the caller already placed the arc's start via the preceding edge,
	# so re-appending it would create a zero-length duplicate segment.
	for i in range(1, subdiv + 1):
		var t: float = float(i) / float(subdiv)
		var angle: float = start_angle + (end_angle - start_angle) * t
		pts.append(center + Vector2(cos(angle), sin(angle)) * radius)


func _draw_marching_dashes(pts: PackedVector2Array, dash: float, gap: float, offset: float) -> void:
	if pts.size() < 2:
		return
	var seg_count: int = pts.size() - 1
	var lens := PackedFloat32Array()
	var total: float = 0.0
	for i in range(seg_count):
		var l: float = (pts[i + 1] - pts[i]).length()
		lens.append(l)
		total += l
	if total <= 0.0:
		return

	var period: float = dash + gap
	# Start before zero so the first visible dash can be partial — that's
	# what makes the stroke look like it's moving around the perimeter.
	var t: float = -fposmod(offset, period)
	while t < total:
		var a: float = max(t, 0.0)
		var b: float = min(t + dash, total)
		if a < b:
			_draw_subpath(pts, lens, a, b)
		t += period


func _draw_subpath(pts: PackedVector2Array, lens: PackedFloat32Array, a_len: float, b_len: float) -> void:
	var cum: float = 0.0
	for i in range(lens.size()):
		var start: float = cum
		var end: float = cum + lens[i]
		cum = end
		if end <= a_len:
			continue
		if start >= b_len:
			break
		var seg_len: float = lens[i]
		if seg_len <= 0.0:
			continue
		var clip_a: float = max(a_len, start)
		var clip_b: float = min(b_len, end)
		var dir: Vector2 = (pts[i + 1] - pts[i]) / seg_len
		var p_a: Vector2 = pts[i] + dir * (clip_a - start)
		var p_b: Vector2 = pts[i] + dir * (clip_b - start)
		draw_line(p_a, p_b, _stroke_color, LINE_WIDTH, true)
