@tool
class_name GodetteComposerContext
extends RefCounted
#
# Composer attachment utilities. Since the composer moved to inline chips
# rendered inside the TextEdit (see composer_prompt_input.gd and
# composer_chip_overlay.gd), this module no longer owns any UI — it's a
# home for the pure transforms that both producer (the dock, when it
# appends attachments) and consumer (prompt-block build at send time)
# agree on.
#
# Kept as a class so the existing `const ComposerContextScript =
# preload(...)` call sites in agent_dock.gd keep working without renaming.

# Chip label rules. Pure files / scenes collapse to their basename so a
# long absolute path doesn't blow out the chip; pasted images use a fixed
# "Image" word because the generated filename is a timestamped blob no
# one wants to read; other kinds fall through to whatever label the dock
# supplied.
static func display_label_for_attachment(attachment: Dictionary) -> String:
	var raw_label: String = str(attachment.get("label", "unnamed"))
	var kind: String = str(attachment.get("kind", ""))
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


static func tooltip_for_attachment(attachment: Dictionary) -> String:
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
	return "\n".join(parts)


static func _basename_of(path: String) -> String:
	var normalized := path.replace("\\", "/").trim_suffix("/")
	var slash_index := normalized.rfind("/")
	if slash_index < 0:
		return normalized
	return normalized.substr(slash_index + 1)


# --- Static prompt-block builder ----------------------------------------
# Pure transform from (prompt, attachments) to an ACP-ready prompt block
# array. Called directly by the dock's `_send_prompt`; kept static so it
# has no hidden dependency on a composer instance.
#
# File and scene attachments become `resource_link` blocks — the adapter
# can resolve and read them itself. Node attachments stay as `text` blocks
# with a short structured summary because nodes don't have a URI the
# adapter can fetch.
#
# Regular file content is deliberately NOT embedded. An earlier version
# flattened up to 32 KB of every attached file into the visible prompt body,
# which both ballooned the user-visible "You said" bubble and duplicated
# content the adapter can read on demand via the resource_link URI.
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
				# Send as resource_link, same as plain file attachments.
				# Inline base64 ImageContent is the spec-correct path for
				# vision but in practice: (a) claude-code-acp stdin chokes
				# past ~100 KB and the pipe goes dead with PeekNamedPipe
				# errors, (b) even when it doesn't, the adapter sometimes
				# still tries to route the image through `fs/read_text_file`
				# which is UTF-8-only. Until the adapter supports binary
				# reads or we find a reliable pipe-write path for large
				# base64 payloads, we accept that the model can't see the
				# pixels through this attachment — users can paste OCR
				# text or describe the image in prose when that matters.
				var image_path: String = str(attachment.get("path", ""))
				if image_path.is_empty():
					continue
				blocks.append({
					"type": "resource_link",
					"uri": _path_to_uri(image_path),
					"name": str(attachment.get("label", image_path))
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
				# Unknown kinds: fall back to a labelled text block rather
				# than dropping them silently. Keeps new attachment types
				# visible to the agent even before this builder knows about
				# them.
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
	var normalized := path
	# Collapse Godot resource paths to an absolute OS path before building
	# the final file URI.
	if path.begins_with("res://") or path.begins_with("user://"):
		normalized = ProjectSettings.globalize_path(path)
	normalized = normalized.replace("\\", "/")
	if normalized.begins_with("file://"):
		return normalized
	if normalized.begins_with("/"):
		return "file://%s" % normalized
	# Windows absolute path like C:/...
	return "file:///%s" % normalized
