@tool
extends VBoxContainer

const ACPConnectionScript = preload("res://addons/godette_agent/acp_connection.gd")
const TextBlockScript = preload("res://addons/godette_agent/text_block.gd")
const MarkdownScript = preload("res://addons/godette_agent/markdown.gd")
const MarkdownRenderScript = preload("res://addons/godette_agent/markdown_render.gd")
const SessionStoreScript = preload("res://addons/godette_agent/session_store.gd")
const VirtualFeedScript = preload("res://addons/godette_agent/virtual_feed.gd")
const LoadingScannerScript = preload("res://addons/godette_agent/loading_scanner.gd")
const ComposerContextScript = preload("res://addons/godette_agent/composer_context.gd")
const ComposerPromptInputScript = preload("res://addons/godette_agent/composer_prompt_input.gd")
const PASTED_IMAGE_DIR := "user://godette_attachments/"
const CLAUDE_AGENT_ICON = preload("res://addons/godette_agent/icons/claude.svg")
const CODEX_CLI_ICON = preload("res://addons/godette_agent/icons/openai.svg")
const SEND_ICON = preload("res://addons/godette_agent/icons/send.svg")
const STOP_ICON = preload("res://addons/godette_agent/icons/stop.svg")
const ADD_ICON = preload("res://addons/godette_agent/icons/add.svg")
const HISTORY_ICON = preload("res://addons/godette_agent/icons/history.svg")
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

const DEFAULT_AGENT_ID := "claude_agent"
const HEADER_AGENT_ICON_SIZE := 28
const THREAD_MENU_AGENT_ICON_SIZE := HEADER_AGENT_ICON_SIZE
# Fallbacks used only when the editor hasn't handed us a theme / settings.
# Actual runtime values are pulled via _editor_main_font_size() etc. so the
# dock tracks the user's Godot editor preferences.
const STREAM_BODY_FONT_SIZE_FALLBACK := 14
const STREAM_BODY_LINE_SPACING := 4.0
const STREAM_USER_FONT_SIZE_DELTA := -1  # user bubble renders one pt smaller than body
# Markdown render tunables (heading sizes, margins, list indent, …) live
# on GodetteMarkdownRender. They're rendering-internal and stay with the
# renderer rather than the dock.
const MAX_SCENE_NODES := 128
const RECENT_SESSION_LIMIT := 6
# Session persistence paths + size caps live on GodetteSessionStore.
# Only the Timer debounce interval is a dock concern (Timer is a Node).
const SESSION_PERSIST_DEBOUNCE_SEC := 0.4
const THREAD_MENU_SESSION_ID_OFFSET := 1000
const ADD_MENU_AGENT_ID_OFFSET := 2000
const AGENTS := [
	{"id": "claude_agent", "label": "Claude Agent"},
	{"id": "codex_cli", "label": "Codex CLI"}
]

var editor_interface: EditorInterface
var thread_icon: TextureRect
var thread_menu: MenuButton
var thread_switcher_button: Button
var add_menu: MenuButton
var message_scroll: ScrollContainer
var message_stream: GodetteVirtualFeed
var prompt_input: TextEdit
var composer_options_bar: HBoxContainer
var composer_context: GodetteComposerContext
var send_button: Button
# Left-aligned badge in composer_options_bar showing how many follow-up
# prompts are queued behind the current streaming turn. Hidden when the
# queue is empty so the bar stays uncluttered in the common case.
var queue_count_label: Label
var status_label: Label
var status_dot: PanelContainer
var loading_scanner: GodetteLoadingScanner

var pending_permissions: Dictionary = {}

# View-local expand state keyed by "agent_id|remote_session_id|tool_call_id".
var expanded_tool_calls: Dictionary = {}
# Thinking block expand state keyed by "agent_id|remote_session_id|transcript_index".
var expanded_thinking_blocks: Dictionary = {}
var user_toggled_thinking_blocks: Dictionary = {}
# Most recent auto-expanded thinking key per session, keyed by "agent_id|remote_session_id".
var auto_expanded_thinking_block: Dictionary = {}
# Plan summary collapse state keyed by "agent_id|remote_session_id".
var plan_expanded_sessions: Dictionary = {}
# Session scopes whose Plan panel has been explicitly dismissed via the ×
# button. The dismissal is transient — any subsequent `_upsert_plan_entry`
# call (i.e. the agent writes the todo list again) clears it so a fresh
# plan update re-surfaces the panel. Persistence across sessions isn't
# meaningful either way, so we don't save this to disk.
var plan_dismissed_sessions: Dictionary = {}

const COPIED_STATE_SECONDS := 2.0

# Streaming reveal smoothing, mirroring Zed's StreamingTextBuffer
# (vendor/zed/crates/acp_thread/src/acp_thread.rs:1072-1089, :1718-1745).
# Adapters occasionally emit a big burst of bytes in a single frame; without
# rate-limiting, one frame has to reshape thousands of glyphs. The buffer keeps
# per-frame work bounded by revealing `pending_len * tick / reveal_target`
# bytes each tick, which drains any buffer in ~REVEAL_TARGET regardless of
# size.
const STREAMING_TICK_INTERVAL_SEC := 0.016
const STREAMING_REVEAL_TARGET_SEC := 0.2

# Sessions currently replaying history via session/load; their chat log renders are suppressed.
var replaying_sessions: Dictionary = {}
# Coalescing flag for chat log rebuilds within a single frame.
var chat_log_refresh_pending := false
# Hover-on-host groups polled per frame to emulate Zed's bounds-based group_hover.
var hover_groups: Array = []
# Coalescing flag for thread menu rebuilds. A session/update burst can call
# _touch_session hundreds of times in one frame; the menu only needs to
# reflect the final state, so batch into one rebuild per frame.
var thread_menu_refresh_pending: bool = false
# Pending streaming text keyed by "session_scope|entry_index". Drained by
# _drive_streaming_buffers each tick. Only populated while the owning session
# is busy (active turn); replay / idle chunks bypass the buffer.
var streaming_pending: Dictionary = {}
# Which session `_flush_chat_log_refresh` last rendered. Used to tell a
# "switched to a different thread, jump to the bottom" flush apart from an
# in-place rebuild (`_refresh_chat_log` fires from many non-switch paths —
# tool-call disclosure fallback, plan expand fallback, session/load replay
# completion, etc). Without this split, every such rebuild yanked the
# viewport to the latest message mid-scroll.
var _last_flushed_session_index: int = -1
# `entry_index -> GodetteTextBlock` lookup for the streaming fast path.
# Populated/evicted via VirtualFeed's entry_created / entry_freed signals so
# `_append_delta_to_text_block` no longer has to walk the row subtree for
# every token chunk.
var _entry_text_block_cache: Dictionary = {}
# Per-frame coalescing of streaming text writes. Multiple chunks hitting
# the same entry during one frame combine into a single `append_text`,
# which collapses several `update_minimum_size` + container re-layout
# passes into one and makes replay bursts much smoother.
var _pending_delta_writes: Dictionary = {}  # entry_index -> String
var _delta_flush_pending: bool = false
var streaming_tick_accumulator_sec: float = 0.0

var connections := {}
var connection_status := {}
var pending_remote_sessions := {}
var pending_remote_session_loads := {}
var agent_icon_cache := {}

var sessions: Array = []
var current_session_index := -1
var next_session_number := 1
var selected_agent_id := DEFAULT_AGENT_ID
var startup_discovery_agents := {}
var persist_timer: Timer
var persist_dirty := false


func configure(p_editor_interface: EditorInterface) -> void:
	editor_interface = p_editor_interface


# --- Editor theme helpers --------------------------------------------------
# Pull font + color from the Godot editor's live theme/settings so the dock
# inherits the user's preferences (dark/light theme, font size override,
# custom accent). Silent fallbacks keep things working when run outside the
# editor context.

func _editor_main_font_size() -> int:
	if editor_interface != null:
		var settings := editor_interface.get_editor_settings()
		if settings != null and settings.has_setting("interface/editor/main_font_size"):
			var size := int(settings.get_setting("interface/editor/main_font_size"))
			if size > 0:
				return size
		var theme := editor_interface.get_editor_theme()
		if theme != null and theme.default_font_size > 0:
			return int(theme.default_font_size)
	return STREAM_BODY_FONT_SIZE_FALLBACK


func _editor_default_font() -> Font:
	if editor_interface == null:
		return null
	var theme := editor_interface.get_editor_theme()
	if theme == null:
		return null
	return theme.default_font


func _editor_color(name: String, type_name: String, fallback: Color) -> Color:
	if editor_interface == null:
		return fallback
	var theme := editor_interface.get_editor_theme()
	if theme == null:
		return fallback
	if theme.has_color(name, type_name):
		return theme.get_color(name, type_name)
	return fallback


func _tool_kind_icon(tool_kind: String, title_hint: String = "") -> Texture2D:
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


func _tool_status_color(raw_status: String, awaiting_permission: bool) -> Color:
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
			return _editor_color("font_readonly_color", "Editor", Color(0.78, 0.80, 0.85, 0.90))


func _apply_icon_button_theme(button: Button, icon_px: int) -> void:
	# Mirror Zed's icon-button sizing (14 px for Small, 16 px for Medium —
	# IconSize::Small / Medium in gpui/ui) and tint the `currentColor`
	# SVGs with the editor's font color so they read correctly in both
	# light and dark themes. Without this the raw SVG renders at its
	# intrinsic 64 px and at `rgb(74, 85, 101)` — too big and too muted
	# against a dark panel.
	button.add_theme_constant_override("icon_max_width", icon_px)
	var icon_color := _editor_color("font_color", "Editor", Color(0.88, 0.88, 0.92, 0.95))
	var muted := Color(icon_color.r, icon_color.g, icon_color.b, 0.55)
	button.add_theme_color_override("icon_normal_color", icon_color)
	button.add_theme_color_override("icon_hover_color", icon_color)
	button.add_theme_color_override("icon_focus_color", icon_color)
	button.add_theme_color_override("icon_pressed_color", icon_color)
	button.add_theme_color_override("icon_disabled_color", muted)


func _safe_text(text: String) -> String:
	# Last-mile NUL strip used at every visible text sink (Label.text,
	# popup.add_item, TextBlock set_text, etc). Ingress sanitation already
	# cleans ACP / cache payloads, but defending at the UI boundary too
	# keeps any missed pathway (adapter edge cases, new code paths, bugs in
	# the walker) from flooding the console with 80k+
	# "Unexpected NUL character" warnings. Codepoint iteration on purpose —
	# String.contains / replace can miss embedded U+0000 depending on which
	# internal path Godot takes.
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


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	persist_timer = Timer.new()
	persist_timer.one_shot = true
	persist_timer.wait_time = SESSION_PERSIST_DEBOUNCE_SEC
	persist_timer.timeout.connect(Callable(self, "_flush_persist_state"))
	add_child(persist_timer)
	_build_ui()
	_refresh_add_menu()
	# Startup reconciles three sources in order:
	#   1. Metadata-only restore from local cache (shows threads immediately).
	#   2. `session/list` against every configured adapter (imports anything
	#      new that remote knows about — always runs, even when local cache
	#      already produced a visible active thread).
	#   3. `_finish_startup_discovery_for_agent` falls back to creating a
	#      fresh session only when nothing came back from either source.
	#
	# Discovery is deferred a frame: `OS.execute_with_pipe` inside
	# `_ensure_connection` is synchronous, and spawning the second adapter
	# (the non-active agent) can stall the editor for a couple seconds on
	# Windows. Letting the dock paint the restored metadata first means the
	# user at least sees their threads while the adapter warms up in the
	# background.
	_restore_persisted_state()
	call_deferred("_begin_session_discovery")


func focus_prompt() -> void:
	if prompt_input != null:
		prompt_input.grab_focus()


func _notification(what: int) -> void:
	if what == Control.NOTIFICATION_RESIZED:
		call_deferred("_reflow_composer_selectors")


func shutdown() -> void:
	if persist_timer != null and is_instance_valid(persist_timer):
		persist_timer.stop()
	_flush_persist_state()
	for connection in connections.values():
		if is_instance_valid(connection):
			connection.shutdown()
			connection.queue_free()
	connections.clear()
	connection_status.clear()
	pending_remote_sessions.clear()
	pending_remote_session_loads.clear()


func _build_ui() -> void:
	add_theme_constant_override("separation", 12)

	var header_section := VBoxContainer.new()
	header_section.add_theme_constant_override("separation", 8)
	header_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(header_section)

	var header_row := HBoxContainer.new()
	header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_theme_constant_override("separation", 6)
	header_section.add_child(header_row)

	status_dot = PanelContainer.new()
	status_dot.custom_minimum_size = Vector2(10, 10)
	header_row.add_child(status_dot)

	thread_icon = TextureRect.new()
	thread_icon.custom_minimum_size = Vector2(HEADER_AGENT_ICON_SIZE, HEADER_AGENT_ICON_SIZE)
	thread_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thread_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thread_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	thread_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	thread_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thread_icon.texture = _agent_icon_texture(DEFAULT_AGENT_ID)
	header_row.add_child(thread_icon)

	thread_menu = MenuButton.new()
	thread_menu.flat = true
	thread_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	thread_menu.alignment = HORIZONTAL_ALIGNMENT_LEFT
	thread_menu.clip_text = true
	thread_menu.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	thread_menu.get_popup().id_pressed.connect(Callable(self, "_on_thread_menu_id_pressed"))
	header_row.add_child(thread_menu)

	status_label = Label.new()
	status_label.text = "Starting..."
	status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status_label.clip_text = true
	status_label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	header_row.add_child(status_label)

	# Explicit "switch thread" affordance. Zed shows a small history /
	# hamburger icon next to the thread title so users realise threads
	# can be switched from the top bar — our old flat-text MenuButton
	# didn't read as clickable to first-time users. Clicking here opens
	# the same popup the thread_menu itself does.
	thread_switcher_button = Button.new()
	thread_switcher_button.flat = true
	thread_switcher_button.focus_mode = Control.FOCUS_NONE
	thread_switcher_button.tooltip_text = "Switch thread"
	thread_switcher_button.icon = HISTORY_ICON
	_apply_icon_button_theme(thread_switcher_button, HEADER_AGENT_ICON_SIZE)
	thread_switcher_button.pressed.connect(Callable(self, "_on_thread_switcher_pressed"))
	header_row.add_child(thread_switcher_button)

	add_menu = MenuButton.new()
	add_menu.flat = true
	add_menu.icon = ADD_ICON
	_apply_icon_button_theme(add_menu, HEADER_AGENT_ICON_SIZE)
	add_menu.get_popup().id_pressed.connect(Callable(self, "_on_add_menu_id_pressed"))
	header_row.add_child(add_menu)

	# Context-attach toolbar (Current Scene / Selected Nodes / Selected Files /
	# Clear Context) is hidden for now. The attach functions are still present
	# and callable from the FileSystem / SceneTree context menu plugins, which
	# is the entry point we want to lean on for the open-source MVP. Re-enable
	# by wiring a row of buttons here that call attach_current_scene() etc.

	# Knight Rider loading scanner is disabled for now — flip the flag when
	# the animation should come back. The script is still preloaded so future
	# re-enabling is a one-line change.
	if false:
		loading_scanner = LoadingScannerScript.new()
		loading_scanner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		loading_scanner.visible = false
		loading_scanner.set_accent(_editor_color("accent_color", "Editor", Color(0.55, 0.78, 1.0, 1.0)))
		add_child(loading_scanner)

	message_scroll = ScrollContainer.new()
	message_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	message_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	message_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	message_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(message_scroll)

	var message_padding := MarginContainer.new()
	message_padding.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	message_padding.size_flags_vertical = Control.SIZE_EXPAND_FILL
	message_padding.add_theme_constant_override("margin_left", 14)
	message_padding.add_theme_constant_override("margin_top", 8)
	message_padding.add_theme_constant_override("margin_right", 14)
	message_padding.add_theme_constant_override("margin_bottom", 8)
	message_scroll.add_child(message_padding)

	message_stream = VirtualFeedScript.new()
	message_stream.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	message_padding.add_child(message_stream)
	message_stream.configure(Callable(self, "_build_stream_entry_for_index"), message_scroll)
	message_stream.entry_created.connect(Callable(self, "_on_virtual_feed_entry_created"))
	message_stream.entry_freed.connect(Callable(self, "_on_virtual_feed_entry_freed"))

	# Composer frame: a single bordered surface that hosts both the chip
	# strip and the text input. Zed's "chips inside the input" look is
	# actually two sibling controls sharing one outer border — same trick
	# here. The frame carries the border/background; the TextEdit below is
	# flattened so the frame shows through.
	var composer_frame := PanelContainer.new()
	composer_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	composer_frame.add_theme_stylebox_override("panel", _prompt_input_style(false))
	add_child(composer_frame)

	var composer_input_group := VBoxContainer.new()
	composer_input_group.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	composer_input_group.add_theme_constant_override("separation", 6)
	composer_frame.add_child(composer_input_group)

	composer_context = ComposerContextScript.new()
	composer_context.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	composer_context.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	composer_context.visible = false
	composer_context.attachment_remove_requested.connect(Callable(self, "_on_attachment_remove_requested"))
	composer_context.attachment_activated.connect(Callable(self, "_on_attachment_activated"))
	composer_input_group.add_child(composer_context)

	# Use a local typed ref so the `image_pasted` signal connection resolves
	# through the subclass statically. Assigning the member `prompt_input`
	# (typed as TextEdit) accepts the subclass via polymorphism, but the
	# signal lookup has to happen on the concrete type — hanging it off
	# the base-typed member would trip GDScript's static signal check and
	# refuse to load the whole script.
	var typed_prompt: GodetteComposerPromptInput = ComposerPromptInputScript.new()
	typed_prompt.image_pasted.connect(Callable(self, "_on_composer_image_pasted"))
	typed_prompt.submit_requested.connect(Callable(self, "_on_composer_submit_requested"))
	prompt_input = typed_prompt
	prompt_input.custom_minimum_size = Vector2(0, 120)
	prompt_input.placeholder_text = _prompt_placeholder(DEFAULT_AGENT_ID)
	prompt_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var prompt_font_color := _editor_color("font_color", "Editor", Color(0.97, 0.97, 0.995, 0.98))
	var prompt_placeholder_color := _editor_color("font_placeholder_color", "Editor", prompt_font_color.darkened(0.35))
	var prompt_caret := _editor_color("accent_color", "Editor", Color(0.58, 0.78, 1.0, 0.98))
	var prompt_selection := _editor_color("selection_color", "Editor", prompt_caret)
	prompt_selection.a = 0.4
	prompt_input.add_theme_color_override("font_color", prompt_font_color)
	prompt_input.add_theme_color_override("font_selected_color", prompt_font_color)
	prompt_input.add_theme_color_override("font_placeholder_color", prompt_placeholder_color)
	prompt_input.add_theme_color_override("caret_color", prompt_caret)
	prompt_input.add_theme_color_override("selection_color", prompt_selection)
	# Flat styleboxes so only composer_frame draws the border/background.
	# Without this, the TextEdit would render its own box inside the frame
	# and the chip strip would look like it's floating above a separate
	# input rather than sharing the same surface.
	var flat_style := StyleBoxEmpty.new()
	prompt_input.add_theme_stylebox_override("normal", flat_style)
	prompt_input.add_theme_stylebox_override("focus", flat_style)
	prompt_input.add_theme_stylebox_override("read_only", flat_style)
	# Move the focus-highlight animation onto the frame so the accent
	# border still lights up when the caret is active, even though the
	# TextEdit itself no longer carries a border of its own.
	var focused_frame_style := _prompt_input_style(true)
	var unfocused_frame_style := _prompt_input_style(false)
	prompt_input.focus_entered.connect(
		composer_frame.add_theme_stylebox_override.bind("panel", focused_frame_style)
	)
	prompt_input.focus_exited.connect(
		composer_frame.add_theme_stylebox_override.bind("panel", unfocused_frame_style)
	)
	# No font size / line_spacing overrides — inheriting the theme keeps
	# TextEdit's internal caret/column math aligned with its rendering
	# (a mismatched line_spacing was tripping "p_column > line.length()"
	# spam in text_edit.cpp).
	# Zed-style drag targets: dropping from the FileSystem dock or SceneTree
	# onto the prompt produces attachments directly. We don't subclass
	# TextEdit — set_drag_forwarding lets the dock's own methods handle the
	# drop while leaving text-drag behaviour intact (unknown data types
	# fall back to TextEdit's default text drop). First arg (drag_func)
	# stays empty: users don't drag OUT of the prompt.
	prompt_input.set_drag_forwarding(
		Callable(),
		Callable(self, "_composer_can_drop"),
		Callable(self, "_composer_drop")
	)
	composer_input_group.add_child(prompt_input)

	var composer_section := VBoxContainer.new()
	composer_section.add_theme_constant_override("separation", 6)
	composer_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(composer_section)

	composer_options_bar = HBoxContainer.new()
	composer_options_bar.alignment = BoxContainer.ALIGNMENT_END
	composer_options_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	composer_options_bar.add_theme_constant_override("separation", 8)
	composer_section.add_child(composer_options_bar)
	# Relying on the dock's own NOTIFICATION_RESIZED is unreliable once deep
	# sibling layouts (VirtualFeed) are in the mix — the deferred reflow
	# can fire before the bar's own size has been propagated down the tree.
	# Listening to the bar's resized signal guarantees we reflow exactly when
	# its width actually changes.
	composer_options_bar.resized.connect(Callable(self, "_on_composer_bar_resized"))

	# Queue indicator sits on the LEFT of the bar. Gets SIZE_EXPAND_FILL so
	# it absorbs the horizontal slack that otherwise ALIGNMENT_END would hand
	# to whitespace — the net visual is queue-text left, send-button right.
	# Hidden entirely when the queue is empty (see _refresh_queue_indicator).
	queue_count_label = Label.new()
	queue_count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	queue_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	queue_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	queue_count_label.modulate = Color(0.90, 0.90, 0.95, 0.70)
	queue_count_label.visible = false
	composer_options_bar.add_child(queue_count_label)

	send_button = Button.new()
	send_button.text = ""
	send_button.icon = SEND_ICON
	send_button.tooltip_text = "Send"
	send_button.custom_minimum_size = Vector2(52, 40)
	_apply_icon_button_theme(send_button, HEADER_AGENT_ICON_SIZE)
	send_button.pressed.connect(Callable(self, "_on_send_button_pressed"))
	composer_options_bar.add_child(send_button)

	_refresh_add_menu()
	_refresh_composer_options()


func _make_button(text: String, callable: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callable)
	return button


func _make_supporting_label(text: String) -> Label:
	var label := Label.new()
	label.text = _safe_text(text)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _now_tick() -> int:
	return Time.get_ticks_msec()


func _touch_session(session_index: int) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	var session: Dictionary = sessions[session_index]
	session["updated_at"] = _now_tick()
	sessions[session_index] = session

	if thread_menu != null:
		_refresh_thread_menu()
	_schedule_persist_state()


# Thin wrapper around GodetteSessionStore.persist that pins the dock's
# current state into the static call. Persist logic + I/O lives in the
# store; the dock owns only the Timer debounce plumbing below.
func _persist_state() -> void:
	SessionStoreScript.persist(
		sessions,
		current_session_index,
		next_session_number,
		selected_agent_id,
		DEFAULT_AGENT_ID,
	)


func _schedule_persist_state() -> void:
	persist_dirty = true
	if persist_timer == null or not is_instance_valid(persist_timer):
		_flush_persist_state()
		return
	persist_timer.start()


func _flush_persist_state() -> void:
	if not persist_dirty:
		return
	persist_dirty = false
	_persist_state()


func _project_root_path() -> String:
	return ProjectSettings.globalize_path("res://")


