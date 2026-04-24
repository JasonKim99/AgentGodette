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
const ComposerChipOverlayScript = preload("res://addons/godette_agent/composer_chip_overlay.gd")
# Store pasted images under the addon itself so every generated attachment
# stays in one predictable project-local place. Keep the directory visible
# (no leading dot) because Claude Code's file layer can skip hidden paths.
const PASTED_IMAGE_DIR := "res://addons/godette_agent/attachments/"
const CLAUDE_AGENT_ICON = preload("res://addons/godette_agent/icons/claude.svg")
const CODEX_CLI_ICON = preload("res://addons/godette_agent/icons/openai.svg")
# Plan drawer status icons, copied from Zed's asset set
# (assets/icons/todo_{pending,progress,complete}.svg). Stroked in white so
# we can tint at render time via TextureRect.modulate.
const TODO_PENDING_ICON = preload("res://addons/godette_agent/icons/todo_pending.svg")
const TODO_PROGRESS_ICON = preload("res://addons/godette_agent/icons/todo_progress.svg")
const TODO_COMPLETE_ICON = preload("res://addons/godette_agent/icons/todo_complete.svg")
const SEND_ICON = preload("res://addons/godette_agent/icons/send.svg")
const STOP_ICON = preload("res://addons/godette_agent/icons/stop.svg")
# Shown on the send button while the agent is busy AND the composer has
# typed / chip content — pressing enqueues instead of sending. Matches
# Zed's send → list-end glyph swap.
const QUEUE_ICON = preload("res://addons/godette_agent/icons/lucide--list-end.svg")
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
const ADD_MENU_AGENT_ID_OFFSET := 2000
const AGENTS := [
	{"id": "claude_agent", "label": "Claude Agent"},
	{"id": "codex_cli", "label": "Codex CLI"}
]

var editor_interface: EditorInterface
var thread_icon: TextureRect
# Header button that shows the current thread's title; clicking it opens
# the session picker (GodetteSessionMenu). Was a MenuButton driving a
# native PopupMenu — swapped to a plain Button because PopupMenu can't
# render per-row hover controls.
var thread_menu: Button
var session_popup: GodetteSessionMenu
# Flag set when a delete is initiated from the session popup. The
# ConfirmationDialog steals focus and closes the popup automatically;
# this flag makes the dialog's confirmed / canceled handlers re-show
# the popup after the eviction so the updated list appears in place
# without the user having to reopen it manually.
var session_popup_reopen_after_delete: bool = false
var thread_switcher_button: Button
var add_menu: MenuButton
var message_scroll: ScrollContainer
var message_stream: GodetteVirtualFeed
# Plan drawer sits above the composer, between the message feed and the
# text input — mirrors Zed's layout where the plan collapses / expands in
# place as a sibling of the composer rather than an inline message. Own
# node here (instead of a transcript entry) so toggling expand/collapse
# doesn't reflow the scrollable chat history.
var plan_drawer: PanelContainer
var plan_drawer_content: VBoxContainer
# Queue drawer sits between the plan drawer and the composer frame,
# matching Zed's stacked composer-drawer layout (plan / edits / queue /
# composer, top to bottom). Hidden when the queue is empty.
var queue_drawer: PanelContainer
var queue_drawer_content: VBoxContainer
var queue_expanded_sessions: Dictionary = {}
var prompt_input: TextEdit
var composer_options_bar: HBoxContainer
var composer_chip_overlay: GodetteComposerChipOverlay
# Scene Tree focus indicator — tracks the user's current SceneTree
# selection and optionally injects that node as implicit context into
# the next prompt. Eye toggle decides whether the context is sent.
var focus_indicator_container: GodetteFocusRing
var focus_indicator_inner: HBoxContainer
var focus_eye_button: Button
var focus_icon_rect: TextureRect
var focus_path_label: Label
var focus_include_enabled: bool = true
var focus_selected_node: Node = null
# Spacer between the focus indicator (left) and the dynamic selectors +
# send button (right). Kept as a member so _refresh_composer_options can
# skip it when rebuilding the selector row instead of recreating it.
var composer_options_spacer: Control
var send_button: Button
# Left-aligned badge in composer_options_bar showing how many follow-up
# prompts are queued behind the current streaming turn. Hidden when the
# queue is empty so the bar stays uncluttered in the common case.
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
var managed_attachment_cleanup_pending := false
var editor_fs_scan_pending := false


func configure(p_editor_interface: EditorInterface) -> void:
	editor_interface = p_editor_interface
	# Subscribe to SceneTree selection changes so the focus indicator
	# tracks live. Deferred to a call_deferred because `_build_ui` may
	# not have run yet if `configure` fires earlier than `_ready`.
	call_deferred("_wire_scene_selection_listener")
	call_deferred("_refresh_focus_indicator")


func _wire_scene_selection_listener() -> void:
	if editor_interface == null:
		return
	var selection := editor_interface.get_selection()
	if selection == null:
		return
	if not selection.selection_changed.is_connected(_on_scene_selection_changed):
		selection.selection_changed.connect(_on_scene_selection_changed)


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
	_schedule_managed_attachment_cleanup()
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
	_cleanup_managed_attachments()
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

	thread_menu = Button.new()
	thread_menu.flat = true
	thread_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	thread_menu.alignment = HORIZONTAL_ALIGNMENT_LEFT
	thread_menu.clip_text = true
	thread_menu.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	thread_menu.focus_mode = Control.FOCUS_NONE
	thread_menu.pressed.connect(Callable(self, "_show_session_popup"))
	header_row.add_child(thread_menu)

	# Custom popup replaces the native PopupMenu so each row can host an
	# inline hover-only trash icon (matches Zed's thread history list).
	# Parented to the dock so it inherits the editor theme and gets cleaned
	# up with us.
	session_popup = GodetteSessionMenu.new()
	session_popup.session_chosen.connect(Callable(self, "_on_session_popup_chosen"))
	session_popup.session_delete_requested.connect(Callable(self, "_on_session_popup_delete_requested"))
	add_child(session_popup)

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

	# Composer zone = plan drawer + composer frame, stacked with zero
	# separation so the drawer's flat bottom edge meets the composer's
	# top without a visible gap. Keeps them reading as one attached unit
	# (Zed does the same — the plan panel is structurally "attached" to
	# the composer above by sharing its top rounding with the composer's
	# top edge). The zone sits directly in the dock VBox, inheriting its
	# horizontal expand.
	var composer_zone := VBoxContainer.new()
	composer_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	composer_zone.add_theme_constant_override("separation", 0)
	add_child(composer_zone)

	plan_drawer = PanelContainer.new()
	plan_drawer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plan_drawer.visible = false
	plan_drawer.mouse_filter = Control.MOUSE_FILTER_PASS
	plan_drawer.add_theme_stylebox_override("panel", _plan_drawer_style())
	composer_zone.add_child(plan_drawer)

	var plan_padding := MarginContainer.new()
	plan_padding.add_theme_constant_override("margin_left", 10)
	plan_padding.add_theme_constant_override("margin_right", 8)
	plan_padding.add_theme_constant_override("margin_top", 6)
	plan_padding.add_theme_constant_override("margin_bottom", 6)
	plan_drawer.add_child(plan_padding)

	plan_drawer_content = VBoxContainer.new()
	plan_drawer_content.add_theme_constant_override("separation", 4)
	plan_padding.add_child(plan_drawer_content)

	queue_drawer = PanelContainer.new()
	queue_drawer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	queue_drawer.visible = false
	queue_drawer.mouse_filter = Control.MOUSE_FILTER_PASS
	queue_drawer.add_theme_stylebox_override("panel", _queue_drawer_style())
	composer_zone.add_child(queue_drawer)

	var queue_padding := MarginContainer.new()
	queue_padding.add_theme_constant_override("margin_left", 10)
	queue_padding.add_theme_constant_override("margin_right", 8)
	queue_padding.add_theme_constant_override("margin_top", 6)
	queue_padding.add_theme_constant_override("margin_bottom", 6)
	queue_drawer.add_child(queue_padding)

	queue_drawer_content = VBoxContainer.new()
	queue_drawer_content.add_theme_constant_override("separation", 4)
	queue_padding.add_child(queue_drawer_content)

	# Composer frame: a single bordered surface that hosts the text input
	# directly. Attachments appear INLINE as chips drawn by the overlay (a
	# child of prompt_input) so the old separate chip strip is gone — the
	# user sees one unified editor where chips feel like characters.
	var composer_frame := PanelContainer.new()
	composer_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	composer_frame.add_theme_stylebox_override("panel", _prompt_input_style(false))
	composer_zone.add_child(composer_frame)

	# Use a local typed ref so the `image_pasted` signal connection resolves
	# through the subclass statically. Assigning the member `prompt_input`
	# (typed as TextEdit) accepts the subclass via polymorphism, but the
	# signal lookup has to happen on the concrete type — hanging it off
	# the base-typed member would trip GDScript's static signal check and
	# refuse to load the whole script.
	var typed_prompt: GodetteComposerPromptInput = ComposerPromptInputScript.new()
	typed_prompt.image_pasted.connect(Callable(self, "_on_composer_image_pasted"))
	typed_prompt.submit_requested.connect(Callable(self, "_on_composer_submit_requested"))
	typed_prompt.chips_changed.connect(Callable(self, "_on_composer_chips_changed"))
	# Content-change hook: send button flips between Send / Queue /
	# Stop based on whether the composer has any text or chips. Listen
	# to text_changed on the underlying TextEdit so typing updates the
	# icon without waiting for a focus / session event.
	typed_prompt.text_changed.connect(Callable(self, "_refresh_send_state"))
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
	# Wrap long lines (including chip runs whose NBSP padding can push a
	# line wide) so the horizontal scrollbar never appears. Inline chips
	# already wrap-resist via non-breaking spaces — LINE_WRAPPING_BOUNDARY
	# just handles the plain-text case on the same side of the chip.
	prompt_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
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
	composer_frame.add_child(prompt_input)

	# Overlay paints inline chips on top of the TextEdit. Because it's a
	# child of prompt_input with full anchors, its local coordinates line
	# up with `TextEdit.get_rect_at_line_column`, so rect math stays
	# trivial. Chip clicks bubble out through its signal; unhandled mouse
	# events fall through to TextEdit for normal caret/selection work.
	composer_chip_overlay = ComposerChipOverlayScript.new(typed_prompt)
	composer_chip_overlay.chip_activated.connect(Callable(self, "_on_attachment_activated"))
	prompt_input.add_child(composer_chip_overlay)

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

	# Scene Tree focus indicator on the LEFT of the options bar. Shows
	# the currently selected SceneTree node with an eye toggle — open
	# means "include this node's context in the next prompt", closed
	# means "ignore the selection for now". Hidden entirely when
	# nothing is selected.
	focus_indicator_container = GodetteFocusRing.new()
	focus_indicator_container.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	# Match the selector menus' height (30 px, set in _reflow_composer_selectors)
	# so the focus ring visually aligns with the bar's baseline controls.
	focus_indicator_container.custom_minimum_size = Vector2(0, 30)
	# Clicks anywhere on the ring flip the eye — handled in _on_focus_ring_gui_input.
	focus_indicator_container.gui_input.connect(Callable(self, "_on_focus_ring_gui_input"))
	composer_options_bar.add_child(focus_indicator_container)

	focus_indicator_inner = HBoxContainer.new()
	# Negative separation compensates for two invisible gaps:
	#   1. Godot editor SVG icons ship with ~1-2 px of transparent
	#      padding baked into the glyph bounding box.
	#   2. Labels in the editor font have a small left-side bearing on
	#      the first character.
	# Together those make even zero-separation layouts read ~4 px wider
	# than they look in the Figma spec. Pulling the inner HBox by -4 px
	# lands the visible glyph + label at what feels like "touching".
	focus_indicator_inner.add_theme_constant_override("separation", -4)
	# HBox itself ignores mouse so clicks on its empty margins fall through
	# to the outer ring container (which handles the eye-toggle hotzone).
	focus_indicator_inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_indicator_container.add_child(focus_indicator_inner)

	focus_eye_button = Button.new()
	focus_eye_button.flat = true
	focus_eye_button.toggle_mode = true
	focus_eye_button.button_pressed = true
	focus_eye_button.focus_mode = Control.FOCUS_NONE
	focus_eye_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_eye_button.custom_minimum_size = Vector2(22, 22)
	focus_eye_button.toggled.connect(Callable(self, "_on_focus_eye_toggled"))
	focus_indicator_inner.add_child(focus_eye_button)

	focus_icon_rect = TextureRect.new()
	# Editor icons are native 16×16 glyphs — render at 18 × editor_scale
	# so they track the label font on high-DPI and don't look like a
	# tiny dot beside the node name.
	var focus_icon_scale: float = 1.0
	if editor_interface != null:
		focus_icon_scale = editor_interface.get_editor_scale()
	var focus_icon_px: float = 18.0 * focus_icon_scale
	focus_icon_rect.custom_minimum_size = Vector2(focus_icon_px, focus_icon_px)
	focus_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# KEEP_ASPECT (not KEEP_ASPECT_CENTERED) scales the native 16×16 icon
	# up to the full TextureRect bounds instead of leaving blank padding
	# around it — without that, the padding reads as extra gap between
	# the icon and the label.
	focus_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	focus_icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# Let clicks on the icon fall through to the outer ring (hot zone).
	focus_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_indicator_inner.add_child(focus_icon_rect)

	focus_path_label = Label.new()
	# Autosize to content. The previous 120px min + clip + ellipsis was
	# mis-trimming short strings like "No focus" into "No focu…". Node
	# names are usually short; if a pathological long name ever shows
	# up we can revisit with a max-width cap.
	focus_path_label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	# Let clicks on the name text fall through to the ring hotzone.
	focus_path_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_indicator_inner.add_child(focus_path_label)

	# Spacer pushes the send button to the right. The old "N queued"
	# label lived here too; queue state now renders in `queue_drawer`
	# above the composer (see _refresh_queue_drawer).
	composer_options_spacer = Control.new()
	composer_options_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	composer_options_bar.add_child(composer_options_spacer)

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
	# Focus indicator's initial state. `configure()` runs BEFORE
	# `_build_ui` (plugin.gd creates the dock then immediately calls
	# configure before add_control_to_dock), so the deferred refresh
	# fired from configure may land before widgets exist. Call
	# directly here to guarantee the widget is populated the moment
	# the dock is visible.
	_refresh_focus_indicator()


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
	# Unix milliseconds — what the session list's relative-time
	# formatting expects. `Time.get_ticks_msec()` used to live here, but
	# that's engine-start-relative (values like 30_000 for "30 s into
	# editor session") and collides with the Unix-timestamp convention
	# every other `updated_at` source uses (remote `updatedAt` parsed
	# via `_timestamp_msec_from_iso` is already Unix ms).
	return int(Time.get_unix_time_from_system() * 1000.0)


