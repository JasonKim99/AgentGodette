@tool
class_name GodetteComposerContext
extends HFlowContainer
#
# Composer context strip. Replaces the old flat ItemList with typed chips so
# each attachment is its own addressable UI element: kind tag, label, open-on-
# click, × remove button. Chips wrap to multiple rows via HFlowContainer when
# the dock is narrow.
#
# Ownership split with the dock:
#   - dock owns the attachment array (`sessions[i].attachments`).
#   - this control owns the chip rendering + emits intent signals.
#   - dock handles those signals by mutating storage and calling
#     `set_attachments(...)` again. No back-channel; no duplicated state.
#
# The static `build_prompt_blocks()` helper lives here too: it's a pure
# attachments→ACP-blocks transform, and keeping it next to the chip data
# shape means both sides evolve together.

signal attachment_remove_requested(key: String)
signal attachment_activated(key: String)

const CHIP_SEPARATION := 6
const REMOVE_GLYPH := "×"
const CHIP_ICON_SIZE := 16

var _attachments: Array = []
# Dock pushes the editor theme's base color in here so chip panels track light
# / dark editor themes without this module having to reach into EditorInterface
# on its own.
var _chip_base_color: Color = Color(0.22, 0.24, 0.28, 1.0)


func _init() -> void:
	add_theme_constant_override("h_separation", CHIP_SEPARATION)
	add_theme_constant_override("v_separation", CHIP_SEPARATION)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_PASS


func set_attachments(attachments: Array) -> void:
	_attachments = attachments.duplicate()
	_rebuild_chips()


func set_chip_base_color(color: Color) -> void:
	if _chip_base_color == color:
		return
	_chip_base_color = color
	if not _attachments.is_empty():
		_rebuild_chips()


func has_attachments() -> bool:
	return not _attachments.is_empty()


func _rebuild_chips() -> void:
	for child in get_children():
		child.queue_free()
	for attachment_variant in _attachments:
		if typeof(attachment_variant) != TYPE_DICTIONARY:
			continue
		add_child(_build_chip(attachment_variant))


func _build_chip(attachment: Dictionary) -> Control:
	var key: String = str(attachment.get("key", ""))
	var kind: String = str(attachment.get("kind", "context"))
	var label: String = _safe_text(_chip_display_label(attachment, kind))
	# The dock resolves the editor-theme icon for this attachment and
	# stashes it under `_icon_texture` before handing us the enriched
	# dictionary. Underscore prefix marks it as a runtime-only field so
	# it never gets confused with persisted attachment data.
	var icon_texture: Texture2D = attachment.get("_icon_texture", null)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _chip_style())
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.tooltip_text = _chip_tooltip(attachment)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_child(row)

	if icon_texture != null:
		var icon := TextureRect.new()
		icon.texture = icon_texture
		icon.custom_minimum_size = Vector2(CHIP_ICON_SIZE, CHIP_ICON_SIZE)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(icon)

	# The label is clickable — activating the chip is the "open target" intent
	# (open file, focus node, etc). Flat Button, not LinkButton: Godot 4's
	# LinkButton inherits from BaseButton (not Button), so it doesn't expose
	# `clip_text` / `text_overrun_behavior`, and its internal relative-path
	# lookups can trip `rp_child is null` errors when rebuilt rapidly.
	#
	# No SIZE_EXPAND_FILL here: HFlowContainer gives stretch behaviour that
	# makes the Button try to span the whole row, which then collides with
	# `clip_text` and ends up truncating the label to zero width. Natural
	# sizing keeps the chip as wide as its displayed text — long names wrap
	# the whole chip to the next row instead.
	var open_button := Button.new()
	open_button.text = label
	open_button.flat = true
	open_button.focus_mode = Control.FOCUS_NONE
	open_button.tooltip_text = _chip_tooltip(attachment)
	open_button.pressed.connect(_on_chip_activate.bind(key))
	open_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.add_child(open_button)

	var remove_button := Button.new()
	remove_button.text = REMOVE_GLYPH
	remove_button.flat = true
	remove_button.focus_mode = Control.FOCUS_NONE
	remove_button.tooltip_text = "Remove this context"
	remove_button.custom_minimum_size = Vector2(18, 18)
	remove_button.pressed.connect(_on_chip_remove.bind(key))
	row.add_child(remove_button)

	return panel


func _chip_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = _chip_base_color
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 8
	style.content_margin_right = 6
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	return style


func _chip_display_label(attachment: Dictionary, kind: String) -> String:
	# Match Zed's chip display: short, recognisable labels. Files / scenes
	# show basename; pasted images collapse to just "Image" (the filename
	# is a timestamped clip_… blob nobody wants to read — full path lives
	# in the tooltip for disambiguation). Non-path attachments fall
	# through to whatever label the dock populated.
	var raw_label: String = str(attachment.get("label", "unnamed"))
	match kind:
		"file":
			var path: String = str(attachment.get("path", raw_label))
			return _basename_of(path) if not path.is_empty() else raw_label
		"scene":
			var scene_path: String = str(attachment.get("scene_path", ""))
			if not scene_path.is_empty():
				return _basename_of(scene_path)
			return raw_label
		"image":
			return "Image"
		_:
			return raw_label


static func _basename_of(path: String) -> String:
	var normalized := path.replace("\\", "/").trim_suffix("/")
	var slash_index := normalized.rfind("/")
	if slash_index < 0:
		return normalized
	return normalized.substr(slash_index + 1)