func _normalized_path(path: String) -> String:
	return path.replace("\\", "/").trim_suffix("/").to_lower()


func _timestamp_msec_from_iso(value: String) -> int:
	if value.is_empty():
		return _now_tick()
	var seconds := Time.get_unix_time_from_datetime_string(value)
	if seconds <= 0:
		return _now_tick()
	return int(seconds * 1000.0)




func _most_recent_session_index() -> int:
	if sessions.is_empty():
		return -1

	var best_index := 0
	var best_updated_at: int = int(sessions[0].get("updated_at", 0))
	for session_index in range(1, sessions.size()):
		var candidate_updated_at: int = int(sessions[session_index].get("updated_at", 0))
		if candidate_updated_at > best_updated_at:
			best_index = session_index
			best_updated_at = candidate_updated_at
	return best_index


func _restore_persisted_state() -> bool:
	# Parse + legacy migration + metadata-only hydration all live on
	# SessionStore.load_persisted. The dock picks an active session
	# afterward: explicit "was current when Godot closed" beats
	# most-recent-updated so replay-driven `_touch_session` bumps on
	# background threads don't silently steal the active slot from the
	# one the user was actually reading.
	var result: Dictionary = SessionStoreScript.load_persisted(DEFAULT_AGENT_ID)
	if not bool(result.get("found", false)):
		return false

	var loaded_sessions_variant = result.get("sessions", [])
	var loaded_sessions: Array = loaded_sessions_variant if loaded_sessions_variant is Array else []
	if loaded_sessions.is_empty():
		return false

	sessions = loaded_sessions
	next_session_number = int(result.get("next_session_number", sessions.size() + 1))
	selected_agent_id = str(result.get("selected_agent_id", DEFAULT_AGENT_ID))

	var session_index := -1
	var current_session_id: String = str(result.get("current_session_id", ""))
	if not current_session_id.is_empty():
		session_index = _find_session_index_by_id(current_session_id)
	if session_index < 0:
		session_index = _most_recent_session_index()
	if session_index < 0:
		session_index = 0

	_switch_session(session_index)
	return true


func _begin_session_discovery() -> void:
	startup_discovery_agents.clear()
	for agent in AGENTS:
		var agent_id: String = str(agent.get("id", ""))
		if agent_id.is_empty():
			continue
		startup_discovery_agents[agent_id] = true
		_ensure_connection(agent_id)


func _finish_startup_discovery_for_agent(agent_id: String) -> void:
	if not startup_discovery_agents.has(agent_id):
		return

	startup_discovery_agents.erase(agent_id)
	if not startup_discovery_agents.is_empty():
		return

	if sessions.is_empty():
		_create_session(DEFAULT_AGENT_ID, true, true)
	elif current_session_index < 0:
		_switch_session(0)


func _current_thread_title() -> String:
	if current_session_index < 0 or current_session_index >= sessions.size():
		return "New Thread"
	return _safe_text(str(sessions[current_session_index].get("title", "New Thread")))


func _recent_session_indices(limit: int) -> Array:
	var ordered: Array = []
	for session_index in range(sessions.size()):
		var inserted := false
		var updated_at: int = int(sessions[session_index].get("updated_at", 0))
		for ordered_index in range(ordered.size()):
			var candidate_index: int = int(ordered[ordered_index])
			var candidate_updated_at: int = int(sessions[candidate_index].get("updated_at", 0))
			if updated_at > candidate_updated_at:
				ordered.insert(ordered_index, session_index)
				inserted = true
				break
		if not inserted:
			ordered.append(session_index)

	if limit <= 0 or ordered.size() <= limit:
		return ordered

	var limited: Array = []
	for item_index in range(limit):
		limited.append(ordered[item_index])
	return limited


func _thread_menu_label(session_index: int) -> String:
	if session_index < 0 or session_index >= sessions.size():
		return "Session"

	var session: Dictionary = sessions[session_index]
	return _safe_text(str(session.get("title", "Session")))


func _thread_menu_tooltip(session_index: int) -> String:
	if session_index < 0 or session_index >= sessions.size():
		return "Session"

	var session: Dictionary = sessions[session_index]
	return _safe_text("%s | %s" % [str(session.get("title", "Session")), _agent_label(str(session.get("agent_id", DEFAULT_AGENT_ID)))])


func _agent_icon_texture(agent_id: String, size: int = HEADER_AGENT_ICON_SIZE) -> Texture2D:
	var cache_key := "%s:%d" % [agent_id, size]
	if agent_icon_cache.has(cache_key):
		return agent_icon_cache[cache_key]

	var source_texture: Texture2D = CLAUDE_AGENT_ICON
	match agent_id:
		"codex_cli":
			source_texture = CODEX_CLI_ICON

	var scaled_texture: Texture2D = source_texture
	var image: Image = source_texture.get_image()
	if image != null and not image.is_empty():
		image.resize(size, size, Image.INTERPOLATE_LANCZOS)
		scaled_texture = ImageTexture.create_from_image(image)

	agent_icon_cache[cache_key] = scaled_texture
	return scaled_texture


func _status_dot_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 99
	style.corner_radius_top_right = 99
	style.corner_radius_bottom_right = 99
	style.corner_radius_bottom_left = 99
	return style


func _entry_kind(entry: Dictionary) -> String:
	var explicit_kind: String = str(entry.get("kind", ""))
	if not explicit_kind.is_empty():
		return explicit_kind

	var speaker: String = str(entry.get("speaker", "System"))
	match speaker:
		"You":
			return "user"
		"Tool":
			return "tool"
		"Plan":
			return "plan"
		"System":
			return "system"
		_:
			return "assistant"


func _build_stream_entry_for_index(entry: Dictionary, entry_index: int) -> Control:
	return _build_stream_entry(entry, entry_index)


func _build_stream_entry(entry: Dictionary, entry_index: int = -1) -> Control:
	var kind: String = _entry_kind(entry)
	if kind == "system":
		var system_label := _make_supporting_label(str(entry.get("content", "")))
		system_label.modulate = Color(0.86, 0.86, 0.90, 0.72)
		return system_label
	if kind == "plan":
		return _build_plan_entry(entry)
	if kind == "thought":
		return _build_thinking_entry(entry, entry_index)
	if kind == "user" or kind == "assistant":
		return _build_chat_message_entry(entry, kind, entry_index)
	if kind == "tool":
		return _build_tool_call_entry(entry)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _stream_panel_style(kind))

	var padding := MarginContainer.new()
	padding.add_theme_constant_override("margin_left", 12)
	padding.add_theme_constant_override("margin_top", 10)
	padding.add_theme_constant_override("margin_right", 12)
	padding.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(padding)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	padding.add_child(content)

	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8)
	header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(header_row)

	var title_label := Label.new()
	title_label.text = _stream_entry_title(entry, kind)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.clip_text = true
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.modulate = _stream_title_color(kind)
	header_row.add_child(title_label)

	var summary_text: String = _stream_entry_summary(entry, kind)
	if not summary_text.is_empty():
		content.add_child(_make_stream_text(summary_text, kind))

	var body_text: String = _safe_text(str(entry.get("content", "")))
	if not body_text.is_empty():
		content.add_child(_make_stream_text(body_text, kind))

	return panel


func _build_tool_call_entry(entry: Dictionary) -> Control:
	# Dispatcher mirrors Zed's `render_any_tool_call` / `render_tool_call`
	# (thread_view.rs:6288-6387). Zed only wraps *three* tool-call flavours
	# in a card: Edit (diff UI), Execute (terminal), and permission prompts.
	# Everything else — read / search / fetch / think / delete / move /
	# catch-all "other" — renders inline as a muted one-liner that only
	# reveals full output on hover+click. We mirror that taxonomy here so
	# a chat full of `Read X.rs` calls doesn't explode into a wall of
	# disclosure cards.
	var pending_request_id: int = int(entry.get("pending_permission_request_id", -1))
	var awaiting_permission: bool = pending_request_id >= 0 and pending_permissions.has(pending_request_id)
	var style: String = _tool_call_style(entry, awaiting_permission)
	if style == "inline":
		return _build_tool_call_inline(entry)
	return _build_tool_call_card(entry, awaiting_permission)


func _tool_call_style(entry: Dictionary, awaiting_permission: bool) -> String:
	# Classify the entry into a render style string. "card" for
	# edit/terminal/permission, "inline" for everything else. Keep the
	# string-enum (not bool) so we can add e.g. "subagent" later without a
	# churn through call sites.
	if awaiting_permission:
		return "card"
	var tool_kind: String = str(entry.get("tool_kind", "")).to_lower()
	if tool_kind == "edit" or tool_kind == "execute":
		return "card"
	# Claude Agent ACP marks most tools as "other"; fall back to the same
	# heuristic _tool_kind_icon uses so obvious terminal/edit commands also
	# get the card treatment. Keep this scan in sync with that function.
	if tool_kind == "other" or tool_kind == "":
		var title_hint: String = _stream_entry_title(entry, "tool").to_lower()
		if "run " in title_hint or "exec" in title_hint or "$" in title_hint or "bash" in title_hint or "powershell" in title_hint:
			return "card"
		if "write" in title_hint or "edit" in title_hint or "patch" in title_hint or "apply" in title_hint:
			return "card"
	return "inline"


# Inline tool label: Zed's thread_view.rs:7313-7458 + 7679-7726.
# Collapsed state:
#   [icon] Title ellipsized to fit                    [✕ if failed]
# Expanded state adds below the header:
#   Raw Input:
#   ┌──────────────────────────────────────────┐
#   │ mono-text of the JSON the agent sent     │
#   └──────────────────────────────────────────┘
#   Output:
#   ┌──────────────────────────────────────────┐
#   │ mono-text of the tool's output / summary │
#   └──────────────────────────────────────────┘
#   ┌────────────────── ^ ─────────────────────┐   ← full-width collapse bar
#   └──────────────────────────────────────────┘
# The outer wrapper is just margin — no panel / border. Only the Raw Input
# and Output subsection cards get a dark bg, mirroring Zed's tool card
# colour (editor `dark_color_3`).
func _build_tool_call_inline(entry: Dictionary) -> Control:
	var wrapper := MarginContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Zed's inline tool row: `my_1 mx_5` = 4px vertical, 20px horizontal
	# (same left edge as the surrounding assistant prose column). We had
	# 2/2 + a 25 left indent before, which matched nothing in Zed and
	# read as cramped — tool rows sat nearly on top of the paragraph
	# above/below.
	wrapper.add_theme_constant_override("margin_left", 20)
	wrapper.add_theme_constant_override("margin_right", 20)
	wrapper.add_theme_constant_override("margin_top", 4)
	wrapper.add_theme_constant_override("margin_bottom", 4)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 6)
	wrapper.add_child(column)

	# -- Header row: icon + title + (failed ✕) --
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(header)

	var tool_kind: String = str(entry.get("tool_kind", "")).to_lower()
	var title_text: String = _stream_entry_title(entry, "tool")
	var raw_status: String = str(entry.get("status", "pending")).to_lower()
	var muted_color := _editor_color("font_readonly_color", "Editor", Color(0.78, 0.80, 0.85, 0.90))

	var tool_icon_rect := TextureRect.new()
	tool_icon_rect.texture = _tool_kind_icon(tool_kind, title_text)
	# Zed pins IconSize::Small = 14 px (constant) against a 13 px label.
	# Our label inherits the editor theme font (often 16-20+ at HiDPI),
	# so a fixed 14 looks too small there. Scale icon to ~80 % of the
	# font size (floor 13) — the icon stays visibly smaller than a cap
	# height under any theme, matching Zed's "compact row" feel without
	# ballooning at large font sizes.
	var icon_px: int = max(13, int(round(_editor_main_font_size_for_markdown() * 0.8)))
	tool_icon_rect.custom_minimum_size = Vector2(icon_px, icon_px)
	tool_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tool_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# Zed keeps the tool icon at a constant muted tint regardless of status;
	# status is communicated by the top-right glyph (red ✕ for failed) so
	# the icon stays "what tool" not "what state".
	tool_icon_rect.modulate = muted_color
	tool_icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tool_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(tool_icon_rect)

	var title_label := Label.new()
	title_label.text = title_text
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.clip_text = true
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.modulate = muted_color
	header.add_child(title_label)

	var is_failed: bool = raw_status == "failed" or raw_status == "error"
	if is_failed:
		var fail_glyph := Label.new()
		fail_glyph.text = "✕"
		fail_glyph.modulate = Color(0.95, 0.48, 0.50, 0.95)
		fail_glyph.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		fail_glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
		header.add_child(fail_glyph)

	# Expansion: Zed uses a full-width bottom bar (no header chevron) so the
	# disclosure affordance only shows up once the user has drilled in. For
	# COLLAPSED state, header gets a hover-revealed chevron to open the
	# panel in the first place.
	var expand_key: String = _tool_call_expand_key(entry)
	var user_expanded: bool = not expand_key.is_empty() and expanded_tool_calls.has(expand_key)
	var raw_input_text: String = _safe_text(str(entry.get("raw_input", "")))
	var summary_text: String = _safe_text(str(entry.get("summary", "")))
	var has_raw_input: bool = not raw_input_text.is_empty()
	var has_output: bool = not summary_text.is_empty()
	var has_content: bool = has_raw_input or has_output

	if has_content and not expand_key.is_empty() and not user_expanded:
		var chevron := _make_disclosure_chevron(false)
		chevron.pressed.connect(Callable(self, "_on_tool_call_disclosure_pressed").bind(expand_key))
		_wire_hover_only_visibility(wrapper, [chevron])
		header.add_child(chevron)

	if has_content and user_expanded:
		# Indent the section contents so they read as "belonging to" the
		# tool header above (Zed uses 16px, matching ml_4 in their code).
		var body_indent := MarginContainer.new()
		body_indent.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body_indent.add_theme_constant_override("margin_left", 16)
		column.add_child(body_indent)

		var body_col := VBoxContainer.new()
		body_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body_col.add_theme_constant_override("separation", 6)
		body_indent.add_child(body_col)

		if has_raw_input:
			body_col.add_child(_make_tool_section_label("Raw Input:", muted_color))
			body_col.add_child(_make_tool_code_card(raw_input_text))

		if has_output:
			body_col.add_child(_make_tool_section_label("Output:", muted_color))
			var output_key: String = expand_key + "|full" if not expand_key.is_empty() else ""
			var show_full: bool = not output_key.is_empty() and expanded_tool_calls.has(output_key)
			var is_long: bool = _is_long_tool_content(summary_text)
			var display_text: String = summary_text
			if is_long and not show_full:
				display_text = _truncate_for_preview(summary_text)
			body_col.add_child(_make_tool_code_card(display_text))
			if is_long and not output_key.is_empty():
				body_col.add_child(_make_show_more_toggle(show_full, output_key))

		# Full-width collapse bar at the bottom (Zed's pattern — the open
		# disclosure lives at the foot of the expanded section, not the
		# header, so a long output can be closed without scrolling back up).
		column.add_child(_make_tool_collapse_bar(expand_key, muted_color))

	return wrapper


func _make_tool_section_label(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.modulate = color
	return label


func _make_tool_code_card(text: String) -> Control:
	# Dark rounded card holding monospace text. Mirrors Zed's "Raw Input" /
	# "Output" inline preview style (thread_view.rs:7679-7726) — same chip
	# background we use for inline `code`, just scaled up.
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	var bg := _editor_color("dark_color_3", "Editor", Color(0, 0, 0, 0.30))
	bg.a = max(bg.a, 0.35)
	style.bg_color = bg
	style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", style)

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 10)
	pad.add_theme_constant_override("margin_right", 10)
	pad.add_theme_constant_override("margin_top", 8)
	pad.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(pad)

	var tb: GodetteTextBlock = TextBlockScript.new()
	tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray([
		"Cascadia Mono", "Cascadia Code", "Consolas", "JetBrains Mono",
		"Fira Code", "SF Mono", "Menlo", "Monaco", "Courier New", "monospace",
	])
	tb.set_font(mono)
	tb.set_line_spacing(STREAM_BODY_LINE_SPACING)
	var fg := _editor_color("font_color", "Editor", Color(0.93, 0.94, 0.98, 0.96))
	tb.set_color(fg)
	var sel := _editor_color("selection_color", "Editor", Color(0.36, 0.52, 0.85, 1.0))
	sel.a = 0.55
	tb.set_selection_color(sel)
	tb.set_text(text)
	pad.add_child(tb)
	return panel


func _make_tool_collapse_bar(expand_key: String, color: Color) -> Control:
	# Full-width, single-line bar with a centered up-chevron. Click anywhere
	# on it closes the expanded tool call. Uses Button.flat so the bar
	# doesn't pick up the editor's focus ring / hover tint visible on real
	# buttons, only the cursor change + press signal.
	var bar := Button.new()
	bar.flat = true
	bar.focus_mode = Control.FOCUS_NONE
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.custom_minimum_size = Vector2(0, 22)
	bar.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	bar.text = "⌃"
	bar.alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar.add_theme_color_override("font_color", color)
	bar.add_theme_color_override("font_hover_color", color)
	bar.add_theme_color_override("font_pressed_color", color)
	if not expand_key.is_empty():
		bar.pressed.connect(Callable(self, "_on_tool_call_disclosure_pressed").bind(expand_key))
	return bar


# Card-style tool entry. Preserves the pre-refactor layout for the three
# cases Zed still shows as cards (edit / terminal / permission). The body
# was originally _build_tool_call_entry itself; `awaiting_permission` is
# passed in from the dispatcher so we don't re-compute it.
func _build_tool_call_card(entry: Dictionary, awaiting_permission: bool) -> Control:
	# Zed spec: tool cards use `my_1p5 mx_5` (6px vertical, 20px horizontal)
	# outer margin + `border_1 rounded_md` inside. Header padding is tighter
	# than our previous 12/10.
	var wrapper := MarginContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_theme_constant_override("margin_left", 20)
	wrapper.add_theme_constant_override("margin_right", 20)
	wrapper.add_theme_constant_override("margin_top", 6)
	wrapper.add_theme_constant_override("margin_bottom", 6)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _stream_panel_style("tool"))
	wrapper.add_child(panel)

	var padding := MarginContainer.new()
	padding.add_theme_constant_override("margin_left", 10)
	padding.add_theme_constant_override("margin_top", 8)
	padding.add_theme_constant_override("margin_right", 10)
	padding.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(padding)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	padding.add_child(content)

	# Permission prompt needs the original pending_request_id so the
	# approval/reject buttons know which permission to resolve. The caller
	# already computed awaiting_permission; look the id up again here so the
	# card doesn't silently drop the approval row.
	var pending_request_id: int = int(entry.get("pending_permission_request_id", -1))

	var expand_key: String = _tool_call_expand_key(entry)
	var user_expanded: bool = not expand_key.is_empty() and expanded_tool_calls.has(expand_key)
	var summary_text: String = _safe_text(str(entry.get("summary", "")))
	var body_text: String = _safe_text(str(entry.get("content", "")))
	var has_expandable_body: bool = not summary_text.is_empty() or not body_text.is_empty()
	var is_collapsible: bool = has_expandable_body and not awaiting_permission
	var is_open: bool = user_expanded or awaiting_permission or not is_collapsible

	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 6)
	header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(header_row)

	# Tool-kind icon on the left, colored by status. Matches Zed's
	# thread_view.rs:7313-7382 rendering: an icon chosen by
	# `toolKind` carries both "what tool" and "what state" via its
	# tint, so the header can drop the "Completed" / "Pending" text
	# chip in the normal case and hand the freed horizontal space to
	# the command label.
	var raw_status: String = str(entry.get("status", "pending")).to_lower()
	var tool_kind: String = str(entry.get("tool_kind", "")).to_lower()
	var title_text: String = _stream_entry_title(entry, "tool")
	var tool_icon_rect := TextureRect.new()
	tool_icon_rect.texture = _tool_kind_icon(tool_kind, title_text)
	# See _build_tool_call_inline for the scaling rationale. Same 0.8x
	# ratio here keeps the card header icon at the same visual weight as
	# the inline path's icons.
	var card_icon_px: int = max(13, int(round(_editor_main_font_size_for_markdown() * 0.8)))
	tool_icon_rect.custom_minimum_size = Vector2(card_icon_px, card_icon_px)
	tool_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tool_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tool_icon_rect.modulate = _tool_status_color(raw_status, awaiting_permission)
	tool_icon_rect.mouse_filter = Control.MOUSE_FILTER_PASS
	header_row.add_child(tool_icon_rect)

	var title_label := Label.new()
	title_label.text = title_text
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.clip_text = true
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.modulate = _stream_title_color("tool")
	header_row.add_child(title_label)

	# Only a narrow set of statuses still warrant an inline text chip:
	# the ones where "colour-on-icon alone" doesn't carry enough
	# actionability. Completed / pending / running / canceled render
	# as icon-tint-only so they don't clutter the header.
	if awaiting_permission:
		var approval_chip := Label.new()
		approval_chip.text = "Needs approval"
		approval_chip.modulate = Color(0.98, 0.86, 0.52, 0.92)
		header_row.add_child(approval_chip)
	elif raw_status == "failed" or raw_status == "error":
		var failed_chip := Label.new()
		failed_chip.text = "Failed"
		failed_chip.modulate = Color(0.95, 0.48, 0.50, 0.95)
		header_row.add_child(failed_chip)

	var hover_only_controls: Array = []

	if not body_text.is_empty():
		var copy_button := _make_copy_button(body_text, "Copy Command")
		hover_only_controls.append(copy_button)
		header_row.add_child(copy_button)

	var chevron: Button = null
	if is_collapsible:
		chevron = _make_disclosure_chevron(is_open)
		chevron.pressed.connect(Callable(self, "_on_tool_call_disclosure_pressed").bind(expand_key))
		hover_only_controls.append(chevron)
		header_row.add_child(chevron)

	_wire_hover_only_visibility(panel, hover_only_controls)

	# Zed-style content: show summary only; body_text == _format_tool_call_entry
	# which just reassembles title+summary+status, all of which are already
	# visible via the header chip / title label. Duplicating it here was the
	# main reason the confirmation dialog exploded into an 80-line wall.
	if is_open and not summary_text.is_empty():
		var full_key: String = expand_key + "|full" if not expand_key.is_empty() else ""
		var show_full: bool = not full_key.is_empty() and expanded_tool_calls.has(full_key)
		var is_long: bool = _is_long_tool_content(summary_text)

		var display_text: String = summary_text
		if is_long and not show_full:
			display_text = _truncate_for_preview(summary_text)

		content.add_child(_make_stream_text(display_text, "tool"))

		if is_long and not full_key.is_empty():
			# Secondary disclosure — same shape as Zed's "View Raw Input"
			# (thread_view.rs:6431-6493): a muted toggle line inside the card.
			content.add_child(_make_show_more_toggle(show_full, full_key))

	if awaiting_permission:
		content.add_child(_build_permission_option_row(pending_request_id))

	return wrapper


const TOOL_PREVIEW_LINE_LIMIT := 10
const TOOL_PREVIEW_CHAR_LIMIT := 500


func _is_long_tool_content(text: String) -> bool:
	if text.length() > TOOL_PREVIEW_CHAR_LIMIT:
		return true
	var newline_count: int = text.count("\n")
	return newline_count > TOOL_PREVIEW_LINE_LIMIT


func _truncate_for_preview(text: String) -> String:
	var lines: PackedStringArray = text.split("\n")
	if lines.size() > TOOL_PREVIEW_LINE_LIMIT:
		var head: Array = []
		for i in range(TOOL_PREVIEW_LINE_LIMIT):
			head.append(lines[i])
		return "\n".join(head) + "\n…"
	if text.length() > TOOL_PREVIEW_CHAR_LIMIT:
		return text.substr(0, TOOL_PREVIEW_CHAR_LIMIT) + "…"
	return text