func _touch_session(session_index: int) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	# Bump the thread cache file's mtime on disk by rewriting it.
	# The menu label reads `FileAccess.get_modified_time(thread_cache_path)`
	# directly as the "updated_at" source of truth, so this write IS the
	# timestamp update — no in-memory field to keep in sync.
	var session: Dictionary = sessions[session_index]
	if bool(session.get("hydrated", false)):
		SessionStoreScript.write_thread_cache(session)

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


func _managed_attachment_dir_path() -> String:
	return ProjectSettings.globalize_path(PASTED_IMAGE_DIR).replace("\\", "/").trim_suffix("/")


func _attachment_absolute_path(path: String) -> String:
	if path.is_empty():
		return ""
	var absolute_path := path
	if path.begins_with("res://") or path.begins_with("user://"):
		absolute_path = ProjectSettings.globalize_path(path)
	return _normalized_path(absolute_path)


func _managed_attachment_absolute_path(path: String) -> String:
	var absolute_path := _attachment_absolute_path(path)
	if absolute_path.is_empty():
		return ""
	var managed_dir := _normalized_path(_managed_attachment_dir_path())
	if not absolute_path.begins_with(managed_dir + "/"):
		return ""
	var managed_file := absolute_path.get_file()
	if not managed_file.begins_with("clip_") or managed_file.get_extension().to_lower() != "png":
		return ""
	return absolute_path


func _append_managed_attachment_ref(path: String, merged: Array, seen: Dictionary) -> void:
	var managed_path := _managed_attachment_absolute_path(path)
	if managed_path.is_empty() or seen.has(managed_path):
		return
	seen[managed_path] = true
	merged.append(managed_path)


func _managed_attachment_refs_from_attachments(attachments_variant: Variant) -> Array:
	var refs: Array = []
	var seen: Dictionary = {}
	if typeof(attachments_variant) != TYPE_ARRAY:
		return refs
	for attachment_variant in attachments_variant:
		if typeof(attachment_variant) != TYPE_DICTIONARY:
			continue
		var attachment: Dictionary = attachment_variant
		_append_managed_attachment_ref(str(attachment.get("path", "")), refs, seen)
	return refs


func _merge_managed_attachment_refs(existing_variant: Variant, attachments_variant: Variant) -> Array:
	var merged: Array = []
	var seen: Dictionary = {}
	if typeof(existing_variant) == TYPE_ARRAY:
		for path_variant in existing_variant:
			_append_managed_attachment_ref(str(path_variant), merged, seen)
	for path_variant in _managed_attachment_refs_from_attachments(attachments_variant):
		_append_managed_attachment_ref(str(path_variant), merged, seen)
	return merged


func _mark_managed_attachment_paths(attachments_variant: Variant, referenced: Dictionary) -> void:
	if typeof(attachments_variant) != TYPE_ARRAY:
		return
	for attachment_variant in attachments_variant:
		if typeof(attachment_variant) != TYPE_DICTIONARY:
			continue
		var attachment: Dictionary = attachment_variant
		var managed_path := _managed_attachment_absolute_path(str(attachment.get("path", "")))
		if managed_path.is_empty():
			continue
		referenced[managed_path] = true


func _mark_managed_attachment_refs(refs_variant: Variant, referenced: Dictionary) -> void:
	if typeof(refs_variant) != TYPE_ARRAY:
		return
	for path_variant in refs_variant:
		var managed_path := _managed_attachment_absolute_path(str(path_variant))
		if managed_path.is_empty():
			continue
		referenced[managed_path] = true


func _collect_referenced_managed_attachment_paths() -> Dictionary:
	var referenced: Dictionary = {}
	for session_variant in sessions:
		if typeof(session_variant) != TYPE_DICTIONARY:
			continue
		var session: Dictionary = session_variant
		_mark_managed_attachment_paths(session.get("attachments", []), referenced)
		_mark_managed_attachment_refs(session.get("managed_attachment_refs", []), referenced)
		if bool(session.get("hydrated", false)):
			continue
		var session_id := str(session.get("id", ""))
		if session_id.is_empty():
			continue
		var thread_cache: Dictionary = SessionStoreScript.read_thread_cache(session_id)
		_mark_managed_attachment_paths(thread_cache.get("attachments", []), referenced)
		_mark_managed_attachment_refs(thread_cache.get("managed_attachment_refs", []), referenced)
	return referenced


func _schedule_managed_attachment_cleanup() -> void:
	if managed_attachment_cleanup_pending:
		return
	managed_attachment_cleanup_pending = true
	call_deferred("_cleanup_managed_attachments")


func _cleanup_managed_attachments() -> void:
	managed_attachment_cleanup_pending = false
	var managed_dir_path := _managed_attachment_dir_path()
	if not DirAccess.dir_exists_absolute(managed_dir_path):
		return
	var dir := DirAccess.open(managed_dir_path)
	if dir == null:
		return

	var referenced := _collect_referenced_managed_attachment_paths()
	dir.list_dir_begin()
	var entry_name := dir.get_next()
	while not entry_name.is_empty():
		if not dir.current_is_dir():
			var absolute_path := managed_dir_path.path_join(entry_name).replace("\\", "/")
			var normalized_path := _normalized_path(absolute_path)
			var managed_file := normalized_path.get_file()
			if managed_file.begins_with("clip_") and managed_file.get_extension().to_lower() == "png":
				if not referenced.has(normalized_path):
					DirAccess.remove_absolute(absolute_path)
		entry_name = dir.get_next()
	dir.list_dir_end()


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

	# Sort by the same timestamp the menu shows — filesystem mtime of
	# the thread cache file, falling back to created_at. Otherwise the
	# "most recent" notion here can diverge from what's visibly at the
	# top of the thread menu.
	var best_index := 0
	var best_ts: int = _session_activity_msec(sessions[0])
	for session_index in range(1, sessions.size()):
		var candidate_ts: int = _session_activity_msec(sessions[session_index])
		if candidate_ts > best_ts:
			best_index = session_index
			best_ts = candidate_ts
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

	# One-shot migrations. Each one reads / patches the per-session
	# thread cache files on disk; runs only when there's work to do so
	# repeated startups are no-ops after the first pass.
	_purge_legacy_cancellation_system_messages()
	_backfill_derived_titles()

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


func _purge_legacy_cancellation_system_messages() -> void:
	# Older versions appended a "<Agent> finished with cancelled." system
	# message every time the user hit Stop or Send Now. Zed never did
	# this, and we stopped doing it (see _on_connection_prompt_finished).
	# Scrub any lingering copies from both the in-memory transcript of
	# the current hydrated session AND the on-disk cache files for the
	# rest.
	for session_index in range(sessions.size()):
		var session: Dictionary = sessions[session_index]
		var session_id := str(session.get("id", ""))
		if session_id.is_empty():
			continue
		if bool(session.get("hydrated", false)):
			var in_memory_variant = session.get("transcript", [])
			if in_memory_variant is Array:
				var cleaned_memory := _strip_legacy_cancel_messages(in_memory_variant)
				if cleaned_memory.size() != (in_memory_variant as Array).size():
					session["transcript"] = cleaned_memory
					sessions[session_index] = session
			continue
		var cache: Dictionary = SessionStoreScript.read_thread_cache(session_id)
		if cache.is_empty():
			continue
		var transcript_variant = cache.get("transcript", [])
		if not (transcript_variant is Array):
			continue
		var cleaned_disk := _strip_legacy_cancel_messages(transcript_variant)
		if cleaned_disk.size() == (transcript_variant as Array).size():
			continue
		var patched: Dictionary = cache
		patched["transcript"] = cleaned_disk
		var path := SessionStoreScript.thread_cache_path(session_id)
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(patched))
			file.flush()


func _strip_legacy_cancel_messages(transcript: Array) -> Array:
	var cleaned: Array = []
	for entry_variant in transcript:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			cleaned.append(entry_variant)
			continue
		var entry: Dictionary = entry_variant
		if str(entry.get("speaker", "")) == "System" and " finished with cancelled." in str(entry.get("content", "")):
			continue
		cleaned.append(entry)
	return cleaned


func _backfill_derived_titles() -> void:
	var changed := false
	for session_index in range(sessions.size()):
		var session: Dictionary = sessions[session_index]
		if not str(session.get("derived_title", "")).strip_edges().is_empty():
			continue
		# Only peek when the session actually needs the backfill —
		# i.e. the stored title is a placeholder like "Session 14".
		# If it already has a real title we have nothing to derive.
		if not _is_placeholder_title(str(session.get("title", "")).strip_edges()):
			continue
		var session_id := str(session.get("id", ""))
		if session_id.is_empty():
			continue
		var cache: Dictionary = SessionStoreScript.read_thread_cache(session_id)
		var transcript_variant = cache.get("transcript", [])
		if not (transcript_variant is Array):
			continue
		for entry_variant in transcript_variant:
			if typeof(entry_variant) != TYPE_DICTIONARY:
				continue
			var entry: Dictionary = entry_variant
			if str(entry.get("kind", "")) != "user":
				continue
			var snippet := _snippet_from_user_text(str(entry.get("content", "")))
			if snippet.is_empty():
				continue
			session["derived_title"] = snippet
			sessions[session_index] = session
			changed = true
			break
	if changed:
		_schedule_persist_state()


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
	# Use the same derived-from-first-user-message fallback as the
	# thread menu so the header and the menu don't disagree on what
	# a session is called.
	return _safe_text(_session_display_title(sessions[current_session_index]))


func _recent_session_indices(limit: int) -> Array:
	var ordered: Array = []
	for session_index in range(sessions.size()):
		var inserted := false
		var updated_at: int = _session_activity_msec(sessions[session_index])
		for ordered_index in range(ordered.size()):
			var candidate_index: int = int(ordered[ordered_index])
			var candidate_updated_at: int = _session_activity_msec(sessions[candidate_index])
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
	var title := _session_display_title(session)
	# `updated_at` source of truth = thread cache file's mtime. The
	# file is rewritten on every _touch_session, so its mtime tracks
	# real activity. Falls back to the in-memory `created_at` field
	# when the thread cache doesn't exist yet (brand-new session, no
	# persisted transcript). Shows "—" only if nothing is available.
	var ts_msec: int = _session_activity_msec(session)
	var relative: String = _relative_time_label(ts_msec) if ts_msec > 0 else "—"
	return _safe_text("%s  ·  %s" % [title, relative])


func _session_display_title(session: Dictionary) -> String:
	# Prefer a title the adapter (or remote session info) set explicitly.
	# For locally-created sessions whose adapter never emitted a
	# session_info_update, the stored title is a placeholder like
	# "Session 14" — substitute the first user message's content so the
	# menu shows what the conversation is actually about. `derived_title`
	# is populated on first user-message append and persisted, so it
	# survives dehydration (menu renders work without having to re-read
	# each inactive session's transcript off disk).
	var stored_title := str(session.get("title", "")).strip_edges()
	if not _is_placeholder_title(stored_title):
		return stored_title
	var persisted_derived := str(session.get("derived_title", "")).strip_edges()
	if not persisted_derived.is_empty():
		return persisted_derived
	# Live-transcript fallback for the currently hydrated session when
	# derived_title hasn't been captured yet (edge case: first-time
	# upgrade path, very-first-message-in-flight, etc).
	var derived := _first_user_message_snippet(session)
	if not derived.is_empty():
		return derived
	if stored_title.is_empty():
		return "Session"
	return stored_title


