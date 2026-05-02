@tool
class_name GodetteEditorTheme
extends RefCounted

# Stateless helpers that pull fonts / colors / icons from the live Godot
# editor theme so widgets in the dock track the user's preferences (dark
# vs. light, custom font size, accent color). Extracted from agent_dock.gd
# (was `_editor_*` / `_tool_*` / `_apply_icon_button_theme` helpers) so the
# dock file shrinks and these can be reused by other plugin surfaces.
#
# All methods are static — no per-instance state. They lean on the
# `EditorInterface` singleton, which is available in any @tool script
# loaded by the editor; outside that context the lookups return sensible
# fallbacks rather than crashing.


# Tool-kind glyphs for the tool card header — Lucide set, matches the ACP
# kind enum one-to-one (`read` / `search` share one magnifier, `move` /
# `switch_mode` share one swap icon, per Zed's mapping in thread_view.rs).
const TOOL_ICON_SEARCH = preload("res://addons/godette_agent/icons/lucide--search.svg")
const TOOL_ICON_EDIT = preload("res://addons/godette_agent/icons/lucide--pencil.svg")
const TOOL_ICON_DELETE = preload("res://addons/godette_agent/icons/lucide--trash-2.svg")
const TOOL_ICON_SWAP = preload("res://addons/godette_agent/icons/lucide--arrow-left-right.svg")
const TOOL_ICON_TERMINAL = preload("res://addons/godette_agent/icons/lucide--terminal.svg")
const TOOL_ICON_THINK = preload("res://addons/godette_agent/icons/lucide--brain.svg")
const TOOL_ICON_WEB = preload("res://addons/godette_agent/icons/lucide--globe.svg")
const TOOL_ICON_OTHER = preload("res://addons/godette_agent/icons/lucide--hammer.svg")
const TOOL_ICON_WARNING = preload("res://addons/godette_agent/icons/lucide--alert-triangle.svg")

const FONT_SIZE_FALLBACK := 14


# --- Font + size ----------------------------------------------------------

static func main_font_size() -> int:
	if Engine.is_editor_hint():
		var settings := EditorInterface.get_editor_settings()
		if settings != null and settings.has_setting("interface/editor/main_font_size"):
			var size := int(settings.get_setting("interface/editor/main_font_size"))
			if size > 0:
				return size
		var theme := EditorInterface.get_editor_theme()
		if theme != null and theme.default_font_size > 0:
			return int(theme.default_font_size)
	return FONT_SIZE_FALLBACK


static func default_font() -> Font:
	if not Engine.is_editor_hint():
		return null
	var theme := EditorInterface.get_editor_theme()
	if theme == null:
		return null
	return theme.default_font


# Return the editor theme's font at the given slot (EditorFonts type).
# Slots used: "main", "bold", "italic", "source". Falls back to
# SystemFont with `weight` + `italic` trait hints when the editor theme
# is unavailable — keeps the plugin from crashing in standalone runs.
# The SystemFont fallback mirrors the editor's defaults (Inter for
# main/bold/italic, JetBrains Mono for source) via its font_names list.
static func font(slot: String, fallback_weight: int, fallback_italic: bool) -> Font:
	if Engine.is_editor_hint():
		var theme: Theme = EditorInterface.get_editor_theme()
		if theme != null and theme.has_font(slot, "EditorFonts"):
			return theme.get_font(slot, "EditorFonts")
	var sys := SystemFont.new()
	if slot == "source":
		sys.font_names = PackedStringArray([
			"JetBrains Mono", "Cascadia Mono", "Cascadia Code", "Consolas",
			"Fira Code", "SF Mono", "Menlo", "Monaco", "Courier New", "monospace",
		])
	else:
		sys.font_names = PackedStringArray([
			"Inter", "Segoe UI", "SF Pro Text", "Noto Sans", "Arial", "sans-serif",
		])
	sys.font_weight = fallback_weight
	sys.font_italic = fallback_italic
	return sys


# --- Colors + icons -------------------------------------------------------

static func color(name: String, type_name: String, fallback: Color) -> Color:
	if not Engine.is_editor_hint():
		return fallback
	var theme := EditorInterface.get_editor_theme()
	if theme == null:
		return fallback
	if theme.has_color(name, type_name):
		return theme.get_color(name, type_name)
	return fallback


# Read a Color from EditorSettings (text editor / syntax highlighting
# colours live there, not in the editor Theme). Returns `fallback`
# outside the editor or when the key is missing.
static func editor_settings_color(setting_key: String, fallback: Color) -> Color:
	if not Engine.is_editor_hint():
		return fallback
	var settings := EditorInterface.get_editor_settings()
	if settings == null:
		return fallback
	if not settings.has_setting(setting_key):
		return fallback
	var v = settings.get_setting(setting_key)
	if v is Color:
		return v
	return fallback