func _make_show_more_toggle(is_expanded: bool, expand_key: String) -> Control:
	var button := Button.new()
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	button.text = "Show less ⌃" if is_expanded else "Show full command ⌄"
	button.modulate = _editor_color("font_readonly_color", "Editor", Color(0.7, 0.7, 0.8, 0.85))
	button.pressed.connect(Callable(self, "_on_tool_call_show_more_pressed").bind(expand_key))
	return button


func _on_tool_call_show_more_pressed(full_key: String) -> void:
	if full_key.is_empty():
		return
	if expanded_tool_calls.has(full_key):
		expanded_tool_calls.erase(full_key)
	else:
		expanded_tool_calls[full_key] = true
	# Peel "|full" off the right; the remainder is the base expand_key whose
	# tool_call_id is already its last segment.
	var without_suffix: PackedStringArray = full_key.rsplit("|", false, 1)
	if without_suffix.size() != 2 or current_session_index < 0:
		_refresh_chat_log()
		return
	var base_key: String = without_suffix[0]
	var base_parts: PackedStringArray = base_key.rsplit("|", false, 1)
	if base_parts.size() != 2:
		_refresh_chat_log()
		return
	var tool_call_id: String = base_parts[1]
	var session: Dictionary = sessions[current_session_index]
	var tool_calls: Dictionary = session.get("tool_calls", {})
	var tool_state: Dictionary = tool_calls.get(tool_call_id, {})
	var transcript_index: int = int(tool_state.get("transcript_index", -1))
	if transcript_index < 0:
		_refresh_chat_log()
		return
	_update_entry_in_feed(transcript_index)


func _tool_call_expand_key(entry: Dictionary) -> String:
	var tool_call_id: String = str(entry.get("tool_call_id", ""))
	if tool_call_id.is_empty() or current_session_index < 0 or current_session_index >= sessions.size():
		return ""
	var session: Dictionary = sessions[current_session_index]
	return "%s|%s|%s" % [
		str(session.get("agent_id", DEFAULT_AGENT_ID)),
		str(session.get("remote_session_id", "")),
		tool_call_id,
	]


func _on_tool_call_disclosure_pressed(expand_key: String) -> void:
	if expand_key.is_empty():
		return
	if expanded_tool_calls.has(expand_key):
		expanded_tool_calls.erase(expand_key)
	else:
		expanded_tool_calls[expand_key] = true

	# Translate the expand_key back to a transcript index so we can patch just
	# that entry instead of rebuilding the whole feed.
	var parts := expand_key.split("|", false)
	if parts.size() < 3 or current_session_index < 0:
		_refresh_chat_log()
		return
	var tool_call_id := str(parts[parts.size() - 1])
	var session: Dictionary = sessions[current_session_index]
	var tool_calls: Dictionary = session.get("tool_calls", {})
	var tool_state: Dictionary = tool_calls.get(tool_call_id, {})
	var transcript_index: int = int(tool_state.get("transcript_index", -1))
	if transcript_index < 0:
		_refresh_chat_log()
		return
	_update_entry_in_feed(transcript_index)


func _make_disclosure_chevron(is_open: bool) -> Button:
	var button := Button.new()
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(22, 22)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.text = "⌃" if is_open else "⌄"
	button.tooltip_text = "Collapse" if is_open else "Expand"
	return button


func _wire_hover_only_visibility(host: Control, targets: Array) -> void:
	if targets.is_empty():
		return
	# Use modulate.a instead of .visible so the control still occupies layout
	# space when hidden. Toggling .visible would add/remove the control from
	# the Container sort pass each hover, causing the header row to grow/shrink
	# and the entry height to jitter on mouse enter/leave.
	for target_variant in targets:
		if target_variant is Control:
			var control: Control = target_variant
			control.modulate.a = 0.0
	hover_groups.append({"host": host, "targets": targets, "was_inside": false})
	set_process(true)


func _process(delta: float) -> void:
	_update_hover_groups()
	_drive_streaming_buffers(delta)
	if hover_groups.is_empty() and streaming_pending.is_empty():
		set_process(false)


func _update_hover_groups() -> void:
	if hover_groups.is_empty():
		return

	var mouse_pos := get_global_mouse_position()
	var kept: Array = []
	for group_variant in hover_groups:
		if typeof(group_variant) != TYPE_DICTIONARY:
			continue
		var group: Dictionary = group_variant
		var host_variant = group.get("host", null)
		# Order matters: is_instance_valid() must run before any `is` test,
		# since `is` on a freed Object errors out in Godot 4.
		if host_variant == null or not is_instance_valid(host_variant):
			continue
		if not (host_variant is Control):
			continue
		var host: Control = host_variant
		if not host.is_inside_tree() or not host.is_visible_in_tree():
			kept.append(group)
			continue
		var inside: bool = host.get_global_rect().has_point(mouse_pos)
		if inside != bool(group.get("was_inside", false)):
			group["was_inside"] = inside
			for target_variant in group.get("targets", []):
				if target_variant == null or not is_instance_valid(target_variant):
					continue
				if not (target_variant is Control):
					continue
				(target_variant as Control).modulate.a = 1.0 if inside else 0.0
		kept.append(group)

	hover_groups = kept


func _drive_streaming_buffers(delta: float) -> void:
	if streaming_pending.is_empty():
		return
	streaming_tick_accumulator_sec += delta
	if streaming_tick_accumulator_sec < STREAMING_TICK_INTERVAL_SEC:
		return
	# Collapse multiple missed ticks into a single reveal this frame — we
	# still cap per-frame work via the bytes-per-tick formula.
	streaming_tick_accumulator_sec = 0.0

	var current_scope := _current_session_scope_key()
	var keys: Array = streaming_pending.keys()
	for key_variant in keys:
		var key := str(key_variant)
		var pending := str(streaming_pending.get(key, ""))
		if pending.is_empty():
			streaming_pending.erase(key)
			continue
		var ratio: float = STREAMING_TICK_INTERVAL_SEC / STREAMING_REVEAL_TARGET_SEC
		var bytes_per_tick: int = int(ceil(float(pending.length()) * ratio))
		if bytes_per_tick < 1:
			bytes_per_tick = 1
		bytes_per_tick = min(bytes_per_tick, pending.length())
		var to_reveal: String = pending.substr(0, bytes_per_tick)
		var remaining: String = pending.substr(bytes_per_tick)
		if remaining.is_empty():
			streaming_pending.erase(key)
		else:
			streaming_pending[key] = remaining
		# key format: "scope|entry_index"
		var parts := key.rsplit("|", false, 1)
		if parts.size() != 2:
			continue
		if parts[0] != current_scope:
			# Pending belongs to a different session (user switched threads
			# mid-stream). Drop silently; the transcript already has the full
			# content, and when they switch back the full rebuild will show it.
			continue
		_append_delta_to_text_block(int(parts[1]), to_reveal)


func _streaming_key_for_current(entry_index: int) -> String:
	var scope := _current_session_scope_key()
	if scope.is_empty() or entry_index < 0:
		return ""
	return "%s|%d" % [scope, entry_index]


func _streaming_key_for_session(session: Dictionary, entry_index: int) -> String:
	if entry_index < 0:
		return ""
	return "%s|%s|%d" % [
		str(session.get("agent_id", DEFAULT_AGENT_ID)),
		str(session.get("remote_session_id", "")),
		entry_index,
	]


func _queue_streaming_delta(session: Dictionary, entry_index: int, delta: String) -> void:
	if delta.is_empty():
		return
	var key := _streaming_key_for_session(session, entry_index)
	if key.is_empty():
		return
	streaming_pending[key] = str(streaming_pending.get(key, "")) + delta
	set_process(true)


func _flush_streaming_pending_for_session(session_index: int) -> void:
	# Called on prompt_finished to release any un-revealed bytes immediately so
	# the user sees the final state without the 200ms tail.
	if session_index < 0 or session_index >= sessions.size():
		return
	var session: Dictionary = sessions[session_index]
	var scope := "%s|%s" % [
		str(session.get("agent_id", DEFAULT_AGENT_ID)),
		str(session.get("remote_session_id", "")),
	]
	var keys: Array = streaming_pending.keys()
	for key_variant in keys:
		var key := str(key_variant)
		if not key.begins_with(scope + "|"):
			continue
		var pending := str(streaming_pending.get(key, ""))
		streaming_pending.erase(key)
		if session_index != current_session_index:
			continue
		var parts := key.rsplit("|", false, 1)
		if parts.size() != 2:
			continue
		_append_delta_to_text_block(int(parts[1]), pending)


func _clear_streaming_pending_for_current(entry_index: int) -> void:
	var key := _streaming_key_for_current(entry_index)
	if not key.is_empty():
		streaming_pending.erase(key)


func _build_permission_option_row(request_id: int) -> Control:
	# Zed's `render_permission_buttons_flat` (thread_view.rs:7186-7270):
	#   div().p_1().border_t_1().v_flex().gap_0p5()
	#       .children(options.map(|o| Button::new(o.name).start_icon(icon)))
	# We match that shape — vertical stack, full-width buttons, icon-first.
	var wrapper := MarginContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_theme_constant_override("margin_top", 6)
	wrapper.add_theme_constant_override("margin_left", 4)
	wrapper.add_theme_constant_override("margin_right", 4)
	wrapper.add_theme_constant_override("margin_bottom", 4)

	var separator := HSeparator.new()
	separator.modulate = _editor_color("contrast_color_1", "Editor", Color(0.4, 0.4, 0.45, 0.6))

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 2)
	col.add_child(separator)
	wrapper.add_child(col)

	var pending: Dictionary = pending_permissions.get(request_id, {})
	var options: Array = pending.get("options", [])
	var success_color: Color = _editor_color("success_color", "Editor", Color(0.48, 0.80, 0.54))
	var error_color: Color = _editor_color("error_color", "Editor", Color(0.93, 0.50, 0.50))

	for index in range(options.size()):
		var option_variant = options[index]
		if typeof(option_variant) != TYPE_DICTIONARY:
			continue
		var option: Dictionary = option_variant
		var option_kind: String = str(option.get("kind", ""))
		var button := Button.new()
		button.text = "  %s  %s" % [_permission_glyph(option_kind), _permission_option_label(option)]
		button.focus_mode = Control.FOCUS_NONE
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size = Vector2(0, 28)
		# Tint just the text color per kind, not the whole button surface.
		# Keeps the button chrome neutral and editor-consistent.
		match option_kind:
			"allow_once", "allow_always":
				button.add_theme_color_override("font_color", success_color)
				button.add_theme_color_override("font_hover_color", success_color.lightened(0.1))
			"reject_once", "reject_always":
				button.add_theme_color_override("font_color", error_color)
				button.add_theme_color_override("font_hover_color", error_color.lightened(0.1))
		button.pressed.connect(Callable(self, "_on_permission_option_pressed").bind(request_id, index))
		col.add_child(button)

	return wrapper


func _permission_glyph(option_kind: String) -> String:
	match option_kind:
		"allow_once":
			return "✓"
		"allow_always":
			return "✓✓"
		"reject_once":
			return "✕"
		"reject_always":
			return "✕✕"
		_:
			return "•"


func _make_copy_button(text_to_copy: String, tooltip_label: String = "Copy") -> Button:
	var button := Button.new()
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(22, 22)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.text = "⧉"
	button.tooltip_text = tooltip_label
	button.set_meta("copy_text", text_to_copy)
	button.set_meta("copy_tooltip", tooltip_label)
	button.pressed.connect(Callable(self, "_on_copy_button_pressed").bind(button))
	return button


func _on_copy_button_pressed(button: Button) -> void:
	if not is_instance_valid(button):
		return
	var text_to_copy: String = str(button.get_meta("copy_text", ""))
	if text_to_copy.is_empty():
		return
	DisplayServer.clipboard_set(text_to_copy)
	button.text = "✓"
	button.tooltip_text = "Copied!"
	button.modulate = Color(0.72, 0.94, 0.78, 1.0)
	var tree := get_tree()
	if tree == null:
		return
	var timer := tree.create_timer(COPIED_STATE_SECONDS)
	timer.timeout.connect(Callable(self, "_reset_copy_button").bind(button))


func _reset_copy_button(button: Button) -> void:
	if not is_instance_valid(button):
		return
	button.text = "⧉"
	button.tooltip_text = str(button.get_meta("copy_tooltip", "Copy"))
	button.modulate = Color(1.0, 1.0, 1.0, 1.0)


func _build_thinking_entry(entry: Dictionary, entry_index: int = -1) -> Control:
	var session_scope: String = _current_session_scope_key()
	var block_key := ""
	if not session_scope.is_empty() and entry_index >= 0:
		block_key = "%s|%d" % [session_scope, entry_index]

	var is_open: bool = not block_key.is_empty() and expanded_thinking_blocks.has(block_key)

	# Zed thinking block spec: lives at the assistant indentation (px_5)
	# with light internal padding; no card background in Auto display mode.
	var wrapper := MarginContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_theme_constant_override("margin_left", 20)
	wrapper.add_theme_constant_override("margin_right", 20)
	wrapper.add_theme_constant_override("margin_top", 6)
	wrapper.add_theme_constant_override("margin_bottom", 6)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _stream_panel_style("assistant"))
	wrapper.add_child(panel)

	var padding := MarginContainer.new()
	padding.add_theme_constant_override("margin_left", 10)
	padding.add_theme_constant_override("margin_top", 6)
	padding.add_theme_constant_override("margin_right", 10)
	padding.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(padding)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	padding.add_child(content)

	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8)
	header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# PASS so wheel events bubble up to the ScrollContainer; the left-click
	# handler in _on_summary_row_gui_input doesn't care about propagation.
	header_row.mouse_filter = Control.MOUSE_FILTER_PASS
	header_row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	header_row.gui_input.connect(Callable(self, "_on_summary_row_gui_input").bind(Callable(self, "_on_thinking_block_pressed").bind(block_key)))
	content.add_child(header_row)

	var title_label := Label.new()
	title_label.text = "Thinking"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.modulate = Color(0.82, 0.82, 0.92, 0.78)
	header_row.add_child(title_label)

	var chevron := _make_disclosure_chevron(is_open)
	chevron.pressed.connect(Callable(self, "_on_thinking_block_pressed").bind(block_key))
	header_row.add_child(chevron)

	_wire_hover_only_visibility(panel, [chevron])

	if is_open:
		var body_text: String = _safe_text(str(entry.get("content", "")))
		if not body_text.is_empty():
			content.add_child(_make_stream_text(body_text, "assistant"))

	return wrapper


func _on_thinking_block_pressed(block_key: String) -> void:
	if block_key.is_empty():
		return
	if expanded_thinking_blocks.has(block_key):
		expanded_thinking_blocks.erase(block_key)
	else:
		expanded_thinking_blocks[block_key] = true
	user_toggled_thinking_blocks[block_key] = true

	var parts := block_key.rsplit("|", false, 1)
	if parts.size() == 2 and parts[1].is_valid_int():
		_update_entry_in_feed(int(parts[1]))
	else:
		_refresh_chat_log()


func _build_chat_message_entry(entry: Dictionary, kind: String, entry_index: int = -1) -> Control:
	var body_text: String = str(entry.get("content", ""))
	if body_text.is_empty():
		return Control.new()

	if kind == "user":
		# Zed user message spec (thread_view.rs:4596-4661):
		#   outer: pt_2 pb_3 px_2   (8/12/8)
		#   bubble: py_3 px_2 rounded_md border_1  (12/8)
		var user_wrapper := MarginContainer.new()
		user_wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		user_wrapper.add_theme_constant_override("margin_left", 8)
		user_wrapper.add_theme_constant_override("margin_right", 8)
		user_wrapper.add_theme_constant_override("margin_top", 8)
		user_wrapper.add_theme_constant_override("margin_bottom", 12)

		var panel := PanelContainer.new()
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.add_theme_stylebox_override("panel", _user_prompt_style())
		user_wrapper.add_child(panel)

		var padding := MarginContainer.new()
		padding.add_theme_constant_override("margin_left", 8)
		padding.add_theme_constant_override("margin_top", 12)
		padding.add_theme_constant_override("margin_right", 8)
		padding.add_theme_constant_override("margin_bottom", 12)
		panel.add_child(padding)
		padding.add_child(_make_stream_text(body_text, kind))
		return user_wrapper

	# Zed assistant message spec (thread_view.rs:4797-4802):
	#   px_5 py_1p5  (20/6)  no bubble, just text at the main column
	var assistant_wrapper := MarginContainer.new()
	assistant_wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	assistant_wrapper.add_theme_constant_override("margin_left", 20)
	assistant_wrapper.add_theme_constant_override("margin_right", 20)
	assistant_wrapper.add_theme_constant_override("margin_top", 6)
	assistant_wrapper.add_theme_constant_override("margin_bottom", 6)
	# Streaming → single TextBlock so `_pending_delta_writes` can keep
	# routing chunks to one block.append_text. Finalized → markdown blocks.
	# The transition happens automatically on _on_connection_prompt_finished
	# via _update_entry_in_feed → re-enters this function with the same
	# entry_index but no longer flagged as the active streaming target.
	var assistant_text: Control
	if _is_assistant_entry_streaming(entry_index):
		assistant_text = _make_stream_text(body_text, kind)
	else:
		assistant_text = _make_markdown_blocks(body_text, kind)
	# Wire the right-click context menu on every TextBlock under the
	# assistant body. Single-block streaming layout puts a TextBlock right
	# at the top; markdown layout buries N TextBlocks inside the VBox tree.
	# The walker handles both cases uniformly.
	if entry_index >= 0:
		_attach_assistant_block_right_click(assistant_text, entry_index)
	assistant_wrapper.add_child(assistant_text)
	return assistant_wrapper


func _attach_assistant_block_right_click(root: Control, entry_index: int) -> void:
	if root == null:
		return
	if root is GodetteTextBlock:
		var tb: GodetteTextBlock = root
		tb.set_meta("entry_index", entry_index)
		tb.right_clicked.connect(Callable(self, "_on_assistant_block_right_clicked").bind(tb))
	for child in root.get_children():
		if child is Control:
			_attach_assistant_block_right_click(child, entry_index)


func _is_assistant_entry_streaming(entry_index: int) -> bool:
	# True if any session is currently streaming into this entry slot. The
	# build seam uses this to choose between the single-TextBlock streaming
	# layout and the markdown blocks layout. We scan all sessions, not just
	# the active one, because background sessions can also be streaming
	# simultaneously and only the build site here knows the entry_index.
	if entry_index < 0:
		return false
	for session_variant in sessions:
		var session: Dictionary = session_variant
		if not bool(session.get("busy", false)):
			continue
		if int(session.get("assistant_entry_index", -1)) == entry_index:
			return true
	return false


func _on_assistant_block_right_clicked(_local_pos: Vector2, source: GodetteTextBlock) -> void:
	if not is_instance_valid(source):
		return
	var entry_index: int = int(source.get_meta("entry_index", -1))
	_show_assistant_context_menu(entry_index, source)


func _show_assistant_context_menu(entry_index: int, source: Control) -> void:
	var popup := PopupMenu.new()
	popup.hide_on_item_selection = true
	add_child(popup)
	popup.close_requested.connect(Callable(self, "_cleanup_context_popup").bind(popup))
	popup.id_pressed.connect(Callable(self, "_on_assistant_context_menu_id_pressed").bind(entry_index, source, popup))

	var selected_text := ""
	if source is GodetteTextBlock:
		selected_text = (source as GodetteTextBlock).get_selected_text()
	var id_copy_selection := 1
	popup.add_item("Copy Selection", id_copy_selection)
	popup.set_item_disabled(popup.get_item_count() - 1, selected_text.is_empty())

	popup.add_item("Copy This Agent Response", 2)

	popup.add_separator()

	var at_top: bool = message_scroll != null and message_scroll.scroll_vertical <= 0
	if at_top:
		popup.add_item("Scroll to Bottom", 3)
	else:
		popup.add_item("Scroll to Top", 4)

	popup.reset_size()
	popup.position = DisplayServer.mouse_get_position()
	popup.popup()


func _cleanup_context_popup(popup: PopupMenu) -> void:
	if is_instance_valid(popup):
		popup.queue_free()


func _on_assistant_context_menu_id_pressed(id: int, entry_index: int, source: Control, popup: PopupMenu) -> void:
	match id:
		1:
			if source is GodetteTextBlock:
				var selected: String = (source as GodetteTextBlock).get_selected_text()
				if not selected.is_empty():
					DisplayServer.clipboard_set(selected)
		2:
			var grouped := _collect_agent_response_text(entry_index)
			if not grouped.is_empty():
				DisplayServer.clipboard_set(grouped)
		3:
			_scroll_feed_to_end()
		4:
			_scroll_feed_to_top()
	_cleanup_context_popup(popup)


func _collect_agent_response_text(entry_index: int) -> String:
	if current_session_index < 0 or entry_index < 0:
		return ""
	var current_transcript: Array = _session_transcript(current_session_index)
	if entry_index >= current_transcript.size():
		return ""

	var start_index := 0
	for i in range(entry_index - 1, -1, -1):
		var candidate = current_transcript[i]
		if typeof(candidate) == TYPE_DICTIONARY and _entry_kind(candidate) == "user":
			start_index = i + 1
			break

	var end_index := current_transcript.size() - 1
	for i in range(entry_index + 1, current_transcript.size()):
		var candidate = current_transcript[i]
		if typeof(candidate) == TYPE_DICTIONARY and _entry_kind(candidate) == "user":
			end_index = i - 1
			break

	var parts: Array = []
	for i in range(start_index, end_index + 1):
		var candidate = current_transcript[i]
		if typeof(candidate) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = candidate
		if _entry_kind(entry) != "assistant":
			continue
		var text: String = str(entry.get("content", "")).strip_edges()
		if not text.is_empty():
			parts.append(text)

	return "\n\n".join(parts)


func _scroll_feed_to_top() -> void:
	if message_stream != null:
		message_stream.scroll_to_top()
	elif message_scroll != null:
		message_scroll.scroll_vertical = 0


func _stream_entry_title(entry: Dictionary, kind: String) -> String:
	match kind:
		"user":
			return "You"
		"assistant":
			return _safe_text(str(entry.get("speaker", _agent_label(_current_agent_id()))))
		"tool":
			return _safe_text(str(entry.get("title", "Tool")))
		"plan":
			return "Plan"
		_:
			return _safe_text(str(entry.get("speaker", "System")))


func _stream_entry_summary(entry: Dictionary, kind: String) -> String:
	if kind == "tool":
		return _safe_text(str(entry.get("summary", "")))
	return ""


func _make_stream_text(text: String, kind: String = "") -> Control:
	var block := TextBlockScript.new()
	block.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Deliberately don't call set_font / set_font_size here — TextBlock
	# inherits both from the Control theme chain, which is exactly what
	# neighbouring Label widgets do. That guarantees our body text matches
	# the editor's Label typography (including HiDPI scaling the editor
	# applies on top of the user's configured main font size).

	var body_color := _editor_color("font_color", "Editor", Color(0.93, 0.94, 0.98, 0.96))
	var muted_color := _editor_color("font_readonly_color", "Editor", body_color.darkened(0.2))
	# Match the CodeEdit selection chroma: editor `selection_color` is
	# what the user already recognises as "selected text" across every
	# other editor surface. Its native alpha is around 1.0; bumping it
	# slightly toward translucent (alpha 0.55) keeps the underlying
	# glyphs legible while the selection is visible.
	var selection_color := _editor_color(
		"selection_color",
		"Editor",
		Color(0.36, 0.52, 0.85, 1.0)
	)
	selection_color.a = 0.55

	match kind:
		"user":
			block.set_color(body_color)
		"assistant":
			block.set_color(body_color)
		"tool":
			block.set_color(muted_color)
		_:
			block.set_color(muted_color)
	block.set_line_spacing(STREAM_BODY_LINE_SPACING)
	block.set_selection_color(selection_color)
	block.set_text(_safe_text(text))
	return block