func _is_placeholder_title(title: String) -> bool:
	# "Session 14", "Session 2", etc. — the numeric-suffix pattern we
	# mint in `_create_session` when the adapter hasn't given us a
	# real title. Treat any such value as "needs replacement".
	if title.is_empty():
		return true
	if not title.begins_with("Session "):
		return false
	var suffix := title.substr(8).strip_edges()
	return suffix.is_valid_int()


func _first_user_message_snippet(session: Dictionary) -> String:
	var transcript_variant = session.get("transcript", [])
	if not (transcript_variant is Array):
		return ""
	for entry_variant in transcript_variant:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_variant
		if str(entry.get("kind", "")) != "user":
			continue
		var content := str(entry.get("content", "")).strip_edges()
		if content.is_empty():
			continue
		# First line only, trimmed — multi-line prompts would blow out
		# the menu row otherwise.
		var newline_index := content.find("\n")
		if newline_index >= 0:
			content = content.substr(0, newline_index).strip_edges()
		# Cap to a reasonable length so long one-liners still fit in
		# the menu without clipping.
		const MAX_SNIPPET_CHARS := 48
		if content.length() > MAX_SNIPPET_CHARS:
			content = content.substr(0, MAX_SNIPPET_CHARS).strip_edges() + "…"
		return content
	return ""


func _session_activity_msec(session: Dictionary) -> int:
	var session_id := str(session.get("id", ""))
	if not session_id.is_empty():
		var path := SessionStoreScript.thread_cache_path(session_id)
		if FileAccess.file_exists(path):
			var mtime_sec := FileAccess.get_modified_time(path)
			if mtime_sec > 0:
				return mtime_sec * 1000
	# No cache file on disk — session was created but never persisted
	# anything (just spawned, never sent a prompt). Fall back to the
	# explicit created_at we wrote when the session was spawned.
	return int(session.get("created_at", 0))


func _thread_menu_tooltip(session_index: int) -> String:
	if session_index < 0 or session_index >= sessions.size():
		return "Session"

	var session: Dictionary = sessions[session_index]
	return _safe_text("%s | %s" % [str(session.get("title", "Session")), _agent_label(str(session.get("agent_id", DEFAULT_AGENT_ID)))])


# Compact relative time string for session list labels:
#   <45 s     → "now"
#   <60 min   → "Xm"
#   <24 h     → "Xh"
#   <7 d      → "Xd"
#   <5 w      → "Xw"
#   otherwise → absolute date "YYYY-MM-DD"
# `updated_at` is stored as unix milliseconds (see `_timestamp_msec_from_iso`).
# Returns empty string for zero / negative values so the caller can fall
# back to the bare title without dangling separator punctuation.
func _relative_time_label(updated_at_msec: int) -> String:
	if updated_at_msec <= 0:
		return ""
	var now_msec: int = int(Time.get_unix_time_from_system() * 1000.0)
	var delta_sec: int = max(0, int((now_msec - updated_at_msec) / 1000))
	if delta_sec < 45:
		return "now"
	if delta_sec < 3600:
		return "%dm" % int(delta_sec / 60)
	if delta_sec < 86400:
		return "%dh" % int(delta_sec / 3600)
	if delta_sec < 604800:
		return "%dd" % int(delta_sec / 86400)
	if delta_sec < 2592000:
		return "%dw" % int(delta_sec / 604800)
	var date := Time.get_datetime_dict_from_unix_time(int(updated_at_msec / 1000))
	return "%04d-%02d-%02d" % [int(date.year), int(date.month), int(date.day)]


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
	tb.set_font(_editor_font("source", 400, false))
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
	button.tooltip_text = "Collapse" if is_open else "Expand"
	# Prefer the editor's own tree-disclosure icons so the glyph lines
	# up with neighbouring Label baselines. Unicode carets (⌃ / ⌄) used
	# to drift vertically because their metrics don't share the Label
	# font's x-height. Fall back to the text glyph only when no editor
	# theme is available.
	var open_icon := _editor_theme_icon("GuiTreeArrowDown")
	var closed_icon := _editor_theme_icon("GuiTreeArrowRight")
	var icon: Texture2D = open_icon if is_open else closed_icon
	if icon != null:
		button.icon = icon
		button.expand_icon = false
	else:
		button.text = "⌃" if is_open else "⌄"
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
	# Attachment-only user turns have empty `content` but a non-empty
	# `segments` list (e.g. drop a file + hit send without typing). Keep
	# the bubble in that case so the chips are still visible.
	var segments_variant = entry.get("segments", null)
	var has_segments: bool = segments_variant is Array and (segments_variant as Array).size() > 0
	# Chip segments specifically: only route through RichTextLabel
	# (fit_content path) when there's actually a chip to render.
	# Pure-text segments fall back to TextBlock, which sizes tight.
	# RichTextLabel's fit_content mis-measures vertical extent when
	# the control's width isn't resolved before layout — the bubble
	# ends up occupying dozens of lines of blank space. TextBlock has
	# no such issue.
	var has_chip_segments := false
	if has_segments:
		for seg_variant in (segments_variant as Array):
			if typeof(seg_variant) == TYPE_DICTIONARY and str((seg_variant as Dictionary).get("type", "")) == "chip":
				has_chip_segments = true
				break
	if body_text.is_empty() and not has_segments:
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
		# Horizontal breathing room inside the bubble. Zed's `px_2` (8 px)
		# reads tight for CJK content where glyph ink fills the advance
		# width edge-to-edge, so we bump to 14 — still visually similar
		# to Zed on Latin text, noticeably more comfortable for Chinese.
		padding.add_theme_constant_override("margin_left", 14)
		padding.add_theme_constant_override("margin_top", 12)
		padding.add_theme_constant_override("margin_right", 14)
		padding.add_theme_constant_override("margin_bottom", 12)
		panel.add_child(padding)
		# Chips present → RichTextLabel flow (inline bgcolor-pill chips
		# interleaved with text, matches Zed's mention layout).
		# Otherwise → plain TextBlock, which sizes tight. The "segments
		# but no chips" case (serialised pre-send state that happens to
		# be text-only) takes the TextBlock path too, so the RTL
		# fit_content bug can't bite a bubble that has no chips to
		# justify using RTL.
		if has_chip_segments:
			padding.add_child(_build_user_bubble_flow(segments_variant as Array))
		else:
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


# Builds Zed-style segmented user-message rendering inside a single
# RichTextLabel. RichTextLabel owns the text layout engine, so CJK
# characters, whitespace, and Latin words all wrap at their correct
# natural boundaries without us having to tokenize anything by hand.
# Chips are inlined via push_meta + push_bgcolor + add_image + add_text
# so they flow with the text, and clicks surface through meta_clicked.
#
# Trade-off vs. Control-based pills: RichTextLabel bgcolor regions are
# not rounded, so the chip reads as a flat-bg run rather than the
# pill the composer draws. Text fidelity wins — the user sees exactly
# the characters they typed in the same order and spacing.
func _build_user_bubble_flow(segments: Array) -> Control:
	var rtl := RichTextLabel.new()
	# `bbcode_enabled = true` is required — without it the internal
	# layout path for `add_image` + `push_*` didn't drive fit_content
	# correctly, and each chip reserved a too-tall placeholder so the
	# bubble rendered with a big blank strip below the content. With
	# bbcode on, the same programmatic calls route through the tag
	# parser's sizing machinery and the control measures tight.
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.scroll_active = false
	rtl.selection_enabled = true
	rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# push_meta regions default to URL-style underline. Chips are pills,
	# not hyperlinks — kill the underline so the run reads as a tag.
	rtl.meta_underlined = false

	var body_color := _editor_color("font_color", "Editor", Color(0.93, 0.94, 0.98, 0.96))
	rtl.add_theme_color_override("default_color", body_color)

	# Meta click handler needs the segment list so it can resolve the
	# clicked index back to an open-target dispatch. Binding it per-bubble
	# avoids a field-level cache that would drift across sessions.
	rtl.meta_clicked.connect(Callable(self, "_on_user_bubble_meta_clicked").bind(segments))

	var chip_bg := _user_bubble_chip_bg_color()

	for seg_index in range(segments.size()):
		var segment_variant = segments[seg_index]
		if typeof(segment_variant) != TYPE_DICTIONARY:
			continue
		var segment: Dictionary = segment_variant
		var segment_type: String = str(segment.get("type", ""))
		match segment_type:
			"text":
				var segment_text: String = _safe_text(str(segment.get("text", "")))
				if segment_text.is_empty():
					continue
				rtl.add_text(segment_text)
			"chip":
				# Icon-less chip: just bgcolor + label. Inline
				# `add_image` oversized the control's fit_content
				# measurement, making the bubble reserve a tall blank
				# strip below the text that visually swallowed the next
				# turn's content. Dropping the icon is an acceptable
				# trade — the label text alone still identifies the
				# attachment, and hover tooltips (TODO) can surface the
				# type glyph when needed.
				rtl.push_meta("chip:%d" % seg_index)
				rtl.push_bgcolor(chip_bg)
				rtl.add_text(" ")
				rtl.add_text(_safe_text(str(segment.get("label", ""))))
				rtl.add_text(" ")
				rtl.pop()  # bgcolor
				rtl.pop()  # meta
				# Unstyled trailing space sits outside the bgcolor so the
				# next text token isn't flush against the chip's right edge.
				rtl.add_text(" ")
	return rtl


func _chip_segment_to_attachment(segment: Dictionary) -> Dictionary:
	# Rebuild the attachment dict shape _attachment_icon / _open_path
	# expect from a transcript chip segment. Kept as its own helper so
	# the build and click paths can't drift on the field mapping.
	var payload_variant = segment.get("payload", {})
	var payload: Dictionary = payload_variant if typeof(payload_variant) == TYPE_DICTIONARY else {}
	return {
		"kind": str(segment.get("kind", "")),
		"label": str(segment.get("label", "")),
		"path": str(payload.get("path", "")),
		"scene_path": str(payload.get("scene_path", "")),
		"relative_node_path": str(payload.get("relative_node_path", "")),
	}


func _user_bubble_chip_bg_color() -> Color:
	# Subtly lighter than the bubble base so the chip run pops without
	# competing with the editor accent. Alpha < 1 softens the edge where
	# the bgcolor meets the surrounding text background.
	var base := _editor_color("base_color", "Editor", Color(0.16, 0.17, 0.19, 1.0))
	var chip_color := base.lightened(0.18)
	chip_color.a = 0.85
	return chip_color


func _on_user_bubble_meta_clicked(meta: Variant, segments: Array) -> void:
	var meta_str := str(meta)
	if not meta_str.begins_with("chip:"):
		return
	var idx_str := meta_str.substr(5)
	if not idx_str.is_valid_int():
		return
	var idx := int(idx_str)
	if idx < 0 or idx >= segments.size():
		return
	var seg_variant = segments[idx]
	if typeof(seg_variant) != TYPE_DICTIONARY:
		return
	var synthetic := _chip_segment_to_attachment(seg_variant)
	match str(synthetic.get("kind", "")):
		"image":
			# Pasted clipboard images live under a `.gdignore`d directory
			# so Godot never imports them. `_open_path` → `load()` would
			# fail with "Failed loading resource". Hand the absolute path
			# to the OS default viewer instead.
			var image_path := str(synthetic.get("path", ""))
			if image_path.begins_with("res://") or image_path.begins_with("user://"):
				image_path = ProjectSettings.globalize_path(image_path)
			if not image_path.is_empty():
				OS.shell_open(image_path)
		"file":
			_open_path(str(synthetic.get("path", "")))
		"scene":
			_open_path(str(synthetic.get("scene_path", "")))
		"node":
			var relative := str(synthetic.get("relative_node_path", ""))
			if relative.is_empty():
				relative = "."
			_focus_attached_node(relative)


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

	# Pull bold / italic / mono straight from the editor's own font slots
	# (EditorFonts: "bold", "italic", "source") so markdown typography
	# tracks whatever font the user has configured for the editor —
	# Inter + JetBrains Mono by default, or their custom choice. Godot
	# 4.6 doesn't ship a dedicated bold_italic or mono_bold slot, so we
	# degrade gracefully: bold_italic → bold (keeps the weight trait,
	# loses italic), mono_bold → mono. SystemFont fallbacks only kick
	# in when running without an editor interface (unlikely in practice
	# for an editor plugin but defensive).
	var bold: Font = _editor_font("bold", 700, false)
	var italic: Font = _editor_font("italic", 400, true)
	var bold_italic: Font = _editor_font("bold", 700, false)
	var mono: Font = _editor_font("source", 400, false)
	var mono_bold: Font = _editor_font("source", 700, false)

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