func _chip_tooltip(attachment: Dictionary) -> String:
	var parts: Array = []
	var kind: String = str(attachment.get("kind", ""))
	if not kind.is_empty():
		parts.append("[%s]" % kind)
	var label: String = str(attachment.get("label", ""))
	if not label.is_empty():
		parts.append(label)
	if attachment.has("path"):
		parts.append("Path: %s" % str(attachment.get("path", "")))
	if attachment.has("scene_path") and not str(attachment.get("scene_path", "")).is_empty():
		parts.append("Scene: %s" % str(attachment.get("scene_path", "")))
	if attachment.has("relative_node_path"):
		parts.append("Node: %s" % str(attachment.get("relative_node_path", "")))
	return _safe_text("\n".join(parts))


func _on_chip_activate(key: String) -> void:
	emit_signal("attachment_activated", key)


func _on_chip_remove(key: String) -> void:
	emit_signal("attachment_remove_requested", key)


static func _safe_text(text: String) -> String:
	# Final-mile NUL strip for anything we're about to hand to a Label /
	# tooltip. Matches the dock's helper; duplicated so this module has no
	# cross-file dependency.
	if text.is_empty():
		return text
	var length: int = text.length()
	var first_nul: int = -1
	for i in range(length):
		if text.unicode_at(i) == 0:
			first_nul = i
			break
	if first_nul < 0:
		return text
	var out := text.substr(0, first_nul)
	for i in range(first_nul + 1, length):
		var cp: int = text.unicode_at(i)
		if cp != 0:
			out += String.chr(cp)
	return out


# --- Static prompt-block builder ----------------------------------------
# Pure transform from (prompt, attachments) to an ACP-ready prompt block
# array. Kept static so it has no hidden dependency on a composer instance;
# the dock's `_send_prompt` calls it directly.
#
# Output shape (matches what adapters expect per ACP spec):
#   [
#     {"type": "text", "text": "<user prompt>"},
#     {"type": "resource_link", "uri": "file:///abs/path", "name": "rel/path"},
#     ... more blocks per attachment ...
#   ]
#
# File and scene attachments become `resource_link` blocks — the adapter
# can resolve and read them itself. Node attachments stay as `text` blocks
# with a short structured summary, because nodes don't have a URI the
# adapter can fetch.
#
# Raw file content is deliberately NOT embedded. The previous code
# flattened up to 32 KB of every attached file into the visible prompt
# body, which both ballooned the user-visible "You said" bubble and
# duplicated content the adapter can read on demand via the resource_link
# URI.
static func build_prompt_blocks(prompt: String, attachments: Array) -> Array:
	var blocks: Array = []
	if not prompt.is_empty():
		blocks.append({"type": "text", "text": prompt})

	for attachment_variant in attachments:
		if typeof(attachment_variant) != TYPE_DICTIONARY:
			continue
		var attachment: Dictionary = attachment_variant
		var kind: String = str(attachment.get("kind", ""))
		match kind:
			"image":
				# Pasted-from-clipboard images are on-disk PNGs under
				# user://godette_attachments/. Inline them as ACP image
				# blocks (base64 bytes + mimeType) so the adapter can ship
				# them to the model in the same turn without needing
				# filesystem-read permission.
				var image_path: String = str(attachment.get("path", ""))
				if image_path.is_empty():
					continue
				var image_bytes: PackedByteArray = FileAccess.get_file_as_bytes(image_path)
				if image_bytes.size() == 0:
					continue
				blocks.append({
					"type": "image",
					"data": Marshalls.raw_to_base64(image_bytes),
					"mimeType": "image/png"
				})
			"file":
				var path: String = str(attachment.get("path", ""))
				if path.is_empty():
					continue
				blocks.append({
					"type": "resource_link",
					"uri": _path_to_uri(path),
					"name": str(attachment.get("label", path))
				})
			"scene":
				var scene_path: String = str(attachment.get("scene_path", ""))
				if not scene_path.is_empty():
					blocks.append({
						"type": "resource_link",
						"uri": _path_to_uri(scene_path),
						"name": str(attachment.get("label", scene_path))
					})
				var summary_text: String = str(attachment.get("summary", ""))
				if not summary_text.is_empty():
					blocks.append({
						"type": "text",
						"text": "Scene outline:\n%s" % summary_text
					})
			"node":
				var node_lines: Array = []
				node_lines.append("Attached node: %s" % str(attachment.get("label", "node")))
				var relative_path: String = str(attachment.get("relative_node_path", ""))
				if not relative_path.is_empty():
					node_lines.append("Path: %s" % relative_path)
				var scene_parent: String = str(attachment.get("scene_path", ""))
				if not scene_parent.is_empty():
					node_lines.append("Scene: %s" % scene_parent)
				var node_summary: String = str(attachment.get("summary", ""))
				if not node_summary.is_empty():
					node_lines.append(node_summary)
				blocks.append({
					"type": "text",
					"text": "\n".join(node_lines)
				})
			_:
				# Unknown kinds: fall back to a labelled text block rather than
				# dropping them silently. Keeps new attachment types visible
				# to the agent even before this builder knows about them.
				var fallback_label: String = str(attachment.get("label", ""))
				var fallback_summary: String = str(attachment.get("summary", ""))
				var fallback_text: String = fallback_label
				if not fallback_summary.is_empty():
					fallback_text = "%s\n%s" % [fallback_label, fallback_summary]
				if not fallback_text.is_empty():
					blocks.append({"type": "text", "text": fallback_text})

	if blocks.is_empty():
		blocks.append({"type": "text", "text": ""})
	return blocks


static func _path_to_uri(path: String) -> String:
	if path.is_empty():
		return ""
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path).replace("\\", "/")
	var normalized := path.replace("\\", "/")
	if normalized.begins_with("file://"):
		return normalized
	if normalized.begins_with("/"):
		return "file://%s" % normalized
	# Windows absolute path like C:/...
	return "file:///%s" % normalized