# Build a finalized assistant body as a stack of styled markdown widgets.
# Used only after streaming finishes — during streaming we keep
# _make_stream_text's single TextBlock so the streaming append path stays
# valid (`_pending_delta_writes` routes deltas to one cached block per
# entry, not to a tree of sub-blocks).
#
# Architecture mirrors pulldown-cmark + Zed's thread_view markdown: the
# parser produces a flat event stream (start/end/text/rule/…) and the
# renderer walks it with a container + text-target stack. Keeps block
# handling orthogonal and makes adding new constructs (task list,
# footnote, etc.) a parser-only change.
func _make_markdown_blocks(text: String, kind: String) -> Control:
	# Thin wrapper. Sanitises the text, parses it, hands the event stream
	# off to GodetteMarkdownRender along with a ctx built from the
	# editor theme. The renderer owns all block-widget assembly; the dock
	# stays out of markdown internals.
	var safe: String = _safe_text(text)
	var events: Array = MarkdownScript.parse(safe)
	if events.is_empty():
		return _make_stream_text(text, kind)
	return MarkdownRenderScript.render_events(events, _markdown_render_context(kind))


# Resolve the per-render fonts/colors once per assistant message so each
# block widget can pull from a consistent palette without re-reading the
# editor theme N times. The fonts live for the lifetime of the entry.
func _markdown_render_context(kind: String) -> Dictionary:
	var body_color := _editor_color("font_color", "Editor", Color(0.93, 0.94, 0.98, 0.96))
	var muted_color := _editor_color("font_readonly_color", "Editor", body_color.darkened(0.2))
	var selection_color := _editor_color("selection_color", "Editor", Color(0.36, 0.52, 0.85, 1.0))
	selection_color.a = 0.55

	var fg: Color = body_color
	if kind == "tool":
		fg = muted_color

	# SystemFont rather than FontVariation so we get a real bold / italic /
	# monospace cut from the OS font fallback chain. FontVariation can fake
	# weight by stretching glyph contours but the result is uglier than the
	# native cut and doesn't help if the inherited font lacks bold info.
	var bold := SystemFont.new()
	bold.font_weight = 700
	var italic := SystemFont.new()
	italic.font_italic = true
	var bold_italic := SystemFont.new()
	bold_italic.font_weight = 700
	bold_italic.font_italic = true
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray([
		"Cascadia Mono", "Cascadia Code", "Consolas", "JetBrains Mono",
		"Fira Code", "SF Mono", "Menlo", "Monaco", "Courier New", "monospace",
	])
	var mono_bold := SystemFont.new()
	mono_bold.font_names = mono.font_names
	mono_bold.font_weight = 700

	# Code chip background uses the editor's "dark_color_2" / fallback to a
	# slightly lighter surface than the panel itself so chips read as raised.
	var code_bg := _editor_color("dark_color_2", "Editor", Color(1, 1, 1, 0.06))
	code_bg.a = max(code_bg.a, 0.18)
	var code_block_bg := _editor_color("dark_color_3", "Editor", Color(0, 0, 0, 0.25))
	code_block_bg.a = max(code_block_bg.a, 0.22)
	var rule_color := body_color
	rule_color.a = 0.18
	var blockquote_bar := _editor_color("accent_color", "Editor", Color(0.55, 0.78, 1.0, 1.0))
	blockquote_bar.a = 0.5
	# Link "chip" background — subtle so links read as inline but flagged.
	# Real per-glyph colour for links would need a glyph self-draw path,
	# which is intentionally out of scope for v1 (see TextBlock.set_color).
	var link_bg := _editor_color("accent_color", "Editor", Color(0.55, 0.78, 1.0, 1.0))
	link_bg.a = 0.18

	return {
		"kind": kind,
		"fg": fg,
		"selection_color": selection_color,
		"font_bold": bold,
		"font_italic": italic,
		"font_bold_italic": bold_italic,
		"font_mono": mono,
		"font_mono_bold": mono_bold,
		"code_bg": code_bg,
		"code_block_bg": code_block_bg,
		"rule_color": rule_color,
		"blockquote_bar": blockquote_bar,
		"link_bg": link_bg,
		# GodetteMarkdownRender reads these for heading size derivation
		# and per-TextBlock line spacing. Resolved here so the renderer
		# doesn't need Node access to the editor theme.
		"base_font_size": _editor_main_font_size_for_markdown(),
		"line_spacing": STREAM_BODY_LINE_SPACING,
	}


func _editor_main_font_size_for_markdown() -> int:
	# Mirror the inheritance chain TextBlock would pick up on its own — we
	# need an explicit number so heading sizes can be derived.
	var settings := get_theme_default_font_size()
	if settings > 0:
		return settings
	return STREAM_BODY_FONT_SIZE_FALLBACK


func _user_prompt_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	# Editor "base_color" is the main panel background; darken slightly to
	# give the user bubble its own presence against surrounding feed chrome.
	var base := _editor_color("base_color", "Editor", Color(0.16, 0.17, 0.19, 1.0))
	style.bg_color = base.darkened(0.25)
	var accent := _editor_color("accent_color", "Editor", Color(0.48, 0.52, 0.60, 1.0))
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	# Use accent at low opacity — gives the bubble a subtle, themed outline
	# without screaming for attention like editor buttons do.
	var border := accent
	border.a = 0.35
	style.border_color = border
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_right = 6
	style.corner_radius_bottom_left = 6
	return style


func _prompt_input_style(focused: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	var base := _editor_color("base_color", "Editor", Color(0.06, 0.07, 0.09, 1.0))
	style.bg_color = base.darkened(0.15)
	var accent := _editor_color("accent_color", "Editor", Color(0.48, 0.52, 0.60, 1.0))
	var contrast := _editor_color("contrast_color_1", "Editor", Color(0.30, 0.33, 0.40, 1.0))
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	if focused:
		style.border_color = accent
	else:
		style.border_color = contrast
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_right = 6
	style.corner_radius_bottom_left = 6
	style.content_margin_left = 12
	style.content_margin_top = 10
	style.content_margin_right = 12
	style.content_margin_bottom = 10
	return style


func _build_plan_entry(entry: Dictionary) -> Control:
	var session_key: String = _current_session_scope_key()
	# Dismissed → render a zero-height placeholder so the feed still has a
	# slot for the entry (keeps indices stable and lets an `_upsert_plan_entry`
	# un-dismiss cleanly via update_entry) but nothing shows.
	if bool(plan_dismissed_sessions.get(session_key, false)):
		return Control.new()

	var is_expanded: bool = plan_expanded_sessions.get(session_key, false)
	var plan_entries: Array = entry.get("entries", [])

	var wrapper := MarginContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_theme_constant_override("margin_left", 20)
	wrapper.add_theme_constant_override("margin_right", 20)
	wrapper.add_theme_constant_override("margin_top", 6)
	wrapper.add_theme_constant_override("margin_bottom", 6)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _stream_panel_style("plan"))
	wrapper.add_child(panel)

	var padding := MarginContainer.new()
	padding.add_theme_constant_override("margin_left", 10)
	padding.add_theme_constant_override("margin_top", 8)
	padding.add_theme_constant_override("margin_right", 10)
	padding.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(padding)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	padding.add_child(content)

	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8)
	header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# PASS so wheel events bubble up to the ScrollContainer; the left-click
	# handler in _on_summary_row_gui_input doesn't care about propagation.
	header_row.mouse_filter = Control.MOUSE_FILTER_PASS
	header_row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	header_row.gui_input.connect(Callable(self, "_on_summary_row_gui_input").bind(Callable(self, "_on_plan_summary_pressed").bind(session_key)))
	content.add_child(header_row)

	# Title + count depend on collapsed/expanded:
	#   Expanded  → "Plan"              + "5/7"
	#   Collapsed → "Current: <task>"   + "2 left"   (or just "Plan" when no tasks)
	var title_label := Label.new()
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.modulate = _stream_title_color("plan")
	# Ellipsis is applied by Label automatically when the text overflows the
	# available width — important for long "Current: …" rows so the row
	# doesn't force the feed wider than the viewport.
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.clip_text = true
	var count_label := Label.new()
	count_label.modulate = Color(0.91, 0.91, 0.96, 0.66)

	if is_expanded or plan_entries.is_empty():
		title_label.text = "Plan"
		if plan_entries.is_empty():
			count_label.text = ""
		else:
			count_label.text = _plan_progress_label(plan_entries)
	else:
		var current_task: String = _plan_current_task_text(plan_entries)
		if current_task.is_empty():
			title_label.text = "Plan complete"
		else:
			title_label.text = "Current: %s" % current_task
		var remaining: int = _plan_remaining_count(plan_entries)
		count_label.text = "%d left" % remaining

	header_row.add_child(title_label)
	header_row.add_child(count_label)

	var chevron := _make_disclosure_chevron(is_expanded)
	chevron.pressed.connect(Callable(self, "_on_plan_summary_pressed").bind(session_key))
	header_row.add_child(chevron)

	# × close button. Visually matches the chevron button (same theme path)
	# and sits to its right so the row reads "title … count ⌄ ×" like Zed.
	var close_button := _make_plan_close_button()
	close_button.pressed.connect(Callable(self, "_on_plan_close_pressed").bind(session_key))
	header_row.add_child(close_button)

	if not is_expanded:
		return wrapper

	var divider := HSeparator.new()
	content.add_child(divider)

	if plan_entries.is_empty():
		var empty_label := _make_supporting_label("No planned tasks yet.")
		empty_label.modulate = Color(0.86, 0.86, 0.92, 0.66)
		content.add_child(empty_label)
		return wrapper

	var tasks := VBoxContainer.new()
	tasks.add_theme_constant_override("separation", 2)
	content.add_child(tasks)

	for plan_entry_variant in plan_entries:
		if typeof(plan_entry_variant) != TYPE_DICTIONARY:
			continue
		var plan_entry: Dictionary = plan_entry_variant
		tasks.add_child(_build_plan_task_row(plan_entry))

	return wrapper


func _on_summary_row_gui_input(event: InputEvent, on_press: Callable) -> void:
	if not (event is InputEventMouseButton):
		return
	var mouse_event: InputEventMouseButton = event
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	on_press.call()


func _on_plan_summary_pressed(session_key: String) -> void:
	if session_key.is_empty():
		return
	if plan_expanded_sessions.get(session_key, false):
		plan_expanded_sessions.erase(session_key)
	else:
		plan_expanded_sessions[session_key] = true

	_rebuild_plan_entry_for_session_key(session_key)


func _on_plan_close_pressed(session_key: String) -> void:
	# Hide the plan panel for this session until the agent writes the plan
	# again. We don't touch the transcript entry itself — the dismissal is a
	# UI-only decision. `_upsert_plan_entry` clears the flag on the next
	# update so a fresh plan surfaces immediately.
	if session_key.is_empty():
		return
	plan_dismissed_sessions[session_key] = true
	_rebuild_plan_entry_for_session_key(session_key)


func _rebuild_plan_entry_for_session_key(session_key: String) -> void:
	# Only one plan entry per active session; patch in place if the session
	# is the current foreground one, otherwise the next feed refresh picks
	# up the new state.
	if session_key != _current_session_scope_key():
		return
	if current_session_index >= 0 and current_session_index < sessions.size():
		var session: Dictionary = sessions[current_session_index]
		var plan_index: int = int(session.get("plan_entry_index", -1))
		if plan_index >= 0:
			_update_entry_in_feed(plan_index)
			return
	_refresh_chat_log()


func _make_plan_close_button() -> Button:
	var button := Button.new()
	button.text = "×"
	button.focus_mode = Control.FOCUS_NONE
	button.flat = true
	button.custom_minimum_size = Vector2(20, 20)
	button.tooltip_text = "Dismiss plan"
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# Slightly muted until hovered, matching the chevron button's affordance
	# so the two controls read as a paired toolbar rather than one shouting
	# at the user.
	button.modulate = Color(1.0, 1.0, 1.0, 0.7)
	return button


func _current_session_scope_key() -> String:
	if current_session_index < 0 or current_session_index >= sessions.size():
		return ""
	var session: Dictionary = sessions[current_session_index]
	return "%s|%s" % [
		str(session.get("agent_id", DEFAULT_AGENT_ID)),
		str(session.get("remote_session_id", "")),
	]


func _build_plan_task_row(plan_entry: Dictionary) -> Control:
	var status: String = str(plan_entry.get("status", "pending"))
	var is_completed: bool = status == "completed"

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 10)

	var status_dot_panel := PanelContainer.new()
	status_dot_panel.custom_minimum_size = Vector2(12, 12)
	status_dot_panel.add_theme_stylebox_override("panel", _plan_status_style(status))
	row.add_child(status_dot_panel)

	var task_body := VBoxContainer.new()
	task_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	task_body.add_theme_constant_override("separation", 2)
	row.add_child(task_body)

	# PlanTaskLabel draws its own strike line via _draw when struck=true.
	# Plain Label has no strike-through in Godot's theme system and a
	# RichTextLabel is off the table (see the rendering-stack note), so we
	# subclass Label locally. The fade-to-60% on completed rows is the
	# secondary "done" cue, matching Zed's panel.
	var task_label := PlanTaskLabel.new()
	task_label.text = _safe_text(str(plan_entry.get("content", "")))
	task_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	task_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if is_completed:
		task_label.struck = true
		task_label.modulate = Color(1.0, 1.0, 1.0, 0.6)
	task_body.add_child(task_label)

	var meta_text: String = _plan_meta_text(plan_entry)
	if not meta_text.is_empty():
		var meta_label := Label.new()
		meta_label.text = _safe_text(meta_text)
		meta_label.modulate = Color(0.85, 0.85, 0.90, 0.58)
		meta_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		meta_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		task_body.add_child(meta_label)

	return row


func _plan_status_style(status: String) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.corner_radius_top_left = 99
	style.corner_radius_top_right = 99
	style.corner_radius_bottom_right = 99
	style.corner_radius_bottom_left = 99
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1

	match status:
		"completed":
			style.bg_color = Color(0.34, 0.82, 0.47, 0.98)
			style.border_color = Color(0.34, 0.82, 0.47, 0.98)
		"in_progress":
			style.bg_color = Color(0.52, 0.69, 0.98, 0.95)
			style.border_color = Color(0.52, 0.69, 0.98, 0.95)
		_:
			style.bg_color = Color(0, 0, 0, 0)
			style.border_color = Color(0.78, 0.79, 0.84, 0.52)

	return style


func _plan_progress_label(entries: Array) -> String:
	# Expanded-header count, e.g. "5/7". Matches the progress indicator Zed
	# shows in its plan panel — users read it as "5 of 7 tasks done".
	var done: int = 0
	for entry_variant in entries:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		if str((entry_variant as Dictionary).get("status", "")) == "completed":
			done += 1
	return "%d/%d" % [done, entries.size()]


func _plan_remaining_count(entries: Array) -> int:
	# Collapsed-header count, e.g. "2 left". Anything not "completed"
	# (pending, in_progress, or unknown statuses) counts as remaining so the
	# number doesn't understate when the agent emits unusual statuses.
	var remaining: int = 0
	for entry_variant in entries:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		if str((entry_variant as Dictionary).get("status", "")) != "completed":
			remaining += 1
	return remaining


func _plan_current_task_text(entries: Array) -> String:
	# Pick the task to surface on the collapsed row. Prefer in_progress — if
	# the agent has explicitly flagged one task as active, that's the most
	# useful "Current:" label. Otherwise fall back to the first pending
	# entry so the user sees what's next. Returns empty string when nothing
	# qualifies (e.g., all tasks done).
	var first_pending: String = ""
	for entry_variant in entries:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_variant
		var status: String = str(entry.get("status", ""))
		var content: String = str(entry.get("content", ""))
		if status == "in_progress":
			return content
		if first_pending.is_empty() and status != "completed":
			first_pending = content
	return first_pending


func _plan_meta_text(plan_entry: Dictionary) -> String:
	var parts: Array = []
	var status: String = str(plan_entry.get("status", "pending"))
	var priority: String = str(plan_entry.get("priority", ""))

	if not status.is_empty():
		parts.append(_humanize_identifier(status))
	if not priority.is_empty():
		parts.append("%s priority" % _humanize_identifier(priority).to_lower())

	return " | ".join(parts)


func _stream_panel_style(kind: String) -> StyleBoxFlat:
	# All card backgrounds derive from the editor's "base_color". Per-kind
	# tweaks are small offsets so the feed reads as "subtly banded" rather
	# than a rainbow of panel colors.
	var base := _editor_color("base_color", "Editor", Color(0.16, 0.17, 0.19, 1.0))
	var background: Color = base
	match kind:
		"user":
			background = base.lightened(0.06)
		"assistant":
			background = base.lightened(0.02)
		"tool":
			background = base.darkened(0.06)
		"plan":
			background = base
		_:
			background = base

	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	# Editor "contrast_color_1" is the default border color in dark themes;
	# falls back to a lightened base if the theme doesn't define it.
	style.border_color = _editor_color("contrast_color_1", "Editor", background.lightened(0.08))
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_right = 6
	style.corner_radius_bottom_left = 6
	return style


func _stream_title_color(kind: String) -> Color:
	var base := _editor_color("font_color", "Editor", Color(0.95, 0.95, 1.0, 1.0))
	var muted := _editor_color("font_readonly_color", "Editor", base.darkened(0.15))
	match kind:
		"user":
			return base
		"assistant":
			return base
		"tool":
			return muted
		"plan":
			return muted
		_:
			return muted


func _scroll_feed_to_end() -> void:
	# Re-arm the VirtualFeed's follow-tail so subsequent range changes track
	# the bottom automatically. During bulk replay the direct scroll-to-max
	# here races the layout pass (max_value is stale); follow-tail handles
	# the post-layout scroll via the scrollbar's changed signal.
	if message_stream != null:
		message_stream.scroll_to_bottom()
	elif message_scroll != null:
		var scrollbar: VScrollBar = message_scroll.get_v_scroll_bar()
		if scrollbar != null:
			message_scroll.scroll_vertical = int(scrollbar.max_value)


func _send_prompt() -> void:
	if current_session_index < 0:
		return

	var prompt: String = prompt_input.text.strip_edges()
	if prompt.is_empty():
		_append_system_message("Write a prompt first.")
		return

	var session: Dictionary = sessions[current_session_index]
	# Busy → enqueue and let `_on_connection_prompt_finished` pick it up
	# when the current turn ends. `_dispatch_next_prompt` already no-ops
	# while busy, so calling it unconditionally is safe.
	var blocks: Array = _build_prompt_blocks(prompt, _session_attachments(current_session_index))
	var queue: Array = session.get("queued_prompts", [])
	queue.append({"blocks": blocks})
	session["queued_prompts"] = queue
	sessions[current_session_index] = session

	_append_user_message_to_session(current_session_index, prompt)
	prompt_input.clear()
	_ensure_remote_session(current_session_index)
	_dispatch_next_prompt(current_session_index)
	_refresh_queue_indicator()
	_refresh_status()


func _on_send_button_pressed() -> void:
	if current_session_index < 0 or current_session_index >= sessions.size():
		return

	var session: Dictionary = sessions[current_session_index]
	if bool(session.get("busy", false)):
		_cancel_current_turn(current_session_index)
		return

	_send_prompt()


func _on_composer_submit_requested() -> void:
	# Enter-to-submit routes straight to _send_prompt regardless of busy
	# state. Busy + Enter = queue the follow-up (handled inside
	# _send_prompt). The send button is the only control that doubles as
	# Stop — the keyboard shortcut never cancels, to avoid surprising a
	# user who hit Enter intending to queue and instead killed the turn.
	_send_prompt()


func _dispatch_next_prompt(session_index: int) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	var session: Dictionary = sessions[session_index]
	if bool(session.get("busy", false)):
		return

	var remote_session_id: String = str(session.get("remote_session_id", ""))
	if remote_session_id.is_empty():
		return

	var queue: Array = session.get("queued_prompts", [])
	if queue.is_empty():
		return

	var connection = _ensure_connection(str(session.get("agent_id", DEFAULT_AGENT_ID)))
	if connection == null:
		return

	var next_prompt: Dictionary = queue.pop_front()
	session["queued_prompts"] = queue
	session["busy"] = true
	session["cancelling"] = false
	session["assistant_entry_index"] = -1
	session["plan_entry_index"] = -1
	sessions[session_index] = session

	var request_id: int = int(connection.prompt(remote_session_id, next_prompt.get("blocks", [])))
	if request_id < 0:
		queue.push_front(next_prompt)
		session["queued_prompts"] = queue
		session["busy"] = false
		sessions[session_index] = session
		_append_transcript_to_session(session_index, "System", "Couldn't send the prompt to the local ACP adapter.")
		_refresh_send_state()
		_refresh_status()
		return

	_refresh_send_state()
	_refresh_status()


func _cancel_current_turn(session_index: int) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	var session: Dictionary = sessions[session_index]
	if not bool(session.get("busy", false)):
		return
	if bool(session.get("cancelling", false)):
		return

	var remote_session_id: String = str(session.get("remote_session_id", ""))
	if remote_session_id.is_empty():
		return

	var agent_id: String = str(session.get("agent_id", DEFAULT_AGENT_ID))
	var connection = _ensure_connection(agent_id)
	if connection == null:
		return

	session["cancelling"] = true
	sessions[session_index] = session
	_cancel_permission_requests_for_session(agent_id, remote_session_id)
	connection.cancel_session(remote_session_id)
	_refresh_send_state()
	_refresh_status()


func _cancel_permission_requests_for_session(agent_id: String, remote_session_id: String) -> void:
	var to_cancel: Array = []
	for request_id_variant in pending_permissions.keys():
		var pending: Dictionary = pending_permissions[request_id_variant]
		if str(pending.get("agent_id", "")) != agent_id:
			continue
		var pending_session_id: String = str(pending.get("remote_session_id", ""))
		if not remote_session_id.is_empty() and pending_session_id != remote_session_id:
			continue
		to_cancel.append(request_id_variant)
	for request_id_variant in to_cancel:
		_resolve_permission(int(request_id_variant), {"outcome": "cancelled"})


func _ensure_connection(agent_id: String):
	var existing = connections.get(agent_id, null)
	if existing != null and is_instance_valid(existing):
		var existing_status: String = str(connection_status.get(agent_id, ""))
		if existing_status != "error" and existing_status != "offline":
			return existing
		existing.shutdown()
		existing.queue_free()
		connections.erase(agent_id)

	var connection = ACPConnectionScript.new()
	add_child(connection)
	connection.initialized.connect(Callable(self, "_on_connection_initialized"))
	connection.session_created.connect(Callable(self, "_on_connection_session_created"))
	connection.session_loaded.connect(Callable(self, "_on_connection_session_loaded"))
	connection.session_load_failed.connect(Callable(self, "_on_connection_session_load_failed"))
	connection.session_create_failed.connect(Callable(self, "_on_connection_session_create_failed"))
	connection.sessions_listed.connect(Callable(self, "_on_connection_sessions_listed"))
	connection.session_update.connect(Callable(self, "_on_connection_session_update"))
	connection.prompt_finished.connect(Callable(self, "_on_connection_prompt_finished"))
	connection.session_mode_changed.connect(Callable(self, "_on_connection_session_mode_changed"))
	connection.session_model_changed.connect(Callable(self, "_on_connection_session_model_changed"))
	connection.session_config_options_changed.connect(Callable(self, "_on_connection_session_config_options_changed"))
	connection.permission_requested.connect(Callable(self, "_on_connection_permission_requested"))
	connection.transport_status.connect(Callable(self, "_on_connection_transport_status"))
	connection.protocol_error.connect(Callable(self, "_on_connection_protocol_error"))
	connection.stderr_output.connect(Callable(self, "_on_connection_stderr_output"))

	connections[agent_id] = connection
	connection_status[agent_id] = "starting"
	pending_remote_sessions[agent_id] = pending_remote_sessions.get(agent_id, [])
	pending_remote_session_loads[agent_id] = pending_remote_session_loads.get(agent_id, [])

	if not connection.start(agent_id, _adapter_candidates(agent_id)):
		connection_status[agent_id] = "offline"
		connections.erase(agent_id)
		connection.queue_free()
		_append_system_message_to_agent(agent_id, "Couldn't launch the local ACP adapter for %s." % _agent_label(agent_id))
		_refresh_status()
		return null

	return connection