# Rebuild the plan drawer from the current session's plan state. Called
# on session switch, plan upsert, expand/collapse, and dismiss. Zero
# animation — layout flips instantly like Zed's does.
func _refresh_plan_drawer() -> void:
	if plan_drawer == null or plan_drawer_content == null:
		return
	# Wipe prior content; we rebuild the whole drawer body on each refresh.
	# Safe because the drawer is small (≤ a handful of rows) and this path
	# doesn't run during hot streaming.
	for child in plan_drawer_content.get_children():
		child.queue_free()

	if current_session_index < 0 or current_session_index >= sessions.size():
		plan_drawer.visible = false
		return

	var session: Dictionary = sessions[current_session_index]
	var plan_entries_variant = session.get("plan_entries", [])
	var plan_entries: Array = plan_entries_variant if plan_entries_variant is Array else []
	var session_key: String = _current_session_scope_key()

	if plan_entries.is_empty() or bool(plan_dismissed_sessions.get(session_key, false)):
		plan_drawer.visible = false
		return

	plan_drawer.visible = true
	var is_expanded: bool = plan_expanded_sessions.get(session_key, false)
	var all_done: bool = _plan_remaining_count(plan_entries) == 0

	# Header: chevron (left) | title (flex) | count | × (right). Chevron
	# stays anchored left across states so it doesn't jump position when
	# the title text changes length.
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 6)
	header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.mouse_filter = Control.MOUSE_FILTER_PASS
	header_row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	header_row.gui_input.connect(Callable(self, "_on_summary_row_gui_input").bind(Callable(self, "_on_plan_summary_pressed").bind(session_key)))
	plan_drawer_content.add_child(header_row)

	var chevron := _make_disclosure_chevron(is_expanded)
	chevron.pressed.connect(Callable(self, "_on_plan_summary_pressed").bind(session_key))
	header_row.add_child(chevron)

	var title_label := Label.new()
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.modulate = _editor_color("font_color", "Editor", Color(0.95, 0.95, 1.0, 1.0))
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.clip_text = true
	if is_expanded:
		title_label.text = "Plan"
	else:
		var current_task: String = _plan_current_task_text(plan_entries)
		title_label.text = ("Current: %s" % current_task) if not current_task.is_empty() else "Plan"
	header_row.add_child(title_label)

	var count_label := Label.new()
	count_label.modulate = Color(0.91, 0.91, 0.96, 0.66)
	if all_done:
		count_label.text = "All Done"
	elif is_expanded:
		count_label.text = _plan_progress_label(plan_entries)
	else:
		count_label.text = "%d left" % _plan_remaining_count(plan_entries)
	header_row.add_child(count_label)

	var close_button := _make_plan_close_button()
	close_button.pressed.connect(Callable(self, "_on_plan_close_pressed").bind(session_key))
	header_row.add_child(close_button)

	if not is_expanded:
		return

	# Expanded body: separator line between header and rows (Zed uses
	# border_b_1 on the header; an HSeparator here is the equivalent), then
	# a VBox of task rows.
	plan_drawer_content.add_child(HSeparator.new())
	var tasks := VBoxContainer.new()
	tasks.add_theme_constant_override("separation", 2)
	plan_drawer_content.add_child(tasks)
	for plan_entry_variant in plan_entries:
		if typeof(plan_entry_variant) != TYPE_DICTIONARY:
			continue
		tasks.add_child(_build_plan_task_row(plan_entry_variant))


func _plan_drawer_style() -> StyleBoxFlat:
	# Colors come straight from the editor theme's named tokens so the
	# drawer tracks whatever light / dark / custom theme the user has
	# configured:
	#   bg     = dark_color_1  (one step below base_color — same surface
	#                           depth other editor side panels use)
	#   border = contrast_color_1  (default border tint in dark themes)
	# Top-only rounding + no bottom border so the drawer meets the
	# composer's top edge seamlessly (Zed's rounded_t_md + border_b_0
	# pattern).
	var style := StyleBoxFlat.new()
	var base := _editor_color("base_color", "Editor", Color(0.16, 0.17, 0.19, 1.0))
	style.bg_color = _editor_color("dark_color_1", "Editor", base.darkened(0.04))
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 0
	style.corner_radius_bottom_right = 0
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 0
	style.border_color = _editor_color("contrast_color_1", "Editor", base.lightened(0.12))
	return style


# Queue drawer ——————————————————————————————————————————————————————————
#
# Mirrors Zed's queued-messages UI (thread_view.rs:2708-2753 summary,
# 3382-3560 per-entry rows). Sits directly above the composer frame,
# below the plan drawer when both are visible. Header shows the
# pending count + a "Clear All" shortcut; expanded body renders each
# queued prompt with edit / send-now / delete controls.
func _refresh_queue_drawer() -> void:
	if queue_drawer == null or queue_drawer_content == null:
		return
	for child in queue_drawer_content.get_children():
		child.queue_free()

	if current_session_index < 0 or current_session_index >= sessions.size():
		queue_drawer.visible = false
		return

	var session: Dictionary = sessions[current_session_index]
	var queue_variant = session.get("queued_prompts", [])
	var queue: Array = queue_variant if queue_variant is Array else []
	if queue.is_empty():
		queue_drawer.visible = false
		return

	queue_drawer.visible = true
	var session_key: String = _current_session_scope_key()
	# Default expanded (matches Zed). `queue_expanded_sessions`
	# holds the user's explicit preference — if they've never toggled
	# the drawer for this session, show it open so the queue contents
	# are visible at a glance; once they collapse it, remember that
	# choice for the session.
	var is_expanded: bool = queue_expanded_sessions.get(session_key, true)

	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 6)
	header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.mouse_filter = Control.MOUSE_FILTER_PASS
	header_row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	header_row.gui_input.connect(Callable(self, "_on_summary_row_gui_input").bind(Callable(self, "_on_queue_summary_pressed").bind(session_key)))
	queue_drawer_content.add_child(header_row)

	var chevron := _make_disclosure_chevron(is_expanded)
	chevron.pressed.connect(Callable(self, "_on_queue_summary_pressed").bind(session_key))
	header_row.add_child(chevron)

	var title_label := Label.new()
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.modulate = _editor_color("font_color", "Editor", Color(0.95, 0.95, 1.0, 1.0))
	title_label.text = "%d Queued Message%s" % [queue.size(), "" if queue.size() == 1 else "s"]
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.clip_text = true
	header_row.add_child(title_label)

	var clear_all := Button.new()
	clear_all.flat = true
	clear_all.focus_mode = Control.FOCUS_NONE
	clear_all.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	clear_all.text = "Clear All"
	clear_all.tooltip_text = "Drop every queued prompt"
	clear_all.modulate = Color(1.0, 1.0, 1.0, 0.75)
	clear_all.pressed.connect(Callable(self, "_on_queue_clear_all_pressed"))
	header_row.add_child(clear_all)

	if not is_expanded:
		return

	queue_drawer_content.add_child(HSeparator.new())
	var entries_vbox := VBoxContainer.new()
	entries_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	entries_vbox.add_theme_constant_override("separation", 2)
	queue_drawer_content.add_child(entries_vbox)

	for i in range(queue.size()):
		var entry_variant = queue[i]
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		entries_vbox.add_child(_build_queue_entry_row(entry_variant, i))
		# Zed adds a bottom border between queue rows (not after the
		# last). HSeparator is the Godot-native way to draw that line
		# — it inherits the editor theme's separator color automatically.
		if i < queue.size() - 1:
			entries_vbox.add_child(HSeparator.new())


func _build_queue_entry_row(entry: Dictionary, index: int) -> Control:
	var is_next: bool = index == 0

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 4)  # gap_1 equivalent
	row.mouse_filter = Control.MOUSE_FILTER_PASS

	# Circle dot — Color::Accent for head-of-queue, Color::Muted for
	# the rest. Zed puts "Next in Queue" / "In Queue" in the dot's
	# tooltip rather than a visible inline label.
	var dot := PanelContainer.new()
	dot.custom_minimum_size = Vector2(10, 10)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.add_theme_stylebox_override("panel", _queue_dot_style(is_next))
	dot.tooltip_text = "Next in Queue" if is_next else "In Queue"
	row.add_child(dot)

	var preview_label := Label.new()
	preview_label.text = _queue_entry_preview(entry)
	preview_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	preview_label.clip_text = true
	preview_label.modulate = _editor_color("font_color", "Editor", Color(0.95, 0.95, 1.0, 1.0)) if is_next else Color(1.0, 1.0, 1.0, 0.72)
	row.add_child(preview_label)

	# Action triplet on the right — Zed order (thread_view.rs:3480-3555):
	# Trash (IconButton) → Pencil (IconButton) → Send Now (text button).
	# The first entry shows everything by default; other entries hide
	# the group until the row is hovered.
	var delete_button := _make_queue_icon_button("Remove Message from Queue", _editor_theme_icon("Remove"))
	delete_button.pressed.connect(Callable(self, "_on_queue_delete_pressed").bind(index))
	row.add_child(delete_button)

	var edit_button := _make_queue_icon_button("Edit", _editor_theme_icon("Edit"))
	edit_button.pressed.connect(Callable(self, "_on_queue_edit_pressed").bind(index))
	row.add_child(edit_button)

	var send_now_button := _make_queue_send_now_button(is_next)
	send_now_button.pressed.connect(Callable(self, "_on_queue_send_now_pressed").bind(index))
	row.add_child(send_now_button)

	if not is_next:
		_wire_hover_only_visibility(row, [delete_button, edit_button, send_now_button])

	return row


func _make_queue_icon_button(tooltip: String, icon: Texture2D) -> Button:
	var button := Button.new()
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.tooltip_text = tooltip
	button.custom_minimum_size = Vector2(18, 18)
	if icon != null:
		button.icon = icon
		button.expand_icon = false
	else:
		button.text = tooltip.substr(0, 1)
	return button


func _make_queue_send_now_button(is_next: bool) -> Button:
	# Zed renders "Send Now" as a text button (not an icon). The
	# head-of-queue row gets an Outlined variant so it reads as the
	# primary affordance; subsequent rows use the default flat look
	# so they're visible-but-secondary when the user hovers.
	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.text = "Send Now"
	button.tooltip_text = "Send this queued message immediately"
	if is_next:
		# Outlined — accent border, transparent bg, so it stands out
		# against the drawer surface.
		button.add_theme_stylebox_override("normal", _queue_send_now_outlined_style(false))
		button.add_theme_stylebox_override("hover", _queue_send_now_outlined_style(true))
		button.add_theme_stylebox_override("pressed", _queue_send_now_outlined_style(true))
		button.add_theme_stylebox_override("focus", _queue_send_now_outlined_style(false))
	else:
		button.flat = true
	return button


func _queue_send_now_outlined_style(emphasized: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0) if not emphasized else _editor_color("accent_color", "Editor", Color(0.55, 0.78, 1.0, 1.0)).darkened(0.6)
	var accent := _editor_color("accent_color", "Editor", Color(0.55, 0.78, 1.0, 1.0))
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = accent
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	return style


func _queue_entry_preview(entry: Dictionary) -> String:
	# Prefer the display_text we captured on enqueue; fall back to
	# scraping text blocks for older queue entries (defensive — if
	# anything upstream forgot to fill display_text, we still render
	# something).
	var text_variant = entry.get("display_text", "")
	var text := str(text_variant).strip_edges()
	if text.is_empty():
		var blocks_variant = entry.get("blocks", [])
		if blocks_variant is Array:
			for block_variant in blocks_variant:
				if typeof(block_variant) != TYPE_DICTIONARY:
					continue
				var block: Dictionary = block_variant
				if str(block.get("type", "")) == "text":
					text = str(block.get("text", "")).strip_edges()
					if not text.is_empty():
						break
	if text.is_empty():
		var attachments_variant = entry.get("attachments", [])
		if attachments_variant is Array and (attachments_variant as Array).size() > 0:
			text = "%d attachment%s" % [
				(attachments_variant as Array).size(),
				"" if (attachments_variant as Array).size() == 1 else "s",
			]
	if text.is_empty():
		return "(empty prompt)"
	# Collapse newlines to a single space so the row stays compact.
	return text.replace("\n", " ").replace("\r", "")


func _queue_drawer_style() -> StyleBoxFlat:
	# Same visual family as the plan drawer — top-rounded, bordered
	# except on the bottom, editor dark_color_1 surface. When both
	# drawers are visible they stack cleanly into one continuous
	# "composer tray" without a gap or a colour shift.
	var style := StyleBoxFlat.new()
	var base := _editor_color("base_color", "Editor", Color(0.16, 0.17, 0.19, 1.0))
	style.bg_color = _editor_color("dark_color_1", "Editor", base.darkened(0.04))
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 0
	style.corner_radius_bottom_right = 0
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 0
	style.border_color = _editor_color("contrast_color_1", "Editor", base.lightened(0.12))
	return style