static func theme_icon(icon_name: String) -> Texture2D:
	if not Engine.is_editor_hint():
		return null
	var theme: Theme = EditorInterface.get_editor_theme()
	if theme == null:
		return null
	if theme.has_icon(icon_name, "EditorIcons"):
		return theme.get_icon(icon_name, "EditorIcons")
	return null


# --- Tool-call kind glyphs + status tinting -------------------------------

static func tool_kind_icon(tool_kind: String, title_hint: String = "") -> Texture2D:
	# Map ACP's `toolKind` to a Lucide glyph — mirrors Zed's switch in
	# thread_view.rs:7368-7380. For adapters that don't populate
	# `toolKind` (or use "other"), we fall back to a keyword scan on
	# the tool's visible title so terminal / read / edit commands still
	# get a meaningful icon.
	match tool_kind:
		"read":
			return TOOL_ICON_SEARCH
		"edit":
			return TOOL_ICON_EDIT
		"delete":
			return TOOL_ICON_DELETE
		"move":
			return TOOL_ICON_SWAP
		"search":
			return TOOL_ICON_SEARCH
		"execute":
			return TOOL_ICON_TERMINAL
		"think":
			return TOOL_ICON_THINK
		"fetch":
			return TOOL_ICON_WEB
		"switch_mode":
			return TOOL_ICON_SWAP

	# Heuristic for "other" / missing kind — Claude Agent ACP in practice
	# marks almost every tool as "other", so the kind field alone isn't
	# enough to pick a meaningful glyph.
	var lowered: String = title_hint.to_lower()
	if "run " in lowered or "exec" in lowered or "$" in lowered or "bash" in lowered or "powershell" in lowered:
		return TOOL_ICON_TERMINAL
	if "read" in lowered or "cat " in lowered or "open " in lowered:
		return TOOL_ICON_SEARCH
	if "write" in lowered or "edit" in lowered or "patch" in lowered or "apply" in lowered:
		return TOOL_ICON_EDIT
	if "delete" in lowered or "rm " in lowered or "remove" in lowered:
		return TOOL_ICON_DELETE
	if "move" in lowered or "mv " in lowered or "rename" in lowered:
		return TOOL_ICON_SWAP
	if "fetch" in lowered or "http" in lowered or "url" in lowered or "web" in lowered:
		return TOOL_ICON_WEB
	if "search" in lowered or "grep" in lowered or "find" in lowered:
		return TOOL_ICON_SEARCH
	if "think" in lowered or "plan" in lowered or "todo" in lowered:
		return TOOL_ICON_THINK
	return TOOL_ICON_OTHER


static func tool_status_color(raw_status: String, awaiting_permission: bool) -> Color:
	# Match Zed's status semantics on the tool-kind icon tint. Completed /
	# unknown renders at the normal muted text color; exceptional states
	# borrow the warning / error chroma so the icon carries the signal
	# even without an adjacent status word.
	if awaiting_permission:
		return Color(0.98, 0.86, 0.52, 0.95)  # warning amber
	match raw_status:
		"failed", "error":
			return Color(0.95, 0.48, 0.50, 0.95)  # error red
		"canceled", "cancelled", "rejected":
			return Color(0.78, 0.80, 0.85, 0.72)  # muted
		"pending", "in_progress", "running":
			return Color(0.58, 0.78, 1.0, 0.95)   # accent / in-flight blue
		_:
			# "completed" and anything else default to the editor's
			# readonly/muted text color so the icon reads as "done,
			# nothing to flag".
			return color("font_readonly_color", "Editor", Color(0.78, 0.80, 0.85, 0.90))


# --- Button theming -------------------------------------------------------

static func apply_icon_button_theme(button: Button, icon_px: int) -> void:
	# Mirror Zed's icon-button sizing (14 px for Small, 16 px for Medium —
	# IconSize::Small / Medium in gpui/ui) and tint the `currentColor`
	# SVGs with the editor's font color so they read correctly in both
	# light and dark themes. Without this the raw SVG renders at its
	# intrinsic 64 px and at `rgb(74, 85, 101)` — too big and too muted
	# against a dark panel.
	button.add_theme_constant_override("icon_max_width", icon_px)
	var icon_color := color("font_color", "Editor", Color(0.88, 0.88, 0.92, 0.95))
	var muted := Color(icon_color.r, icon_color.g, icon_color.b, 0.55)
	button.add_theme_color_override("icon_normal_color", icon_color)
	button.add_theme_color_override("icon_hover_color", icon_color)
	button.add_theme_color_override("icon_focus_color", icon_color)
	button.add_theme_color_override("icon_pressed_color", icon_color)
	button.add_theme_color_override("icon_disabled_color", muted)