func _ensure_remote_session(session_index: int) -> bool:
	if session_index < 0 or session_index >= sessions.size():
		return false

	var session: Dictionary = sessions[session_index]
	var remote_session_id: String = str(session.get("remote_session_id", ""))
	if not remote_session_id.is_empty():
		if bool(session.get("remote_session_loaded", false)):
			return true
		if bool(session.get("loading_remote_session", false)):
			return false

		var agent_id_for_load := str(session.get("agent_id", DEFAULT_AGENT_ID))
		var load_connection = _ensure_connection(agent_id_for_load)
		if load_connection == null:
			return false

		session["loading_remote_session"] = true
		sessions[session_index] = session

		var pending_loads: Array = pending_remote_session_loads.get(agent_id_for_load, [])
		if pending_loads.find(str(session.get("id", ""))) < 0:
			pending_loads.append(str(session.get("id", "")))
		pending_remote_session_loads[agent_id_for_load] = pending_loads

		if str(connection_status.get(agent_id_for_load, "")) == "ready":
			_flush_pending_session_loads(agent_id_for_load)

		_refresh_status()
		return false

	if bool(session.get("creating_remote_session", false)):
		return false

	var agent_id := str(session.get("agent_id", DEFAULT_AGENT_ID))
	var connection = _ensure_connection(agent_id)
	if connection == null:
		return false

	session["creating_remote_session"] = true
	sessions[session_index] = session

	var pending: Array = pending_remote_sessions.get(agent_id, [])
	if pending.find(str(session.get("id", ""))) < 0:
		pending.append(str(session.get("id", "")))
	pending_remote_sessions[agent_id] = pending

	if str(connection_status.get(agent_id, "")) == "ready":
		_flush_pending_session_creates(agent_id)
		_flush_pending_session_loads(agent_id)

	_refresh_status()
	return false


func _flush_pending_session_creates(agent_id: String) -> void:
	var connection = connections.get(agent_id, null)
	if connection == null or not is_instance_valid(connection):
		return

	var pending: Array = pending_remote_sessions.get(agent_id, [])
	if pending.is_empty():
		return

	pending_remote_sessions[agent_id] = []
	var project_root := ProjectSettings.globalize_path("res://")
	for local_session_id in pending:
		var session_index: int = _find_session_index_by_id(str(local_session_id))
		if session_index < 0:
			continue
		var session: Dictionary = sessions[session_index]
		if not str(session.get("remote_session_id", "")).is_empty():
			continue
		if connection.create_session(str(session.get("id", "")), project_root) < 0:
			session["creating_remote_session"] = false
			sessions[session_index] = session
			_append_transcript_to_session(session_index, "System", "Couldn't create the remote ACP session.")


func _flush_pending_session_loads(agent_id: String) -> void:
	var connection = connections.get(agent_id, null)
	if connection == null or not is_instance_valid(connection):
		return

	var pending: Array = pending_remote_session_loads.get(agent_id, [])
	if pending.is_empty():
		return

	pending_remote_session_loads[agent_id] = []
	var project_root := _project_root_path()
	for local_session_id in pending:
		var session_index: int = _find_session_index_by_id(str(local_session_id))
		if session_index < 0:
			continue
		var session: Dictionary = sessions[session_index]
		var remote_session_id: String = str(session.get("remote_session_id", ""))
		if remote_session_id.is_empty():
			continue
		if bool(session.get("remote_session_loaded", false)):
			continue
		var replay_key: String = "%s|%s" % [
			str(session.get("agent_id", DEFAULT_AGENT_ID)),
			remote_session_id,
		]
		replaying_sessions[replay_key] = true
		if connection.load_session(str(session.get("id", "")), remote_session_id, project_root) < 0:
			session["loading_remote_session"] = false
			sessions[session_index] = session
			replaying_sessions.erase(replay_key)
			_append_transcript_to_session(session_index, "System", "Couldn't load the existing remote ACP session.")


func _adapter_candidates(agent_id: String) -> Array:
	var candidates: Array = []
	var os_name := OS.get_name()

	if os_name == "Windows":
		var appdata := OS.get_environment("APPDATA").replace("\\", "/")
		var npm_root := appdata.path_join("npm")
		var zed_root := npm_root.path_join("node_modules").path_join("@zed-industries")
		var system_root := OS.get_environment("SystemRoot").replace("\\", "/")
		var cmd_exe := OS.get_environment("ComSpec").replace("\\", "/")
		if cmd_exe.is_empty() and not system_root.is_empty():
			cmd_exe = system_root.path_join("System32").path_join("cmd.exe")
		var program_files := OS.get_environment("ProgramFiles").replace("\\", "/")
		var npx_cmd := program_files.path_join("nodejs").path_join("npx.cmd")
		if agent_id == "claude_agent":
			var claude_global_cmd := npm_root.path_join("claude-agent-acp.cmd")
			if not cmd_exe.is_empty() and FileAccess.file_exists(claude_global_cmd):
				candidates.append({"path": cmd_exe, "args": PackedStringArray(["/d", "/c", claude_global_cmd])})
			var claude_js := appdata.path_join("npm").path_join("node_modules").path_join("@agentclientprotocol").path_join("claude-agent-acp").path_join("dist").path_join("index.js")
			if FileAccess.file_exists(claude_js):
				candidates.append({"path": "node", "args": PackedStringArray([claude_js])})
			if not cmd_exe.is_empty() and FileAccess.file_exists(npx_cmd):
				candidates.append({"path": cmd_exe, "args": PackedStringArray(["/d", "/c", npx_cmd, "-y", "@agentclientprotocol/claude-agent-acp@0.30.0"])})
		else:
			var codex_global_cmd := npm_root.path_join("codex-acp.cmd")
			if not cmd_exe.is_empty() and FileAccess.file_exists(codex_global_cmd):
				candidates.append({"path": cmd_exe, "args": PackedStringArray(["/d", "/c", codex_global_cmd])})
			var codex_js := zed_root.path_join("codex-acp").path_join("bin").path_join("codex-acp.js")
			if FileAccess.file_exists(codex_js):
				candidates.append({"path": "node", "args": PackedStringArray([codex_js])})
			if not cmd_exe.is_empty() and FileAccess.file_exists(npx_cmd):
				candidates.append({"path": cmd_exe, "args": PackedStringArray(["/d", "/c", npx_cmd, "-y", "@zed-industries/codex-acp@0.11.1"])})
		return candidates

	if agent_id == "claude_agent":
		candidates.append({"path": "claude-agent-acp", "args": PackedStringArray()})
		candidates.append({"path": "npx", "args": PackedStringArray(["-y", "@agentclientprotocol/claude-agent-acp@0.30.0"])})
	else:
		candidates.append({"path": "codex-acp", "args": PackedStringArray()})
		candidates.append({"path": "npx", "args": PackedStringArray(["-y", "@zed-industries/codex-acp@0.11.1"])})
	return candidates


func _on_connection_initialized(agent_id: String, _result: Dictionary) -> void:
	connection_status[agent_id] = "ready"
	if startup_discovery_agents.has(agent_id):
		var connection = connections.get(agent_id, null)
		if connection != null and is_instance_valid(connection):
			connection.list_sessions(_project_root_path())
	_flush_pending_session_creates(agent_id)
	_flush_pending_session_loads(agent_id)
	_refresh_status()


func _on_connection_session_created(agent_id: String, local_session_id: String, remote_session_id: String, result: Dictionary) -> void:
	var session_index: int = _find_session_index_by_id(local_session_id)
	if session_index < 0:
		return

	var session: Dictionary = sessions[session_index]
	session["remote_session_id"] = remote_session_id
	session["remote_session_loaded"] = true
	session["loading_remote_session"] = false
	session["creating_remote_session"] = false
	session["models"] = result.get("models", [])
	session["modes"] = result.get("modes", [])
	session["config_options"] = result.get("configOptions", [])
	session["current_model_id"] = _selector_current_value(session.get("models", []), "currentModelId", "availableModels")
	session["current_mode_id"] = _selector_current_value(session.get("modes", []), "currentModeId", "availableModes")
	sessions[session_index] = session
	_schedule_persist_state()

	if session_index == current_session_index:
		_refresh_composer_options()
	_dispatch_next_prompt(session_index)
	_refresh_status()


func _on_connection_session_loaded(agent_id: String, local_session_id: String, remote_session_id: String, result: Dictionary) -> void:
	var session_index: int = _find_session_index_by_id(local_session_id)
	if session_index < 0:
		return

	var session: Dictionary = sessions[session_index]
	session["remote_session_id"] = remote_session_id
	session["remote_session_loaded"] = true
	session["loading_remote_session"] = false
	session["creating_remote_session"] = false
	session["models"] = result.get("models", session.get("models", []))
	session["modes"] = result.get("modes", session.get("modes", []))
	session["config_options"] = result.get("configOptions", session.get("config_options", []))
	session["current_model_id"] = _selector_current_value(session.get("models", []), "currentModelId", "availableModels", str(session.get("current_model_id", "")))
	session["current_mode_id"] = _selector_current_value(session.get("modes", []), "currentModeId", "availableModes", str(session.get("current_mode_id", "")))
	sessions[session_index] = session

	var replay_key: String = "%s|%s" % [str(session.get("agent_id", DEFAULT_AGENT_ID)), remote_session_id]
	replaying_sessions.erase(replay_key)

	_schedule_persist_state()

	if session_index == current_session_index:
		_refresh_composer_options()
		# Rebuild the feed from the now-complete transcript. Without this,
		# first-time open may leave the feed empty: set_entries_snapshot()
		# ran before replay arrived, and the per-chunk _append_entry_to_feed
		# path has shown timing-related gaps where the feed falls out of
		# sync with the transcript. One explicit snapshot here matches what
		# manually re-selecting the same session from the thread menu does,
		# and guarantees the post-load view is correct regardless of how
		# the incremental path fared.
		_refresh_chat_log()
	_dispatch_next_prompt(session_index)
	_refresh_status()


func _on_connection_session_load_failed(agent_id: String, local_session_id: String, remote_session_id: String, _error_code: int, error_message: String) -> void:
	var session_index: int = _find_session_index_by_id(local_session_id)
	if session_index < 0:
		return

	var session: Dictionary = sessions[session_index]
	session["loading_remote_session"] = false
	session["creating_remote_session"] = false
	sessions[session_index] = session

	var replay_key: String = "%s|%s" % [str(session.get("agent_id", DEFAULT_AGENT_ID)), remote_session_id]
	replaying_sessions.erase(replay_key)

	if _is_resource_missing_error(error_message):
		var title: String = str(session.get("title", remote_session_id))
		_evict_session(session_index)
		_append_system_message_to_agent(agent_id, "Session \"%s\" no longer exists on %s; removing from local history." % [title, _agent_label(agent_id)])
	else:
		_append_transcript_to_session(session_index, "System", "Couldn't load this session: %s" % error_message)

	_refresh_send_state()
	_refresh_status()


func _on_connection_session_create_failed(agent_id: String, local_session_id: String, _error_code: int, error_message: String) -> void:
	var session_index: int = _find_session_index_by_id(local_session_id)
	if session_index < 0:
		_append_system_message_to_agent(agent_id, "Couldn't create a new session: %s" % error_message)
		return

	var session: Dictionary = sessions[session_index]
	session["creating_remote_session"] = false
	session["loading_remote_session"] = false
	sessions[session_index] = session

	_append_transcript_to_session(session_index, "System", "Couldn't create this session: %s" % error_message)
	_refresh_send_state()
	_refresh_status()


func _drop_keys_with_prefix(target: Dictionary, prefix: String) -> void:
	var to_drop: Array = []
	for key_variant in target.keys():
		if str(key_variant).begins_with(prefix):
			to_drop.append(key_variant)
	for key_variant in to_drop:
		target.erase(key_variant)


func _is_resource_missing_error(error_message: String) -> bool:
	var lowered: String = error_message.to_lower()
	return "not found" in lowered or "does not exist" in lowered or "no such" in lowered or "missing" in lowered


func _evict_session(session_index: int) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	var session: Dictionary = sessions[session_index]
	var evicted_session_key: String = "%s|%s" % [
		str(session.get("agent_id", DEFAULT_AGENT_ID)),
		str(session.get("remote_session_id", "")),
	]
	# Drop view-local expand state that referenced this session.
	var scope_prefix: String = evicted_session_key + "|"
	_drop_keys_with_prefix(expanded_tool_calls, scope_prefix)
	_drop_keys_with_prefix(expanded_thinking_blocks, scope_prefix)
	_drop_keys_with_prefix(user_toggled_thinking_blocks, scope_prefix)
	_drop_keys_with_prefix(streaming_pending, scope_prefix)
	auto_expanded_thinking_block.erase(evicted_session_key)
	plan_expanded_sessions.erase(evicted_session_key)
	replaying_sessions.erase(evicted_session_key)

	SessionStoreScript.delete_thread_cache(str(session.get("id", "")))
	sessions.remove_at(session_index)

	if current_session_index == session_index:
		current_session_index = -1
		if not sessions.is_empty():
			_switch_session(_most_recent_session_index())
		else:
			_refresh_thread_menu()
			_refresh_chat_log()
			_create_session(selected_agent_id, true, true)
	elif current_session_index > session_index:
		current_session_index -= 1
		_refresh_thread_menu()

	_schedule_persist_state()


func _on_connection_sessions_listed(agent_id: String, remote_sessions: Array, next_cursor: String) -> void:
	_import_remote_sessions(agent_id, remote_sessions)

	if not next_cursor.is_empty():
		var connection = connections.get(agent_id, null)
		if connection != null and is_instance_valid(connection):
			connection.list_sessions(_project_root_path(), next_cursor)
		return

	_finish_startup_discovery_for_agent(agent_id)


func _on_connection_session_update(agent_id: String, remote_session_id: String, update: Dictionary) -> void:
	var session_index: int = _find_session_index_by_remote(agent_id, remote_session_id)
	if session_index < 0:
		return

	var update_kind := str(update.get("sessionUpdate", ""))
	match update_kind:
		"agent_message_chunk":
			var content: Dictionary = update.get("content", {})
			var chunk_text := ""
			if str(content.get("type", "")) == "text":
				chunk_text = str(content.get("text", ""))
			elif not str(content.get("type", "")).is_empty():
				chunk_text = "[%s]" % str(content.get("type", "chunk"))
			if not chunk_text.is_empty():
				_append_agent_chunk_to_session(session_index, chunk_text)
		"agent_thought_chunk":
			var thought_content: Dictionary = update.get("content", {})
			var thought_text := ""
			if str(thought_content.get("type", "")) == "text":
				thought_text = str(thought_content.get("text", ""))
			if not thought_text.is_empty():
				_append_thought_chunk_to_session(session_index, thought_text)
		"tool_call":
			_upsert_tool_call_entry(session_index, update)
		"tool_call_update":
			_upsert_tool_call_entry(session_index, update)
		"plan":
			var plan_entries_in: Array = update.get("entries", [])
			print("[godette/plan] received plan update from %s session=%s entries=%d" % [agent_id, remote_session_id, plan_entries_in.size()])
			_upsert_plan_entry(session_index, plan_entries_in)
		"current_mode_update":
			_update_session_mode_state(session_index, str(update.get("currentModeId", "")))
		"config_option_update":
			_update_session_config_options(session_index, update.get("configOptions", []))
		"session_info_update":
			_update_session_title_from_info(session_index, update)
		"available_commands_update":
			var session: Dictionary = sessions[session_index]
			session["available_commands"] = update
			sessions[session_index] = session
			var cmd_names: Array = []
			for cmd_variant in update.get("availableCommands", []):
				if typeof(cmd_variant) == TYPE_DICTIONARY:
					cmd_names.append(str(cmd_variant.get("name", "?")))
			print("[godette/cmds] available_commands_update from %s session=%s commands=%s" % [agent_id, remote_session_id, str(cmd_names)])
		_:
			pass


func _on_connection_prompt_finished(agent_id: String, remote_session_id: String, result: Dictionary) -> void:
	var session_index: int = _find_session_index_by_remote(agent_id, remote_session_id)
	if session_index < 0:
		return

	var session: Dictionary = sessions[session_index]
	# Capture the streaming target before we clear it: the build seam uses
	# `_is_assistant_entry_streaming` to choose layout, so we need to flip
	# busy/assistant_entry_index off *first*, then re-build the entry to
	# swap its single-TextBlock layout for the markdown blocks layout.
	var prev_assistant_entry_index: int = int(session.get("assistant_entry_index", -1))
	session["busy"] = false
	session["cancelling"] = false
	session["assistant_entry_index"] = -1
	sessions[session_index] = session

	var stop_reason := str(result.get("stopReason", "done"))
	if stop_reason != "end_turn":
		_append_transcript_to_session(session_index, "System", "%s finished with %s." % [_agent_label(agent_id), stop_reason])

	# Release any un-revealed smoothing buffer so the final state shows
	# immediately instead of trickling over another 200ms.
	_flush_streaming_pending_for_session(session_index)
	_finalize_auto_expanded_thoughts_for_session(session_index)
	# Trigger the streaming → markdown swap. Only when this session is the
	# foreground one — background sessions don't have their entries
	# materialised in the visible feed, so the rebuild would be wasted work
	# (re-materialisation when the user switches threads picks up the
	# finalized layout anyway).
	if session_index == current_session_index and prev_assistant_entry_index >= 0:
		_update_entry_in_feed(prev_assistant_entry_index)
	_dispatch_next_prompt(session_index)
	_refresh_send_state()
	_refresh_status()


func _on_connection_session_mode_changed(agent_id: String, remote_session_id: String, mode_id: String) -> void:
	var session_index: int = _find_session_index_by_remote(agent_id, remote_session_id)
	if session_index < 0:
		return

	_update_session_mode_state(session_index, mode_id)


func _on_connection_session_model_changed(agent_id: String, remote_session_id: String, model_id: String) -> void:
	var session_index: int = _find_session_index_by_remote(agent_id, remote_session_id)
	if session_index < 0:
		return

	_update_session_model_state(session_index, model_id)


func _on_connection_session_config_options_changed(agent_id: String, remote_session_id: String, config_options: Array) -> void:
	var session_index: int = _find_session_index_by_remote(agent_id, remote_session_id)
	if session_index < 0:
		return

	_update_session_config_options(session_index, config_options)


func _on_connection_permission_requested(agent_id: String, request_id: int, params: Dictionary) -> void:
	var remote_session_id: String = str(params.get("sessionId", ""))
	var tool_call_variant = params.get("toolCall", {})
	var tool_call: Dictionary = tool_call_variant if typeof(tool_call_variant) == TYPE_DICTIONARY else {}
	var tool_call_id: String = str(tool_call.get("toolCallId", ""))
	var options_variant = params.get("options", [])
	var options: Array = options_variant if options_variant is Array else []

	var connection = connections.get(agent_id, null)

	if options.is_empty() or tool_call_id.is_empty():
		if connection != null and is_instance_valid(connection):
			connection.reply_permission(request_id, _default_permission_outcome(params))
		return

	var session_index: int = _find_session_index_by_remote(agent_id, remote_session_id)
	if session_index < 0:
		if connection != null and is_instance_valid(connection):
			connection.reply_permission(request_id, {"outcome": "cancelled"})
		return

	_upsert_tool_call_entry(session_index, tool_call)

	var session: Dictionary = sessions[session_index]
	var tool_calls: Dictionary = session.get("tool_calls", {})
	var tool_state: Dictionary = tool_calls.get(tool_call_id, {})
	var transcript_index: int = int(tool_state.get("transcript_index", -1))
	if transcript_index < 0:
		if connection != null and is_instance_valid(connection):
			connection.reply_permission(request_id, {"outcome": "cancelled"})
		return

	var current_transcript: Array = session.get("transcript", [])
	var entry: Dictionary = current_transcript[transcript_index]
	entry["pending_permission_request_id"] = request_id
	current_transcript[transcript_index] = entry
	session["transcript"] = current_transcript
	sessions[session_index] = session

	pending_permissions[request_id] = {
		"agent_id": agent_id,
		"remote_session_id": remote_session_id,
		"tool_call_id": tool_call_id,
		"options": options
	}

	if session_index == current_session_index:
		_update_entry_in_feed(transcript_index)


func _on_connection_transport_status(agent_id: String, status: String) -> void:
	connection_status[agent_id] = status
	if status == "offline" or status == "error":
		_finish_startup_discovery_for_agent(agent_id)
	_refresh_status()


func _on_connection_protocol_error(agent_id: String, message: String) -> void:
	connection_status[agent_id] = "error"
	_append_system_message_to_agent(agent_id, message)
	_finish_startup_discovery_for_agent(agent_id)
	_refresh_status()


func _on_connection_stderr_output(agent_id: String, line: String) -> void:
	if "error" in line.to_lower() or "failed" in line.to_lower():
		_append_system_message_to_agent(agent_id, line)
	_refresh_status()


func _permission_option_label(option: Dictionary) -> String:
	var name := str(option.get("name", ""))
	if not name.is_empty():
		return name
	return _humanize_identifier(str(option.get("kind", "Choose"))).capitalize()


func _default_permission_outcome(params: Dictionary) -> Dictionary:
	var options: Array = params.get("options", [])
	for option in options:
		if str(option.get("kind", "")) == "reject_once":
			return {"outcome": "selected", "optionId": str(option.get("optionId", ""))}
	if not options.is_empty():
		return {"outcome": "selected", "optionId": str(options[0].get("optionId", ""))}
	return {"outcome": "cancelled"}


func _resolve_permission(request_id: int, outcome: Dictionary) -> void:
	if not pending_permissions.has(request_id):
		return

	var pending: Dictionary = pending_permissions[request_id]
	var agent_id: String = str(pending.get("agent_id", ""))
	var remote_session_id: String = str(pending.get("remote_session_id", ""))
	var tool_call_id: String = str(pending.get("tool_call_id", ""))

	var connection = connections.get(agent_id, null)
	if connection != null and is_instance_valid(connection):
		connection.reply_permission(request_id, outcome)

	pending_permissions.erase(request_id)

	var session_index: int = _find_session_index_by_remote(agent_id, remote_session_id)
	if session_index < 0:
		return

	var session: Dictionary = sessions[session_index]
	var tool_calls: Dictionary = session.get("tool_calls", {})
	var tool_state: Dictionary = tool_calls.get(tool_call_id, {})
	var transcript_index: int = int(tool_state.get("transcript_index", -1))
	if transcript_index >= 0:
		var current_transcript: Array = session.get("transcript", [])
		if transcript_index < current_transcript.size():
			var entry: Dictionary = current_transcript[transcript_index]
			entry.erase("pending_permission_request_id")
			current_transcript[transcript_index] = entry
			session["transcript"] = current_transcript
			sessions[session_index] = session

	if session_index == current_session_index and transcript_index >= 0:
		_update_entry_in_feed(transcript_index)


func _on_permission_option_pressed(request_id: int, option_index: int) -> void:
	if not pending_permissions.has(request_id):
		return

	var pending: Dictionary = pending_permissions[request_id]
	var options: Array = pending.get("options", [])
	if option_index < 0 or option_index >= options.size():
		_resolve_permission(request_id, {"outcome": "cancelled"})
		return

	var option: Dictionary = options[option_index]
	_resolve_permission(request_id, {
		"outcome": "selected",
		"optionId": str(option.get("optionId", ""))
	})