func _queue_dot_style(is_next: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	var fill: Color
	if is_next:
		fill = _editor_color("accent_color", "Editor", Color(0.55, 0.78, 1.0, 1.0))
	else:
		fill = _editor_color("font_readonly_color", "Editor", Color(0.78, 0.79, 0.84, 0.55))
	style.bg_color = fill
	style.corner_radius_top_left = 99
	style.corner_radius_top_right = 99
	style.corner_radius_bottom_right = 99
	style.corner_radius_bottom_left = 99
	return style


func _on_queue_summary_pressed(session_key: String) -> void:
	if session_key.is_empty():
		return
	# Default is expanded, so the toggle stores the explicit choice
	# (false = user collapsed; true = user re-opened). Never erase the
	# key — we want the collapsed state to stick across _refresh
	# rebuilds, otherwise the default-expanded would snap back open on
	# every queue mutation.
	var is_currently_expanded: bool = queue_expanded_sessions.get(session_key, true)
	queue_expanded_sessions[session_key] = not is_currently_expanded
	if session_key == _current_session_scope_key():
		_refresh_queue_drawer()


func _on_queue_clear_all_pressed() -> void:
	if current_session_index < 0 or current_session_index >= sessions.size():
		return
	var session: Dictionary = sessions[current_session_index]
	session["queued_prompts"] = []
	sessions[current_session_index] = session
	_refresh_queue_drawer()
	_refresh_queue_indicator()


func _on_queue_delete_pressed(index: int) -> void:
	if current_session_index < 0 or current_session_index >= sessions.size():
		return
	var session: Dictionary = sessions[current_session_index]
	var queue_variant = session.get("queued_prompts", [])
	if not (queue_variant is Array):
		return
	var queue: Array = queue_variant
	if index < 0 or index >= queue.size():
		return
	queue.remove_at(index)
	session["queued_prompts"] = queue
	sessions[current_session_index] = session
	_refresh_queue_drawer()
	_refresh_queue_indicator()


func _on_queue_send_now_pressed(index: int) -> void:
	# Zed semantics: Send Now fires the targeted queued message
	# immediately — interrupts the current turn if one's in flight,
	# jumps the target to position 0 if it wasn't already, and
	# dispatches. `_cancel_current_turn` triggers prompt_finished,
	# which in turn calls `_dispatch_next_prompt` — so we don't have
	# to re-dispatch here when busy.
	if current_session_index < 0 or current_session_index >= sessions.size():
		return
	var session: Dictionary = sessions[current_session_index]
	var queue_variant = session.get("queued_prompts", [])
	if not (queue_variant is Array):
		return
	var queue: Array = queue_variant
	if index < 0 or index >= queue.size():
		return
	# Move the target to the head of the queue if it wasn't already.
	# Re-persist so the reorder survives an editor crash before the
	# message fires.
	if index > 0:
		var entry = queue[index]
		queue.remove_at(index)
		queue.insert(0, entry)
		session["queued_prompts"] = queue
		sessions[current_session_index] = session
	_refresh_queue_drawer()
	_refresh_queue_indicator()
	if bool(session.get("busy", false)):
		# Cancel the in-flight turn; prompt_finished will pop the
		# queue head (now our target) and send it.
		_cancel_current_turn(current_session_index)
	else:
		# Idle — dispatch directly.
		_dispatch_next_prompt(current_session_index)


func _on_queue_edit_pressed(index: int) -> void:
	# Pull the entry out of the queue and restore the composer to its
	# state at enqueue time: text, inline chips, attachment list. Anything
	# the user was currently typing gets dropped — same Zed behaviour
	# (edit pulls the queued message INTO the main editor, replacing
	# whatever was there).
	if current_session_index < 0 or current_session_index >= sessions.size():
		return
	var session: Dictionary = sessions[current_session_index]
	var queue_variant = session.get("queued_prompts", [])
	if not (queue_variant is Array):
		return
	var queue: Array = queue_variant
	if index < 0 or index >= queue.size():
		return
	var entry_variant = queue[index]
	if typeof(entry_variant) != TYPE_DICTIONARY:
		return
	var entry: Dictionary = entry_variant
	queue.remove_at(index)
	session["queued_prompts"] = queue
	# Restore attachments to session.attachments (for the chip overlay +
	# the next _send_prompt) before poking the composer, so the
	# composer's chip layer has the metadata it needs to reconstruct
	# chips on restore.
	var restored_attachments_variant = entry.get("attachments", [])
	var restored_attachments: Array = restored_attachments_variant.duplicate(true) if restored_attachments_variant is Array else []
	session["attachments"] = restored_attachments
	sessions[current_session_index] = session
	# Composer text + chips: build a draft dict shaped like
	# GodetteComposerPromptInput.serialize_draft's output so we can
	# reuse its restore_draft path unchanged.
	var inline_prompt := prompt_input as GodetteComposerPromptInput
	if inline_prompt != null:
		inline_prompt.clear_all()
		var display_text := str(entry.get("display_text", ""))
		var segments_variant = entry.get("segments", [])
		var segments: Array = segments_variant if segments_variant is Array else []
		_restore_composer_from_queue_entry(inline_prompt, display_text, segments, restored_attachments)
	_refresh_composer_context()
	_refresh_queue_drawer()
	_refresh_queue_indicator()


func _restore_composer_from_queue_entry(
	inline_prompt: GodetteComposerPromptInput,
	display_text: String,
	segments: Array,
	attachments: Array,
) -> void:
	# Walk the segment stream and replay it into the composer: text
	# segments go in verbatim, chip segments become insert_chip calls.
	# Attachments have already been restored to session.attachments
	# above, so insert_chip's underlying metadata lookup succeeds.
	var metadata_lookup: Dictionary = {}
	for attachment_variant in attachments:
		if typeof(attachment_variant) != TYPE_DICTIONARY:
			continue
		var attachment: Dictionary = attachment_variant
		var key := str(attachment.get("key", ""))
		if key.is_empty():
			continue
		metadata_lookup[key] = {
			"kind": str(attachment.get("kind", "")),
			"label": ComposerContextScript.display_label_for_attachment(attachment),
			"tooltip": ComposerContextScript.tooltip_for_attachment(attachment),
			"icon": _attachment_icon(attachment),
			"payload": _chip_payload_for_attachment(attachment),
		}

	if segments.is_empty():
		# No chip metadata available — restore as plain text.
		inline_prompt.text = display_text
		return

	for seg_variant in segments:
		if typeof(seg_variant) != TYPE_DICTIONARY:
			continue
		var seg: Dictionary = seg_variant
		var seg_type := str(seg.get("type", ""))
		if seg_type == "text":
			inline_prompt.insert_text_at_caret(str(seg.get("text", "")))
		elif seg_type == "chip":
			var key := str(seg.get("key", ""))
			if key.is_empty():
				continue
			var meta_variant = metadata_lookup.get(key, null)
			if typeof(meta_variant) != TYPE_DICTIONARY:
				continue
			var meta: Dictionary = meta_variant
			inline_prompt.insert_chip(
				key,
				str(meta.get("kind", "")),
				str(meta.get("label", "")),
				meta.get("icon", null),
				str(meta.get("tooltip", "")),
				meta.get("payload", {}),
			)


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
	if session_key == _current_session_scope_key():
		_refresh_plan_drawer()


func _on_plan_close_pressed(_session_key: String) -> void:
	# × actually clears the plan entries on the current session (not
	# just a UI-only dismissal). The old in-memory dismissal flag was
	# lost on editor reload, so a persisted plan came back every time.
	# Clearing matches the user's intent — "this plan is done, get it
	# out of here" — and the next _upsert_plan_entry (agent writes a
	# fresh TodoWrite) surfaces the drawer again with new content.
	if current_session_index < 0 or current_session_index >= sessions.size():
		return
	var session: Dictionary = sessions[current_session_index]
	session["plan_entries"] = []
	sessions[current_session_index] = session
	_touch_session(current_session_index)
	_refresh_plan_drawer()


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
	var is_in_progress: bool = status == "in_progress"

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)

	# Status indicator: editor theme icon when available (matches Zed's
	# TodoPending / TodoProgress / TodoComplete set), falling back to the
	# colored dot when the theme doesn't ship a suitable glyph. In-progress
	# gets a gentle continuous rotation so it reads as "active" at a
	# glance.
	var status_node := _build_plan_status_indicator(status)
	row.add_child(status_node)
	if is_in_progress:
		_attach_rotation_tween(status_node)

	# RichTextLabel + [s] BBCode: strike is drawn by TextServer
	# against the actual glyph run, not our hand-rolled measurement,
	# so endpoints land exactly at text edges regardless of font
	# side bearing. The Plan drawer sits outside the VirtualFeed
	# (the "no RTL in the message feed" rule applies to assistant /
	# user transcript rendering), so it's safe to use here.
	var task_label := RichTextLabel.new()
	task_label.bbcode_enabled = true
	task_label.fit_content = true
	task_label.scroll_active = false
	task_label.selection_enabled = false
	task_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	task_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	task_label.clip_contents = true

	var raw_content := _safe_text(str(plan_entry.get("content", "")))
	# Escape `[` so user-typed brackets don't get parsed as BBCode
	# tags. `]` alone isn't a tag opener, so it stays literal.
	var escaped := raw_content.replace("[", "[lb]")
	if is_completed:
		# Strike + dim via BBCode — `[s]` draws the strikethrough at
		# the font's underline metrics; `[color]` with alpha gives
		# the completed-task fade that the old Label used modulate
		# for.
		task_label.text = "[s][color=#ffffff8c]%s[/color][/s]" % escaped
	else:
		task_label.text = escaped

	row.add_child(task_label)

	return row


func _build_plan_status_indicator(status: String) -> Control:
	# Mirrors Zed's Plan panel icons one-to-one: same SVG shapes
	# (dashed ring for pending, dashed ring + center dot for
	# in_progress, solid ring + check for completed), colored via
	# editor theme tokens. The in_progress glyph spins via a Tween
	# on `rotation` — Zed does the same with a 2 s rotation
	# animation.
	var icon: Texture2D
	var color: Color
	match status:
		"completed":
			icon = TODO_COMPLETE_ICON
			color = _editor_color("success_color", "Editor", Color(0.34, 0.82, 0.47, 1.0))
		"in_progress":
			icon = TODO_PROGRESS_ICON
			color = _editor_color("accent_color", "Editor", Color(0.55, 0.78, 1.0, 1.0))
		_:
			icon = TODO_PENDING_ICON
			color = _editor_color("font_readonly_color", "Editor", Color(0.85, 0.85, 0.90, 0.55))

	# 14 px at 1.0 UI scale (same as Zed's `IconSize::Small`). Multiply
	# by EditorInterface's display scale so the glyph keeps pace with
	# the editor's font size — on a 150 % DPI setup we render at
	# 21 px, matching the Label font's visual weight instead of
	# shrinking into a tiny dot beside big text.
	var scale := 1.0
	if editor_interface != null:
		scale = editor_interface.get_editor_scale()
	var icon_px: float = 14.0 * scale
	var rect := TextureRect.new()
	rect.texture = icon
	rect.custom_minimum_size = Vector2(icon_px, icon_px)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.modulate = color
	rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return rect


func _editor_theme_icon(icon_name: String) -> Texture2D:
	if editor_interface == null:
		return null
	var theme: Theme = editor_interface.get_editor_theme()
	if theme == null:
		return null
	if theme.has_icon(icon_name, "EditorIcons"):
		return theme.get_icon(icon_name, "EditorIcons")
	return null


# Return the editor theme's font at the given slot (EditorFonts type).
# Slots used: "main", "bold", "italic", "source". Falls back to
# SystemFont with `weight` + `italic` trait hints when the editor theme
# is unavailable — keeps the plugin from crashing in standalone runs.
# The SystemFont fallback mirrors the editor's defaults (Inter for
# main/bold/italic, JetBrains Mono for source) via its font_names list.
func _editor_font(slot: String, fallback_weight: int, fallback_italic: bool) -> Font:
	if editor_interface != null:
		var theme: Theme = editor_interface.get_editor_theme()
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


func _attach_rotation_tween(node: Control) -> void:
	# Spin the TextureRect to match Zed's TodoProgress behaviour
	# (2 s per revolution, infinite loop). Deferred so the node is
	# inside the tree and its size is resolved before we compute
	# pivot_offset — otherwise the first frames rotate around (0, 0)
	# and the glyph drifts off its slot.
	call_deferred("_start_plan_rotation_for", node)


func _start_plan_rotation_for(node: Control) -> void:
	if node == null or not is_instance_valid(node):
		return
	if not node.is_inside_tree():
		return
	var pivot: Vector2 = node.size * 0.5
	if pivot == Vector2.ZERO:
		pivot = node.custom_minimum_size * 0.5
	node.pivot_offset = pivot
	node.rotation = 0.0
	var tween := node.create_tween().set_loops()
	# `.from(0.0)` resets the start of each loop — without it the
	# second revolution would tween "from TAU to TAU" (no motion)
	# because the previous loop left `rotation` at its end value.
	tween.tween_property(node, "rotation", TAU, 2.0).from(0.0)


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

	var inline_prompt := prompt_input as GodetteComposerPromptInput
	var prompt: String = ""
	# Segments capture the composer's inline chip layout so the user
	# bubble can render the chips interleaved with text (Zed-style).
	# Captured BEFORE clear_all so the chip metadata is still present.
	var prompt_segments: Array = []
	if inline_prompt != null:
		prompt = inline_prompt.get_plain_text().strip_edges()
		prompt_segments = inline_prompt.get_segments()
	else:
		prompt = prompt_input.text.strip_edges()
	# Allow attachment-only turns ("here's the file, help me read it") by
	# treating prompt_text+attachments as the real empty check, not just
	# the typed prose. The inline chips live in the text buffer but strip
	# to empty in get_plain_text(), so this matters.
	var attachments := _session_attachments(current_session_index)
	if prompt.is_empty() and attachments.is_empty():
		_append_system_message("Write a prompt first.")
		return

	var session: Dictionary = sessions[current_session_index]
	# Busy → enqueue and let `_on_connection_prompt_finished` pick it up
	# when the current turn ends. `_dispatch_next_prompt` already no-ops
	# while busy, so calling it unconditionally is safe.
	var blocks: Array = _build_prompt_blocks(prompt, attachments)
	# SceneTree focus context: when the eye is open and a node is
	# selected in the editor, append a text block describing that node
	# so the agent has implicit "what the user is looking at right now"
	# context without the user having to chip-attach it explicitly.
	var focus_block: Dictionary = _build_focus_context_block()
	if not focus_block.is_empty():
		blocks.append(focus_block)
	var queue: Array = session.get("queued_prompts", [])
	# Carry enough on the queue entry to support Zed's three per-row
	# actions (edit / send-now / delete):
	#   blocks       → what the ACP adapter sees on send
	#   display_text → single-line preview for the drawer
	#   segments     → composer text + inline-chip restore on edit
	#   attachments  → session.attachments restore on edit
	queue.append({
		"blocks": blocks,
		"display_text": prompt,
		"segments": prompt_segments.duplicate(true),
		"attachments": attachments.duplicate(true),
	})
	session["queued_prompts"] = queue
	session["managed_attachment_refs"] = _merge_managed_attachment_refs(
		session.get("managed_attachment_refs", []),
		attachments
	)
	sessions[current_session_index] = session

	# Composer is cleared on enqueue so the user can keep typing the
	# NEXT prompt immediately. The transcript's user-bubble, however,
	# only appears when the queued item actually dispatches to the
	# adapter — see `_dispatch_next_prompt`. Appending the bubble on
	# enqueue would interleave it into the still-streaming agent
	# response above, splitting that response into two transcript
	# entries around the user bubble.
	if inline_prompt != null:
		# Chips are one-shot, matching Zed's @-mention behaviour: once
		# the turn is sent the attachment is consumed and the composer
		# clears. If the user wants the same file / scene / image in
		# the next turn they re-attach (drag, paste, or @-mention). This
		# is less fiddly than having to manually backspace-delete a chip
		# you no longer want, and avoids the "why is this still here?"
		# surprise after send.
		inline_prompt.clear_all()
	else:
		prompt_input.clear()
	_set_session_attachments(current_session_index, [])
	_ensure_remote_session(current_session_index)
	_dispatch_next_prompt(current_session_index)
	_refresh_queue_indicator()
	_refresh_status()


func _on_send_button_pressed() -> void:
	if current_session_index < 0 or current_session_index >= sessions.size():
		return

	var session: Dictionary = sessions[current_session_index]
	# Three-way dispatch matching _refresh_send_state's icon choice:
	#   idle          → send
	#   busy + empty  → cancel the current turn
	#   busy + typed  → queue (route to _send_prompt, which already
	#                   handles "busy = enqueue" via queued_prompts)
	if bool(session.get("busy", false)) and not _composer_has_content():
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
	sessions[session_index] = session

	# Append the user-bubble to the transcript RIGHT before dispatching.
	# Done here — not in `_send_prompt` — so that prompts queued while
	# an earlier turn was still streaming don't interrupt the agent's
	# in-flight response and split it into two transcript entries.
	# `_append_user_message_to_session` resets assistant_entry_index,
	# which is exactly what we want once the current turn is done and
	# the next one is about to start.
	var prompt_text := str(next_prompt.get("display_text", ""))
	var prompt_segments_variant = next_prompt.get("segments", [])
	var prompt_segments: Array = prompt_segments_variant if prompt_segments_variant is Array else []
	_append_user_message_to_session(session_index, prompt_text, prompt_segments)

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
	connection.fs_write_completed.connect(Callable(self, "_on_connection_fs_write_completed"))

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
			var claude_code_global_cmd := npm_root.path_join("claude-code-acp.cmd")
			if not cmd_exe.is_empty() and FileAccess.file_exists(claude_code_global_cmd):
				candidates.append({"path": cmd_exe, "args": PackedStringArray(["/d", "/c", claude_code_global_cmd])})
			var claude_code_js := zed_root.path_join("claude-code-acp").path_join("dist").path_join("index.js")
			if FileAccess.file_exists(claude_code_js):
				candidates.append({"path": "node", "args": PackedStringArray([claude_code_js])})
			if not cmd_exe.is_empty() and FileAccess.file_exists(npx_cmd):
				candidates.append({"path": cmd_exe, "args": PackedStringArray(["/d", "/c", npx_cmd, "-y", "@zed-industries/claude-code-acp@0.16.2"])})
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
		candidates.append({"path": "claude-code-acp", "args": PackedStringArray()})
		candidates.append({"path": "npx", "args": PackedStringArray(["-y", "@zed-industries/claude-code-acp@0.16.2"])})
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
	_schedule_managed_attachment_cleanup()

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

	# During session/load replay, the adapter re-emits the full history as
	# session/update events. Our on-disk transcript cache is already the
	# authoritative copy of that history (we persisted it during the
	# original live turns), so ingesting the replay would double every
	# entry — and because replay doesn't carry clean turn boundaries,
	# agent chunks from adjacent turns would merge into one fat entry.
	# Suppress updates while replay is in flight; live events resume once
	# _on_connection_session_loaded clears the replay flag.
	var replay_key: String = "%s|%s" % [agent_id, remote_session_id]
	if replaying_sessions.has(replay_key):
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

	# Silently swallow normal terminations and user-initiated cancels —
	# Zed's thread view does the same (no "Turn cancelled" system
	# bubble after a Stop / Send Now interrupt; the stream just stops
	# mid-flight and the next turn starts clean). Only surface
	# stopReasons the user genuinely needs to know about
	# (max_tokens hits, adapter errors, etc).
	var stop_reason := str(result.get("stopReason", "done"))
	if stop_reason != "end_turn" and stop_reason != "cancelled" and stop_reason != "done":
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
	# Bash-initiated file writes (mkdir, cp, sed, etc.) bypass our
	# fs/write_text_file path and its targeted signal, so do a
	# catch-all scan once the turn ends. Coalesced with any per-write
	# scans already scheduled this frame.
	_schedule_editor_fs_scan()
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


func _on_connection_fs_write_completed(_agent_id: String, path: String) -> void:
	# Our fs/write_text_file handler drops bytes straight to disk,
	# bypassing Godot's resource system. Poke EditorFileSystem with
	# the specific path so the FileSystem dock updates without waiting
	# for the next editor-focus scan. `update_file` is cheap and
	# targeted — no full-project rescan needed for a single-file write.
	_update_editor_fs_file(path)


func _update_editor_fs_file(path: String) -> void:
	if editor_interface == null or path.is_empty():
		return
	var fs := editor_interface.get_resource_filesystem()
	if fs == null:
		return
	# EditorFileSystem expects `res://...` paths. OS-absolute paths that
	# resolve inside the project get mapped back via ProjectSettings.
	var resource_path := path
	if not resource_path.begins_with("res://"):
		resource_path = ProjectSettings.localize_path(path.replace("\\", "/"))
	if not resource_path.begins_with("res://"):
		return
	fs.update_file(resource_path)


# Coalesces bursts of filesystem changes (e.g. a turn that ran multiple
# Bash commands creating files outside our fs/write_text_file path) into
# a single full scan per frame. The targeted `update_file` above handles
# the common case; this catches the "agent shelled out and we don't know
# which files changed" case on prompt_finished.
func _schedule_editor_fs_scan() -> void:
	if editor_fs_scan_pending:
		return
	editor_fs_scan_pending = true
	call_deferred("_run_editor_fs_scan")


func _run_editor_fs_scan() -> void:
	editor_fs_scan_pending = false
	if editor_interface == null:
		return
	var fs := editor_interface.get_resource_filesystem()
	if fs == null:
		return
	# `scan()` is the catch-all. EditorFileSystem in Godot 4.6 doesn't
	# expose an incremental-only variant; this queues a full rescan,
	# which is relatively cheap for small-to-medium projects and is
	# the official API for picking up out-of-band filesystem changes.
	fs.scan()


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
	var newly_added: Array = []
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
		var attachment := {
			"key": key,
			"kind": "file",
			"label": normalized_path,
			"path": normalized_path
		}
		current_attachments.append(attachment)
		newly_added.append(attachment)

	_set_session_attachments(current_session_index, current_attachments)
	for attachment in newly_added:
		_insert_chip_for_attachment(attachment)
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

	var scene_attachment := {
		"key": key,
		"kind": "scene",
		"label": label,
		"scene_path": scene_path,
		"summary": _build_scene_summary(root)
	}
	current_attachments.append(scene_attachment)
	_set_session_attachments(current_session_index, current_attachments)
	_insert_chip_for_attachment(scene_attachment)
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
	var newly_added: Array = []
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
		var node_attachment := {
			"key": key,
			"kind": "node",
			"label": label,
			"relative_node_path": relative_path,
			"scene_path": root.scene_file_path if root != null else "",
			"summary": _describe_node(node)
		}
		current_attachments.append(node_attachment)
		newly_added.append(node_attachment)

	_set_session_attachments(current_session_index, current_attachments)
	for attachment in newly_added:
		_insert_chip_for_attachment(attachment)
	_refresh_status()


func clear_context() -> void:
	if current_session_index < 0:
		return

	_set_session_attachments(current_session_index, [])
	var inline_prompt := prompt_input as GodetteComposerPromptInput
	if inline_prompt != null:
		inline_prompt.remove_all_chips()
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
	# Ctrl+V of an image lands here. Normalize pasted rasters into a small,
	# predictable PNG before attaching them:
	# 1. cap the long side to 1568 px
	# 2. convert to RGBA8
	# 3. save as PNG
	# 4. reject files over 5 MB
	if current_session_index < 0 or image == null or image.is_empty():
		return
	if not DirAccess.dir_exists_absolute(PASTED_IMAGE_DIR):
		DirAccess.make_dir_recursive_absolute(PASTED_IMAGE_DIR)

	const ANTHROPIC_SIZE_LIMIT := 1568
	const MAX_IMAGE_BYTES := 5 * 1024 * 1024
	var image_w := image.get_width()
	var image_h := image.get_height()
	var longest_side := max(image_w, image_h)
	if longest_side > ANTHROPIC_SIZE_LIMIT:
		var downscale: float = float(ANTHROPIC_SIZE_LIMIT) / float(longest_side)
		image.resize(int(image_w * downscale), int(image_h * downscale), Image.INTERPOLATE_BILINEAR)

	# Normalise the pixel format before PNG save. Clipboard images can
	# arrive in a pile of Godot-internal formats (RGBA8, RGB8, RGBA4444,
	# RGF etc.) — forcing RGBA8 makes Godot's PngEncoder take the most
	# exercised code path and produces a stock 8-bit-per-channel PNG.
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)

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
	var saved_bytes := FileAccess.get_file_as_bytes(path).size()
	if saved_bytes > MAX_IMAGE_BYTES:
		DirAccess.remove_absolute(path)
		_append_system_message("Pasted image is too large (%d bytes) — try a smaller screenshot." % saved_bytes)
		return

	var key := "image:%s" % path
	var session_attachments := _session_attachments(current_session_index)
	if _attachments_has_key(session_attachments, key):
		return
	var image_attachment := {
		"key": key,
		"kind": "image",
		"label": filename,
		"path": path,
		"width": image.get_width(),
		"height": image.get_height()
	}
	session_attachments.append(image_attachment)
	_set_session_attachments(current_session_index, session_attachments)
	_insert_chip_for_attachment(image_attachment)
	_refresh_status()
	_schedule_persist_state()