func attach_paths(paths: PackedStringArray) -> void:
	if current_session_index < 0:
		return

	var current_attachments := _session_attachments(current_session_index)
	for path in paths:
		var normalized_path := str(path).strip_edges()
		if normalized_path.is_empty():
			continue
		var key := "file:%s" % normalized_path
		if _attachments_has_key(current_attachments, key):
			continue

		# Structured prompt blocks (composer_context.build_prompt_blocks)
		# emit a `resource_link` for the path and let the adapter resolve
		# file contents on its own. Previously we pre-read up to 32 KB of
		# each attached file and embedded it into the user bubble + the
		# ACP prompt body; that bloated the per-thread cache and duplicated
		# content the adapter can fetch on demand.
		current_attachments.append({
			"key": key,
			"kind": "file",
			"label": normalized_path,
			"path": normalized_path
		})

	_set_session_attachments(current_session_index, current_attachments)
	_refresh_composer_context()
	_refresh_status()


func attach_selected_files() -> void:
	if editor_interface == null:
		return

	attach_paths(editor_interface.get_selected_paths())


func attach_current_scene() -> void:
	if editor_interface == null or current_session_index < 0:
		return

	var root := editor_interface.get_edited_scene_root()
	if root == null:
		_append_system_message("No edited scene is open.")
		return

	var current_attachments := _session_attachments(current_session_index)
	var scene_path := root.scene_file_path
	var label := scene_path if not scene_path.is_empty() else root.name
	var key := "scene:%s" % label
	if _attachments_has_key(current_attachments, key):
		_append_system_message("Current scene is already attached.")
		return

	current_attachments.append({
		"key": key,
		"kind": "scene",
		"label": label,
		"scene_path": scene_path,
		"summary": _build_scene_summary(root)
	})
	_set_session_attachments(current_session_index, current_attachments)
	_refresh_composer_context()
	_refresh_status()


func attach_selected_nodes() -> void:
	if editor_interface == null:
		return

	var selection := editor_interface.get_selection()
	if selection == null:
		return

	attach_nodes(selection.get_selected_nodes())


func attach_nodes(nodes: Array) -> void:
	if editor_interface == null or current_session_index < 0:
		return

	var current_attachments := _session_attachments(current_session_index)
	var root := editor_interface.get_edited_scene_root()
	for node in nodes:
		if not (node is Node):
			continue

		var relative_path := "."
		if root != null and node != root:
			relative_path = str(root.get_path_to(node))

		var key := "node:%s" % relative_path
		if _attachments_has_key(current_attachments, key):
			continue

		var label := "%s (%s)" % [node.name, node.get_class()]
		current_attachments.append({
			"key": key,
			"kind": "node",
			"label": label,
			"relative_node_path": relative_path,
			"scene_path": root.scene_file_path if root != null else "",
			"summary": _describe_node(node)
		})

	_set_session_attachments(current_session_index, current_attachments)
	_refresh_composer_context()
	_refresh_status()


func clear_context() -> void:
	if current_session_index < 0:
		return

	_set_session_attachments(current_session_index, [])
	_refresh_composer_context()
	_refresh_status()


func clear_chat() -> void:
	if current_session_index < 0:
		return

	_create_session(_current_agent_id(), true, true)
	_refresh_status()


# --- Composer drag-drop ----------------------------------------------------
# Drops onto prompt_input go through these two callbacks via
# set_drag_forwarding. They recognise the two drag-data shapes Godot's
# editor produces from its own docks:
#   FileSystem dock  -> {"type": "files", "files": PackedStringArray}
#   SceneTree dock   -> {"type": "nodes", "nodes": Array[NodePath|Node]}
# Anything else (raw text etc.) is declined so TextEdit's default drop
# behaviour (paste-as-text) still works.

func _on_composer_image_pasted(image: Image) -> void:
	# Ctrl+V of an image (screenshots, copied rasters) lands here. Save the
	# image into the per-project attachment dir as PNG so the adapter can
	# later read it off disk or embed it, then append it as a chip. PNG is
	# a safe common denominator across adapter ingest paths — lossless,
	# universally accepted, and we don't have to guess the clipboard's
	# original MIME type.
	if current_session_index < 0 or image == null or image.is_empty():
		return
	if not DirAccess.dir_exists_absolute(PASTED_IMAGE_DIR):
		DirAccess.make_dir_recursive_absolute(PASTED_IMAGE_DIR)

	# Ticks-msec suffix: `Time.get_datetime_string_from_system` only has
	# second resolution, so rapid paste bursts would collide on the
	# filename. Appending ticks_msec gives per-paste uniqueness without
	# pulling in UUID machinery.
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	var filename := "clip_%s_%d.png" % [stamp, Time.get_ticks_msec()]
	var path := PASTED_IMAGE_DIR + filename
	var save_err := image.save_png(path)
	if save_err != OK:
		_append_system_message("Couldn't save pasted image: error %d" % save_err)
		return

	var key := "image:%s" % path
	var session_attachments := _session_attachments(current_session_index)
	if _attachments_has_key(session_attachments, key):
		return
	session_attachments.append({
		"key": key,
		"kind": "image",
		"label": filename,
		"path": path,
		"width": image.get_width(),
		"height": image.get_height()
	})
	_set_session_attachments(current_session_index, session_attachments)
	_refresh_composer_context()
	_refresh_status()
	_schedule_persist_state()