func _composer_can_drop(_at_position: Vector2, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var kind := str(data.get("type", ""))
	return kind == "files" or kind == "nodes"


func _composer_drop(at_position: Vector2, data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	# Position the caret at the drop point before we insert chips so the
	# chip lands exactly where the user aimed — inline chips follow the
	# caret, so this is the only place that cares about `at_position`.
	# get_line_column_at_pos is tolerant of positions slightly outside the
	# text area (snaps to the nearest column), so no bounds check needed.
	#
	# `deselect()` afterwards is load-bearing: TextEdit marks a single-
	# character selection at the drag target while a drag is hovering, as
	# a drop indicator. If we leave that selection in place, the next
	# insert_text_at_caret call (inside insert_chip) REPLACES it — eating
	# the character the user dropped right next to.
	var inline_prompt := prompt_input as GodetteComposerPromptInput
	if inline_prompt != null:
		var drop_coord: Vector2i = inline_prompt.get_line_column_at_pos(Vector2i(at_position))
		inline_prompt.set_caret_line(drop_coord.y)
		inline_prompt.set_caret_column(drop_coord.x)
		inline_prompt.deselect()

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


func _build_focus_context_block() -> Dictionary:
	# Empty dict = "no focus context to inject". Returned when the eye
	# is closed, no node is selected, or the selected node has been
	# freed since last refresh.
	if not focus_include_enabled:
		return {}
	if focus_selected_node == null or not is_instance_valid(focus_selected_node):
		return {}
	var node := focus_selected_node
	var scene_root: Node = editor_interface.get_edited_scene_root() if editor_interface != null else null
	var lines: Array = []
	lines.append("Currently focused in the Scene Tree (implicit context — user had this node selected when sending):")
	lines.append("- Name: %s" % str(node.name))
	lines.append("- Class: %s" % node.get_class())
	var relative_path := "."
	if scene_root != null and node != scene_root and scene_root.is_ancestor_of(node):
		relative_path = str(scene_root.get_path_to(node))
	lines.append("- Path: %s" % relative_path)
	var script_variant = node.get_script()
	if script_variant is Script:
		var script_path := (script_variant as Script).resource_path
		if not script_path.is_empty():
			lines.append("- Script: %s" % script_path)
	var scene_file := node.scene_file_path if "scene_file_path" in node else ""
	if not scene_file.is_empty():
		lines.append("- Scene file: %s" % scene_file)
	lines.append("- Children: %d" % node.get_child_count())
	return {"type": "text", "text": "\n".join(lines)}


func _on_scene_selection_changed() -> void:
	_refresh_focus_indicator()


func _on_focus_eye_toggled(pressed: bool) -> void:
	# Toggle is "include in prompts". When pressed=true the eye reads
	# as open, icon + label show in full color; when false the whole
	# indicator dims so the user can still see WHICH node is focused
	# but understands it won't be sent.
	focus_include_enabled = pressed
	_refresh_focus_indicator()


func _on_focus_ring_gui_input(event: InputEvent) -> void:
	# The whole ring is a hot zone for the eye toggle — clicks that don't
	# land on the eye button itself still flip the include flag. Flipping
	# `button_pressed` routes through the button's `toggled` signal, so
	# `_on_focus_eye_toggled` runs exactly once and the icon swap stays in
	# sync with the state.
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and not mb.is_echo():
			if focus_eye_button != null:
				focus_eye_button.button_pressed = not focus_eye_button.button_pressed
			if focus_indicator_container != null:
				focus_indicator_container.accept_event()


func _refresh_focus_indicator() -> void:
	if focus_indicator_container == null or focus_path_label == null:
		return
	focus_indicator_container.visible = true

	# Eye button is always there; its icon swaps with the include flag.
	if focus_eye_button != null:
		var eye_open := _editor_theme_icon("GuiVisibilityVisible")
		var eye_closed := _editor_theme_icon("GuiVisibilityHidden")
		focus_eye_button.icon = eye_open if focus_include_enabled else eye_closed
		focus_eye_button.tooltip_text = (
			"Focus node is INCLUDED in the next prompt — click to ignore"
			if focus_include_enabled
			else "Focus node is IGNORED — click to include in the next prompt"
		)

	var selection = editor_interface.get_selection() if editor_interface != null else null
	var selected_nodes: Array = selection.get_selected_nodes() if selection != null else []

	if selected_nodes.is_empty():
		# No node selected — show the indicator in a muted state with a
		# placeholder so the user knows the feature exists and can
		# find the eye toggle. The eye still responds so the user can
		# flip the include-preference even before picking a node.
		focus_selected_node = null
		focus_icon_rect.texture = _editor_theme_icon("Node")
		focus_path_label.text = "No focus"
		focus_path_label.tooltip_text = "Select a node in the Scene Tree to attach it as context"
		focus_indicator_container.modulate = Color(1, 1, 1, 0.45)
		focus_indicator_container.set_active(false)
		return

	# Multi-select: show the first + a "(+N)" suffix. The focus context
	# injected on send still uses only the first, matching the
	# single-focus mental model.
	var primary: Node = selected_nodes[0]
	focus_selected_node = primary

	# Label shows the node's NAME (the leaf identifier, same text the
	# Scene Tree dock itself prints). Full path + class land in the
	# tooltip so the user can disambiguate when multiple nodes share a
	# name.
	var node_name: String = str(primary.name)
	var label_text: String = node_name
	if selected_nodes.size() > 1:
		label_text = "%s  (+%d)" % [label_text, selected_nodes.size() - 1]
	focus_path_label.text = label_text

	var scene_root: Node = editor_interface.get_edited_scene_root()
	var relative_path: String = "."
	if scene_root != null and primary != scene_root and scene_root.is_ancestor_of(primary):
		relative_path = str(scene_root.get_path_to(primary))
	focus_path_label.tooltip_text = "%s  ·  %s\nEye toggle decides whether this node is included in the next prompt." % [relative_path, primary.get_class()]

	# Icon: use editor-theme class icon for the node (Node2D / Button /
	# CollisionShape3D, etc), falling back to the generic Node glyph.
	var theme: Theme = editor_interface.get_editor_theme() if editor_interface != null else null
	if theme != null:
		var cls := primary.get_class()
		if theme.has_icon(cls, "EditorIcons"):
			focus_icon_rect.texture = theme.get_icon(cls, "EditorIcons")
		elif theme.has_icon("Node", "EditorIcons"):
			focus_icon_rect.texture = theme.get_icon("Node", "EditorIcons")

	# Grey out the whole indicator when the eye is closed so the user
	# sees at a glance that this selection won't be sent.
	focus_indicator_container.modulate = Color(1, 1, 1, 1) if focus_include_enabled else Color(1, 1, 1, 0.45)

	# Marching-ants ring animates only when the selection will actually
	# be injected (node selected AND eye open). Eye-closed keeps the
	# ring static so the animation doesn't compete with the dim modulate.
	var accent: Color = _editor_color("accent_color", "Editor", Color(0.55, 0.78, 1.0, 1.0))
	focus_indicator_container.set_stroke_color(accent)
	focus_indicator_container.set_active(focus_include_enabled)


func _refresh_composer_context() -> void:
	if composer_chip_overlay == null or prompt_input == null:
		return

	# Keep overlay styling in step with the editor theme in case the user
	# flips between dark / light themes at runtime.
	composer_chip_overlay.set_chip_base_color(
		_editor_color("base_color", "Editor", Color(0.22, 0.24, 0.28, 1.0)).lightened(0.08)
	)
	composer_chip_overlay.set_font_color(
		_editor_color("font_color", "Editor", Color(0.97, 0.97, 0.995, 0.98))
	)

	# The inline composer owns its own chip metadata — attach_paths /
	# attach_nodes / image_pasted already push insert_chip when the user
	# adds something, and backspace drives removal via chips_changed. The
	# only sync job left is converging the overlay's chip set with the
	# session's attachment list in edge cases (session switch, programmatic
	# clear) where the two can drift.
	var inline_prompt := prompt_input as GodetteComposerPromptInput
	if inline_prompt == null:
		return

	if current_session_index < 0:
		inline_prompt.clear_all()
		return

	var attachments: Array = _session_attachments(current_session_index)
	var desired_keys: Array = []
	var attachment_by_key: Dictionary = {}
	for attachment_variant in attachments:
		if typeof(attachment_variant) != TYPE_DICTIONARY:
			continue
		var attachment: Dictionary = attachment_variant
		var key := str(attachment.get("key", ""))
		if key.is_empty():
			continue
		desired_keys.append(key)
		attachment_by_key[key] = attachment

	var existing_keys := inline_prompt.get_chip_keys_in_order()
	var existing_set: Dictionary = {}
	for existing in existing_keys:
		existing_set[existing] = true
	var desired_set: Dictionary = {}
	for desired in desired_keys:
		desired_set[desired] = true

	# Drop chips the attachment list no longer carries (usually from a
	# programmatic clear; user-driven backspace already synced the other
	# direction via chips_changed).
	for existing_key in existing_keys:
		if not desired_set.has(existing_key):
			inline_prompt.remove_chip_by_key(existing_key)

	# Add chips that the attachment list has but the composer doesn't
	# (session switch restore, first-time attach from a code path that
	# didn't go through attach_*). New chips land at the caret, so push
	# the caret to end-of-buffer first.
	for desired_key in desired_keys:
		if existing_set.has(desired_key):
			continue
		var attachment: Dictionary = attachment_by_key[desired_key]
		_insert_chip_for_attachment(attachment)


# Resolves an attachment dict to the display bits the prompt input needs
# (label, icon, tooltip) and inserts a chip at the current caret position.
# Centralised so attach_paths / attach_nodes / image_pasted / context
# refresh all compute the same label + icon for a given attachment.
#
# Caret is deliberately NOT moved before insertion: Zed-style "attach at
# cursor" is the natural behaviour once chips are inline. Callers that
# want append-to-end semantics (session restore, context-refresh sync)
# position the caret themselves first; drag-drop positions it to the drop
# point. The common path — user pasting an image or dragging a file —
# ends up with a chip exactly where the text caret was, not teleported to
# the end of the prompt.
func _insert_chip_for_attachment(attachment: Dictionary) -> void:
	if prompt_input == null:
		return
	var inline_prompt := prompt_input as GodetteComposerPromptInput
	if inline_prompt == null:
		return
	var key := str(attachment.get("key", ""))
	if key.is_empty():
		return
	var label := ComposerContextScript.display_label_for_attachment(attachment)
	var tooltip := ComposerContextScript.tooltip_for_attachment(attachment)
	var icon := _attachment_icon(attachment)
	inline_prompt.insert_chip(
		key,
		str(attachment.get("kind", "")),
		label,
		icon,
		tooltip,
		_chip_payload_for_attachment(attachment)
	)


# Minimal slice of the attachment dict that the hover tooltip needs. Kept
# narrow so the prompt input doesn't end up holding onto unrelated session
# fields (summary bytes for attached scenes can get large).
func _chip_payload_for_attachment(attachment: Dictionary) -> Dictionary:
	return {
		"path": str(attachment.get("path", "")),
		"scene_path": str(attachment.get("scene_path", "")),
		"relative_node_path": str(attachment.get("relative_node_path", "")),
		"width": int(attachment.get("width", 0)),
		"height": int(attachment.get("height", 0)),
	}


# Builds a per-attachment display-bits lookup for restore_draft. The draft
# only stores codepoint→key bindings + the raw text buffer; the display
# metadata (icon, label, tooltip) is derived fresh from session attachments
# so a renamed / moved target picks up its new name on restore.
func _build_chip_metadata_lookup(session_index: int) -> Dictionary:
	var out: Dictionary = {}
	for attachment_variant in _session_attachments(session_index):
		if typeof(attachment_variant) != TYPE_DICTIONARY:
			continue
		var attachment: Dictionary = attachment_variant
		var key := str(attachment.get("key", ""))
		if key.is_empty():
			continue
		out[key] = {
			"kind": str(attachment.get("kind", "")),
			"label": ComposerContextScript.display_label_for_attachment(attachment),
			"tooltip": ComposerContextScript.tooltip_for_attachment(attachment),
			"icon": _attachment_icon(attachment),
			"payload": _chip_payload_for_attachment(attachment),
		}
	return out


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

	# Only rebuild the popup if it's actually on screen. When closed, the
	# next `_show_session_popup` call does a fresh populate anyway —
	# skipping work here keeps deletion / session-update bursts cheap.
	if session_popup != null and session_popup.visible:
		_populate_session_popup()


func _build_session_popup_groups() -> Array:
	# Mirrors the old PopupMenu layout: "Recently Updated" (capped at
	# RECENT_SESSION_LIMIT), followed by "All Sessions" for the remainder.
	# Using the same two-section structure keeps the user's spatial
	# memory ("this thread was near the top") stable across the refactor.
	var groups: Array = []
	if sessions.is_empty():
		return groups

	var recent_indices: Array = _recent_session_indices(RECENT_SESSION_LIMIT)
	var listed: Dictionary = {}
	var recent_group: Dictionary = {"header": "Recently Updated", "indices": []}
	for session_index_variant in recent_indices:
		var session_index: int = int(session_index_variant)
		recent_group["indices"].append(session_index)
		listed[session_index] = true
	if not recent_group["indices"].is_empty():
		groups.append(recent_group)

	if sessions.size() > recent_indices.size():
		var all_group: Dictionary = {"header": "All Sessions", "indices": []}
		for session_index in range(sessions.size()):
			if listed.has(session_index):
				continue
			all_group["indices"].append(session_index)
		if not all_group["indices"].is_empty():
			groups.append(all_group)

	return groups


func _populate_session_popup() -> void:
	if session_popup == null:
		return
	var context: Dictionary = {
		"editor_theme": editor_interface.get_editor_theme() if editor_interface != null else null,
		"agent_icon_for": Callable(self, "_session_popup_agent_icon"),
		"label_for": Callable(self, "_thread_menu_label"),
		"tooltip_for": Callable(self, "_thread_menu_tooltip"),
	}
	session_popup.populate(_build_session_popup_groups(), context)


func _session_popup_agent_icon(session_index: int) -> Texture2D:
	if session_index < 0 or session_index >= sessions.size():
		return null
	var agent_id: String = str(sessions[session_index].get("agent_id", DEFAULT_AGENT_ID))
	return _agent_icon_texture(agent_id, THREAD_MENU_AGENT_ICON_SIZE)


func _show_session_popup() -> void:
	if session_popup == null or thread_switcher_button == null:
		return
	_populate_session_popup()
	# Anchor under the history / switcher button so the popup reads as
	# belonging to the right-hand icon (visually clearer than anchoring to
	# the long title button).
	session_popup.popup_at_button(thread_switcher_button)


func _on_session_popup_chosen(session_index: int) -> void:
	_switch_session(session_index)


func _on_session_popup_delete_requested(session_index: int) -> void:
	# Set the reopen flag BEFORE showing the dialog. The dialog's
	# confirmed / canceled paths clear the flag and call
	# `_show_session_popup` again so the updated list pops back without
	# the user having to click the thread switcher a second time.
	session_popup_reopen_after_delete = true
	_confirm_delete_session(session_index)


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

	# Persistent children — focus indicator (left), spacer, send button
	# (right). Only the dynamic selector menus between them get rebuilt.
	for child in composer_options_bar.get_children():
		if child == send_button:
			continue
		if child == focus_indicator_container:
			continue
		if child == composer_options_spacer:
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
	# Three-state send button (matches Zed):
	#   idle               → Send (fires _send_prompt immediately)
	#   busy + has content → Queue (list-end icon; pressing enqueues)
	#   busy + empty       → Stop (cancels current turn)
	# "has content" means either typed text or at least one inline chip
	# on the prompt input, OR unsent attachments on the session.
	var has_content: bool = _composer_has_content()
	if busy:
		if has_content:
			send_button.icon = QUEUE_ICON
			send_button.tooltip_text = "Queue this prompt — sends when the current turn ends"
		else:
			send_button.icon = STOP_ICON
			send_button.tooltip_text = "Stop"
	else:
		send_button.icon = SEND_ICON
		send_button.tooltip_text = "Send"
	send_button.disabled = cancelling
	_refresh_queue_indicator()


func _composer_has_content() -> bool:
	if prompt_input == null:
		return false
	var inline_prompt := prompt_input as GodetteComposerPromptInput
	if inline_prompt != null:
		if not inline_prompt.get_plain_text().strip_edges().is_empty():
			return true
		if not inline_prompt.get_chip_keys_in_order().is_empty():
			return true
	else:
		if not prompt_input.text.strip_edges().is_empty():
			return true
	if current_session_index >= 0 and current_session_index < sessions.size():
		var attachments := _session_attachments(current_session_index)
		if not attachments.is_empty():
			return true
	return false


func _refresh_queue_indicator() -> void:
	# Queue state now lives in the expandable queue_drawer above the
	# composer (matches Zed). The old composer-options-bar `N queued`
	# label has been superseded — this function just forwards to
	# `_refresh_queue_drawer` so every historical caller keeps driving
	# the new UI without touching call sites.
	_refresh_queue_drawer()


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
			"managed_attachment_refs": [],
			"transcript": [],
			"assistant_entry_index": -1,
			"plan_entries": [],
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
			"updated_at": _timestamp_msec_from_iso(str(remote_session.get("updatedAt", ""))),
			"created_at": _timestamp_msec_from_iso(str(remote_session.get("createdAt", remote_session.get("updatedAt", "")))),
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
		"managed_attachment_refs": [],
		"transcript": [],
		"assistant_entry_index": -1,
		"plan_entries": [],
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
		"updated_at": _now_tick(),
		"created_at": _now_tick(),
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
	var inline_prompt := prompt_input as GodetteComposerPromptInput
	# Capture the outgoing session's composer state (typed text + chip
	# bindings) so switching back restores exactly what the user was
	# looking at. Chip metadata itself is re-derived from the session's
	# attachments on restore — the draft only needs to remember WHICH
	# chips were placed where.
	if inline_prompt != null and previous_session_index != index \
			and previous_session_index >= 0 and previous_session_index < sessions.size():
		sessions[previous_session_index]["composer_draft"] = inline_prompt.serialize_draft()
	if previous_session_index != index and previous_session_index >= 0 and previous_session_index < sessions.size():
		SessionStoreScript.dehydrate(sessions[previous_session_index])
	SessionStoreScript.hydrate(sessions[index])

	current_session_index = index
	selected_agent_id = str(sessions[index].get("agent_id", DEFAULT_AGENT_ID))

	# Restore the incoming session's draft (if any) before the refresh
	# passes run — _refresh_composer_context will then diff chip state
	# against session.attachments and no-op if the restore already matches.
	if inline_prompt != null:
		var draft_variant = sessions[index].get("composer_draft", {})
		if typeof(draft_variant) == TYPE_DICTIONARY and not (draft_variant as Dictionary).is_empty():
			inline_prompt.restore_draft(draft_variant, _build_chip_metadata_lookup(index))
		else:
			inline_prompt.clear_all()

	_refresh_thread_menu()
	_refresh_add_menu()
	_refresh_composer_context()
	_refresh_chat_log()
	_refresh_plan_drawer()
	_refresh_queue_drawer()
	_refresh_composer_options()
	_refresh_send_state()
	_refresh_status()
	_ensure_remote_session(index)
	_schedule_persist_state()


func _append_user_message_to_session(session_index: int, text: String, segments: Array = []) -> void:
	_append_transcript_to_session(session_index, "You", text, segments)
	# Capture the first user message as a derived title on the session
	# metadata so the thread menu shows real content (not "Session 14")
	# for sessions other than the currently hydrated one. Only set it
	# ONCE — the session's identity is anchored to its first message,
	# not the latest.
	if session_index < 0 or session_index >= sessions.size():
		return
	var session: Dictionary = sessions[session_index]
	if str(session.get("derived_title", "")).strip_edges().is_empty():
		var snippet := _snippet_from_user_text(text)
		if not snippet.is_empty():
			session["derived_title"] = snippet
			sessions[session_index] = session
			_schedule_persist_state()


func _snippet_from_user_text(text: String) -> String:
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return ""
	var newline_index := trimmed.find("\n")
	if newline_index >= 0:
		trimmed = trimmed.substr(0, newline_index).strip_edges()
	const MAX_SNIPPET_CHARS := 48
	if trimmed.length() > MAX_SNIPPET_CHARS:
		trimmed = trimmed.substr(0, MAX_SNIPPET_CHARS).strip_edges() + "…"
	return trimmed


func _append_system_message(text: String) -> void:
	if current_session_index >= 0:
		_append_transcript_to_session(current_session_index, "System", text)


func _append_system_message_to_agent(agent_id: String, text: String) -> void:
	var target_index := _find_latest_session_index_by_agent(agent_id)
	if target_index >= 0:
		_append_transcript_to_session(target_index, "System", text)


func _append_transcript_to_session(session_index: int, speaker: String, text: String, segments: Array = []) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return

	var session: Dictionary = sessions[session_index]
	var current_transcript: Array = session.get("transcript", [])
	var entry: Dictionary = {
		"kind": _entry_kind({"speaker": speaker}),
		"speaker": speaker,
		"content": text
	}
	# Only user messages carry segments today; the renderer falls back to
	# `content` whenever `segments` is absent, which keeps assistant /
	# system / tool entries unchanged and makes older transcripts (saved
	# before this field existed) render as plain text.
	if not segments.is_empty():
		entry["segments"] = segments
	current_transcript.append(entry)
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
	session["plan_entries"] = normalized_entries

	# A fresh plan update un-dismisses the drawer — users expect the panel
	# to reappear when the agent actually changes its plan, even if they
	# × closed the previous version.
	var session_scope_key := "%s|%s" % [
		str(session.get("agent_id", DEFAULT_AGENT_ID)),
		str(session.get("remote_session_id", "")),
	]
	plan_dismissed_sessions.erase(session_scope_key)

	sessions[session_index] = session
	_touch_session(session_index)

	if session_index == current_session_index:
		_refresh_plan_drawer()


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
	# Cleanup only fires on dock startup and session deletion. Per-change
	# scanning every time attachments mutate (add, remove, send-consume)
	# is wasted disk I/O: orphans can wait until the next startup, and
	# attachments in active sessions must be kept alive anyway.


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
		elif kind == "image":
			# Pasted images live in a `.gdignore`d scratch dir so the
			# Godot resource loader can't open them; shell out to the OS
			# default viewer instead.
			var img_path := str(attachment.get("path", ""))
			if img_path.begins_with("res://") or img_path.begins_with("user://"):
				img_path = ProjectSettings.globalize_path(img_path)
			if not img_path.is_empty():
				OS.shell_open(img_path)
		elif kind == "scene":
			_open_path(str(attachment.get("scene_path", "")))
		elif kind == "node":
			_focus_attached_node(str(attachment.get("relative_node_path", ".")))
		return


# Fired by prompt_input whenever the text buffer's chip set or order
# changes from a user edit (backspace at run end, delete-forward at run
# start, selection-spanning delete). The authoritative chip set now lives
# in the text buffer, so we sync session["attachments"] to match — drop
# missing keys, reorder survivors to chip order for prompt-block
# consistency.
func _on_composer_chips_changed(ordered_keys: Array) -> void:
	if current_session_index < 0:
		return
	var attachments := _session_attachments(current_session_index)
	if attachments.is_empty() and ordered_keys.is_empty():
		return

	var by_key: Dictionary = {}
	for attachment_variant in attachments:
		if typeof(attachment_variant) != TYPE_DICTIONARY:
			continue
		var attachment: Dictionary = attachment_variant
		by_key[str(attachment.get("key", ""))] = attachment

	var reordered: Array = []
	for key_variant in ordered_keys:
		var key := str(key_variant)
		if by_key.has(key):
			reordered.append(by_key[key])

	# Short-circuit when nothing actually changed to avoid firing persist
	# timers on caret-only edits. Length + key order comparison is enough
	# since content dicts are shared by reference.
	if reordered.size() == attachments.size():
		var identical := true
		for i in reordered.size():
			if str(reordered[i].get("key", "")) != str(attachments[i].get("key", "")):
				identical = false
				break
		if identical:
			return

	_set_session_attachments(current_session_index, reordered)
	_refresh_status()
	_refresh_send_state()
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


func _confirm_delete_session(session_index: int) -> void:
	if session_index < 0 or session_index >= sessions.size():
		return
	var session: Dictionary = sessions[session_index]
	var title := _session_display_title(session)

	# ConfirmationDialog as a child of the dock so it inherits the
	# editor theme + gets cleaned up when the dock is freed. Binding
	# `session_index` into the confirmed handler freezes the target
	# so a later `_refresh_thread_menu` re-ordering can't shift
	# which session gets evicted after the user has already decided.
	var dialog := ConfirmationDialog.new()
	dialog.title = "Delete Thread"
	dialog.dialog_text = "Delete thread \"%s\"?\n\nThis removes the transcript from disk and can't be undone." % title
	dialog.ok_button_text = "Delete"
	dialog.get_ok_button().modulate = Color(1.0, 0.55, 0.55, 1.0)
	add_child(dialog)
	var target_index := session_index
	dialog.confirmed.connect(func():
		_evict_session(target_index)
		dialog.queue_free()
		_maybe_reopen_session_popup_after_delete()
	)
	dialog.canceled.connect(func():
		dialog.queue_free()
		_maybe_reopen_session_popup_after_delete()
	)
	dialog.close_requested.connect(func():
		dialog.queue_free()
		_maybe_reopen_session_popup_after_delete()
	)
	dialog.popup_centered()


func _maybe_reopen_session_popup_after_delete() -> void:
	# Only reopen if the delete originated from a row in the session
	# popup. Deletes triggered from other entry points (if any are added
	# later) won't force the popup to appear unsolicited.
	if not session_popup_reopen_after_delete:
		return
	session_popup_reopen_after_delete = false
	# Deferred so the dialog's Window finishes tearing down before we
	# try to open our own popup — on some platforms showing a new popup
	# in the same frame as a dialog close causes the new one to inherit
	# the "closing" state and never appear.
	call_deferred("_show_session_popup")


func _on_thread_switcher_pressed() -> void:
	# The switcher icon and the thread title button both open the same
	# session popup — one source of truth, anchored under the switcher so
	# the popup reads as coming from the right-hand icon.
	_show_session_popup()


func _on_add_menu_id_pressed(item_id: int) -> void:
	if item_id < ADD_MENU_AGENT_ID_OFFSET:
		return

	var agent_index: int = item_id - ADD_MENU_AGENT_ID_OFFSET
	if agent_index < 0 or agent_index >= AGENTS.size():
		return

	selected_agent_id = str(AGENTS[agent_index]["id"])
	_refresh_add_menu()
	_create_session(selected_agent_id, true, true)