func _composer_can_drop(_at_position: Vector2, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var kind := str(data.get("type", ""))
	return kind == "files" or kind == "nodes"


func _composer_drop(_at_position: Vector2, data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	var kind := str(data.get("type", ""))
	match kind:
		"files":
			var paths := _coerce_paths(data.get("files", PackedStringArray()))
			if paths.size() > 0:
				attach_paths(paths)
		"nodes":
			var resolved: Array = []
			var scene_root: Node = null
			if editor_interface != null:
				scene_root = editor_interface.get_edited_scene_root()
			var nodes_variant = data.get("nodes", [])
			if nodes_variant is Array:
				for entry in nodes_variant:
					var node := _resolve_drag_node(entry, scene_root)
					if node != null:
						resolved.append(node)
			if not resolved.is_empty():
				attach_nodes(resolved)
	if prompt_input != null:
		prompt_input.grab_focus()


func _coerce_paths(value: Variant) -> PackedStringArray:
	if value is PackedStringArray:
		return value
	var packed := PackedStringArray()
	if value is Array:
		for entry in value:
			packed.append(str(entry))
	return packed


func _resolve_drag_node(entry: Variant, scene_root: Node) -> Node:
	# SceneTree drag payloads can contain Node instances (rare), NodePath
	# objects, or plain Strings. Resolve against the edited scene root so
	# the path format (absolute vs relative) doesn't matter at the call
	# site.
	if entry is Node:
		return entry
	if scene_root == null:
		return null
	if entry is NodePath:
		return scene_root.get_node_or_null(entry)
	if entry is String:
		return scene_root.get_node_or_null(NodePath(entry))
	return null


func _build_prompt_blocks(prompt: String, current_attachments: Array) -> Array:
	# Delegates to the composer module so the data shape stays next to its
	# producer. File/scene attachments are emitted as `resource_link` blocks
	# rather than flattened text, so raw file bodies no longer appear in
	# the visible user bubble.
	return ComposerContextScript.build_prompt_blocks(prompt, current_attachments)


func _refresh_composer_context() -> void:
	if composer_context == null:
		return

	# Keep chip styling in step with the editor's base color in case the user
	# flips between dark / light themes at runtime.
	composer_context.set_chip_base_color(
		_editor_color("base_color", "Editor", Color(0.22, 0.24, 0.28, 1.0)).lightened(0.08)
	)

	if current_session_index < 0:
		composer_context.set_attachments([])
		composer_context.visible = false
		return

	var raw_attachments: Array = _session_attachments(current_session_index)
	# Enrich with runtime-only fields (editor-theme icons) before handing to
	# the composer. The originals in `sessions[i].attachments` stay clean so
	# persistence doesn't have to worry about non-serializable Texture2D
	# references leaking into the per-thread cache.
	var enriched: Array = []
	for attachment_variant in raw_attachments:
		if typeof(attachment_variant) != TYPE_DICTIONARY:
			continue
		var copy: Dictionary = (attachment_variant as Dictionary).duplicate()
		var icon := _attachment_icon(copy)
		if icon != null:
			copy["_icon_texture"] = icon
		enriched.append(copy)

	composer_context.set_attachments(enriched)
	composer_context.visible = composer_context.has_attachments()


func _attachment_icon(attachment: Dictionary) -> Texture2D:
	# Pick a Godot editor icon that matches the attachment kind / extension.
	# Returns null when no editor theme is available (plugin being run
	# outside the editor) so the composer just renders the chip without an
	# icon rather than showing a broken texture slot.
	if editor_interface == null:
		return null
	var theme: Theme = editor_interface.get_editor_theme()
	if theme == null:
		return null

	var kind := str(attachment.get("kind", ""))
	var icon_name: String = ""
	match kind:
		"file":
			icon_name = _icon_name_for_file_path(str(attachment.get("path", "")))
		"image":
			icon_name = "ImageTexture"
		"scene":
			icon_name = "PackedScene"
		"node":
			# attach_nodes stores label as "NodeName (ClassName)"; pull the
			# ClassName out so we show Node2D / Button / etc. icons that
			# match the editor's tree view.
			var lbl := str(attachment.get("label", ""))
			var paren_open := lbl.rfind("(")
			var paren_close := lbl.rfind(")")
			if paren_open >= 0 and paren_close > paren_open:
				icon_name = lbl.substr(paren_open + 1, paren_close - paren_open - 1)
			if icon_name.is_empty():
				icon_name = "Node"
		_:
			icon_name = "File"

	if theme.has_icon(icon_name, "EditorIcons"):
		return theme.get_icon(icon_name, "EditorIcons")
	# Fallback chain: known-missing class names shouldn't leave the chip
	# bare — fall back to a generic file icon so the chip still looks
	# anchored.
	if theme.has_icon("File", "EditorIcons"):
		return theme.get_icon("File", "EditorIcons")
	return null


func _icon_name_for_file_path(path: String) -> String:
	if path.is_empty():
		return "File"
	# Directories drop in as paths too (Godot FileSystem supports folder
	# drops). Check first so the extension branch doesn't treat the last
	# segment as a filename.
	if DirAccess.dir_exists_absolute(path) or path.ends_with("/"):
		return "Folder"
	var ext := path.get_extension().to_lower()
	match ext:
		"gd":
			return "GDScript"
		"cs":
			return "CSharpScript"
		"tscn", "scn":
			return "PackedScene"
		"tres", "res":
			return "Resource"
		"png", "jpg", "jpeg", "webp", "svg", "bmp":
			return "ImageTexture"
		"ogg", "wav", "mp3":
			return "AudioStream"
		"ttf", "otf":
			return "FontFile"
		"md", "txt":
			return "TextFile"
		"json":
			return "JSON"
		"shader", "gdshader":
			return "Shader"
		"cfg":
			return "ConfigFile"
		_:
			return "File"


func _refresh_chat_log() -> void:
	if chat_log_refresh_pending:
		return
	chat_log_refresh_pending = true
	call_deferred("_flush_chat_log_refresh")


func _append_entry_to_feed(entry_index: int) -> void:
	if message_stream == null or current_session_index < 0:
		return
	if chat_log_refresh_pending:
		return
	var transcript: Array = _session_transcript(current_session_index)
	if entry_index < 0 or entry_index >= transcript.size():
		return
	var entry_variant = transcript[entry_index]
	if typeof(entry_variant) != TYPE_DICTIONARY:
		return
	# The feed must be in sync with the transcript tail for incremental append.
	if entry_index != message_stream.get_entry_count():
		_refresh_chat_log()
		return
	# No explicit scroll-to-end here: VirtualFeed's follow-tail auto-scrolls
	# when the virtual height grows and the user hasn't scrolled up.
	message_stream.append_entry(entry_variant)


func _update_entry_in_feed(entry_index: int) -> void:
	if message_stream == null or current_session_index < 0:
		return
	if chat_log_refresh_pending:
		return
	if entry_index < 0 or entry_index >= message_stream.get_entry_count():
		_refresh_chat_log()
		return
	var transcript: Array = _session_transcript(current_session_index)
	if entry_index >= transcript.size():
		_refresh_chat_log()
		return
	var entry_variant = transcript[entry_index]
	if typeof(entry_variant) != TYPE_DICTIONARY:
		return
	# Rebuild invalidates any pending streaming reveal for this slot; the new
	# Control already shows the full transcript content so further buffer
	# appends would duplicate text.
	_clear_streaming_pending_for_current(entry_index)
	message_stream.update_entry(entry_index, entry_variant)


func _flush_chat_log_refresh() -> void:
	chat_log_refresh_pending = false
	if message_stream == null:
		return
	# Every row goes away under a full swap / clear. VirtualFeed's
	# `_destroy_all_controls` skips per-entry `entry_freed` emissions to
	# avoid signal storms, so wipe the text-block cache here explicitly.
	# New entries will repopulate it as they materialize. Also drop any
	# pending per-frame delta writes: their entry indices refer to the
	# pre-swap transcript and would mis-target after the rebuild.
	_entry_text_block_cache.clear()
	_pending_delta_writes.clear()
	if current_session_index < 0:
		message_stream.clear_entries()
		_last_flushed_session_index = -1
		return
	var current_transcript: Array = _session_transcript(current_session_index)
	message_stream.set_entries_snapshot(current_transcript)
	# Only pin to the bottom when this flush is the first render for a
	# newly-activated thread. Mid-session rebuilds (tool-card expand, plan
	# item update, replay completion while the user is reading history,
	# etc) preserve whatever scroll position / follow-tail state the user
	# already has.
	var switched_session: bool = _last_flushed_session_index != current_session_index
	_last_flushed_session_index = current_session_index
	if switched_session:
		call_deferred("_scroll_feed_to_end")


func _refresh_thread_menu() -> void:
	if thread_menu_refresh_pending:
		return
	thread_menu_refresh_pending = true
	call_deferred("_flush_thread_menu_refresh")


func _flush_thread_menu_refresh() -> void:
	thread_menu_refresh_pending = false
	if thread_menu == null:
		return

	thread_menu.text = _current_thread_title()
	var popup := thread_menu.get_popup()
	popup.clear()

	if sessions.is_empty():
		return

	var recent_indices: Array = _recent_session_indices(RECENT_SESSION_LIMIT)
	var listed: Dictionary = {}
	popup.add_item("Recently Updated", -1)
	popup.set_item_disabled(popup.get_item_count() - 1, true)
	for session_index_variant in recent_indices:
		var session_index: int = int(session_index_variant)
		var recent_session: Dictionary = sessions[session_index]
		popup.add_icon_item(
			_agent_icon_texture(str(recent_session.get("agent_id", DEFAULT_AGENT_ID)), THREAD_MENU_AGENT_ICON_SIZE),
			_thread_menu_label(session_index),
			THREAD_MENU_SESSION_ID_OFFSET + session_index
		)
		popup.set_item_tooltip(popup.get_item_count() - 1, _thread_menu_tooltip(session_index))
		listed[session_index] = true

	if sessions.size() > recent_indices.size():
		popup.add_separator()
		popup.add_item("All Sessions", -1)
		popup.set_item_disabled(popup.get_item_count() - 1, true)
		for session_index in range(sessions.size()):
			if listed.has(session_index):
				continue
			var session: Dictionary = sessions[session_index]
			popup.add_icon_item(
				_agent_icon_texture(str(session.get("agent_id", DEFAULT_AGENT_ID)), THREAD_MENU_AGENT_ICON_SIZE),
				_thread_menu_label(session_index),
				THREAD_MENU_SESSION_ID_OFFSET + session_index
			)
			popup.set_item_tooltip(popup.get_item_count() - 1, _thread_menu_tooltip(session_index))


func _refresh_add_menu() -> void:
	if add_menu == null:
		return

	var popup := add_menu.get_popup()
	popup.clear()
	popup.add_item("External Agents", -1)
	popup.set_item_disabled(popup.get_item_count() - 1, true)
	for index in range(AGENTS.size()):
		popup.add_item(str(AGENTS[index]["label"]), ADD_MENU_AGENT_ID_OFFSET + index)
	popup.add_separator()
	popup.add_item("Add More Agents", -1)
	popup.set_item_disabled(popup.get_item_count() - 1, true)
	add_menu.icon = ADD_ICON


func _selector_option_value(option_dict: Dictionary) -> String:
	if option_dict.has("value"):
		return str(option_dict.get("value", ""))
	if option_dict.has("id"):
		return str(option_dict.get("id", ""))
	if option_dict.has("modelId"):
		return str(option_dict.get("modelId", ""))
	return ""


func _humanize_identifier(value: String) -> String:
	if value.is_empty():
		return ""

	var words: PackedStringArray = value.replace("-", " ").replace("_", " ").split(" ", false)
	var result: Array = []
	for word in words:
		if word.is_empty():
			continue
		result.append(word.substr(0, 1).to_upper() + word.substr(1))
	return " ".join(result)


func _selector_option_name(option_dict: Dictionary) -> String:
	var option_value: String = _selector_option_value(option_dict)
	return _safe_text(str(option_dict.get("name", option_value)))


func _selector_button_name(option_dict: Dictionary) -> String:
	var name: String = _selector_option_name(option_dict)
	if name.ends_with(" (recommended)"):
		return name.trim_suffix(" (recommended)")
	return name


func _selector_option_tooltip(option_dict: Dictionary) -> String:
	var description: String = _safe_text(str(option_dict.get("description", "")).strip_edges())
	if description.is_empty():
		return _selector_option_name(option_dict)
	return "%s\n\n%s" % [_selector_option_name(option_dict), description]


func _selector_options(options_variant, collection_key: String) -> Array:
	if typeof(options_variant) == TYPE_DICTIONARY:
		var options_dict: Dictionary = options_variant
		var collected = options_dict.get(collection_key, [])
		if collected is Array:
			return collected
		return []
	if options_variant is Array:
		return options_variant
	return []


func _selector_default_value(options: Array) -> String:
	for option in options:
		if typeof(option) != TYPE_DICTIONARY:
			continue
		var option_dict: Dictionary = option
		for key in ["current", "isCurrent", "selected", "isSelected", "default", "isDefault", "recommended"]:
			if bool(option_dict.get(key, false)):
				return _selector_option_value(option_dict)

	if not options.is_empty():
		var first_option = options[0]
		if typeof(first_option) == TYPE_DICTIONARY:
			return _selector_option_value(first_option)
		return str(first_option)
	return ""


func _selector_current_value(options_variant, current_key: String, collection_key: String, fallback: String = "") -> String:
	if typeof(options_variant) == TYPE_DICTIONARY:
		var options_dict: Dictionary = options_variant
		var explicit_value: String = str(options_dict.get(current_key, fallback))
		if not explicit_value.is_empty():
			return explicit_value
		return _selector_default_value(_selector_options(options_variant, collection_key))

	if options_variant is Array:
		if not fallback.is_empty():
			return fallback
		return _selector_default_value(options_variant)

	return fallback


func _selector_current_name(options: Array, current_value: String, fallback: String) -> String:
	for option in options:
		if typeof(option) != TYPE_DICTIONARY:
			continue
		var option_dict: Dictionary = option
		if _selector_option_value(option_dict) == current_value:
			return _selector_button_name(option_dict)
	return fallback


func _selector_text_width(button: MenuButton, label: String) -> float:
	# `font.get_string_size` reshapes the string, which fires a NUL warning
	# for every embedded U+0000. Selectors measure themselves constantly
	# during composer reflow — an unsanitised label here is enough to
	# account for tens of thousands of "Unexpected NUL character" entries
	# during a single startup when the adapter-supplied model / mode names
	# carry NUL escapes.
	var safe_label: String = _safe_text(label)
	var font: Font = button.get_theme_font("font")
	var font_size: int = button.get_theme_font_size("font_size")
	if font == null:
		return float(safe_label.length() * max(font_size, 14))
	return font.get_string_size(safe_label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


func _selector_preferred_width(button: MenuButton, label: String) -> float:
	# Includes padding, arrow space, and left/right chrome around the text glyphs.
	return ceilf(_selector_text_width(button, label) + 36.0)


func _selector_min_adaptive_width(button: MenuButton, label: String) -> float:
	if label.is_empty():
		return _selector_preferred_width(button, "…")
	var first_grapheme := label.substr(0, 1)
	return _selector_preferred_width(button, "%s…" % first_grapheme)


func _make_selector_menu(current_label: String, options: Array, current_value: String, pressed_handler: Callable, tooltip_text: String = "") -> MenuButton:
	var button := MenuButton.new()
	button.flat = false
	button.focus_mode = Control.FOCUS_NONE
	button.text = _safe_text(current_label) if not current_label.is_empty() else "Option"
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.clip_text = true
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.tooltip_text = button.text if tooltip_text.is_empty() else _safe_text("%s\n%s" % [button.text, tooltip_text])
	button.custom_minimum_size = Vector2(_selector_preferred_width(button, button.text), 30)
	button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

	var popup := button.get_popup()
	popup.hide_on_item_selection = true
	popup.hide_on_checkable_item_selection = true

	var item_id := 0
	for option in options:
		if typeof(option) != TYPE_DICTIONARY:
			continue
		var option_dict: Dictionary = option
		popup.add_radio_check_item(_selector_option_name(option_dict), item_id)
		popup.set_item_metadata(item_id, _selector_option_value(option_dict))
		popup.set_item_checked(item_id, _selector_option_value(option_dict) == current_value)
		popup.set_item_tooltip(item_id, _selector_option_tooltip(option_dict))
		item_id += 1

	popup.id_pressed.connect(pressed_handler.bind(popup))
	return button


func _make_placeholder_selector(label: String, tooltip_text: String = "") -> MenuButton:
	var button := MenuButton.new()
	button.flat = false
	button.text = label
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.disabled = false
	button.tooltip_text = button.text if tooltip_text.is_empty() else "%s\n%s" % [button.text, tooltip_text]
	button.custom_minimum_size = Vector2(_selector_preferred_width(button, button.text), 30)
	button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return button


func _on_composer_bar_resized() -> void:
	call_deferred("_reflow_composer_selectors")


func _reflow_composer_selectors() -> void:
	if composer_options_bar == null or send_button == null:
		return

	var selectors: Array = []
	for child in composer_options_bar.get_children():
		if child == send_button:
			continue
		if child is MenuButton:
			selectors.append(child)

	if selectors.is_empty():
		return

	var bar_width: float = composer_options_bar.size.x
	if bar_width <= 0.0:
		bar_width = size.x
	if bar_width <= 0.0:
		call_deferred("_reflow_composer_selectors")
		return

	var available_width: float = bar_width - send_button.get_combined_minimum_size().x
	var separation: float = float(composer_options_bar.get_theme_constant("separation"))
	available_width -= separation * float(selectors.size())
	if available_width <= 0.0:
		call_deferred("_reflow_composer_selectors")
		return

	var preferred_total := 0.0
	var preferred_widths: Array = []
	for selector_variant in selectors:
		var selector: MenuButton = selector_variant as MenuButton
		var preferred := _selector_preferred_width(selector, selector.text)
		preferred_widths.append(preferred)
		preferred_total += preferred

	var width_scale := 1.0
	if preferred_total > available_width:
		width_scale = available_width / preferred_total

	for selector_index in range(selectors.size()):
		var selector: MenuButton = selectors[selector_index] as MenuButton
		var preferred: float = float(preferred_widths[selector_index])
		var adaptive_min := _selector_min_adaptive_width(selector, selector.text)
		var target_width := max(adaptive_min, floor(preferred * width_scale))
		selector.custom_minimum_size = Vector2(target_width, 30)


func _normalized_config_options(session: Dictionary) -> Array:
	var config_options: Array = session.get("config_options", [])
	if not config_options.is_empty():
		return config_options

	if str(session.get("agent_id", DEFAULT_AGENT_ID)) == "codex_cli":
		return _codex_fallback_config_options(session)

	return []


func _normalized_modes(session: Dictionary):
	var modes_variant = session.get("modes", [])
	if not _selector_options(modes_variant, "availableModes").is_empty():
		return modes_variant

	if str(session.get("agent_id", DEFAULT_AGENT_ID)) == "claude_agent":
		return {
			"currentModeId": str(session.get("current_mode_id", "default")),
			"availableModes": [
				{"id": "default", "name": "Default", "description": "Standard behavior, prompts for dangerous operations"},
				{"id": "acceptEdits", "name": "Accept Edits", "description": "Auto-accept file edit operations"},
				{"id": "plan", "name": "Plan Mode", "description": "Planning mode, no actual tool execution"},
				{"id": "dontAsk", "name": "Don't Ask", "description": "Don't prompt for permissions, deny if not pre-approved"},
				{"id": "bypassPermissions", "name": "Bypass Permissions", "description": "Bypass all permission checks"}
			]
		}

	if str(session.get("agent_id", DEFAULT_AGENT_ID)) == "codex_cli":
		return {
			"currentModeId": str(session.get("current_mode_id", "auto")),
			"availableModes": [
				{"id": "read-only", "name": "Read Only", "description": "Codex can read files in the current workspace. Approval is required to edit files or access the internet."},
				{"id": "auto", "name": "Default", "description": "Codex can read and edit files in the current workspace, and run commands. Approval is required to access the internet or edit other files."},
				{"id": "full-access", "name": "Full Access", "description": "Codex can edit files outside this workspace and access the internet without asking for approval."}
			]
		}

	return modes_variant


func _normalized_models(session: Dictionary):
	var models_variant = session.get("models", [])
	if not _selector_options(models_variant, "availableModels").is_empty():
		return models_variant

	if str(session.get("agent_id", DEFAULT_AGENT_ID)) == "claude_agent":
		return {
			"currentModelId": str(session.get("current_model_id", "default")),
			"availableModels": [
				{"modelId": "default", "name": "Default (recommended)", "description": "Opus 4.6 - Most capable for complex work"},
				{"modelId": "sonnet", "name": "Sonnet", "description": "Sonnet 4.5 - Best for everyday tasks"},
				{"modelId": "haiku", "name": "Haiku", "description": "Haiku 4.5 - Fastest for quick answers"}
			]
		}

	return models_variant


func _codex_fallback_config_options(session: Dictionary) -> Array:
	var current_mode_id: String = str(session.get("current_mode_id", "auto"))
	var current_model_token: String = str(session.get("current_model_id", ""))
	if current_model_token.is_empty():
		current_model_token = _selector_current_value(session.get("models", []), "currentModelId", "availableModels", "gpt-5.4/xhigh")

	var model_family: String = current_model_token.get_slice("/", 0)
	if model_family.is_empty():
		model_family = "gpt-5.4"

	var reasoning_effort: String = current_model_token.get_slice("/", 1)
	if reasoning_effort.is_empty():
		reasoning_effort = "xhigh"

	return [
		{
			"id": "mode",
			"name": "Approval Preset",
			"description": "Choose an approval and sandboxing preset for your session",
			"type": "select",
			"currentValue": current_mode_id,
			"options": [
				{"value": "read-only", "name": "Read Only", "description": "Codex can read files in the current workspace. Approval is required to edit files or access the internet."},
				{"value": "auto", "name": "Default", "description": "Codex can read and edit files in the current workspace, and run commands. Approval is required to access the internet or edit other files."},
				{"value": "full-access", "name": "Full Access", "description": "Codex can edit files outside this workspace and access the internet without asking for approval."}
			]
		},
		{
			"id": "model",
			"name": "Model",
			"description": "Choose which model Codex should use",
			"type": "select",
			"currentValue": model_family,
			"options": [
				{"value": "gpt-5.4", "name": "gpt-5.4", "description": "Latest frontier agentic coding model."},
				{"value": "gpt-5.2-codex", "name": "gpt-5.2-codex", "description": "Frontier agentic coding model."},
				{"value": "gpt-5.1-codex-max", "name": "gpt-5.1-codex-max", "description": "Codex-optimized flagship for deep and fast reasoning."},
				{"value": "gpt-5.4-mini", "name": "GPT-5.4-Mini", "description": "Smaller frontier agentic coding model."},
				{"value": "gpt-5.3-codex", "name": "gpt-5.3-codex", "description": "Frontier Codex-optimized agentic coding model."},
				{"value": "gpt-5.2", "name": "gpt-5.2", "description": "Optimized for professional work and long-running agents"},
				{"value": "gpt-5.1-codex-mini", "name": "gpt-5.1-codex-mini", "description": "Optimized for codex. Cheaper, faster, but less capable."}
			]
		},
		{
			"id": "reasoning_effort",
			"name": "Reasoning Effort",
			"description": "Choose how much reasoning effort the model should use",
			"type": "select",
			"currentValue": reasoning_effort,
			"options": [
				{"value": "low", "name": "Low", "description": "Fast responses with lighter reasoning"},
				{"value": "medium", "name": "Medium", "description": "Balances speed and reasoning depth for everyday tasks"},
				{"value": "high", "name": "High", "description": "Greater reasoning depth for complex problems"},
				{"value": "xhigh", "name": "Xhigh", "description": "Extra high reasoning depth for complex problems"}
			]
		}
	]


func _refresh_composer_options() -> void:
	if composer_options_bar == null:
		return

	for child in composer_options_bar.get_children():
		if child == send_button:
			continue
		composer_options_bar.remove_child(child)
		child.queue_free()

	if current_session_index < 0:
		_update_prompt_placeholder()
		call_deferred("_reflow_composer_selectors")
		return

	var session: Dictionary = sessions[current_session_index]
	var agent_id: String = str(session.get("agent_id", DEFAULT_AGENT_ID))

	var config_options: Array = _normalized_config_options(session)
	if not config_options.is_empty():
		for config_option in config_options:
			if typeof(config_option) != TYPE_DICTIONARY:
				continue
			var config_option_dict: Dictionary = config_option
			if str(config_option_dict.get("type", "")) != "select":
				continue
			var options: Array = config_option_dict.get("options", [])
			var current_value: String = str(config_option_dict.get("currentValue", ""))
			var fallback_label: String = _humanize_identifier(str(config_option_dict.get("id", "option")))
			var current_label: String = _selector_current_name(options, current_value, fallback_label)
			var selector := _make_selector_menu(
				current_label,
				options,
				current_value,
				Callable(self, "_on_config_menu_id_pressed").bind(str(config_option_dict.get("id", ""))),
				str(config_option_dict.get("description", ""))
			)
			composer_options_bar.add_child(selector)
		composer_options_bar.move_child(send_button, composer_options_bar.get_child_count() - 1)
		_update_prompt_placeholder()
		call_deferred("_reflow_composer_selectors")
		return

	var modes_variant = _normalized_modes(session)
	var current_mode_id: String = _selector_current_value(modes_variant, "currentModeId", "availableModes", str(session.get("current_mode_id", "")))
	var available_modes: Array = _selector_options(modes_variant, "availableModes")
	if not available_modes.is_empty():
		var mode_selector := _make_selector_menu(
			_selector_current_name(available_modes, current_mode_id, "Mode"),
			available_modes,
			current_mode_id,
			Callable(self, "_on_mode_menu_id_pressed")
		)
		composer_options_bar.add_child(mode_selector)

	var models_variant = _normalized_models(session)
	var current_model_id: String = _selector_current_value(models_variant, "currentModelId", "availableModels", str(session.get("current_model_id", "")))
	var available_models: Array = _selector_options(models_variant, "availableModels")
	if not available_models.is_empty():
		var model_selector := _make_selector_menu(
			_selector_current_name(available_models, current_model_id, "Model"),
			available_models,
			current_model_id,
			Callable(self, "_on_model_menu_id_pressed")
		)
		composer_options_bar.add_child(model_selector)
	if config_options.is_empty() and available_modes.is_empty() and available_models.is_empty():
		if agent_id == "codex_cli":
			composer_options_bar.add_child(_make_placeholder_selector("Access", "Codex session options are not available yet."))
			composer_options_bar.add_child(_make_placeholder_selector("Model", "Codex session options are not available yet."))
			composer_options_bar.add_child(_make_placeholder_selector("Reasoning", "Codex session options are not available yet."))
		elif agent_id == "claude_agent":
			composer_options_bar.add_child(_make_placeholder_selector("Mode", "Claude session options are not available yet."))
			if available_models.is_empty():
				composer_options_bar.add_child(_make_placeholder_selector("Model", "Claude session options are not available yet."))

	composer_options_bar.move_child(send_button, composer_options_bar.get_child_count() - 1)
	_update_prompt_placeholder()
	call_deferred("_reflow_composer_selectors")


func _refresh_send_state() -> void:
	if send_button == null:
		return

	if current_session_index < 0:
		send_button.disabled = true
		send_button.icon = SEND_ICON
		send_button.tooltip_text = "Send"
		_refresh_queue_indicator()
		return

	var session: Dictionary = sessions[current_session_index]
	var busy: bool = bool(session.get("busy", false))
	var cancelling: bool = bool(session.get("cancelling", false))
	send_button.icon = STOP_ICON if busy else SEND_ICON
	send_button.tooltip_text = "Stop" if busy else "Send"
	send_button.disabled = cancelling
	_refresh_queue_indicator()


func _refresh_queue_indicator() -> void:
	# Kept distinct from _refresh_send_state so it can be called after a
	# queue mutation without forcing a send-button repaint. Shows the
	# pending prompt count for the active session; hidden when zero.
	if queue_count_label == null:
		return
	var count: int = 0
	if current_session_index >= 0 and current_session_index < sessions.size():
		var session: Dictionary = sessions[current_session_index]
		count = (session.get("queued_prompts", []) as Array).size()
	if count <= 0:
		queue_count_label.visible = false
		queue_count_label.text = ""
		queue_count_label.tooltip_text = ""
		return
	queue_count_label.visible = true
	queue_count_label.text = "%d queued" % count
	queue_count_label.tooltip_text = (
		"Prompts waiting behind the current turn.\n"
		+ "They'll send automatically in order when the agent finishes."
	)


func _refresh_loading_scanner() -> void:
	if loading_scanner == null:
		return
	var should_show: bool = false
	if current_session_index >= 0 and current_session_index < sessions.size():
		var session: Dictionary = sessions[current_session_index]
		should_show = bool(session.get("loading_remote_session", false)) \
			or bool(session.get("creating_remote_session", false)) \
			or bool(session.get("busy", false))
	loading_scanner.visible = should_show


func _refresh_status() -> void:
	if status_label == null:
		return

	_refresh_loading_scanner()

	if current_session_index < 0:
		status_label.text = "No session"
		status_label.visible = true
		if thread_icon != null:
			thread_icon.texture = null
		if status_dot != null:
			status_dot.add_theme_stylebox_override("panel", _status_dot_style(Color(0.46, 0.48, 0.52, 0.85)))
			status_dot.tooltip_text = "No session"
		return

	var session: Dictionary = sessions[current_session_index]
	var agent_id: String = str(session.get("agent_id", DEFAULT_AGENT_ID))
	var status: String = str(connection_status.get(agent_id, "starting"))
	var status_text := "Connecting"
	var dot_color := Color(0.81, 0.66, 0.27, 0.95)

	if thread_icon != null:
		thread_icon.texture = _agent_icon_texture(agent_id)

	if bool(session.get("busy", false)):
		status_text = "Stopping" if bool(session.get("cancelling", false)) else "Working"
		dot_color = Color(0.83, 0.69, 0.29, 0.95)
		status_label.text = status_text
		status_label.visible = true
		if status_dot != null:
			status_dot.add_theme_stylebox_override("panel", _status_dot_style(dot_color))
			status_dot.tooltip_text = status_text
		return

	if bool(session.get("creating_remote_session", false)):
		status_text = "Opening"
		dot_color = Color(0.81, 0.66, 0.27, 0.95)
		status_label.text = status_text
		status_label.visible = true
		if status_dot != null:
			status_dot.add_theme_stylebox_override("panel", _status_dot_style(dot_color))
			status_dot.tooltip_text = status_text
		return

	if bool(session.get("loading_remote_session", false)):
		status_text = "Loading"
		dot_color = Color(0.81, 0.66, 0.27, 0.95)
		status_label.text = status_text
		status_label.visible = true
		if status_dot != null:
			status_dot.add_theme_stylebox_override("panel", _status_dot_style(dot_color))
			status_dot.tooltip_text = status_text
		return

	match status:
		"ready":
			status_text = "Ready"
			dot_color = Color(0.34, 0.82, 0.47, 0.98)
		"starting":
			status_text = "Connecting"
			dot_color = Color(0.81, 0.66, 0.27, 0.95)
		"error":
			status_text = "Error"
			dot_color = Color(0.89, 0.37, 0.38, 0.98)
		"offline":
			status_text = "Offline"
			dot_color = Color(0.52, 0.54, 0.58, 0.95)
		_:
			status_text = status.capitalize()
			dot_color = Color(0.58, 0.60, 0.64, 0.95)

	status_label.text = status_text
	status_label.visible = status_text != "Ready"
	if status_dot != null:
		status_dot.add_theme_stylebox_override("panel", _status_dot_style(dot_color))
		status_dot.tooltip_text = status_text


func _update_prompt_placeholder() -> void:
	if prompt_input == null:
		return

	prompt_input.placeholder_text = _prompt_placeholder(_current_agent_id())


func _prompt_placeholder(agent_id: String) -> String:
	# Keep the placeholder honest: promising `@` / `/` pickers that don't
	# exist was listed as a direct disconnect in TODO.md P0 #2. Re-add the
	# hints only once the pickers ship so new users aren't misled.
	return "Message %s..." % _agent_label(agent_id)


func _on_config_menu_id_pressed(item_id: int, popup: PopupMenu, config_id: String) -> void:
	if current_session_index < 0 or config_id.is_empty():
		return
	if item_id < 0 or item_id >= popup.get_item_count():
		return

	var session: Dictionary = sessions[current_session_index]
	var remote_session_id: String = str(session.get("remote_session_id", ""))
	if remote_session_id.is_empty():
		return

	var value: String = str(popup.get_item_metadata(item_id))
	var connection = _ensure_connection(str(session.get("agent_id", DEFAULT_AGENT_ID)))
	if connection == null:
		return

	if int(connection.set_session_config_option(remote_session_id, config_id, value)) < 0:
		return

	_apply_config_option_value(current_session_index, config_id, value)


func _on_mode_menu_id_pressed(item_id: int, popup: PopupMenu) -> void:
	if current_session_index < 0:
		return
	if item_id < 0 or item_id >= popup.get_item_count():
		return

	var session: Dictionary = sessions[current_session_index]
	var remote_session_id: String = str(session.get("remote_session_id", ""))
	if remote_session_id.is_empty():
		return

	var mode_id: String = str(popup.get_item_metadata(item_id))
	var connection = _ensure_connection(str(session.get("agent_id", DEFAULT_AGENT_ID)))
	if connection == null:
		return

	if int(connection.set_session_mode(remote_session_id, mode_id)) < 0:
		return

	_update_session_mode_state(current_session_index, mode_id)


func _on_model_menu_id_pressed(item_id: int, popup: PopupMenu) -> void:
	if current_session_index < 0:
		return
	if item_id < 0 or item_id >= popup.get_item_count():
		return

	var session: Dictionary = sessions[current_session_index]
	var remote_session_id: String = str(session.get("remote_session_id", ""))
	if remote_session_id.is_empty():
		return

	var model_id: String = str(popup.get_item_metadata(item_id))
	var connection = _ensure_connection(str(session.get("agent_id", DEFAULT_AGENT_ID)))
	if connection == null:
		return

	if int(connection.set_session_model(remote_session_id, model_id)) < 0:
		return

	_update_session_model_state(current_session_index, model_id)


func _apply_config_option_value(session_index: int, config_id: String, value: String) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	var session: Dictionary = sessions[session_index]
	var config_options: Array = session.get("config_options", [])
	for option_index in range(config_options.size()):
		if typeof(config_options[option_index]) != TYPE_DICTIONARY:
			continue
		var option_dict: Dictionary = config_options[option_index]
		if str(option_dict.get("id", "")) != config_id:
			continue
		option_dict["currentValue"] = value
		config_options[option_index] = option_dict
		break
	session["config_options"] = config_options
	if config_id == "mode":
		session["current_mode_id"] = value
		if typeof(session.get("modes", [])) == TYPE_DICTIONARY:
			var modes: Dictionary = session.get("modes", {})
			if not modes.is_empty():
				modes["currentModeId"] = value
				session["modes"] = modes
	if config_id == "model":
		session["current_model_id"] = value
	sessions[session_index] = session

	if session_index == current_session_index:
		_refresh_composer_options()


func _update_session_mode_state(session_index: int, mode_id: String) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	var session: Dictionary = sessions[session_index]
	session["current_mode_id"] = mode_id
	if typeof(session.get("modes", [])) == TYPE_DICTIONARY:
		var modes: Dictionary = session.get("modes", {})
		if not modes.is_empty():
			modes["currentModeId"] = mode_id
			session["modes"] = modes
	sessions[session_index] = session

	if session_index == current_session_index:
		_refresh_composer_options()


func _update_session_model_state(session_index: int, model_id: String) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	var session: Dictionary = sessions[session_index]
	session["current_model_id"] = model_id
	if typeof(session.get("models", [])) == TYPE_DICTIONARY:
		var models: Dictionary = session.get("models", {})
		if not models.is_empty():
			models["currentModelId"] = model_id
			session["models"] = models
	sessions[session_index] = session

	if session_index == current_session_index:
		_refresh_composer_options()


func _update_session_config_options(session_index: int, config_options: Array) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	var session: Dictionary = sessions[session_index]
	session["config_options"] = config_options
	sessions[session_index] = session

	if session_index == current_session_index:
		_refresh_composer_options()


func _update_session_title_from_info(session_index: int, update: Dictionary) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	if not update.has("title"):
		return

	var title: String = str(update.get("title", "")).strip_edges()
	if title.is_empty():
		return

	var session: Dictionary = sessions[session_index]
	session["title"] = title
	sessions[session_index] = session
	_touch_session(session_index)
	_refresh_thread_menu()


func _import_remote_sessions(agent_id: String, remote_sessions: Array) -> void:
	# Two-layer project scope. We pass `cwd` to `session/list` so compliant
	# adapters can filter server-side (Codex does, Claude mostly does). Some
	# adapter builds ignore `cwd` and return every historical session — so we
	# also drop anything whose `cwd` doesn't normalize to this project here.
	# Sessions missing `cwd` entirely are dropped too: we can't verify they
	# belong here, and adding them would pollute the thread menu with noise
	# from other projects.
	var normalized_project_root: String = _normalized_path(_project_root_path())
	var imported_any := false
	var current_best_index := current_session_index
	var current_best_updated_at := -1
	if current_best_index >= 0 and current_best_index < sessions.size():
		current_best_updated_at = int(sessions[current_best_index].get("updated_at", 0))

	for remote_session_variant in remote_sessions:
		if typeof(remote_session_variant) != TYPE_DICTIONARY:
			continue
		var remote_session: Dictionary = remote_session_variant
		var remote_cwd: String = str(remote_session.get("cwd", ""))
		if remote_cwd.is_empty():
			continue
		if _normalized_path(remote_cwd) != normalized_project_root:
			continue

		var remote_session_id: String = str(remote_session.get("sessionId", ""))
		if remote_session_id.is_empty():
			continue
		if _find_session_index_by_remote(agent_id, remote_session_id) >= 0:
			continue

		var title: String = _safe_text(str(remote_session.get("title", "")).strip_edges())
		if title.is_empty():
			title = "Session %d" % next_session_number

		var session: Dictionary = {
			"id": "session_%d" % next_session_number,
			"title": title,
			"agent_id": agent_id,
			"remote_session_id": remote_session_id,
			"remote_session_loaded": false,
			"loading_remote_session": false,
			"creating_remote_session": false,
			"attachments": [],
			"transcript": [],
			"assistant_entry_index": -1,
			"plan_entry_index": -1,
			"queued_prompts": [],
			"tool_calls": {},
			"available_commands": {},
			"models": [],
			"modes": [],
			"config_options": [],
			"current_model_id": "",
			"current_mode_id": "",
			"cancelling": false,
			"busy": false,
			"hydrated": true,
			"updated_at": _timestamp_msec_from_iso(str(remote_session.get("updatedAt", "")))
		}
		next_session_number += 1
		sessions.append(session)
		imported_any = true
		var appended_index := sessions.size() - 1
		var appended_updated_at: int = int(session.get("updated_at", 0))
		if current_best_index < 0 or appended_updated_at > current_best_updated_at:
			current_best_index = appended_index
			current_best_updated_at = appended_updated_at

	if imported_any:
		_refresh_thread_menu()
		# Only auto-switch on cold startup (no restored session to respect).
		# If the restore path already picked a session — typically the one
		# the user was last on — don't clobber it just because `session/list`
		# found a remote thread with a newer updated_at. The newly imported
		# thread still shows up in the thread menu for manual switching.
		if current_session_index < 0 and current_best_index >= 0 and current_best_index < sessions.size():
			_switch_session(current_best_index)
		_schedule_persist_state()


func _create_session(agent_id: String, switch_to_new: bool, connect_remote: bool) -> void:
	var title: String = "Session %d" % next_session_number
	var session: Dictionary = {
		"id": "session_%d" % next_session_number,
		"title": title,
		"agent_id": agent_id,
		"remote_session_id": "",
		"remote_session_loaded": false,
		"loading_remote_session": false,
		"creating_remote_session": false,
		"attachments": [],
		"transcript": [],
		"assistant_entry_index": -1,
		"plan_entry_index": -1,
		"queued_prompts": [],
		"tool_calls": {},
		"available_commands": {},
		"models": [],
		"modes": [],
		"config_options": [],
		"current_model_id": "",
		"current_mode_id": "",
		"cancelling": false,
		"busy": false,
		"hydrated": true,
		"updated_at": _now_tick()
	}
	next_session_number += 1
	sessions.append(session)
	_refresh_thread_menu()

	var new_index := sessions.size() - 1
	if switch_to_new:
		_switch_session(new_index)

	if connect_remote:
		_ensure_remote_session(new_index)
		_refresh_status()
	else:
		_schedule_persist_state()


func _switch_session(index: int) -> void:
	if index < 0 or index >= sessions.size():
		return

	# Dropping pending streaming for the leaving session: its TextBlocks are
	# about to be freed by the feed rebuild; the full transcript content will
	# be visible on return via _refresh_chat_log, so any un-revealed bytes
	# would be duplicative.
	streaming_pending.clear()
	streaming_tick_accumulator_sec = 0.0

	# Only one session keeps its full transcript in memory. Dehydrate the
	# outgoing one first (flushes its cache + clears heavy fields), then
	# hydrate the new one from disk if it isn't already in memory.
	var previous_session_index := current_session_index
	if previous_session_index != index and previous_session_index >= 0 and previous_session_index < sessions.size():
		SessionStoreScript.dehydrate(sessions[previous_session_index])
	SessionStoreScript.hydrate(sessions[index])

	current_session_index = index
	selected_agent_id = str(sessions[index].get("agent_id", DEFAULT_AGENT_ID))
	_refresh_thread_menu()
	_refresh_add_menu()
	_refresh_composer_context()
	_refresh_chat_log()
	_refresh_composer_options()
	_refresh_send_state()
	_refresh_status()
	_ensure_remote_session(index)
	_schedule_persist_state()


func _append_user_message_to_session(session_index: int, text: String) -> void:
	_append_transcript_to_session(session_index, "You", text)


func _append_system_message(text: String) -> void:
	if current_session_index >= 0:
		_append_transcript_to_session(current_session_index, "System", text)


func _append_system_message_to_agent(agent_id: String, text: String) -> void:
	var target_index := _find_latest_session_index_by_agent(agent_id)
	if target_index >= 0:
		_append_transcript_to_session(target_index, "System", text)


func _append_transcript_to_session(session_index: int, speaker: String, text: String) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	var session: Dictionary = sessions[session_index]
	var current_transcript: Array = session.get("transcript", [])
	current_transcript.append({
		"kind": _entry_kind({"speaker": speaker}),
		"speaker": speaker,
		"content": text
	})
	var new_index: int = current_transcript.size() - 1
	# Any non-assistant / non-thought entry breaks the streaming continuity.
	# Without this reset, a session/load replay (which does not emit a
	# prompt_finished between past turns) would keep appending subsequent
	# assistant chunks into the first past assistant message.
	session["assistant_entry_index"] = -1
	session["thought_entry_index"] = -1
	session["transcript"] = current_transcript
	sessions[session_index] = session
	_touch_session(session_index)

	if session_index == current_session_index:
		_append_entry_to_feed(new_index)


func _append_agent_chunk_to_session(session_index: int, text: String) -> void:
	var session: Dictionary = sessions[session_index]
	var current_transcript: Array = session.get("transcript", [])
	var assistant_entry_index := int(session.get("assistant_entry_index", -1))
	var is_new_entry: bool = assistant_entry_index < 0 or assistant_entry_index >= current_transcript.size()
	if is_new_entry:
		current_transcript.append({
			"kind": "assistant",
			"speaker": _agent_label(str(session.get("agent_id", DEFAULT_AGENT_ID))),
			"content": text
		})
		assistant_entry_index = current_transcript.size() - 1
		session["assistant_entry_index"] = assistant_entry_index
	else:
		var entry: Dictionary = current_transcript[assistant_entry_index]
		entry["content"] = str(entry.get("content", "")) + text
		current_transcript[assistant_entry_index] = entry

	# A normal assistant chunk ends any in-flight thought streaming segment.
	session["thought_entry_index"] = -1
	session["transcript"] = current_transcript
	sessions[session_index] = session
	_touch_session(session_index)
	if session_index == current_session_index:
		if is_new_entry:
			_append_entry_to_feed(assistant_entry_index)
		else:
			# Active turn => smooth reveal via buffer; replay / idle appends
			# bypass it so long history doesn't dribble character-by-character.
			if bool(session.get("busy", false)):
				_queue_streaming_delta(session, assistant_entry_index, text)
			else:
				_append_delta_to_text_block(assistant_entry_index, text)


func _append_thought_chunk_to_session(session_index: int, text: String) -> void:
	var session: Dictionary = sessions[session_index]
	var current_transcript: Array = session.get("transcript", [])
	var thought_entry_index := int(session.get("thought_entry_index", -1))
	var is_new_entry: bool = thought_entry_index < 0 or thought_entry_index >= current_transcript.size()
	var entry_index: int
	if is_new_entry:
		current_transcript.append({
			"kind": "thought",
			"speaker": "Thinking",
			"content": text
		})
		entry_index = current_transcript.size() - 1
		session["thought_entry_index"] = entry_index
	else:
		var entry: Dictionary = current_transcript[thought_entry_index]
		entry["content"] = str(entry.get("content", "")) + text
		current_transcript[thought_entry_index] = entry
		entry_index = thought_entry_index

	# Thought chunks interrupt any running assistant message segment: next
	# assistant_message_chunk should start a new entry.
	session["assistant_entry_index"] = -1
	session["transcript"] = current_transcript
	sessions[session_index] = session

	var thought_key: String = _thinking_block_key(session, entry_index)
	if not thought_key.is_empty():
		expanded_thinking_blocks[thought_key] = true
		var scope_key: String = "%s|%s" % [str(session.get("agent_id", DEFAULT_AGENT_ID)), str(session.get("remote_session_id", ""))]
		auto_expanded_thinking_block[scope_key] = thought_key

	_touch_session(session_index)
	if session_index == current_session_index:
		if is_new_entry:
			_append_entry_to_feed(entry_index)
		else:
			if bool(session.get("busy", false)):
				_queue_streaming_delta(session, entry_index, text)
			else:
				_append_delta_to_text_block(entry_index, text)


func _append_delta_to_text_block(entry_index: int, delta: String) -> void:
	# Streaming fast path. Instead of writing to TextBlock immediately, we
	# accumulate deltas per entry for the current frame and flush once at
	# the end. That way N chunks arriving in one frame turn into one
	# `append_text` + one `update_minimum_size` + one redraw per entry,
	# instead of N of each. The cache lookup + actual append happen inside
	# `_flush_pending_delta_writes`.
	if message_stream == null:
		return
	if chat_log_refresh_pending:
		return
	if delta.is_empty():
		return
	if entry_index < 0 or entry_index >= message_stream.get_entry_count():
		_refresh_chat_log()
		return

	var accumulated: String = str(_pending_delta_writes.get(entry_index, ""))
	_pending_delta_writes[entry_index] = accumulated + delta
	if not _delta_flush_pending:
		_delta_flush_pending = true
		call_deferred("_flush_pending_delta_writes")


func _flush_pending_delta_writes() -> void:
	_delta_flush_pending = false
	if _pending_delta_writes.is_empty():
		return
	# Swap so new writes that land during the flush queue up for the
	# next frame instead of getting drained mid-iteration.
	var writes: Dictionary = _pending_delta_writes
	_pending_delta_writes = {}

	for key in writes.keys():
		var entry_index: int = int(key)
		var combined: String = str(writes[key])
		if combined.is_empty():
			continue
		if message_stream == null:
			continue
		if entry_index < 0 or entry_index >= message_stream.get_entry_count():
			continue

		var cached_block: Variant = _entry_text_block_cache.get(entry_index, null)
		if cached_block is GodetteTextBlock and is_instance_valid(cached_block):
			(cached_block as GodetteTextBlock).append_text(combined)
			continue

		var entry_control := message_stream.get_entry_control(entry_index)
		if entry_control == null:
			# Entry scrolled out between schedule and flush; the transcript
			# already has the combined text, so re-materialization picks up
			# the latest content when the user scrolls back.
			continue
		var block := _find_text_block(entry_control)
		if block == null:
			_update_entry_in_feed(entry_index)
			continue
		_entry_text_block_cache[entry_index] = block
		block.append_text(combined)


func _on_virtual_feed_entry_created(entry_index: int, control: Control) -> void:
	if not is_instance_valid(control):
		return
	var block := _find_text_block(control)
	if block != null:
		_entry_text_block_cache[entry_index] = block


func _on_virtual_feed_entry_freed(entry_index: int, _control: Control) -> void:
	_entry_text_block_cache.erase(entry_index)


func _find_text_block(root: Node) -> GodetteTextBlock:
	if root is GodetteTextBlock:
		return root
	for child in root.get_children():
		var found := _find_text_block(child)
		if found != null:
			return found
	return null


func _thinking_block_key(session: Dictionary, entry_index: int) -> String:
	if entry_index < 0:
		return ""
	return "%s|%s|%d" % [
		str(session.get("agent_id", DEFAULT_AGENT_ID)),
		str(session.get("remote_session_id", "")),
		entry_index,
	]


func _finalize_auto_expanded_thoughts_for_session(session_index: int) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return
	var session: Dictionary = sessions[session_index]
	var scope_key: String = "%s|%s" % [str(session.get("agent_id", DEFAULT_AGENT_ID)), str(session.get("remote_session_id", ""))]
	var auto_key: String = str(auto_expanded_thinking_block.get(scope_key, ""))
	if auto_key.is_empty():
		return
	var was_user_toggled: bool = user_toggled_thinking_blocks.has(auto_key)
	if not was_user_toggled:
		expanded_thinking_blocks.erase(auto_key)
	auto_expanded_thinking_block.erase(scope_key)
	session["thought_entry_index"] = -1
	sessions[session_index] = session

	if session_index != current_session_index:
		return
	# The auto_key format is "agent|remote_session|entry_index". Extract the
	# entry index and refresh only that entry so the chevron flips state without
	# rebuilding the entire feed.
	var parts: PackedStringArray = auto_key.rsplit("|", false, 1)
	if parts.size() == 2 and parts[1].is_valid_int():
		_update_entry_in_feed(int(parts[1]))
	else:
		_refresh_chat_log()


func _upsert_plan_entry(session_index: int, entries_variant) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	var normalized_entries: Array = []
	if entries_variant is Array:
		for plan_entry_variant in entries_variant:
			if typeof(plan_entry_variant) != TYPE_DICTIONARY:
				continue
			var incoming_entry: Dictionary = plan_entry_variant
			normalized_entries.append({
				"content": str(incoming_entry.get("content", "")),
				"status": str(incoming_entry.get("status", "pending")),
				"priority": str(incoming_entry.get("priority", "medium"))
			})

	var session: Dictionary = sessions[session_index]
	var current_transcript: Array = session.get("transcript", [])
	var plan_entry_index: int = int(session.get("plan_entry_index", -1))

	# Any fresh plan update clears the dismissal — users expect the panel
	# to reappear when the agent actually changes its plan, even if they
	# × closed the last version. This runs before the transcript mutation
	# below so the subsequent feed rebuild picks up the un-dismissed state.
	var session_scope_key := "%s|%s" % [
		str(session.get("agent_id", DEFAULT_AGENT_ID)),
		str(session.get("remote_session_id", "")),
	]
	plan_dismissed_sessions.erase(session_scope_key)

	var plan_is_new := false
	if plan_entry_index >= 0 and plan_entry_index < current_transcript.size():
		var current_entry: Dictionary = current_transcript[plan_entry_index]
		current_entry["kind"] = "plan"
		current_entry["speaker"] = "Plan"
		current_entry["entries"] = normalized_entries
		current_entry["content"] = ""
		current_transcript[plan_entry_index] = current_entry
	else:
		current_transcript.append({
			"kind": "plan",
			"speaker": "Plan",
			"entries": normalized_entries,
			"content": ""
		})
		plan_entry_index = current_transcript.size() - 1
		session["plan_entry_index"] = plan_entry_index
		plan_is_new = true
		session["assistant_entry_index"] = -1
		session["thought_entry_index"] = -1

	session["transcript"] = current_transcript
	sessions[session_index] = session
	_touch_session(session_index)

	if session_index == current_session_index:
		if plan_is_new:
			_append_entry_to_feed(plan_entry_index)
		else:
			_update_entry_in_feed(plan_entry_index)


func _upsert_tool_call_entry(session_index: int, update: Dictionary) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	var tool_call_id: String = str(update.get("toolCallId", ""))
	if tool_call_id.is_empty():
		return

	var session: Dictionary = sessions[session_index]
	var tool_calls: Dictionary = session.get("tool_calls", {})
	var tool_state: Dictionary = tool_calls.get(tool_call_id, {})
	var current_transcript: Array = session.get("transcript", [])

	tool_state["toolCallId"] = tool_call_id
	if update.has("title"):
		tool_state["title"] = str(update.get("title", "Tool"))
	if update.has("kind"):
		tool_state["kind"] = str(update.get("kind", ""))
	if update.has("status"):
		tool_state["status"] = str(update.get("status", ""))

	var summary: String = _tool_call_summary(update, tool_state)
	if not summary.is_empty():
		tool_state["summary"] = summary

	# Preserve the pretty-printed raw input on the tool_state so the renderer
	# can show a "Raw Input" section that matches Zed's thread_view (which
	# always surfaces the literal JSON the agent sent, not the sanitised
	# summary). Stored as a string so it survives transcript serialisation
	# identically to the other entry fields.
	var raw_input_variant = update.get("rawInput", null)
	if raw_input_variant != null:
		if typeof(raw_input_variant) == TYPE_DICTIONARY or typeof(raw_input_variant) == TYPE_ARRAY:
			tool_state["raw_input"] = JSON.stringify(raw_input_variant, "  ")
		else:
			tool_state["raw_input"] = str(raw_input_variant)

	var content: String = _format_tool_call_entry(tool_state)
	var transcript_index: int = int(tool_state.get("transcript_index", -1))

	var tool_is_new := false
	if transcript_index >= 0 and transcript_index < current_transcript.size():
		var entry: Dictionary = current_transcript[transcript_index]
		entry["kind"] = "tool"
		entry["speaker"] = "Tool"
		entry["tool_call_id"] = tool_call_id
		entry["title"] = str(tool_state.get("title", "Tool"))
		entry["summary"] = str(tool_state.get("summary", ""))
		entry["status"] = str(tool_state.get("status", "pending"))
		entry["tool_kind"] = str(tool_state.get("kind", ""))
		entry["raw_input"] = str(tool_state.get("raw_input", ""))
		entry["content"] = content
		current_transcript[transcript_index] = entry
	else:
		current_transcript.append({
			"kind": "tool",
			"speaker": "Tool",
			"tool_call_id": tool_call_id,
			"title": str(tool_state.get("title", "Tool")),
			"summary": str(tool_state.get("summary", "")),
			"status": str(tool_state.get("status", "pending")),
			"tool_kind": str(tool_state.get("kind", "")),
			"raw_input": str(tool_state.get("raw_input", "")),
			"content": content
		})
		transcript_index = current_transcript.size() - 1
		tool_state["transcript_index"] = transcript_index
		tool_is_new = true
		session["assistant_entry_index"] = -1
		session["thought_entry_index"] = -1

	tool_calls[tool_call_id] = tool_state
	session["tool_calls"] = tool_calls
	session["transcript"] = current_transcript
	sessions[session_index] = session
	_touch_session(session_index)

	if session_index == current_session_index:
		if tool_is_new:
			_append_entry_to_feed(transcript_index)
		else:
			_update_entry_in_feed(transcript_index)


func _tool_call_summary(update: Dictionary, tool_state: Dictionary) -> String:
	var raw_input = update.get("rawInput", null)
	if typeof(raw_input) == TYPE_DICTIONARY:
		var raw_input_dict: Dictionary = raw_input
		if raw_input_dict.has("command"):
			var command: String = str(raw_input_dict.get("command", ""))
			var args_variant = raw_input_dict.get("args", [])
			if args_variant is Array:
				var args_array: Array = args_variant
				if not args_array.is_empty():
					var arg_parts: Array = []
					for arg in args_array:
						arg_parts.append(str(arg))
					return "%s %s" % [command, " ".join(arg_parts)]
			return command
		if raw_input_dict.has("cmd"):
			return str(raw_input_dict.get("cmd", ""))
		if raw_input_dict.has("path"):
			return str(raw_input_dict.get("path", ""))
	if typeof(raw_input) == TYPE_STRING:
		return str(raw_input)

	var locations_variant = update.get("locations", [])
	if locations_variant is Array:
		var locations_array: Array = locations_variant
		if locations_array.is_empty():
			return str(tool_state.get("summary", ""))
		var first_location = locations_array[0]
		if typeof(first_location) == TYPE_DICTIONARY:
			var first_location_dict: Dictionary = first_location
			return str(first_location_dict.get("path", ""))

	return str(tool_state.get("summary", ""))


func _format_tool_call_entry(tool_state: Dictionary) -> String:
	var lines: Array = []
	lines.append(str(tool_state.get("title", "Tool")))

	var summary: String = str(tool_state.get("summary", ""))
	if not summary.is_empty():
		lines.append(summary)

	var status: String = str(tool_state.get("status", "pending"))
	if not status.is_empty():
		lines.append("Status: %s" % status)

	return "\n".join(lines)


func _session_attachments(session_index: int) -> Array:
	if session_index < 0 or session_index >= sessions.size():
		return []
	return sessions[session_index].get("attachments", [])


func _set_session_attachments(session_index: int, attachments: Array) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	var session: Dictionary = sessions[session_index]
	session["attachments"] = attachments
	sessions[session_index] = session
	_touch_session(session_index)


func _session_transcript(session_index: int) -> Array:
	if session_index < 0 or session_index >= sessions.size():
		return []
	return sessions[session_index].get("transcript", [])


func _attachments_has_key(current_attachments: Array, key: String) -> bool:
	for attachment in current_attachments:
		if str(attachment.get("key", "")) == key:
			return true
	return false


func _on_attachment_activated(key: String) -> void:
	if current_session_index < 0 or key.is_empty():
		return

	var current_attachments := _session_attachments(current_session_index)
	for attachment_variant in current_attachments:
		if typeof(attachment_variant) != TYPE_DICTIONARY:
			continue
		var attachment: Dictionary = attachment_variant
		if str(attachment.get("key", "")) != key:
			continue
		var kind := str(attachment.get("kind", ""))
		if kind == "file":
			_open_path(str(attachment.get("path", "")))
		elif kind == "scene":
			_open_path(str(attachment.get("scene_path", "")))
		elif kind == "node":
			_focus_attached_node(str(attachment.get("relative_node_path", ".")))
		return


func _on_attachment_remove_requested(key: String) -> void:
	if current_session_index < 0 or key.is_empty():
		return

	var current_attachments := _session_attachments(current_session_index)
	var filtered: Array = []
	var removed := false
	for attachment_variant in current_attachments:
		if typeof(attachment_variant) != TYPE_DICTIONARY:
			filtered.append(attachment_variant)
			continue
		var attachment: Dictionary = attachment_variant
		if str(attachment.get("key", "")) == key:
			removed = true
			continue
		filtered.append(attachment)
	if not removed:
		return
	_set_session_attachments(current_session_index, filtered)
	_refresh_composer_context()
	_refresh_status()
	_schedule_persist_state()


func _open_path(path: String) -> void:
	if path.is_empty() or editor_interface == null:
		return

	if path.ends_with(".tscn"):
		editor_interface.open_scene_from_path(path)
		return

	editor_interface.select_file(path)

	var resource := load(path)
	if resource is Script:
		editor_interface.edit_script(resource)
	elif resource is Resource:
		editor_interface.edit_resource(resource)


func _focus_attached_node(relative_node_path: String) -> void:
	if editor_interface == null:
		return

	var root := editor_interface.get_edited_scene_root()
	if root == null:
		return

	var target: Node = root if relative_node_path == "." else root.get_node_or_null(relative_node_path)
	if target == null:
		return

	var selection := editor_interface.get_selection()
	if selection == null:
		return

	selection.clear()
	selection.add_node(target)
	editor_interface.edit_node(target)


func _build_scene_summary(root: Node) -> String:
	var lines: Array = []
	var scene_path := root.scene_file_path if not root.scene_file_path.is_empty() else "(unsaved scene)"
	lines.append("Scene path: %s" % scene_path)

	var queue: Array = [[root, 0]]
	var count := 0
	while not queue.is_empty() and count < MAX_SCENE_NODES:
		var current_pair = queue.pop_front()
		var current: Node = current_pair[0]
		var depth: int = current_pair[1]
		lines.append("%s- %s [%s]" % ["  ".repeat(depth), current.name, current.get_class()])
		count += 1

		for child in current.get_children():
			if child is Node:
				queue.append([child, depth + 1])

	if not queue.is_empty():
		lines.append("... truncated after %d nodes ..." % MAX_SCENE_NODES)

	return "\n".join(lines)


func _describe_node(node: Node) -> String:
	var lines: Array = []
	lines.append("Node name: %s" % node.name)
	lines.append("Class: %s" % node.get_class())
	lines.append("Node path: %s" % node.get_path())
	lines.append("Child count: %d" % node.get_child_count())

	var script := node.get_script()
	if script is Script and not script.resource_path.is_empty():
		lines.append("Script: %s" % script.resource_path)

	if node.owner != null:
		lines.append("Owner: %s" % node.owner.name)

	return "\n".join(lines)


func _find_session_index_by_id(session_id: String) -> int:
	for index in range(sessions.size()):
		if str(sessions[index].get("id", "")) == session_id:
			return index
	return -1


func _find_session_index_by_remote(agent_id: String, remote_session_id: String) -> int:
	for index in range(sessions.size()):
		if str(sessions[index].get("agent_id", "")) != agent_id:
			continue
		if str(sessions[index].get("remote_session_id", "")) == remote_session_id:
			return index
	return -1


func _find_latest_session_index_by_agent(agent_id: String) -> int:
	for index in range(sessions.size() - 1, -1, -1):
		if str(sessions[index].get("agent_id", "")) == agent_id:
			return index
	return -1


func _find_agent_index_by_id(agent_id: String) -> int:
	for index in range(AGENTS.size()):
		if str(AGENTS[index]["id"]) == agent_id:
			return index
	return 0


func _agent_label(agent_id: String) -> String:
	return str(AGENTS[_find_agent_index_by_id(agent_id)]["label"])


func _current_agent_id() -> String:
	if current_session_index < 0 or current_session_index >= sessions.size():
		return selected_agent_id
	return str(sessions[current_session_index].get("agent_id", selected_agent_id))


func _on_thread_menu_id_pressed(item_id: int) -> void:
	if item_id < THREAD_MENU_SESSION_ID_OFFSET:
		return

	var session_index: int = item_id - THREAD_MENU_SESSION_ID_OFFSET
	_switch_session(session_index)


func _on_thread_switcher_pressed() -> void:
	# Forward to the existing thread_menu popup so there's a single source
	# of truth for the thread list UI. Anchor the popup directly beneath
	# the switcher button so it reads as coming from the clicked icon,
	# not from wherever the cursor happened to be.
	if thread_menu == null or thread_switcher_button == null:
		return
	var popup := thread_menu.get_popup()
	if popup == null:
		return
	var screen_pos := thread_switcher_button.get_screen_position()
	var y_offset := int(thread_switcher_button.size.y)
	popup.popup(Rect2i(
		int(screen_pos.x),
		int(screen_pos.y) + y_offset,
		0, 0
	))


func _on_add_menu_id_pressed(item_id: int) -> void:
	if item_id < ADD_MENU_AGENT_ID_OFFSET:
		return

	var agent_index: int = item_id - ADD_MENU_AGENT_ID_OFFSET
	if agent_index < 0 or agent_index >= AGENTS.size():
		return

	selected_agent_id = str(AGENTS[agent_index]["id"])
	_refresh_add_menu()
	_create_session(selected_agent_id, true, true)


# Label subclass that draws a single strike-through line across its own
# content rect when `struck` is true. Used by the Plan panel to show
# completed tasks — Godot's theme system has no native strike-through and
# RichTextLabel is intentionally not used in this addon (see the repo's
# rendering-stack policy). Kept as an inner class because no other widget
# needs the behaviour.
class PlanTaskLabel extends Label:
	var struck: bool = false:
		set(value):
			if struck == value:
				return
			struck = value
			queue_redraw()

	func _draw() -> void:
		if not struck:
			return
		var sz: Vector2 = get_size()
		if sz.x <= 0.0 or sz.y <= 0.0:
			return
		# Pick a colour that tracks the Label's own theme rather than
		# hard-coding white — otherwise a light theme would paint a bright
		# strike over near-black glyphs and look ridiculous. The 0.7 alpha
		# factor keeps the line subtle; the glyphs themselves are what the
		# user reads, the strike is only an accent.
		var col: Color = Color(1, 1, 1, 1)
		if has_theme_color("font_color"):
			col = get_theme_color("font_color")
		col.a *= 0.7
		# y = 54% of height puts the line through the x-height of typical
		# fonts (slightly above center, since descenders add slack below
		# and caps don't extend above the nominal top).
		var y: float = sz.y * 0.54
		draw_line(Vector2(0, y), Vector2(sz.x, y), col, 1.0)
